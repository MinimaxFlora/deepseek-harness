#!/usr/bin/env bash
###############################################################################
#
#    ██████╗ ███████╗███████╗██╗  ██╗
#    ██╔══██╗██╔════╝██╔════╝██║  ██║      DeepSeek Harness
#    ██║  ██║███████╗███████╗███████║      Docker 一键部署脚本
#    ██║  ██║╚════██║╚════██║██╔══██║
#    ██████╔╝███████║███████║██║  ██║      github.com/MinimaxFlora/deepseek-harness
#    ╚═════╝ ╚══════╝╚══════╝╚═╝  ╚═╝
#
#   把 dsh 的官方 Web UI 装成一个容器：
#     浏览器 --https--> 容器内 Caddy（TLS + 可选 Basic Auth）--> dsh web
#
#   · 域名模式：Caddy 自动申请 Let's Encrypt 证书（需要 80/443 可达）
#   · IP 模式：不填域名就用本机内网 IP，Caddy 内部 CA 自签
#   · 未装 Docker 自动安装；国内自动切换镜像加速源
#   · 安装 / 重新配置 / 更新 / 状态 / 日志 / 访问地址 / 备份 / 恢复 / 卸载
#
#   用法：
#     bash install.sh                交互菜单
#     bash install.sh install        安装（DSH_FORCE=1 覆盖重装）
#     bash install.sh config         重新配置（改域名 / 端口 / 密码）
#     bash install.sh update         更新（拉最新镜像并重建）
#     bash install.sh start|stop|restart|status|logs|url
#     bash install.sh backup|restore [文件] | uninstall | info | help
#
#   环境变量（跳过向导，适合自动化）：
#     DSH_DOMAIN        域名，例如 dsh.example.com（留空 = 用本机 IP）
#     DSH_HOST          显式指定访问地址（域名或 IP），优先级高于 DSH_DOMAIN
#     DSH_AUTH_USERNAME / DSH_AUTH_PASSWORD   Basic Auth（两个都填才启用）
#     DSH_ACME_EMAIL    Let's Encrypt 通知邮箱（域名模式建议填）
#     DSH_HTTPS_PORT    IP 模式下的 HTTPS 端口，默认 8443
#     DSH_TAG           镜像 tag，默认 latest
#     DSH_IMAGE         镜像名，默认 dockorae/deepseek-harness
#     DSH_INSTALL_DIR   安装目录，默认 /opt/deepseek-harness
#     DSH_NO_MIRROR=1   强制直连拉镜像
#
###############################################################################

# ────────────────────────────── 终端能力 ──────────────────────────────
if [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ] && [ -z "${NO_COLOR:-}" ] && [ -z "${DSH_ASCII:-}" ]; then
	IS_TTY=1
else
	IS_TTY=0
fi

if [ "$IS_TTY" = 1 ]; then
	RST=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
	FG_R=$'\033[38;5;203m'; FG_G=$'\033[38;5;114m'; FG_Y=$'\033[38;5;221m'
	FG_B=$'\033[38;5;75m';  FG_C=$'\033[38;5;116m'; FG_M=$'\033[38;5;176m'
	FG_W=$'\033[38;5;252m'; FG_D=$'\033[38;5;245m'
	GR1=$'\033[38;5;39m';   GR2=$'\033[38;5;45m';   GR3=$'\033[38;5;51m'
	OK="${FG_G}✔${RST}"; ERR="${FG_R}✖${RST}"; WARN="${FG_Y}▲${RST}"
	ARROW="${FG_C}→${RST}"; DOT="${FG_D}·${RST}"; CUR="${FG_M}❯${RST}"
	SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
else
	RST=''; BOLD=''; DIM=''; FG_R=''; FG_G=''; FG_Y=''; FG_B=''; FG_C=''
	FG_M=''; FG_W=''; FG_D=''; GR1=''; GR2=''; GR3=''
	OK='[ok]'; ERR='[!!]'; WARN='[!]'; ARROW='->'; DOT='.'; CUR='>'
	SPIN=('|' '/' '-' '\')
fi

# ────────────────────────────── 默认配置 ──────────────────────────────
DSH_INSTALL_DIR="${DSH_INSTALL_DIR:-/opt/deepseek-harness}"
DSH_DATA_DIR="${DSH_DATA_DIR:-$DSH_INSTALL_DIR/data}"
DSH_IMAGE="${DSH_IMAGE:-dockorae/deepseek-harness}"
DSH_TAG="${DSH_TAG:-latest}"
DSH_CONTAINER="${DSH_CONTAINER:-deepseek-harness}"
DSH_NETWORK="${DSH_NETWORK:-dsh-network}"
DSH_HTTPS_PORT="${DSH_HTTPS_PORT:-8443}"
DSH_DOMAIN="${DSH_DOMAIN:-}"
DSH_HOST="${DSH_HOST:-}"
DSH_AUTH_USERNAME="${DSH_AUTH_USERNAME:-}"
DSH_AUTH_PASSWORD="${DSH_AUTH_PASSWORD:-}"
DSH_ACME_EMAIL="${DSH_ACME_EMAIL:-}"
DSH_MODE="ip"                       # ip | domain
TLS_MODE="internal"                 # internal | acme

ENV_FILE="$DSH_INSTALL_DIR/.env"
COMPOSE_FILE="$DSH_INSTALL_DIR/docker-compose.yml"
MARKER_FILE="$DSH_INSTALL_DIR/.install-mode"
BACKUP_DIR="$DSH_INSTALL_DIR/backups"
SELF_PATH="$DSH_INSTALL_DIR/install.sh"
BIN_PATH="/usr/local/bin/dsh-harness"

CN_MIRRORS=("docker.1panel.live" "dockerpull.org" "hub.rat.dev")
CN_GH_PROXIES=("https://ghfast.top/" "https://ghproxy.net/" "https://gh-proxy.com/")

TMP_DIR=""; USE_MIRROR=0; TTY_FD=""

# ──────────────────────── 文本宽度与输出原语 ────────────────────────
disp_width() {
	local s="$1" w
	# 优先用 GNU wc -L（支持 UTF-8 显示宽度）；加 C.UTF-8 以免服务器默认 locale 是 C
	w=$(printf '%s' "$s" | LC_ALL=C.UTF-8 wc -L 2>/dev/null | tr -d ' ')
	case "$w" in ''|*[!0-9]*) w=$(printf '%s' "$s" | wc -L 2>/dev/null | tr -d ' ') ;; esac
	case "$w" in ''|*[!0-9]*) w=${#s} ;; esac
	printf '%s' "$w"
}

pad() { # pad <文本> <目标显示宽度>
	local s="$1" target="$2" w
	w=$(disp_width "$s")
	while [ "$w" -lt "$target" ]; do s="$s "; w=$((w + 1)); done
	printf '%s' "$s"
}

rule() { # rule <重复次数> [字符] —— 按「次数」循环，避免按字节判断导致边框变短
	local n="$1" ch="${2:-─}" out="" i
	for ((i = 0; i < n; i++)); do out="$out$ch"; done
	printf '%s' "$out"
}

log_info()  { printf '  %s %s\n' "$OK" "$*"; }
log_warn()  { printf '  %s %s\n' "$WARN" "${FG_Y}$*${RST}"; }
log_error() { printf '  %s %s\n' "$ERR" "${FG_R}$*${RST}"; }
log_step()  { printf '  %s %s\n' "$ARROW" "$*"; }
log_dim()   { printf '  %s %s\n' "$DOT" "${FG_D}$*${RST}"; }
die()       { log_error "$*"; exit 1; }

IW=62                                # 面板内部宽度（显示列）

banner_text() { # banner_text <颜色> <文本> [边框色] —— 宽度按显示列算；内容只用 ASCII/CJK，避免模糊宽度字符
	local color="$1" text="$2" frame="${3:-$FG_D}" w
	w=$(disp_width "$text")
	printf '  %s│%s  %s%s%s%s│%s%s\n' "$frame" "$RST" "$color" "$text" "$RST" "$(pad '' $((IW - w)))" "$frame" "$RST"
}

banner() {
	printf '\n'
	printf '  %s╭%s╮%s\n' "$FG_D" "$(rule $((IW + 2)))" "$RST"
	local art=(
		" ____  ____  _   _"
		"|  _ \\/ ___|| | | |"
		"| | | \\___ \\| |_| |"
		"| |_| |___) |  _  |"
		"|____/|____/|_| |_|"
	)
	local i=0 line c
	for line in "${art[@]}"; do
		case $i in
			0|1) c=$GR1 ;;
			2|3) c=$GR2 ;;
			*)   c=$GR3 ;;
		esac
		banner_text "$c" "   $line"
		i=$((i + 1))
	done
	banner_text "$FG_W" "  DeepSeek Harness · Docker 一键部署"
	banner_text "$FG_D" "  Caddy HTTPS 前门 · 域名 / 局域网开箱可用"
	printf '  %s╰%s╯%s\n' "$FG_D" "$(rule $((IW + 2)))" "$RST"
}

panel_open()  { printf '  %s╭─%s %s%s%s\n' "$FG_D" "$RST" "$BOLD$FG_C" "$1" "$RST"; }
panel_row()   { printf '  %s│%s  %s %s\n' "$FG_D" "$RST" "$(pad "$1" "${3:-14}")" "$2"; }
panel_note()  { printf '  %s│%s  %s%s%s\n' "$FG_D" "$RST" "$FG_D" "$1" "$RST"; }
panel_blank() { printf '  %s│%s\n' "$FG_D" "$RST"; }
panel_close() { printf '  %s╰%s%s\n' "$FG_D" "$(rule $((IW - 4)))" "$RST"; }

kv() { printf '  %s%s%s  %s\n' "$FG_C" "$(pad "$1" "${3:-14}")" "$RST" "$2"; }

# ─────────────────────── 输入（兼容 curl | bash）───────────────────────
setup_input() {
	if [ -t 0 ]; then
		TTY_FD=0
		return 0
	fi
	if { : </dev/tty; } 2>/dev/null; then
		exec 3</dev/tty
		TTY_FD=3
	fi
}

ask() { # ask <提示> <默认> -> $REPLY
	local prompt="$1" default="${2:-}" answer=""
	if [ -z "$TTY_FD" ]; then REPLY="$default"; return 0; fi
	if [ -n "$default" ]; then
		printf '  %s?%s %s %s[%s]%s ' "$FG_M" "$RST" "$prompt" "$DIM" "$default" "$RST" >&2
	else
		printf '  %s?%s %s ' "$FG_M" "$RST" "$prompt" >&2
	fi
	read -r -u "$TTY_FD" answer || answer=""
	[ -z "$answer" ] && answer="$default"
	REPLY="$answer"
}

ask_secret() {
	local prompt="$1" default="${2:-}" answer=""
	if [ -z "$TTY_FD" ]; then REPLY="$default"; return 0; fi
	printf '  %s?%s %s ' "$FG_M" "$RST" "$prompt" >&2
	read -r -s -u "$TTY_FD" answer || answer=""
	printf '\n' >&2
	[ -z "$answer" ] && answer="$default"
	REPLY="$answer"
}

confirm() { # confirm <提示> [y=默认是]
	local prompt="$1" hint='[y/N]' default="n" answer=""
	[ "${2:-}" = "y" ] && { hint='[Y/n]'; default="y"; }
	if [ -z "$TTY_FD" ]; then [ "$default" = "y" ]; return $?; fi
	printf '  %s?%s %s %s%s%s ' "$FG_M" "$RST" "$prompt" "$DIM" "$hint" "$RST" >&2
	read -r -u "$TTY_FD" answer || answer=""
	[ -z "$answer" ] && answer="$default"
	case "$answer" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

press_enter() {
	[ -z "$TTY_FD" ] && return 0
	printf '  %s按回车继续…%s' "$DIM" "$RST" >&2
	read -r -u "$TTY_FD" _ || true
	printf '\n'
}

# ─────────────────────────── 进度反馈 ───────────────────────────
run_with_spinner() { # run_with_spinner <说明> <命令...>
	local msg="$1"; shift
	if [ "$IS_TTY" != 1 ]; then
		log_step "$msg"
		"$@"
		return $?
	fi
	local log i=0 start rc=0 n
	log=$(mktemp)
	start=$(date +%s)
	n=${#SPIN[@]}
	"$@" >"$log" 2>&1 &
	local pid=$!
	printf '\033[?25l'
	while kill -0 "$pid" 2>/dev/null; do
		printf '\r  %s%s%s %s %s(%ss)%s  ' "$FG_C" "${SPIN[$((i % n))]}" "$RST" "$(pad "$msg" 36)" "$FG_D" "$(( $(date +%s) - start ))" "$RST"
		i=$((i + 1))
		sleep 0.12
	done
	wait "$pid" || rc=$?
	printf '\r\033[K\033[?25h'
	if [ "$rc" -eq 0 ]; then
		log_info "$msg ${FG_D}($(( $(date +%s) - start ))s)${RST}"
	else
		log_error "$msg 失败（退出码 $rc）"
		tail -12 "$log" | sed 's/^/      /'
	fi
	rm -f "$log"
	return "$rc"
}

step() { # step <序号> <总数> <说明>
	printf '\n  %s▸ %s/%s%s %s%s%s\n' "$FG_C" "$1" "$2" "$RST" "$BOLD" "$3" "$RST"
}

# ─────────────────────────── 环境与网络 ───────────────────────────
check_env() {
	[ "$(uname -s)" = "Linux" ] || die "此脚本仅支持 Linux（当前：$(uname -s)）"
	[ "$(id -u)" -eq 0 ] || die "请使用 root 权限运行：sudo bash install.sh"
	command -v curl >/dev/null 2>&1 || die "缺少 curl：apt install curl -y"
	command -v tar  >/dev/null 2>&1 || die "缺少 tar"
	mkdir -p "$DSH_INSTALL_DIR"
	TMP_DIR=$(mktemp -d)
	trap 'rm -rf "$TMP_DIR"; printf "\033[?25h\033[?1049l"' EXIT INT TERM
	setup_input
}

detect_network() {
	if timeout 3 curl -sI https://www.google.com >/dev/null 2>&1; then
		USE_MIRROR=0
	elif timeout 5 curl -sI https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
		USE_MIRROR=0
	else
		USE_MIRROR=1
	fi
	[ -n "${DSH_NO_MIRROR:-}" ] && USE_MIRROR=0
	if [ "$USE_MIRROR" = 1 ]; then log_dim "网络：国内 · 自动启用镜像加速源"; else log_dim "网络：直连"; fi
}

detect_lan_ip() {
	local ip=""
	ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}')
	[ -z "$ip" ] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
	[ -z "$ip" ] && ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
	printf '%s' "$ip"
}

detect_public_ip() {
	local ip
	for src in https://api.ipify.org https://ifconfig.me/ip https://ip.sb; do
		ip=$(timeout 5 curl -s4 --connect-timeout 4 "$src" 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
		[ -n "$ip" ] && { printf '%s' "$ip"; return 0; }
	done
	return 1
}

is_ipv4() { printf '%s' "$1" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
is_domain() { printf '%s' "$1" | grep -qE '^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; }

resolve_domain_ip() {
	local ip=""
	if command -v getent >/dev/null 2>&1; then
		ip=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | head -1)
	fi
	[ -z "$ip" ] && command -v dig >/dev/null 2>&1 && ip=$(dig +short A "$1" 2>/dev/null | grep -oE '^[0-9.]+$' | head -1)
	printf '%s' "$ip"
}

gen_password() {
	local pw=""
	command -v openssl >/dev/null 2>&1 && pw=$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | cut -c1-16)
	if [ -z "$pw" ] && command -v base64 >/dev/null 2>&1; then
		pw=$(head -c 14 /dev/urandom | base64 | tr -d '/+=' | cut -c1-16)
	fi
	[ -z "$pw" ] && pw="dsh${RANDOM}${RANDOM}${RANDOM}"
	printf '%s' "$pw"
}

port_busy() { # port_busy <端口>
	if command -v ss >/dev/null 2>&1; then
		ss -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
	else
		netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
	fi
}

# ───────────────────────── Docker 保障 ─────────────────────────
has_docker()  { command -v docker >/dev/null 2>&1; }
docker_ready() { has_docker && docker info >/dev/null 2>&1; }

ensure_docker() {
	if docker_ready; then
		log_info "Docker 就绪：v$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
		docker compose version >/dev/null 2>&1 || die "缺少 compose 插件：apt install docker-compose-plugin -y"
		return 0
	fi
	if has_docker; then
		log_warn "Docker 已安装但未运行，尝试启动…"
		systemctl start docker 2>/dev/null || service docker start 2>/dev/null || true
		sleep 2
		docker_ready && { log_info "Docker 已启动"; return 0; }
		die "Docker 无法启动，请排查：systemctl status docker"
	fi
	log_warn "未检测到 Docker"
	confirm "现在自动安装 Docker？" y || die "请手动安装 Docker 后重试"
	local official="https://github.com/MinimaxFlora/Docker_Private_Source/raw/refs/heads/master/install.sh"
	if [ "$USE_MIRROR" = 1 ]; then
		run_with_spinner "安装 Docker（国内源）" sh -c "$(curl -fsSL "https://ghfast.top/$official")" \
			|| run_with_spinner "安装 Docker（备用地址）" sh -c "$(curl -fsSL "$official")" \
			|| die "Docker 自动安装失败"
	else
		run_with_spinner "安装 Docker" sh -c "$(curl -fsSL "$official")" \
			|| run_with_spinner "安装 Docker（镜像地址）" sh -c "$(curl -fsSL "https://ghfast.top/$official")" \
			|| die "Docker 自动安装失败"
	fi
	systemctl enable docker >/dev/null 2>&1 || true
	systemctl start docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
	for _ in $(seq 1 20); do docker_ready && break; sleep 1; done
	docker_ready || die "Docker 服务未就绪：systemctl status docker"
	log_info "Docker 就绪：v$(docker version --format '{{.Server.Version}}' 2>/dev/null)"
}

# ─────────────────────────── 配置向导 ───────────────────────────
wizard() {
	local lan pub
	lan=$(detect_lan_ip)
	pub=$(detect_public_ip || true)

	panel_open "配置向导"
	panel_blank
	panel_note "访问方式决定证书来源：域名走 Caddy 自动申请 Let's Encrypt，IP 用容器内部 CA 自签。"

	if [ -n "$DSH_HOST" ] || [ -n "$DSH_DOMAIN" ]; then
		# 环境变量已给出访问地址：按内容自动判定模式（域名 → ACME，IP → 自签）
		[ -z "$DSH_DOMAIN" ] && is_domain "$DSH_HOST" && DSH_DOMAIN="$DSH_HOST"
		if [ -n "$DSH_DOMAIN" ]; then
			DSH_MODE="domain"
			panel_row "访问地址" "${FG_W}${DSH_DOMAIN}${RST} ${DIM}(来自环境变量)${RST}"
		else
			DSH_MODE="ip"
			panel_row "访问地址" "${FG_W}${DSH_HOST}${RST} ${DIM}(来自环境变量)${RST}"
		fi
	else
		panel_blank
		printf '  %s│%s   %s1%s) 域名（推荐，Caddy 自动申请证书）\n' "$FG_D" "$RST" "$FG_G" "$RST"
		printf '  %s│%s   %s2%s) 本机 IP（内网自签证书）\n' "$FG_D" "$RST" "$FG_G" "$RST"
		ask "选择 [1/2]" "2"
		case "$REPLY" in
			1) DSH_MODE="domain" ;;
			*) DSH_MODE="ip" ;;
		esac
	fi

	case "$DSH_MODE" in
		domain)
			[ -n "$DSH_DOMAIN" ] || [ -n "$DSH_HOST" ] || ask "域名（如 dsh.example.com）" ""
			DSH_DOMAIN="${DSH_DOMAIN:-$REPLY}"
			DSH_DOMAIN="${DSH_DOMAIN#http://}"; DSH_DOMAIN="${DSH_DOMAIN#https://}"; DSH_DOMAIN="${DSH_DOMAIN%%/*}"
			is_domain "$DSH_DOMAIN" || die "域名格式不正确：${DSH_DOMAIN}"
			DSH_HOST="$DSH_DOMAIN"
			TLS_MODE="acme"
			panel_blank
			panel_note "证书申请前先确认解析：域名 A 记录必须指向这台机器的公网 IP。"
			local dip sip
			dip=$(resolve_domain_ip "$DSH_DOMAIN")
			if [ -z "$dip" ]; then
				log_warn "解析不到 $DSH_DOMAIN 的 A 记录（DNS 未生效或本机 DNS 异常）"
			elif [ -z "$pub" ]; then
				log_warn "无法探测本机公网 IP，跳过解析比对（域名解析到 $dip）"
			elif [ "$dip" = "$pub" ]; then
				log_info "解析检查通过：$DSH_DOMAIN → $dip（本机公网 IP）"
			else
				log_warn "解析不匹配：$DSH_DOMAIN → $dip，本机公网 IP → $pub"
				if [ -n "$TTY_FD" ]; then
					if ! confirm "仍然继续（证书申请可能失败）？"; then
						log_step "改为使用自签证书（域名照常访问，浏览器会提示一次风险）"
						TLS_MODE="internal"
					fi
				else
					log_warn "无交互终端：保留 acme 模式，请自行确认域名解析"
				fi
			fi
			panel_blank
			ask "Let's Encrypt 通知邮箱" "${DSH_ACME_EMAIL:-}"
			DSH_ACME_EMAIL="$REPLY"
			[ -n "$DSH_ACME_EMAIL" ] || log_warn "未填邮箱：证书仍可申请，但到期/吊销通知收不到"
			for p in 80 443; do port_busy "$p" && log_warn "端口 $p 已被占用，ACME 校验/HTTPS 可能失败"
			done
			DSH_HTTPS_PORT="443"
			;;
		*)
			if [ -z "$DSH_HOST" ]; then
				panel_blank
				if [ -n "$lan" ]; then
					panel_note "探测到本机 IP：${lan}${pub:+    公网 IP：${pub}}"
				fi
				ask "访问地址（留空 = 自动探测的 $lan）" "$lan"
				DSH_HOST="$REPLY"
			fi
			[ -n "$DSH_HOST" ] || die "无法确定访问地址，请手动指定 DSH_HOST=<IP>"
			DSH_HTTPS_PORT="${DSH_HTTPS_PORT:-8443}"
			ask "HTTPS 端口" "$DSH_HTTPS_PORT"; DSH_HTTPS_PORT="$REPLY"
			case "$DSH_HTTPS_PORT" in ''|*[!0-9]*) die "端口必须是数字" ;; esac
			port_busy "$DSH_HTTPS_PORT" && log_warn "端口 $DSH_HTTPS_PORT 已被占用，容器会启动失败"
			TLS_MODE="internal"
			;;
	esac

	# Basic Auth
	if [ -z "$DSH_AUTH_USERNAME" ] && [ -z "$DSH_AUTH_PASSWORD" ]; then
		panel_blank
		panel_note "Basic Auth 是 HTTPS 前门上的账号密码（可选；公网务必开启）。"
		if confirm "启用 Basic Auth？" y; then
			ask "用户名" "dsh"; DSH_AUTH_USERNAME="$REPLY"
			local gen
			gen=$(gen_password)
			ask_secret "密码（回车自动生成强密码）" ""
			DSH_AUTH_PASSWORD="${REPLY:-$gen}"
		fi
	fi

	panel_blank
	ask "镜像 tag" "${DSH_TAG:-latest}"; DSH_TAG="$REPLY"
	TLS_MODE="${DSH_TLS_MODE:-$TLS_MODE}"
	DSH_DEPLOY_MODE="$DSH_MODE"

	# 汇总
	panel_row "访问地址" "${FG_C}$(entry_url)${RST}"
	panel_row "证书" "$([ "$TLS_MODE" = "acme" ] && echo "Let's Encrypt（Caddy 自动申请）" || echo "自签（容器内部 CA）")"
	[ "$DSH_MODE" = "domain" ] && panel_row "邮箱" "${DSH_ACME_EMAIL:-未填}"
	panel_row "Basic Auth" "$([ -n "$DSH_AUTH_USERNAME" ] && echo "${DSH_AUTH_USERNAME} / ${DSH_AUTH_PASSWORD}" || echo "未启用")"
	panel_row "镜像" "${DSH_IMAGE}:${DSH_TAG}"
	panel_row "端口" "$([ "$DSH_MODE" = "domain" ] && echo "80, 443" || echo "$DSH_HTTPS_PORT")"
	panel_row "安装目录" "$DSH_INSTALL_DIR"
	panel_row "数据目录" "$DSH_DATA_DIR"
	panel_close
	confirm "确认以上配置并开始部署？" y || { log_warn "已取消"; exit 0; }
}

# ──────────────────────── 生成部署文件 ────────────────────────
write_files() {
	mkdir -p "$DSH_DATA_DIR/dsh" "$DSH_DATA_DIR/workspace" "$DSH_DATA_DIR/caddy" "$BACKUP_DIR"

	local ports_block
	if [ "$DSH_MODE" = "domain" ]; then
		ports_block=$'      - "80:80"\n      - "443:443"'
	else
		ports_block="      - \"${DSH_HTTPS_PORT}:8443\""
	fi

	cat > "$COMPOSE_FILE" <<EOF
# 由 dsh-harness 一键脚本生成 —— 重新生成请执行：dsh-harness config
name: deepseek-harness

services:
  deepseek-harness:
    image: ${DSH_IMAGE}:${DSH_TAG}
    container_name: ${DSH_CONTAINER}
    restart: unless-stopped
    networks:
      - dsh-network
    environment:
      # 访问地址：域名走 ACME 真证书，IP 走内部 CA 自签
      HTTPS_ACCESS_HOST: \${HTTPS_ACCESS_HOST:-}
      DSH_TLS_MODE: \${DSH_TLS_MODE:-internal}
      DSH_ACME_EMAIL: \${DSH_ACME_EMAIL:-}
      DSH_AUTH_USERNAME: \${DSH_AUTH_USERNAME:-}
      DSH_AUTH_PASSWORD: \${DSH_AUTH_PASSWORD:-}
      DSH_HOME: /data/dsh
      DSH_TELEMETRY_DISABLED: "1"
      DSH_TRUSTED_HOSTS: \${DSH_TRUSTED_HOSTS:-}
      DEEPSEEK_API_KEY: \${DEEPSEEK_API_KEY:-}
      TZ: \${TZ:-Asia/Shanghai}
    volumes:
      - ./data/dsh:/data/dsh
      - ./data/workspace:/workspace
      - ./data/caddy:/data/caddy
      - /etc/localtime:/etc/localtime:ro
    ports:
${ports_block}
    read_only: true
    tmpfs:
      - /tmp:mode=1777,size=256m
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD-SHELL", "curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1:3080/ | grep -qE '^(200|303|401)\$'"]
      interval: 30s
      timeout: 5s
      start_period: 45s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  dsh-network:
    name: \${DSH_NETWORK:-dsh-network}
EOF

	cat > "$ENV_FILE" <<EOF
# dsh-harness 配置（由 install.sh 生成，chmod 600）
# 访问地址：填域名 = Caddy 自动申请 Let's Encrypt；留空或填 IP = 内部 CA 自签
HTTPS_ACCESS_HOST=${DSH_HOST}
DSH_TLS_MODE=${TLS_MODE}
DSH_ACME_EMAIL=${DSH_ACME_EMAIL}
DSH_AUTH_USERNAME=${DSH_AUTH_USERNAME}
DSH_AUTH_PASSWORD=${DSH_AUTH_PASSWORD}
DSH_NETWORK=${DSH_NETWORK}
DSH_DEPLOY_MODE=${DSH_DEPLOY_MODE:-$DSH_MODE}
DSH_TAG=${DSH_TAG}
TZ=${TZ:-Asia/Shanghai}
# 额外需要信任的 authority（再套一层反代时填，逗号分隔）
DSH_TRUSTED_HOSTS=
# provider 凭据：填了即生效，设置页会显示为只读来源
DEEPSEEK_API_KEY=
# 自带证书（DSH_TLS_MODE=files 时启用，证书挂到 ./data/caddy/ 下）
# DSH_TLS_CERT=/data/caddy/tls/fullchain.pem
# DSH_TLS_KEY=/data/caddy/tls/privkey.pem
EOF
	chmod 600 "$ENV_FILE"
	echo "compose" > "$MARKER_FILE"
	log_info "已生成 $COMPOSE_FILE"
	log_info "已生成 $ENV_FILE ${FG_D}(权限 600)${RST}"
}

install_self() {
	[ -f "$SELF_PATH" ] && { ln -sf "$SELF_PATH" "$BIN_PATH" 2>/dev/null || true; return 0; }
	local src
	src=$(cat "${BASH_SOURCE[0]}" 2>/dev/null || true)
	if printf '%s' "$src" | grep -q '^#!/usr/bin/env bash'; then
		printf '%s' "$src" > "$SELF_PATH"
	else
		local p
		for p in "${CN_GH_PROXIES[@]}"; do
			curl -fsSL "${p}https://raw.githubusercontent.com/MinimaxFlora/deepseek-harness/main/install.sh" -o "$SELF_PATH" 2>/dev/null && [ -s "$SELF_PATH" ] && break
		done
	fi
	if [ -s "$SELF_PATH" ]; then
		chmod +x "$SELF_PATH"
		ln -sf "$SELF_PATH" "$BIN_PATH" 2>/dev/null || true
		log_info "管理命令：${FG_C}dsh-harness${RST}"
	else
		log_warn "管理命令安装失败（不影响容器运行，可手动下载 install.sh）"
	fi
}

# ─────────────────────────── 镜像拉取 ───────────────────────────
pull_image() {
	local img="$DSH_IMAGE:$DSH_TAG" mirror
	if [ "$USE_MIRROR" != 1 ]; then
		run_with_spinner "拉取镜像 $img" docker pull "$img" && return 0
		log_warn "直连拉取失败，尝试镜像加速源…"
	fi
	for mirror in "${CN_MIRRORS[@]}"; do
		if run_with_spinner "经 $mirror 拉取" docker pull "$mirror/$img"; then
			docker tag "$mirror/$img" "$img" >/dev/null 2>&1
			docker rmi "$mirror/$img" >/dev/null 2>&1 || true
			log_info "已从加速源获取：$mirror"
			return 0
		fi
	done
	die "镜像拉取失败：docker pull $img（可用 DSH_NO_MIRROR=1 直连重试）"
}

# ─────────────────────────── 启动与等待 ───────────────────────────
compose_up() {
	run_with_spinner "docker compose up -d" bash -c "cd '$DSH_INSTALL_DIR' && docker compose --env-file .env up -d --pull never"
}

wait_healthy() {
	local i status="" n=${#SPIN[@]}
	for i in $(seq 1 60); do
		status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$DSH_CONTAINER" 2>/dev/null || echo absent)
		if [ "$IS_TTY" = 1 ]; then
			printf '\r  %s%s%s 等待服务就绪… %s%s%s  ' "$FG_C" "${SPIN[$((i % n))]}" "$RST" "$FG_D" "$status" "$RST"
		fi
		[ "$status" = "healthy" ] && break
		sleep 2
	done
	[ "$IS_TTY" = 1 ] && printf '\r\033[K'
	if [ "$status" = "healthy" ]; then
		log_info "容器状态：${FG_G}healthy${RST}"
		return 0
	fi
	log_warn "容器未在预期时间内 healthy（当前：${status:-unknown}），最近日志："
	docker logs --tail 15 "$DSH_CONTAINER" 2>&1 | sed 's/^/      /'
	return 1
}

token_url() { # 从日志取 token，并换成「你实际能打开的」部署地址（容器内的 172.x 地址对用户没用）
	local raw
	raw=$(docker logs "$DSH_CONTAINER" 2>&1 | sed -n 's/.*token=\([^ )]*\).*/\1/p' | head -1)
	[ -z "$raw" ] && return 1
	if [ "${DSH_DEPLOY_MODE:-}" = "domain" ] || [ "$TLS_MODE" = "acme" ]; then
		echo "https://${DSH_HOST}/?token=${raw}"
	else
		echo "https://${DSH_HOST}:${DSH_HTTPS_PORT}/?token=${raw}"
	fi
}

entry_url() {
	if [ "${DSH_DEPLOY_MODE:-}" = "domain" ] || [ "$TLS_MODE" = "acme" ]; then
		echo "https://${DSH_HOST}/"
	else
		echo "https://${DSH_HOST}:${DSH_HTTPS_PORT}/"
	fi
}

show_url() {
	panel_open "访问入口"
	panel_row "HTTPS" "$(entry_url)"
	if [ "$TLS_MODE" = "acme" ]; then
		panel_note "证书由 Caddy 自动申请（Let's Encrypt），首次访问可能需要等几秒签发"
	else
		panel_note "自签证书：浏览器提示一次风险，继续访问即可"
	fi
	[ -n "$DSH_AUTH_USERNAME" ] && panel_row "Basic Auth" "${DSH_AUTH_USERNAME} / ${DSH_AUTH_PASSWORD}"
	local t
	t=$(token_url)
	if [ -n "$t" ]; then
		panel_row "首次登录" "${FG_W}${t}${RST}"
		panel_note "打开一次这个地址即可换到持久 cookie（token 每次重启都会变），之后直接用上面的入口"
	else
		panel_note "带 token 的地址还没出现在日志里，稍后执行：dsh-harness url"
	fi
	panel_close
}

# ─────────────────────────── 安装 ───────────────────────────
install_flow() {
	banner
	step 1 6 "环境检查"
	log_info "$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}" ) ${FG_D}$(uname -m)${RST}"
	step 2 6 "网络与 Docker"
	detect_network
	ensure_docker
	if [ -f "$MARKER_FILE" ] && [ "${DSH_FORCE:-}" != "1" ]; then
		log_warn "检测到已安装（$DSH_INSTALL_DIR）"
		show_status || true
		confirm "覆盖重装？（容器重建，数据保留）" || { show_url; exit 0; }
	fi
	step 3 6 "配置"
	wizard
	step 4 6 "写出部署文件"
	write_files
	install_self
	step 5 6 "拉取镜像"
	pull_image
	step 6 6 "启动容器"
	compose_up || die "启动失败：cd $DSH_INSTALL_DIR && docker compose logs"
	wait_healthy || true
	printf '\n  %s╭%s╮%s\n' "$FG_G" "$(rule $((IW + 2)) "━")" "$RST"
	banner_text "$BOLD$FG_G" "  ✔ 部署完成" "$FG_G"
	printf '  %s╰%s╯%s\n' "$FG_G" "$(rule $((IW + 2)) "━")" "$RST"
	show_url
	printf '\n'
	kv "管理命令" "${FG_C}dsh-harness${RST}   ${FG_D}(菜单 / 状态 / 日志 / 更新 / 配置)${RST}"
	kv "安装目录" "$DSH_INSTALL_DIR"
	printf '\n'
}

# ─────────────────────── 状态与信息 ───────────────────────
container_state()  { docker inspect -f '{{.State.Status}}' "$DSH_CONTAINER" 2>/dev/null || echo absent; }
container_health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$DSH_CONTAINER" 2>/dev/null || echo -; }

load_env() { # 读取已生成的 .env（存在才读）
	[ -f "$ENV_FILE" ] || return 1
	# shellcheck disable=SC1090
	. "$ENV_FILE"
	DSH_HOST="${HTTPS_ACCESS_HOST:-$DSH_HOST}"
	TLS_MODE="${DSH_TLS_MODE:-internal}"
	DSH_AUTH_USERNAME="${DSH_AUTH_USERNAME:-}"
	DSH_AUTH_PASSWORD="${DSH_AUTH_PASSWORD:-}"
	DSH_TAG="${DSH_TAG:-latest}"
	return 0
}

show_status() {
	[ -f "$MARKER_FILE" ] || { log_warn "尚未安装（缺少 $MARKER_FILE）"; return 1; }
	load_env || true
	local st hl dot
	st=$(container_state); hl=$(container_health)
	case "${st}:${hl}" in
		running:healthy) dot="${FG_G}●${RST} 运行中 · 健康" ;;
		running:*)       dot="${FG_Y}●${RST} 运行中 · ${hl}" ;;
		exited:*)        dot="${FG_R}●${RST} 已停止" ;;
		absent:*)        dot="${FG_R}●${RST} 容器不存在" ;;
		*)               dot="${FG_Y}●${RST} ${st}" ;;
	esac
	panel_open "运行状态"
	panel_row "容器" "${dot}   ${DIM}${DSH_CONTAINER}${RST}"
	panel_row "镜像" "$(docker inspect -f '{{.Config.Image}}' "$DSH_CONTAINER" 2>/dev/null || echo "${DSH_IMAGE:-?}:${DSH_TAG:-?}")"
	panel_row "访问入口" "${FG_C}$(entry_url)${RST}"
	panel_row "证书" "$([ "$TLS_MODE" = "acme" ] && echo "Let's Encrypt" || echo "自签")"
	panel_row "数据目录" "$DSH_DATA_DIR"
	panel_close
}

show_info() {
	[ -f "$ENV_FILE" ] || { log_warn "尚未安装"; return 1; }
	load_env || true
	panel_open "配置信息"
	kv "访问地址" "${HTTPS_ACCESS_HOST:-未设置}"
	kv "证书模式" "$([ "$TLS_MODE" = "acme" ] && echo "acme（Let's Encrypt）" || echo "internal（自签）")"
	kv "Basic Auth" "${DSH_AUTH_USERNAME:-未启用}"
	kv "镜像 tag" "${DSH_TAG:-latest}"
	kv "网络" "${DSH_NETWORK:-dsh-network}"
	kv "安装目录" "$DSH_INSTALL_DIR"
	kv "compose" "$COMPOSE_FILE"
	kv "env 文件" "$ENV_FILE"
	panel_close
	printf '\n'
	show_status || true
}

# ─────────────────────────── 管理操作 ───────────────────────────
service_action() {
	local action="$1"
	[ -f "$MARKER_FILE" ] || die "尚未安装，请先执行：dsh-harness install"
	cd "$DSH_INSTALL_DIR" || die "无法进入 $DSH_INSTALL_DIR"
	case "$action" in
		logs) docker compose logs -f --tail 120 ;;
		url)  load_env || true; show_url ;;
		*)    run_with_spinner "docker compose $action" docker compose --env-file .env "$action" && { load_env || true; show_status; } ;;
	esac
}

config_flow() {
	[ -f "$MARKER_FILE" ] || die "尚未安装，请先执行：dsh-harness install"
	banner
	load_env || true
	DSH_HOST="${HTTPS_ACCESS_HOST:-}"
	DSH_DOMAIN=""
	DSH_AUTH_USERNAME=""
	DSH_AUTH_PASSWORD=""
	log_step "重新配置会重写 .env 与 compose，并重建容器（数据保留）"
	wizard
	write_files
	compose_up || die "重建失败：cd $DSH_INSTALL_DIR && docker compose logs"
	wait_healthy || true
	show_url
}

update_flow() {
	[ -f "$MARKER_FILE" ] || die "尚未安装，请先执行：dsh-harness install"
	banner
	load_env || true
	local latest
	latest=$(timeout 15 curl -fsSL 'https://registry.npmjs.org/@deepseek-ai%2fdsh' 2>/dev/null | grep -oE '"latest":"[^"]+"' | head -1 | cut -d'"' -f4)
	[ -n "$latest" ] && log_dim "npm 上 @deepseek-ai/dsh 最新版：${latest}（镜像内置版本可能不同步）"
	confirm "拉取最新镜像并重建容器？（数据保留）" y || { log_warn "已取消"; exit 0; }
	pull_image
	compose_up || die "重建失败"
	wait_healthy || true
	show_url
}

backup_flow() {
	[ -d "$DSH_INSTALL_DIR" ] || die "尚未安装"
	mkdir -p "$BACKUP_DIR"
	local f="$BACKUP_DIR/dsh-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
	run_with_spinner "打包配置与数据" tar -czf "$f" -C "$DSH_INSTALL_DIR" .env docker-compose.yml data || die "备份失败"
	log_info "备份文件：${FG_C}$f${RST}"
}

restore_flow() {
	local f="$1"
	if [ -z "$f" ]; then
		log_warn "用法：dsh-harness restore <备份文件>"
		ls -1t "$BACKUP_DIR" 2>/dev/null | head -5 | sed 's/^/      /'
		return 1
	fi
	[ -f "$f" ] || die "备份文件不存在：$f"
	confirm "恢复会覆盖当前配置与 data/，继续？" || { log_warn "已取消"; exit 0; }
	docker compose -f "$COMPOSE_FILE" down >/dev/null 2>&1 || true
	run_with_spinner "解包备份" tar -xzf "$f" -C "$DSH_INSTALL_DIR" || die "恢复失败"
	[ -f "$MARKER_FILE" ] || echo compose > "$MARKER_FILE"
	compose_up || die "启动失败"
	wait_healthy || true
	show_url
}

uninstall_flow() {
	[ -f "$MARKER_FILE" ] || die "尚未安装"
	banner
	log_warn "即将卸载容器 ${DSH_CONTAINER}"
	confirm "确认卸载？" || { log_warn "已取消"; exit 0; }
	load_env || true
	[ -f "$COMPOSE_FILE" ] && run_with_spinner "停止并删除容器" docker compose -f "$COMPOSE_FILE" down || true
	if confirm "同时删除镜像 ${DSH_IMAGE}:${DSH_TAG}？"; then
		docker rmi "${DSH_IMAGE}:${DSH_TAG}" >/dev/null 2>&1 || true
		log_info "镜像已删除"
	fi
	if confirm "同时删除安装目录（含数据 ${DSH_DATA_DIR}）？"; then
		rm -rf "$DSH_INSTALL_DIR" "$BIN_PATH"
		log_info "已删除 $DSH_INSTALL_DIR"
	else
		rm -f "$COMPOSE_FILE" "$MARKER_FILE" "$BIN_PATH"
		log_info "配置已删除，数据保留在 ${FG_C}$DSH_DATA_DIR${RST}"
	fi
}

# ─────────────────────────── 交互菜单 ───────────────────────────
MENU_NAMES=("安装 / 重装" "运行状态" "访问入口" "查看日志" "重新配置" "更新镜像" "启动/停止/重启" "备份 / 恢复" "卸载" "退出")
MENU_HINTS=("配置向导，全自动部署" "容器健康、证书模式与数据目录" "打印 HTTPS 入口与首次登录链接" "实时跟踪容器输出" "改域名 / 端口 / Basic Auth" "拉最新镜像并重建容器" "start | stop | restart | status" "打包 data 与配置" "删除容器（数据可选保留）" "exit")
MENU_ACTIONS=(install status url logs config update service backup uninstall quit)

MENU_LINES=0

menu_block() { # 画整块菜单（紧凑标题版，菜单单独占屏，避免任何光标行数推算）
	local i name hint
	printf '  %s╭─%s %sDEEPSEEK HARNESS%s %s· 管理菜单%s\n' "$FG_D" "$RST" "$BOLD$FG_C" "$RST" "$DIM" "$RST"
	for i in "${!MENU_NAMES[@]}"; do
		name="${MENU_NAMES[$i]}"; hint="${MENU_HINTS[$i]}"
		if [ "$i" -eq "$1" ]; then
			printf '  %s│%s  %s %s%s%s  %s%s%s\n' "$FG_D" "$RST" "$CUR" "$FG_M" "$(pad "$name" 18)" "$RST" "$DIM" "$hint" "$RST"
		else
			printf '  %s│%s    %s%s%s  %s%s%s\n' "$FG_D" "$RST" "$FG_W" "$(pad "$name" 18)" "$RST" "$FG_D" "$hint" "$RST"
		fi
	done
	printf '  %s╰%s%s\n' "$FG_D" "$(rule 58)" "$RST"
}

menu() {
	local sel=0 key c2 c3 act i n=${#MENU_NAMES[@]}
	if [ -z "$TTY_FD" ]; then
		printf '\n'
		menu_block 0
		log_dim "无交互终端：请用子命令 dsh-harness install|status|logs|config|update|..."
		return 0
	fi
	# 备用屏幕缓冲区：菜单独占一屏、每次整屏重绘，退出时终端原样恢复
	[ "$IS_TTY" = 1 ] && printf '\033[?1049h'
	while true; do
		printf '\033[2J\033[H'
		menu_block "$sel"
		printf '  %s↑↓/jk 选择 · Enter 确认 · 数字直选 · q 退出%s ' "$DIM" "$RST" >&2
		IFS= read -r -s -n1 -u "$TTY_FD" key || key=q

		# 先只决定「改选中」还是「执行」，方向键/移动键一律不执行动作
		act=1
		case "$key" in
			$'\033')                            # 方向键：兼容 ESC[A 与 ESC OA 两种编码
				act=0
				c2=""
				IFS= read -r -s -n1 -t 0.08 -u "$TTY_FD" c2 || c2=""
				case "$c2" in
					'[' | 'O')
						c3=""
						IFS= read -r -s -n1 -t 0.08 -u "$TTY_FD" c3 || c3=""
						case "$c3" in
							A) sel=$(((sel - 1 + n) % n)) ;;
							B) sel=$(((sel + 1) % n)) ;;
						esac ;;
				esac ;;
			j|J) act=0; sel=$(((sel + 1) % n)) ;;
			k|K) act=0; sel=$(((sel - 1 + n) % n)) ;;
			q|Q) printf '\n'; exit 0 ;;
			'')  act=1 ;;                       # 回车：执行当前项
			[1-9]|0)
				if [ "$key" = "0" ]; then i=9; else i=$((key - 1)); fi
				if [ "$i" -lt "$n" ]; then sel="$i"; else act=0; fi ;;
			*)   act=0 ;;
		esac

		if [ "$act" = "1" ]; then
			printf '\n'
			run_menu_action "${MENU_ACTIONS[$sel]}"
			printf '\n'
		fi
	done
}

run_menu_action() {
	local act
	case "$1" in
		install)   install_flow ;;
		status)    show_status || true; press_enter ;;
		url)       load_env 2>/dev/null || true; show_url; press_enter ;;
		logs)      printf '  %sCtrl+C 退出%s\n' "$DIM" "$RST"; service_action logs ;;
		config)    config_flow ;;
		update)    update_flow ;;
		service)
			ask "操作 start | stop | restart | status" "status"; act="$REPLY"
			case "$act" in start|stop|restart|status) service_action "$act" ;; *) log_warn "未知操作" ;; esac
			press_enter ;;
		backup)
			ask "操作 backup | restore" "backup"; act="$REPLY"
			case "$act" in
				backup)  backup_flow ;;
				restore) ask "备份文件路径" ""; restore_flow "$REPLY" ;;
				*)       log_warn "未知操作" ;;
			esac
			press_enter ;;
		uninstall) uninstall_flow ;;
		quit)      exit 0 ;;
	esac
}

usage() {
	cat <<'EOF'
DeepSeek Harness Docker 一键脚本

用法:
  bash install.sh                 交互菜单
  bash install.sh install         安装（DSH_FORCE=1 覆盖重装）
  bash install.sh config          重新配置（域名 / 端口 / Basic Auth）
  bash install.sh update          拉最新镜像并重建容器
  bash install.sh start|stop|restart|status|logs|url
  bash install.sh backup          备份配置与数据
  bash install.sh restore <文件>  恢复备份
  bash install.sh uninstall       卸载（数据默认保留）
  bash install.sh info | help

常用环境变量:
  DSH_DOMAIN=dsh.example.com      域名（留空 = 用本机 IP + 自签证书）
  DSH_HOST=192.168.1.10           直接指定访问地址（域名或 IP）
  DSH_AUTH_USERNAME / DSH_AUTH_PASSWORD   Basic Auth（两个都填才启用）
  DSH_ACME_EMAIL=me@example.com   Let's Encrypt 通知邮箱
  DSH_HTTPS_PORT=8443             IP 模式下的 HTTPS 端口
  DSH_TAG=latest                  镜像 tag
  DSH_INSTALL_DIR=/opt/deepseek-harness
  DSH_NO_MIRROR=1                 强制直连拉镜像

域名模式说明:
  选择域名后，容器内的 Caddy 会自动向 Let's Encrypt 申请证书（HTTP-01 校验），
  需要 80/443 对外可达、域名 A 记录指向本机公网 IP。校验不通过会提示，可选择
  继续或退回自签证书。IP 模式下 Caddy 使用自身内部 CA，浏览器提示一次风险。
EOF
}

# ─────────────────────────── 入口 ───────────────────────────
banner
check_env
case "${1:-}" in
	install)          install_flow ;;
	config|reconfig)  config_flow ;;
	update)           update_flow ;;
	uninstall)        uninstall_flow ;;
	start|stop|restart|status) service_action "$1" ;;
	logs)             service_action logs ;;
	url)              load_env 2>/dev/null || true; show_url ;;
	backup)           backup_flow ;;
	restore)          restore_flow "${2:-}" ;;
	info)             show_info ;;
	help|-h|--help)   usage ;;
	"")               load_env 2>/dev/null || true; menu ;;
	*)                log_error "未知子命令：$1"; printf '\n'; usage; exit 1 ;;
esac
