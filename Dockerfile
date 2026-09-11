# syntax=docker/dockerfile:1
###############################################################################
#  DeepSeek Harness (dsh) — Web UI container, HTTPS front door built in
#
#    image    dockorae/deepseek-harness
#    upstream @deepseek-ai/dsh (pinned below; the CLI boots the `web` profile)
#
#  Shape
#    browser --https://<host>:8443--> Caddy [TLS + optional basic auth]
#                                       `--http://127.0.0.1:3080--> dsh
#
#  Everything the container needs is baked in here: the bind patch below, the
#  one-predicate client fix, and the entrypoint. The repository therefore holds
#  no loose patch files — Dockerfile + docker-compose.yml + .env.example is the
#  whole deployment.
#
#  Four upstream behaviours are handled (evidence in README.md):
#    1. the shipped `webserver` row binds 127.0.0.1 and the web app's flag parser
#       refuses `--host 0.0.0.0`
#         -> /opt/dsh/patches/lan-web.yml (written below) restates the row with
#            an all-interfaces fallback; the entrypoint passes it as --patch
#    2. the browser half derives `isLoopback` from the page's own hostname, so a
#       LAN or proxied page silently loses the settings/models surface
#         -> the one predicate is flipped here and re-checked at start; the /api
#            Host fence in the sibling lib/index.js stays untouched
#    3. /api trusts loopback plus the process' own interface IPs, which are
#       bridge addresses in a container
#         -> the entrypoint declares HTTPS_ACCESS_HOST / DSH_TRUSTED_HOSTS
#    4. the client-HMR chain needs Node internals whose native fallback addon
#       cannot resolve its prebuilt on a read-only rootfs
#         -> /usr/local/bin/dsh wraps node with --expose-internals
###############################################################################
FROM node:22-bookworm-slim

# Pinned upstream release. Bump both together and re-verify the patches.
ARG DSH_VERSION=0.1.5-rc.1
ARG PNPM_VERSION=11.8.0

LABEL org.opencontainers.image.title="deepseek-harness" \
      org.opencontainers.image.description="DeepSeek Harness (dsh) web UI in one container: HTTPS + optional basic auth on 8443 via built-in Caddy, all-interfaces bind through the profile patch layer, pinned upstream ${DSH_VERSION}." \
      org.opencontainers.image.source="https://github.com/MinimaxFlora/deepseek-harness" \
      org.opencontainers.image.url="https://hub.docker.com/r/dockorae/deepseek-harness" \
      org.opencontainers.image.version="${DSH_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    HOME=/data/dsh \
    DSH_HOME=/data/dsh \
    DSH_WORKSPACE=/workspace \
    DSH_PORT=3080 \
    DSH_HOST=0.0.0.0 \
    DSH_HTTPS=1 \
    HTTPS_PORT=8443 \
    DSH_TELEMETRY_DISABLED=1 \
    XDG_DATA_HOME=/data/caddy/data \
    XDG_CONFIG_HOME=/data/caddy/config

# caddy = the HTTPS/auth front door; the rest is the shell tooling the harness'
# bash tool expects. tini is PID 1 so both processes stop cleanly.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      caddy ca-certificates curl git jq ripgrep procps less unzip xz-utils \
      tini iproute2 \
 && rm -rf /var/lib/apt/lists/*

# The harness targets Node ^22.19.0 || >=24; fail the build if the base drifts.
RUN node -e "const [maj,min]=process.versions.node.split('.').map(Number); \
      if (!((maj === 22 && min >= 19) || maj >= 24)) { \
        console.error('node ' + process.versions.node + ' is outside the supported range'); process.exit(1); }" \
 && node -v && caddy version

# Pinned upstream CLI + pnpm (`dsh plugin` forwards to pnpm inside the profile).
RUN npm install -g --no-fund --no-audit "pnpm@${PNPM_VERSION}" "@deepseek-ai/dsh@${DSH_VERSION}" \
 && npm cache clean --force

# `dsh` becomes a wrapper that always passes --expose-internals.
#
# The client-HMR chain requires Node internals: cordis-plugin-hmr throws
# `--expose-internals is required for HMR service` unless cordis resolved its
# internal loader. Upstream's fallback for that is the native
# `node-addon-require-builtin`, which needs writable state to pick up its
# prebuilt binding — not guaranteed on this image's intended `read_only: true`
# rootfs (it failed there with "No usable native binding found for
# node-addon-require-builtin-linux-x64-gnu"). The flag is the primary path, and
# Node tolerates a repeat of it, so every entry point goes through this wrapper.
RUN rm -f /usr/local/bin/dsh \
 && printf '%s\n' \
      '#!/bin/sh' \
      '# dsh wrapper: keep the HMR chain working on a read-only root filesystem.' \
      'exec node --expose-internals /usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js "$@"' \
      > /usr/local/bin/dsh \
 && chmod +x /usr/local/bin/dsh \
 && dsh --version

# ── the bind patch ───────────────────────────────────────────────────────────
# The shipped `webserver` row binds 127.0.0.1 and the CLI refuses the
# all-interfaces literal on purpose. A patch layer replaces the row's whole
# `config`, so every key the row owns is restated here, and the `!!js`
# expression keeps `--host` / `--port` winning when the invocation names them.
COPY <<'YAML' /opt/dsh/patches/lan-web.yml
# Bind all interfaces (managed by the container image; see the Dockerfile).
- id: webserver
  config:
    host: !!js ctx.webStartup.host ?? '0.0.0.0'
    port: !!js ctx.webStartup.port ?? 3080
    compression: gzip
    compressionLevel: 1
    compressionThresholdBytes: 1024
YAML

# ── the browser-side origin gate ─────────────────────────────────────────────
# `isLoopback` is derived from the page's own hostname, so a LAN or proxied page
# silently degrades the settings surface ("settings are unavailable in this
# browser") and no model can be configured. Flip that one predicate; the real
# /api Host fence lives in the sibling lib/index.js and must survive.
RUN set -e; \
    CLIENT=$(find /usr/local/lib/node_modules -path '*/@deepseek-ai/dsh-client-connection/lib/client.js' -print -quit); \
    if [ -z "$CLIENT" ]; then echo "[patch] FATAL: client bundle not found"; exit 1; fi; \
    if grep -q 'isLoopbackHostname(pageLocation.hostname)' "$CLIENT"; then \
      cp -n "$CLIENT" "$CLIENT.orig" || true; \
      sed -i 's/|| isLoopbackHostname(pageLocation.hostname),/|| true,/' "$CLIENT"; \
    fi; \
    grep -q 'isLoopback: .*|| true,' "$CLIENT" || { echo "[patch] FATAL: predicate not flipped"; exit 1; }; \
    FENCE="${CLIENT%/*}/index.js"; \
    grep -q 'isLoopbackHostname(hostUrl.hostname)' "$FENCE" || { echo "[patch] FATAL: /api fence missing"; exit 1; }; \
    echo "[patch] client bundle flipped: $CLIENT"; \
    echo "[patch] /api Host fence intact: $FENCE"

COPY scripts/entrypoint.sh /opt/dsh/scripts/entrypoint.sh
RUN chmod +x /opt/dsh/scripts/entrypoint.sh

WORKDIR /workspace
# Everything writable lives in the volumes: /data (harness home + caddy data) and
# /workspace. The image itself is meant to run with `read_only: true`.
VOLUME ["/data"]
EXPOSE 8443 3080

# No `curl -f`: the UI is token-gated, so a bare request answers 401 before
# anyone signs in and -f would turn that into a failure forever. 200 (cookie),
# 303 (token exchange) and 401 (up and asking) all mean the process is serving.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:3080/ | grep -qE '^(200|303|401)$'

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/opt/dsh/scripts/entrypoint.sh"]
