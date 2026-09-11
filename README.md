# DeepSeek Harness — Docker（HTTPS 前门 + 局域网可用）

[![Docker Hub](https://img.shields.io/badge/docker-dockorae%2Fdeepseek--harness-2496ED?logo=docker&logoColor=white)](https://hub.docker.com/r/dockorae/deepseek-harness)
[![Upstream](https://img.shields.io/badge/upstream-%40deepseek--ai%2Fdsh%200.1.5--rc.1-4D6BFE)](https://www.npmjs.com/package/@deepseek-ai/dsh)
[![License](https://img.shields.io/badge/license-MIT-2EA44F)](LICENSE)

一个容器跑起 DeepSeek Harness（`dsh`）的官方 Web UI：**镜像内自带 Caddy 做 HTTPS（8443）**，
dsh 本体按局域网可用打好补丁（自动绑 `0.0.0.0`、`/api` 前门围栏、`--expose-internals`），
认证用 dsh 自带的 token + cookie，数据全部落在 `./data` 下。

```
浏览器 ──https://<HTTPS_ACCESS_HOST>:8443──▶ Caddy（TLS）
                                              └─http://127.0.0.1:3080─▶ dsh web
```

镜像：`dockorae/deepseek-harness:0.1.5-rc.1`（也打了 `latest`）。

---

## 一键脚本

```sh
# 交互菜单（推荐）：域名 / IP、端口 / 镜像 tag 向导式配置，部署完打印部署信息
bash <(curl -fsSL https://raw.githubusercontent.com/MinimaxFlora/deepseek-harness/main/install.sh)

# 或者先下载再跑
curl -fsSLO https://raw.githubusercontent.com/MinimaxFlora/deepseek-harness/main/install.sh
sudo bash install.sh
```

脚本会：检查环境 → 自动装 Docker（国内走私有源镜像）→ 向导式配置 → 拉镜像 → 启动 →
等到 `healthy`，然后打印一条**成框的部署信息**（镜像 / 访问地址 / 首次登录链接 / 数据目录 /
管理命令 / 常用命令），并安装管理命令 `dsh-harness`
（菜单 / 状态 / 日志 / 访问入口 / 重新配置 / 更新 / 备份 / 卸载）。

**认证走 dsh 自带的 token**，不做 Basic Auth：部署完把打印出来的 `https://…/?token=…`
打开一次换持久 cookie，之后直接访问站点根地址。

```sh
dsh-harness                 # 交互菜单
dsh-harness status          # 运行状态
dsh-harness config          # 改域名 / 端口 / 镜像 tag 并重建
dsh-harness url             # 打印 HTTPS 入口 + 带 token 的首次登录地址
dsh-harness update          # 拉最新镜像并重建
```

**域名还是 IP？**

| 选择 | 证书 | 端口 | 说明 |
| --- | --- | --- | --- |
| 填域名 | Let's Encrypt，容器内 Caddy 自动申请 | 映射 80 + 443 | 需要域名 A 记录指向本机公网 IP；脚本申请前会校验解析并提示 |
| 填 IP（默认） | 容器内部 CA 自签 | 默认映射 8443 | **脚本默认探测公网 IP 并作为访问地址**，探不到才退回内网 IP；浏览器提示一次风险，继续即可 |

用环境变量跳过向导：

```sh
DSH_DOMAIN=dsh.example.com DSH_ACME_EMAIL=me@example.com sudo -E bash install.sh install                      # 域名 + Let's Encrypt

DSH_HOST=203.0.113.10 DSH_HTTPS_PORT=8443 sudo -E bash install.sh install   # 公网 IP + 自签
DSH_HOST=192.168.1.10 DSH_HTTPS_PORT=8443 sudo -E bash install.sh install   # 内网 IP + 自签
```

`.env` 里对应 `HTTPS_ACCESS_HOST`：**填域名 = 真证书，填 IP 或留空 = 自签**（留空时先探公网 IP，探不到再用内网 IP）。

### 手动部署（不用脚本）

```sh
git clone https://github.com/MinimaxFlora/deepseek-harness.git
cd deepseek-harness
cp .env.example .env            # 改 HTTPS_ACCESS_HOST（IP 或域名）
docker compose up -d
docker compose logs -f deepseek-harness
```

`.env` 里最小要改的一行：

```sh
HTTPS_ACCESS_HOST=192.168.1.10      # 你的宿主机局域网 IP 或域名
```

然后打开 `https://192.168.1.10:8443/`（自签证书，浏览器会警告一次，继续即可）。

用现成镜像（不构建）：

```sh
docker run -d --name deepseek-harness --restart unless-stopped \
  -p 8443:8443 \
  -e HTTPS_ACCESS_HOST=192.168.1.10 \
  -e DSH_TELEMETRY_DISABLED=1 \
  -v "$PWD/data/dsh:/data/dsh" \
  -v "$PWD/data/workspace:/workspace" \
  -v "$PWD/data/caddy:/data/caddy" \
  --read-only --tmpfs /tmp:mode=1777,size=256m \
  --security-opt no-new-privileges:true \
  dockorae/deepseek-harness:0.1.5-rc.1
```

首次登录：dsh 自带 token 认证。访问一次带 token 的地址（`dsh-harness url` 会按你的部署地址拼好
打印），浏览器拿到持久 cookie，之后直接进根地址即可。token 每次重启都会换。

---

## HTTPS 与认证

| 场景 | 配置 | 说明 |
| --- | --- | --- |
| 内网 IP（默认） | `DSH_TLS_MODE=internal` | Caddy 内部 CA 按请求的域名/IP **现场签发自签证书**，所以浏览器输什么 IP 都能开（有警告） |
| 真域名 + 自动证书 | `DSH_TLS_MODE=acme`、`HTTPS_ACCESS_HOST=dsh.example.com`、`DSH_HTTPS_PORT=443` | Let's Encrypt 需要 80/443 可达，建议前面再放一层反代 |
| 自带证书 | `DSH_TLS_MODE=files` + `DSH_TLS_CERT` / `DSH_TLS_KEY` | 证书和私钥挂进 `/data/caddy/tls/` |
| 关掉 HTTPS | `DSH_HTTPS=0` | 只跑 dsh，直接暴露 3080（compose 里有注释掉的端口映射） |

> ⚠️ 安全提醒：这个 UI 能执行 shell 命令（它就是一个编码 agent）。绑 `0.0.0.0` + 对外端口等于
> 把远程代码执行能力暴露出去——这也是上游拒绝 `--host 0.0.0.0` 的原因。认证只有 dsh 的
> token + cookie 这一层（`SameSite=Strict`、绑定 authority），所以**公网部署别把带 token 的链接外发**；
> 要更强的边界就在外面自己再套一层反代认证（Basic Auth / SSO / IP 白名单都行）。

---

## 为什么需要补丁

`dsh` 在「非回环访问」这件事上有三道独立闸门，缺一个都会以不同方式坏掉。本镜像逐条处理，
下面是上游源码里的证据。

### 1. 绑定：CLI 拒绝 `--host 0.0.0.0`

`@deepseek-ai/dsh-web-app/lib/startup.js`：

```js
if (options.host === "0.0.0.0") program.error(
  "error: --host 0.0.0.0 is intentionally not supported yet for safety: " +
  "it would expose remote code execution to the network; use 127.0.0.1 instead");
```

而 `webserver` 行自己也是回环默认（`dsh-web-app/cordis.patch.yml`）：

```yaml
- id: webserver
  config:
    host: !!js ctx.webStartup.host ?? '127.0.0.1'
```

**做法**：用上游支持的 patch 层（镜像内的 `/opt/dsh/patches/lan-web.yml`，由 Dockerfile 生成，
启动时作为 `--patch` 覆盖层传入）。patch 替换整行 `config`，所以该行拥有的每个键都原样重述；
`!!js` 保留，`--host`/`--port` 依然优先。由此 `host: ... ?? '0.0.0.0'`。

顺带说明为什么入口脚本不传 `--host 0.0.0.0`：上行 schema 只接受两个字面量 ——

```js
host: z.union([z.const("127.0.0.1"), z.const("0.0.0.0")]).required()   // dsh-host-webserver
```

### 2. 浏览器端 origin 门禁（「模型/设置页选不了」的真凶）

`@deepseek-ai/dsh-client-connection/lib/client.js`：

```js
isLoopback: transport?.ownsHost === true || pageLocation === void 0 ||
  isLoopbackHostname(pageLocation.hostname),
```

`isLoopbackHostname` 只认 `localhost` / `[::1]` / `127.x.x.x`，也就是说**由地址栏决定**；为
`false` 时消费方（`dsh-client-ui-settings` 等）静默降级为进程内存储，界面报：

> 加载提供方目录失败：settings are unavailable in this browser

反代/局域网场景必然命中，服务端配置救不了浏览器端判断。镜像**构建时**就把这一处谓词改成
`|| true,`（`docker exec … grep` 可验证），启动时再校验一次并在容器可写时自动修复，**并且刻意
不碰**同包 `lib/index.js` 里的真围栏：

```js
if (!isLoopbackHostname(hostUrl.hostname) && !isTrustedAuthority(hostUrl, trustedHosts)) return false;
```

脚本每次都会断言这道围栏还在，否则构建直接失败。不想要这一改：`DSH_LAN_CLIENT_PATCH=0`。

### 3. `/api` 的 Host 信任围栏

围栏信任：①回环地址、②**本进程网卡**采到的 IPv4 字面量、③显式声明的 authority（`host:port`
精确匹配，或**不带端口匹配任意端口**）。容器里 ② 只有 `172.17.x.x`，而浏览器发来的是域名或
宿主机/公网 IP —— 一旦你访问的地址和 `HTTPS_ACCESS_HOST` 不一致，**页面能打开、但所有 `/api`
请求返回 403**（界面表现为「加载提供方目录失败：llm/listProviders failed: HTTP 403」）。

镜像默认的处理方式：**入口把上游 Host 归一化成回环**（`header_up Host 127.0.0.1:3080`，同时
去掉 Origin），这样浏览器输什么地址都能用：

- 归一化只发生在这条容器内部的 Caddy→dsh 链路上，而 `dsh` 的 3080 **不对外发布**，所以
  直接打到 3080 的请求仍然走完整围栏，DNS rebinding 防护没有削弱；
- 跨站攻击仍被 `SameSite=Strict` 的认证 cookie 拦在门外；
- 想恢复上游原样行为（只认回环 + 容器 IP + 你声明的 authority）：`DSH_STRICT_HOST_FENCE=1`，
  此时必须保证 `HTTPS_ACCESS_HOST` / `DSH_TRUSTED_HOSTS` 与浏览器地址完全一致。

> 切换这个开关会换掉 cookie 的绑定 authority，切完需要重新打开一次带 token 的地址
> （`dsh-harness url` 会直接打印一个可用的登录链接）。

---

## 数据目录

全部在 `./data` 下，容器重建不丢：

| 宿主路径 | 容器路径 | 内容 |
| --- | --- | --- |
| `./data/dsh` | `/data/dsh`（`$DSH_HOME`） | 会话、`settings.yaml`、`.credentials.yaml`、profile、插件 |
| `./data/workspace` | `/workspace` | agent 的工作目录（cwd 即工作区根） |
| `./data/caddy` | `/data/caddy` | Caddyfile（每次启动重写）、内部 CA 根与证书、TLS 文件 |

根文件系统是**只读**的（`read_only: true`）+ `tmpfs /tmp` + `no-new-privileges`，所以镜像之外的
可写面只有上面三个卷。两条与之相关的约定：

- `HOME` 指向 `/data/dsh`（卷内），不是 `/data` —— 容器只读时，进程往 HOME 写的缓存/凭据回退
  才有地方落。如果你把卷挂到别处，记得让 `HOME` 也跟着落在可写目录里。
- 镜像内的 `dsh` 是个包装脚本，固定带上 `--expose-internals`：harness 的 client-HMR 链要求
  Node 内部模块（`cordis-plugin-hmr` 会抛 `--expose-internals is required for HMR service`），
  而上游的原生回退 addon `node-addon-require-builtin` 需要可写状态才能拿到它的预编译 binding
  （只读根下实测报 `No usable native binding found for node-addon-require-builtin-linux-x64-gnu`）。
  `DSH_NODE_FLAGS` 可以覆盖这一默认值。

---

## 环境变量

| 变量 | 默认 | 作用 |
| --- | --- | --- |
| `HTTPS_ACCESS_HOST` | 空 | 浏览器要输入的名字（IP 或域名）：打印访问地址、用作围栏 authority、内部 CA 签名对象 |
| `DSH_HTTPS_PORT` | `8443` | 宿主机映射的 HTTPS 端口（容器内固定 8443） |
| `DSH_TLS_MODE` | `internal` | `internal` 自签 / `acme` 真证书 / `files` 自带证书 |
| `DSH_ACME_EMAIL` | 空 | ACME 模式下的邮箱 |
| `DSH_TLS_CERT` / `DSH_TLS_KEY` | 空 | `files` 模式的证书路径（挂进 `/data/caddy`） |
| `DSH_HTTPS` | `1` | `0` = 不起 Caddy，只跑 dsh（3080） |
| `DSH_HOME` | `/data/dsh` | 数据根目录 |
| `DSH_PORT` / `DSH_HOST` | `3080` / `0.0.0.0` | 容器内监听端口与绑定地址（`127.0.0.1` 可只留给 Caddy） |
| `DSH_TRUSTED_HOSTS` | 空 | 额外信任的 authority，逗号分隔（仅 `DSH_STRICT_HOST_FENCE=1` 时需要） |
| `DSH_STRICT_HOST_FENCE` | `0` | `1` = 不归一化 Host，完全按上游围栏（只认回环/容器 IP/声明的 authority） |
| `DSH_TELEMETRY_DISABLED` | `1` | 关掉遥测 |
| `DEEPSEEK_API_KEY` 等 | 空 | provider 凭据预置（见下节） |
| `DSH_NODE_FLAGS` | `--expose-internals` | 传给 node 的参数；默认值就是 harness 的 HMR 链需要的那个 flag |
| `DSH_EXTRA_ARGS` | 空 | 追加到 web app 之后的参数 |
| `DSH_NETWORK` | `dsh-network` | 网络名；填已存在的网络名即复用它（如 `1panel-network`） |
| `TZ` | `Asia/Shanghai` | 时区（另有 `/etc/localtime` 只读挂载） |

启动器参数与应用参数的顺序：`dsh --profile web --patch x.yml --port 3080 --no-open`。启动器只
解析自己的参数，**从第一个不认识的名词开始**后面全归 app —— 顺序写反会报错，入口脚本已按此拼好。

---

## 模型与 API Key

`dsh` 的凭据模型是「配置里只放**引用**，不放密钥」，引用长得就像环境变量名
（`@deepseek-ai/dsh-credentials`），解析顺序：

**进程环境变量 → `$DSH_HOME/.credentials.yaml` → 项目/用户 `.env`**

**A. 环境变量预置**：compose 里已预留 `DEEPSEEK_API_KEY`（`dsh-base` 默认 provider 就是
`deepseek-official`，`apiKeyEnv: DEEPSEEK_API_KEY`，Web 搜索复用同一引用）。**启动环境提供的密钥
不能被 UI 覆盖**，设置页会显示为只读来源；其他提供方（`llm-pi-ai` 适配器）同理，按引用名给变量。
建议用 `env_file` 或 compose 的 `secrets`，不要把密钥写进仓库。

**B. 全部在 UI 里配**：不填直接跑，进 设置 → Models 添加提供方/模型并填 Key，写入
`./data/dsh/settings.yaml` 与 `./data/dsh/.credentials.yaml`，持久化在卷里。

---

## 插件

镜像内装了 `pnpm`（`dsh plugin` 会转发给 profile 目录里的 pnpm）：

```sh
docker compose exec deepseek-harness dsh plugin --profile web add <package>
docker compose exec deepseek-harness dsh plugin --profile web update
docker compose restart deepseek-harness     # 插件变更需要重启 Loader 组合
```

---

## 仓库结构

```
.
├── Dockerfile                     # 全部构建都在这里：node + 固定版本 dsh + Caddy + tini
│                                  #   · 绑定补丁（内联生成 /opt/dsh/patches/lan-web.yml）
│                                  #   · 客户端单点修复（构建时 sed + 断言 /api 围栏仍在）
│                                  #   · dsh 包装脚本（固定带 --expose-internals）
├── docker-compose.yml             # 单容器：8443 对外，read_only/tmpfs/no-new-privileges
├── install.sh                     # 一键脚本：向导式安装 + 管理（域名/端口/Auth/更新/备份）
├── .env.example                   # 复制成 .env，改 HTTPS_ACCESS_HOST
├── scripts/entrypoint.sh          # 启动逻辑：生成 Caddyfile、起 Caddy + dsh、拼参数
├── README.md  LICENSE  .gitattributes  .dockerignore  .gitignore
└── .github/workflows/docker-publish.yml   # push 到 main / 手动触发即构建并推 Docker Hub
```

健康检查为什么不用 `curl -f`：UI 有 token 门禁，未登录时 `/` 返回 **401**，`-f` 会把 401 变成
失败退出。镜像与 compose 里的检查都按状态码白名单判断（`200/303/401` 都算健康）。

---

## 构建与发布

```sh
# 本地
docker build -t dockorae/deepseek-harness:0.1.5-rc.1 -t dockorae/deepseek-harness:latest .

# 多架构/推送
docker buildx build --platform linux/amd64 \
  --build-arg DSH_VERSION=0.1.5-rc.1 \
  -t dockorae/deepseek-harness:0.1.5-rc.1 -t dockorae/deepseek-harness:latest --push .
```

CI：`.github/workflows/docker-publish.yml` —— push 到 main 或手动触发时自动跑：

1. **自动检测上游版本**：从 npm 读 `@deepseek-ai/dsh` 的 `dist-tags.latest`，作为 `--build-arg DSH_VERSION` 传进构建（读不到才回落到 Dockerfile 里的 pin）。
2. 构建镜像（buildx）。
3. **冒烟测试**：按 compose 同样的方式起容器（`read_only` + `tmpfs /tmp`），要求 health 变 `healthy`、`ss` 必须看到 `0.0.0.0:3080`、启动日志必须有 `client patch: in place` —— 上游把 bundle 改坏了会直接红。
4. **推 Docker Hub**：`:latest` + `:<检测到的版本号>` 两个 tag。

没配 Secret 也能跑（只构建 + 冒烟，不推送），所以新克隆的仓库一开始就是绿的。要推送需要仓库
Secret：`DOCKERHUB_USERNAME` + `DOCKERHUB_TOKEN`（Docker Hub → Account Settings → Personal
access tokens，**不要**用账号密码）。

---

## 排障

| 现象 | 处理 |
| --- | --- |
| 打不开页面 | `docker compose logs -f deepseek-harness` 看 Caddy 日志（`curl -k https://<host>:8443/` 自测） |
| 浏览器证书警告 | 自签证书的正常表现；要么接受风险继续，要么 `DSH_TLS_MODE=acme` / `files` |
| 打开站点提示要 token | cookie 还没换到：跑 `dsh-harness url`，用它打印的链接访问一次 |
| 页面能开但一直「连接中」/设置页空白 | `/api` 被围栏 403：把浏览器地址栏里的名字（IP/域名）填进 `HTTPS_ACCESS_HOST` 或 `DSH_TRUSTED_HOSTS` |
| 提示 settings are unavailable in this browser | 客户端单点修复没生效——看启动日志 `client patch:` 行；若报 “filesystem is read-only” 说明容器根目录只读且镜像被重建覆盖，重新拉取镜像即可 |
| 401 / token 无效 | token 每次重启轮换，用日志里最新的带 token 地址访问一次即可，之后靠 cookie |
| 角色/写入报 read-only 错误 | 容器是 `read_only`，可写面只有 `/data`、`/workspace`、`/tmp`；要写别处请加卷 |
| 需要 `--expose-internals` 报错 | `DSH_NODE_FLAGS=--expose-internals` |
| 容器重启后会话丢失 | 没挂 `./data/dsh` 卷 |

```sh
docker compose logs -f deepseek-harness                      # 应用 + Caddy
docker compose exec deepseek-harness ls -la /data/dsh
docker compose exec deepseek-harness cat /data/caddy/Caddyfile
docker compose exec deepseek-harness dsh --profile web --help
```

---

## 上游版本升级

1. 镜像/CI 会自动使用 npm 上 `@deepseek-ai/dsh` 的最新版本（CI 每次运行都重新检测）；本地构建用
   `Dockerfile` 的 `ARG DSH_VERSION` 默认值，或 `--build-arg DSH_VERSION=…` / compose 的
   `DSH_VERSION` 显式覆盖。
2. 重新构建：构建期会校验客户端修复能否命中，上游改结构会**直接构建失败**而不是悄悄放过。
3. 实机验收：容器起来后确认日志里有 `client patch: /api Host fence intact`，从另一台机器
   打开 HTTPS 地址，进 设置 → Models 能看到提供方目录。
4. 通过后再 `--push` 覆盖 `latest`。

---

## 许可与参考

- 上游 CLI：[@deepseek-ai/dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)（固定 `0.1.5-rc.1`）
- 组成参考：[anywhere-labs/dsh-desktop](https://github.com/anywhere-labs/dsh-desktop)（固定上游运行时 + `patches/` 层 + 网络暴露显式化的思路）
- 本仓库：MIT（见 [LICENSE](LICENSE)）；镜像运行时不复制上游源码，从 npm 安装固定版本。
