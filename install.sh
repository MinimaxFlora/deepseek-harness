#!/bin/bash
###############################################################################
#
# DeepSeek Harness Manage Script
#
# Version: 1.0.0
# Last Updated: 2026-09-11
#
# Description:
#   A management script for DeepSeek Harness (@deepseek-ai/dsh) Docker 部署
#   Provides installation, update, uninstallation and management functions
#   Enhanced with disk space checking, config backup/restore, access-url
#   management and scheduled image updates
#
# Requirements:
#   - Linux (systemd / OpenRC / 其他 init 均可，脚本只用 Docker)
#   - Root privileges for installation
#   - curl
#   - Docker (脚本可自动安装)
#
#   HTTPS 前门由容器内的 Caddy 提供：填域名自动申请 Let's Encrypt，
#   填 IP 用容器内部 CA 自签。认证使用 dsh 自带的 token + cookie。
#
# Author: MinimaxFlora
# Repo:   https://github.com/MinimaxFlora/deepseek-harness
# Image:  dockorae/deepseek-harness
#
# License: MIT
#
###############################################################################

# 颜色定义（用真转义字符：echo 与 printf 都能正确着色）
# ─────────────────────────── 颜色能力与渐变 ───────────────────────────
# COLOR_LEVEL: 3=24bit 真彩 | 2=256 色 | 1=8 色 | 0=无色
# 无色场景：非终端（重定向 / CI / 日志）、NO_COLOR、TERM=dumb；DSH_COLOR_LEVEL 可强制覆盖。
COLOR_LEVEL=0
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    case "${COLORTERM:-} ${TERM:-}" in
        *truecolor*|*24bit*) COLOR_LEVEL=3 ;;
        *256color*)          COLOR_LEVEL=2 ;;
        *)                   COLOR_LEVEL=1 ;;
    esac
fi
# NO_COLOR 是用户级约定，优先于强制覆盖；DSH_COLOR_LEVEL 便于脚本/测试指定能力
case "${DSH_COLOR_LEVEL:-}" in
    0|1|2|3) [ -z "${NO_COLOR:-}" ] && COLOR_LEVEL="$DSH_COLOR_LEVEL" ;;
esac

if [ "$COLOR_LEVEL" -gt 0 ]; then
    RED_COLOR=$'\033[1;31m';  GREEN_COLOR=$'\033[1;32m'; YELLOW_COLOR=$'\033[1;33m'
    BLUE_COLOR=$'\033[1;34m'; CYAN_COLOR=$'\033[1;36m';  PURPLE_COLOR=$'\033[1;35m'
    BOLD=$'\033[1m';          DIM=$'\033[2m';            RES=$'\033[0m'
else
    RED_COLOR=""; GREEN_COLOR=""; YELLOW_COLOR=""; BLUE_COLOR=""; CYAN_COLOR=""; PURPLE_COLOR=""
    BOLD=""; DIM=""; RES=""
fi

# 渐变端点：#4D6BFE（DeepSeek 蓝）→ #22D3EE（青）→ #34D399（绿）
GRAD_FROM="77 107 254"
GRAD_MID="34 211 238"
GRAD_TO="52 211 153"

grad_rgb() { # grad_rgb <位置> <总数> → "r g b"
    local i="$1" n="$2" t r1 g1 b1 r2 g2 b2 k
    if [ "$n" -le 1 ]; then t=0; else t=$((i * 1000 / (n - 1))); fi
    if [ "$t" -le 500 ]; then
        set -- $GRAD_FROM; r1=$1; g1=$2; b1=$3
        set -- $GRAD_MID;  r2=$1; g2=$2; b2=$3
        k=$t
    else
        set -- $GRAD_MID;  r1=$1; g1=$2; b1=$3
        set -- $GRAD_TO;   r2=$1; g2=$2; b2=$3
        k=$((t - 500))
    fi
    printf '%s %s %s' \
        $((r1 + (r2 - r1) * k / 500)) \
        $((g1 + (g2 - g1) * k / 500)) \
        $((b1 + (b2 - b1) * k / 500))
}

grad_esc() { # grad_esc <位置> <总数> → 该处前景色（按终端能力降级）
    [ "$COLOR_LEVEL" -gt 0 ] || return 0
    local rgb r g b
    rgb=$(grad_rgb "$1" "$2"); set -- $rgb; r=$1; g=$2; b=$3
    case "$COLOR_LEVEL" in
        3) printf '\033[38;2;%d;%d;%dm' "$r" "$g" "$b" ;;
        2) printf '\033[38;5;%dm' "$((16 + 36 * (r * 5 / 255) + 6 * (g * 5 / 255) + (b * 5 / 255)))" ;;
        *) printf '\033[1;36m' ;;
    esac
}

rule_grad() { # rule_grad <长度> [字符] —— 分段着色的渐变横线（每段 6 列）
    local n="$1" ch="${2:-─}" seg=6 i=0 x
    if [ "$COLOR_LEVEL" -eq 0 ]; then rule "$n" "$ch"; return 0; fi
    while [ "$i" -lt "$n" ]; do
        x=$((n - i)); [ "$x" -gt "$seg" ] && x="$seg"
        grad_esc "$i" "$n"
        rule "$x" "$ch"
        i=$((i + x))
    done
    printf '%s' "$RES"
}

bar() { # bar <当前> <总数> [宽度] —— 渐变进度条（只用在没有右边框的行上）
    local cur="$1" total="$2" width="${3:-20}" filled=0 i
    [ "$total" -le 0 ] && total=1
    filled=$((cur * width / total))
    for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$filled" ]; then
            grad_esc "$i" "$width"; printf '█'
        else
            printf '%s░%s' "$DIM" "$RES"
        fi
    done
}

# 尽量启用 UTF-8：下面按「字符数」算显示宽度要靠它（否则中文会被算成 3 倍宽）
if [ "$(LC_ALL=C.UTF-8 bash -c 'echo ${#1}' _ 中文 2>/dev/null)" = "2" ]; then
    export LC_ALL=C.UTF-8
fi

clear_screen() { # TERM 未设置时 clear 会报错，退化成 ANSI 清屏
    if [ -n "$TERM" ] && command -v clear >/dev/null 2>&1; then
        command clear 2>/dev/null || printf '\033[2J\033[H'
    else
        printf '\033[2J\033[H'
    fi
}

# 检查系统是否为 Linux
CURRENT_OS=$(uname -s)
if [ "$CURRENT_OS" != "Linux" ]; then
    echo -e "${RED_COLOR}错误：此脚本仅支持 Linux 系统${RES}"
    exit 1
fi

# 获取平台架构（镜像当前只提供 linux/amd64；arm64 需要自行 buildx 构建）
if command -v arch >/dev/null 2>&1; then
    platform=$(arch)
else
    platform=$(uname -m)
fi
case "$platform" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)       ARCH="$platform" ;;
esac

# 检查必要的命令
if ! command -v curl >/dev/null 2>&1; then
    echo -e "${RED_COLOR}错误：未找到 curl 命令，请先安装${RES}"
    exit 1
fi

# 使用 sudo -v 确保当前 script 使用 root 执行
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED_COLOR}此脚本需要root权限运行${RES}"
    echo -e "${YELLOW_COLOR}正在请求root权限...${RES}"
    if command -v sudo >/dev/null 2>&1; then
        sudo -v || {
            echo -e "${RED_COLOR}获取root权限失败(sudo)，退出脚本${RES}"
            exit 1
        }
        exec sudo "bash" "$0" "$@"
    elif command -v doas >/dev/null 2>&1; then
        doas true || {
            echo -e "${RED_COLOR}获取root权限失败(doas)，退出脚本${RES}"
            exit 1
        }
        exec doas "bash" "$0" "$@"
    else
        echo -e "${RED_COLOR}错误：系统中未找到 doas 或 sudo，无法提权${RES}"
        exit 1
    fi
fi

# ─────────────────────────────── 配置部分 ───────────────────────────────

# 镜像与容器
DSH_IMAGE="${DSH_IMAGE:-dockorae/deepseek-harness}"
DSH_IMAGE_TAG="${DSH_TAG:-latest}"
DSH_CONTAINER_NAME="${DSH_CONTAINER_NAME:-deepseek-harness}"
DSH_NETWORK="${DSH_NETWORK:-dsh-network}"

# 路径
DEFAULT_INSTALL_PATH="/opt/deepseek-harness"
MANAGER_PATH="/usr/local/sbin/deepseek-harness-manager"
COMMAND_LINK="/usr/local/bin/dsh-harness"
BACKUP_BASE_DIR="/opt/deepseek-harness_backups"
UPDATE_LOG="/var/log/deepseek-harness-update.log"

# 默认端口
DEFAULT_HTTPS_PORT="${DSH_HTTPS_PORT:-8443}"

# 安装时由向导填写的变量
# 环境里继承来的伪地址（例如镜像自身的 DSH_HOST=0.0.0.0 表示监听地址）不算「用户指定」
case "${DSH_HOST:-}" in 0.0.0.0|::|'*'|localhost) DSH_HOST="" ;; esac
case "${DSH_DOMAIN:-}" in 0.0.0.0|::|'*'|localhost) DSH_DOMAIN="" ;; esac
ACCESS_HOST="${DSH_HOST:-${DSH_DOMAIN:-}}"
ACME_EMAIL="${DSH_ACME_EMAIL:-}"
HTTPS_PORT="$DEFAULT_HTTPS_PORT"
TLS_MODE=""            # internal（IP 自签） | acme（域名真证书） | files（自带证书）
DEPLOY_MODE=""         # ip | domain

# 定时更新配置
CRON_UPDATE_TIME="0 2 * * 0"   # 每周日凌晨2点
CRON_TAG="# deepseek-harness-auto-update"

# 安装路径：第 2 个参数可指定（与 OpenList 脚本一致）
if [ -n "$2" ]; then
    INSTALL_PATH="${2%/}"
    parent_dir=$(dirname "$INSTALL_PATH")
    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir" || {
            echo -e "${RED_COLOR}错误：无法创建目录 $parent_dir${RES}"
            exit 1
        }
    fi
    if [ ! -w "$parent_dir" ]; then
        echo -e "${RED_COLOR}错误：目录 $parent_dir 没有写入权限${RES}"
        exit 1
    fi
else
    INSTALL_PATH="$DEFAULT_INSTALL_PATH"
fi
[ -n "${DSH_INSTALL_DIR:-}" ] && INSTALL_PATH="${DSH_INSTALL_DIR%/}"

COMPOSE_FILE="$INSTALL_PATH/docker-compose.yml"
ENV_FILE="$INSTALL_PATH/.env"
MARKER_FILE="$INSTALL_PATH/.installed"

# 更新/卸载/状态等操作使用已安装的路径
if [ "$1" = "update" ] || [ "$1" = "uninstall" ] || [ "$1" = "status" ] || [ "$1" = "url" ] || \
   [ "$1" = "logs" ] || [ "$1" = "config" ] || [ "$1" = "backup" ] || [ "$1" = "restore" ] || \
   [ "$1" = "start" ] || [ "$1" = "stop" ] || [ "$1" = "restart" ] || [ "$1" = "domain" ] || \
   [ "$1" = "ip" ] || [ "$1" = "switch" ]; then
    if [ -f "$ENV_FILE" ]; then
        INSTALL_PATH=$(sed -n 's/^#\? *DSH_INSTALL_DIR=//p' "$ENV_FILE" 2>/dev/null | head -1)
        INSTALL_PATH="${INSTALL_PATH:-$DEFAULT_INSTALL_PATH}"
        COMPOSE_FILE="$INSTALL_PATH/docker-compose.yml"
        ENV_FILE="$INSTALL_PATH/.env"
        MARKER_FILE="$INSTALL_PATH/.installed"
    fi
fi

# ─────────────────────────────── 输出工具 ───────────────────────────────

# 宽度检测：优先用 GNU wc -L（按显示列宽算，中文=2 列），其次 python3，最后退回字符数
WIDTH_MODE="char"
if printf '中文' | LC_ALL=C.UTF-8 wc -L 2>/dev/null | grep -qx '4'; then
    WIDTH_MODE="wc"
elif command -v python3 >/dev/null 2>&1; then
    WIDTH_MODE="python"
fi

str_width() { # 按显示列宽计算（中文/全角算 2 列）
    local s="$1"
    case "$WIDTH_MODE" in
        wc)     printf '%s' "$s" | LC_ALL=C.UTF-8 wc -L | tr -d ' ' ;;
        python) python3 -c 'import sys,unicodedata
print(sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in sys.argv[1]))' "$s" ;;
        *)      printf '%s' "${#s}" ;;
    esac
}

pad() { # pad <文本> <目标宽度>：右侧补空格
    local text="$1" want="$2" cur
    cur=$(str_width "$text")
    while [ "$cur" -lt "$want" ]; do
        text="$text "
        cur=$((cur + 1))
    done
    printf '%s' "$text"
}

rule() { # rule <重复次数> [字符]
    local n="$1" ch="${2:-─}" out="" i
    for ((i = 0; i < n; i++)); do out="$out$ch"; done
    printf '%s' "$out"
}

draw_box() { # draw_box [--title 标题] <行...> —— 圆角方框、渐变边框、内容按显示宽度对齐
    local title=""
    if [ "$1" = "--title" ]; then title="$2"; shift 2; fi
    local -a lines=("$@")
    local max=54 i w tw x inner
    for i in "${!lines[@]}"; do
        w=$(str_width "${lines[$i]}")
        [ "$w" -gt "$max" ] && max="$w"
    done
    if [ -n "$title" ]; then
        tw=$(str_width "$title")
        [ $((tw + 8)) -gt "$max" ] && max=$((tw + 8))
    fi
    inner=$((max + 2))

    if [ -n "$title" ]; then
        tw=$(str_width "$title"); x=$((inner - tw - 3)); [ "$x" -lt 1 ] && x=1
        printf '%s╭─%s %s%s%s %s%s%s╮%s\n' \
            "$(grad_esc 0 2)" "$RES" "$BOLD$(grad_esc 1 3)" "$title" "$RES" \
            "$(rule_grad "$x")" "$(grad_esc 1 2)" "$RES" "$RES"
    else
        printf '%s╭%s%s╮%s\n' "$(grad_esc 0 2)" "$(rule_grad "$inner")" "$(grad_esc 1 2)" "$RES"
    fi

    for i in "${!lines[@]}"; do
        w=$(str_width "${lines[$i]}")
        printf '%s│%s %s%s %s│%s\n' \
            "$(grad_esc 0 2)" "$RES" "${lines[$i]}" "$(pad '' $((max - w)))" "$(grad_esc 1 2)" "$RES"
    done

    printf '%s╰%s%s╯%s\n' "$(grad_esc 0 2)" "$(rule_grad "$inner")" "$(grad_esc 1 2)" "$RES"
}

ok()   { printf '  %s✔%s %s\n' "$GREEN_COLOR" "$RES" "$*"; }
info() { printf '  %s→%s %s\n' "$CYAN_COLOR" "$RES" "$*"; }
warn() { printf '  %s▲%s %s%s%s\n' "$YELLOW_COLOR" "$RES" "$YELLOW_COLOR" "$*" "$RES"; }
fail() { printf '  %s✖%s %s%s%s\n' "$RED_COLOR" "$RES" "$RED_COLOR" "$*" "$RES"; }
dim()  { printf '  %s%s%s\n' "$DIM" "$*" "$RES"; }

step_head() { # step_head <当前> <总数> <标题> —— 步骤行 + 渐变进度条
    local cur="$1" total="$2" title="$3"
    printf '\n  %s▸%s %s%s%s   %s  %s[%s/%s]%s\n' \
        "$(grad_esc "$((cur - 1))" "$total")" "$RES" "$BOLD" "$title" "$RES" \
        "$(bar "$cur" "$total")" "$DIM" "$cur" "$total" "$RES"
}

banner() { # 顶部渐变标题（纯 ASCII 字形，宽度无歧义）
    local -a art=(
        '      ____  ____  _   _'
        '     |  _ \/ ___|| | | |'
        '     | | | \___ \| |_| |'
        '     | |_| |___) |  _  |'
        '     |____/|____/|_| |_|'
    )
    local i n=${#art[@]}
    printf '\n'
    for i in "${!art[@]}"; do
        printf '%s%s%s\n' "$(grad_esc "$i" "$n")" "${art[$i]}" "$RES"
    done
    printf '  %s%sDeepSeek Harness%s  %s· Docker 一键部署 · Caddy HTTPS 前门 · 域名 / IP 开箱可用%s\n' \
        "$BOLD" "$(grad_esc 2 5)" "" "$DIM" "$RES"
    printf '  %s%s\n\n' "$(grad_esc 0 4)" "$(rule_grad 68)" "$RES"
}

spin() { # spin <说明> <命令...> —— 转圈 + 耗时；失败时打印输出尾部
    local label="$1"; shift
    local out rc=0 pid frame=0 start=$SECONDS elapsed
    local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    out=$(mktemp 2>/dev/null || echo "/tmp/dsh-spin.$$")

    if [ "$COLOR_LEVEL" -gt 0 ] && [ -t 1 ]; then
        printf '\033[?25l'
        ( "$@" ) >"$out" 2>&1 &
        pid=$!
        while kill -0 "$pid" 2>/dev/null; do
            elapsed=$((SECONDS - start))
            printf '\r  %s%s%s %s%s %s%ss%s\033[K' \
                "$CYAN_COLOR" "${frames[$((frame % 10))]}" "$RES" "$label" "$DIM" "$elapsed" "$RES"
            frame=$((frame + 1))
            sleep 0.15
        done
        wait "$pid"; rc=$?
        printf '\r\033[K\033[?25h'
    else
        printf '  %s→%s %s\n' "$CYAN_COLOR" "$RES" "$label"
        "$@" >"$out" 2>&1; rc=$?
    fi

    elapsed=$((SECONDS - start))
    if [ "$rc" -eq 0 ]; then
        printf '  %s✔%s %s %s(%ss)%s\n' "$GREEN_COLOR" "$RES" "$label" "$DIM" "$elapsed" "$RES"
    else
        printf '  %s✖%s %s\n' "$RED_COLOR" "$RES" "$label"
        tail -n 12 "$out" 2>/dev/null | sed 's/^/      /'
    fi
    rm -f "$out"
    return "$rc"
}

confirm() { # confirm <提示> [默认值]
    local prompt="$1" def="${2:-n}" answer
    if [ "${DSH_YES:-0}" = "1" ]; then return 0; fi
    if [ ! -t 0 ]; then
        [ "$def" = "y" ] && return 0 || return 1
    fi
    read -r -p "$prompt [y/N]: " answer
    answer="${answer:-$def}"
    case "$answer" in [yY]*) return 0 ;; *) return 1 ;; esac
}

# ─────────────────────────────── 网络探测 ───────────────────────────────

get_local_ip() {
    if command -v ip >/dev/null 2>&1; then
        ip addr show 2>/dev/null | grep -w inet | grep -v "127.0.0.1" | awk '{print $2}' | cut -d/ -f1 | head -n1
        return 0
    fi
    hostname -I 2>/dev/null | awk '{print $1}'
}

get_public_ip() {
    local ip
    for url in "https://ip.sb" "https://api.ipify.org" "https://ifconfig.me/ip" "https://4.ipw.cn"; do
        ip=$(curl -s4 --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]')
        case "$ip" in
            *[!0-9.]*|"") continue ;;
            *) printf '%s' "$ip"; return 0 ;;
        esac
    done
    return 1
}

is_domain() { # 粗判域名（含点、非 IP）
    local v="$1"
    case "$v" in
        *[!A-Za-z0-9.:_-]*|"") return 1 ;;
    esac
    case "$v" in
        *:*) return 1 ;;                    # 排除 IPv6，避免误判成域名
        *[!0-9.]*)                           # 不是纯数字/点 → 域名
            case "$v" in *.*) return 0 ;; *) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
}

valid_host() { # 访问地址只接受域名或 IP
    case "$1" in
        ""|*[!A-Za-z0-9.:_-]*)
            fail "错误：访问地址只能是域名或 IP（不要带 http:// 或路径）：$1"
            return 1
            ;;
    esac
    return 0
}

# ─────────────────────────────── Docker ───────────────────────────────

get_docker_start_command() {
    if command -v systemctl >/dev/null 2>&1; then
        echo "systemctl start docker"
    elif command -v rc-service >/dev/null 2>&1; then
        echo "rc-service docker start"
    else
        echo "service docker start"
    fi
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        fail "错误：未找到 Docker"
        warn "可以选择菜单里的「安装 Docker」，或手动执行：curl -fsSL https://get.docker.com | sh"
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        fail "错误：Docker 服务未运行"
        warn "启动命令：$(get_docker_start_command)"
        return 1
    fi
    if ! docker compose version >/dev/null 2>&1; then
        fail "错误：未找到 docker compose 插件（v2）"
        warn "Debian/Ubuntu：apt install docker-compose-plugin"
        return 1
    fi
    return 0
}

INSTALL_DOCKER() {
    echo -e "${GREEN_COLOR}安装 Docker${RES}"
    if command -v docker >/dev/null 2>&1; then
        ok "已安装 Docker：$(docker --version)"
        if ! docker info >/dev/null 2>&1; then
            warn "Docker 服务未运行，尝试启动：$(get_docker_start_command)"
            eval "$(get_docker_start_command)" >/dev/null 2>&1
        fi
        return 0
    fi

    echo -e "${GREEN_COLOR}1${RES} - 官方源（get.docker.com，海外机器）"
    echo -e "${GREEN_COLOR}2${RES} - 阿里云镜像源（国内机器）"
    echo -e "${GREEN_COLOR}0${RES} - 返回主菜单"
    echo
    read -r -p "请输入选项 [0-2] (默认2): " choice
    case "${choice:-2}" in
        1) sh -c "$(curl -fsSL https://get.docker.com)" ;;
        2) sh -c "$(curl -fsSL https://get.docker.com)" --mirror Aliyun ;;
        0) return 1 ;;
        *) sh -c "$(curl -fsSL https://get.docker.com)" --mirror Aliyun ;;
    esac

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1
    fi
    if docker info >/dev/null 2>&1; then
        ok "Docker 安装成功：$(docker --version)"
        return 0
    fi
    fail "Docker 安装失败，请手动安装后重试"
    return 1
}

# 检查磁盘空间
check_disk_space() {
    echo -e "${BLUE_COLOR}检查系统空间...${RES}"

    local tmp_space tmp_space_mb install_dir_parent install_space install_space_mb
    tmp_space=$(df -h /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")
    tmp_space_mb=$(df /tmp 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")

    install_dir_parent=$(dirname "$INSTALL_PATH")
    if [ ! -d "$install_dir_parent" ]; then
        mkdir -p "$install_dir_parent" 2>/dev/null || install_dir_parent="/"
    fi
    install_space=$(df -h "$install_dir_parent" 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")
    install_space_mb=$(df "$install_dir_parent" 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")

    # 镜像解压后约 1 GB，低于 1 GB 可用空间给个明确警告
    if [ "$tmp_space_mb" != "0" ] && [ "$install_space_mb" != "0" ]; then
        if [ "$tmp_space_mb" -lt 1048576 ] || [ "$install_space_mb" -lt 1048576 ]; then
            fail "警告：系统空间不足"
            echo -e "临时目录可用空间: $tmp_space"
            echo -e "安装目录可用空间: $install_space"
            echo -e "${YELLOW_COLOR}建议清理系统空间后再继续（镜像 + 数据大约需要 2 GB）${RES}"
            if [ ! -t 0 ]; then
                warn "非交互模式：可用空间不足，自动退出以避免阻塞"
                return 1
            fi
            if ! confirm "是否继续？"; then
                exit 1
            fi
        fi
    fi
    return 0
}

# ─────────────────────────── 状态与访问入口 ───────────────────────────

load_env() {
    [ -f "$ENV_FILE" ] || return 1
    ACCESS_HOST=$(sed -n 's/^HTTPS_ACCESS_HOST=//p' "$ENV_FILE" | head -1)
    TLS_MODE=$(sed -n 's/^DSH_TLS_MODE=//p' "$ENV_FILE" | head -1)
    HTTPS_PORT=$(sed -n 's/^DSH_HTTPS_PORT=//p' "$ENV_FILE" | head -1)
    DSH_IMAGE_TAG=$(sed -n 's/^DSH_TAG=//p' "$ENV_FILE" | head -1)
    ACME_EMAIL=$(sed -n 's/^DSH_ACME_EMAIL=//p' "$ENV_FILE" | head -1)
    DEPLOY_MODE=$([ "$TLS_MODE" = "acme" ] && echo domain || echo ip)
    HTTPS_PORT="${HTTPS_PORT:-$DEFAULT_HTTPS_PORT}"
    DSH_IMAGE_TAG="${DSH_IMAGE_TAG:-latest}"
    return 0
}

container_state()  { docker inspect -f '{{.State.Status}}' "$DSH_CONTAINER_NAME" 2>/dev/null || echo absent; }
container_health() { docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}}' "$DSH_CONTAINER_NAME" 2>/dev/null || echo -; }

entry_url() { # 浏览器直接访问的地址
    if [ "$TLS_MODE" = "acme" ]; then
        printf 'https://%s/' "$ACCESS_HOST"
    else
        printf 'https://%s:%s/' "$ACCESS_HOST" "$HTTPS_PORT"
    fi
}

token_url() { # 从日志取 token，并换成用户真正能打开的地址
    local raw
    raw=$(docker logs "$DSH_CONTAINER_NAME" 2>&1 | sed -n 's/.*token=\([^ )]*\).*/\1/p' | head -1)
    [ -n "$raw" ] || return 1
    if [ "$TLS_MODE" = "acme" ]; then
        printf 'https://%s/?token=%s' "$ACCESS_HOST" "$raw"
    else
        printf 'https://%s:%s/?token=%s' "$ACCESS_HOST" "$HTTPS_PORT" "$raw"
    fi
}

check_system_status() {
    echo -e "${GREEN_COLOR}系统状态检查${RES}"
    load_env 2>/dev/null || true

    if [ -f "$ENV_FILE" ]; then
        local st hl
        st=$(container_state); hl=$(container_health)
        case "$st" in
            running) [ "$hl" = "healthy" ] && ok "DeepSeek Harness 容器：运行中 · 健康" || ok "DeepSeek Harness 容器：运行中（健康检查：$hl）" ;;
            absent)  ok "DeepSeek Harness 容器：未安装" ;;
            *)       fail "● DeepSeek Harness 容器：$st" ;;
        esac
        [ "$st" = "running" ] && {
            echo -e "${GREEN_COLOR}● 访问入口：${RES}$(entry_url)"
            echo -e "${GREEN_COLOR}● 证书模式：${RES}$([ "$TLS_MODE" = "acme" ] && echo "Let's Encrypt（acme）" || echo "自签（internal）")"
            echo -e "${GREEN_COLOR}● 镜像版本：${RES}$DSH_IMAGE_TAG"
        }
    else
        fail "● DeepSeek Harness：未安装"
    fi

    # 端口
    if [ -f "$ENV_FILE" ]; then
        local port_to_check="$HTTPS_PORT"
        [ "$TLS_MODE" = "acme" ] && port_to_check="443"
        if ss -tlnp 2>/dev/null | grep -q ":${port_to_check} " || netstat -tlnp 2>/dev/null | grep -q ":${port_to_check} "; then
            ok "端口 ${port_to_check}：已监听"
        else
            fail "● 端口 ${port_to_check}：未监听"
        fi
    fi

    # 磁盘
    echo -e "${GREEN_COLOR}● 磁盘空间：${RES}"
    df -h / | awk 'NR==2 {printf "  根目录：%s 已用，%s 可用（%s）\n", $3, $4, $5}'
    if [ -d "$INSTALL_PATH" ]; then
        df -h "$INSTALL_PATH" | awk 'NR==2 {printf "  安装目录：%s 已用，%s 可用（%s）\n", $3, $4, $5}'
        du -sh "$INSTALL_PATH" 2>/dev/null | awk '{printf "  占用体积：%s\n", $1}'
    fi

    # 内存
    echo -e "${GREEN_COLOR}● 内存使用：${RES}"
    free -h 2>/dev/null | awk 'NR==2 {printf "  总内存：%s，已用：%s，可用：%s\n", $2, $3, $7}'

    # Docker
    if command -v docker >/dev/null 2>&1; then
        echo -e "${GREEN_COLOR}● Docker 状态：${RES}"
        if docker info >/dev/null 2>&1; then
            echo -e "  Docker 服务：运行中"
            if docker ps --format '{{.Names}}' | grep -q "^${DSH_CONTAINER_NAME}$"; then
                echo -e "  DeepSeek Harness 容器：运行中"
            else
                echo -e "  DeepSeek Harness 容器：未运行"
            fi
        else
            echo -e "  Docker 服务：未运行"
        fi
    fi
    echo
}

# ─────────────────────────── 备份 / 恢复 ───────────────────────────

backup_config() {
    echo -e "${CYAN_COLOR}数据备份${RES}"
    if [ ! -d "$INSTALL_PATH/data" ]; then
        fail "错误：未找到数据目录 $INSTALL_PATH/data"
        return 1
    fi

    local backup_dir="$BACKUP_BASE_DIR/backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    echo -e "${BLUE_COLOR}备份到：$backup_dir${RES}"

    if tar -czf "$backup_dir/dsh-data.tar.gz" -C "$INSTALL_PATH" data .env docker-compose.yml 2>/dev/null; then
        ok "备份成功"
        echo -e "备份文件: $backup_dir/dsh-data.tar.gz（$(du -h "$backup_dir/dsh-data.tar.gz" | awk '{print $1}')）"
        echo -e "${YELLOW_COLOR}注意：模型凭据在 data/dsh/.credentials.yaml 内，备份文件请妥善保管${RES}"
    else
        fail "备份失败"
        return 1
    fi
    return 0
}

restore_config() {
    echo -e "${CYAN_COLOR}数据恢复${RES}"
    if [ ! -d "$BACKUP_BASE_DIR" ]; then
        fail "错误：未找到备份目录 $BACKUP_BASE_DIR"
        return 1
    fi

    echo -e "${GREEN_COLOR}可用的备份：${RES}"
    local backup_count=0
    local -a backup_list=()
    for backup_dir in "$BACKUP_BASE_DIR"/backup_*; do
        if [ -f "$backup_dir/dsh-data.tar.gz" ]; then
            backup_count=$((backup_count + 1))
            backup_list+=("$backup_dir")
            echo -e "${GREEN_COLOR}$backup_count${RES} - $(basename "$backup_dir")"
        fi
    done

    if [ "$backup_count" -eq 0 ]; then
        fail "未找到任何备份"
        return 1
    fi

    echo -e "${GREEN_COLOR}x${RES} - 自定义输入备份文件路径"
    echo
    read -r -p "请选择备份 [1-$backup_count/x]: " choice

    local backup_file=""
    if [ "$choice" = "x" ] || [ "$choice" = "X" ]; then
        read -r -p "请输入备份文件路径: " backup_file
    elif [ -z "$choice" ] && [ "$backup_count" -ge 1 ]; then
        backup_file="${backup_list[$((backup_count - 1))]}/dsh-data.tar.gz"   # 空回车 = 用最新的一份
    elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$backup_count" ]; then
        backup_file="${backup_list[$((choice - 1))]}/dsh-data.tar.gz"
    else
        fail "无效的选择"
        return 1
    fi

    [ -f "$backup_file" ] || { fail "错误：备份文件不存在：$backup_file"; return 1; }

    warn "此操作将覆盖当前 data/ 与配置文件"
    if ! confirm "确认恢复？"; then
        echo -e "${YELLOW_COLOR}已取消恢复${RES}"
        return 0
    fi

    check_docker || return 1
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down >/dev/null 2>&1 || true
    if tar -xzf "$backup_file" -C "$INSTALL_PATH"; then
        ok "恢复成功"
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d >/dev/null 2>&1 || true
    else
        fail "恢复失败"
        return 1
    fi
    return 0
}

# ─────────────────────────── 定时更新 ───────────────────────────

setup_auto_update() {
    echo -e "${GREEN_COLOR}设置定时自动更新镜像${RES}"
    echo -e "${GREEN_COLOR}1${RES} - 启用定时更新"
    echo -e "${GREEN_COLOR}2${RES} - 禁用定时更新"
    echo -e "${GREEN_COLOR}3${RES} - 查看当前设置"
    echo -e "${GREEN_COLOR}0${RES} - 返回主菜单"
    echo
    read -r -p "请输入选项 [0-3]: " choice

    case "$choice" in
        1)
            echo -e "${GREEN_COLOR}设置更新时间（cron 格式）${RES}"
            echo -e "${YELLOW_COLOR}默认：每周日凌晨2点 (0 2 * * 0)${RES}"
            echo -e "${YELLOW_COLOR}示例：每天凌晨3点 (0 3 * * *)${RES}"
            read -r -p "请输入 cron 时间表达式 (默认: 0 2 * * 0): " cron_time
            [ -z "$cron_time" ] && cron_time="0 2 * * 0"

            local script_path cron_cmd
            script_path=$(readlink -f "$0")
            cron_cmd="DSH_YES=1 $script_path update $CRON_TAG >> $UPDATE_LOG 2>&1"
            (crontab -l 2>/dev/null | grep -v "$CRON_TAG"; echo "$cron_time $cron_cmd") | crontab -

            ok "定时更新已启用"
            echo -e "${GREEN_COLOR}更新时间：$cron_time${RES}"
            echo -e "${GREEN_COLOR}日志文件：$UPDATE_LOG${RES}"
            ;;
        2)
            crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
            ok "定时更新已禁用"
            ;;
        3)
            echo -e "${GREEN_COLOR}当前 crontab 设置：${RES}"
            crontab -l 2>/dev/null | grep "$CRON_TAG" || echo -e "${YELLOW_COLOR}未设置定时更新${RES}"
            ;;
        0)
            return 0
            ;;
        *)
            fail "无效的选项"
            return 1
            ;;
    esac
}

# ─────────────────────── 访问方式 / 配置文件 ───────────────────────

SELECT_ACCESS() {
    local lan pub
    lan=$(get_local_ip)
    pub=$(get_public_ip || true)

    echo -e "${CYAN_COLOR}配置向导${RES}"
    echo -e "${GREEN_COLOR}访问方式决定证书来源：域名走 Caddy 自动申请 Let's Encrypt，IP 用容器内部 CA 自签。${RES}"

    # 环境变量已给地址 → 自动判定模式
    if [ -n "$ACCESS_HOST" ]; then
        if is_domain "$ACCESS_HOST"; then
            DEPLOY_MODE="domain"; TLS_MODE="acme"
            ok "访问地址（来自环境变量）：$ACCESS_HOST（域名 → Let's Encrypt）"
        else
            DEPLOY_MODE="ip"; TLS_MODE="internal"
            ok "访问地址（来自环境变量）：$ACCESS_HOST（IP → 自签证书）"
        fi
    else
        echo -e "${GREEN_COLOR}1${RES} - 域名（Caddy 自动申请 Let's Encrypt 证书）"
        echo -e "${GREEN_COLOR}2${RES} - IP 访问（默认公网 IP，自签证书）"
        echo
        read -r -p "请输入选项 [1-2] (默认2): " mode_choice
        case "${mode_choice:-2}" in
            1) DEPLOY_MODE="domain"; TLS_MODE="acme" ;;
            *) DEPLOY_MODE="ip"; TLS_MODE="internal" ;;
        esac

        if [ "$DEPLOY_MODE" = "domain" ]; then
            read -r -p "请输入域名（如 dsh.example.com）: " ACCESS_HOST
            ACCESS_HOST="${ACCESS_HOST#http://}"; ACCESS_HOST="${ACCESS_HOST#https://}"; ACCESS_HOST="${ACCESS_HOST%%/*}"
            if ! is_domain "$ACCESS_HOST"; then
                fail "错误：域名格式不正确：$ACCESS_HOST"
                return 1
            fi
            local dns_ip
            dns_ip=$(getent hosts "$ACCESS_HOST" 2>/dev/null | awk '{print $1}' | head -1)
            if [ -z "$dns_ip" ]; then
                warn "域名 $ACCESS_HOST 暂时解析不到 A 记录，Caddy 申请证书会失败（先把解析指到本机的公网 IP）"
            elif [ -n "$pub" ] && [ "$dns_ip" != "$pub" ]; then
                warn "域名解析到 $dns_ip，而本机公网 IP 是 $pub —— 两者不一致时证书申请会失败"
            else
                ok "域名解析正常：$ACCESS_HOST → $dns_ip"
            fi
            read -r -p "ACME 通知邮箱（可留空）: " ACME_EMAIL
            echo -e "${YELLOW_COLOR}提示：域名模式需要 80 与 443 端口对外可达（安全组/防火墙都要放行）${RES}"
        else
            if [ -n "$pub" ]; then
                echo -e "${GREEN_COLOR}探测到：公网 IP ${RES}${pub}${GREEN_COLOR}    内网 IP ${RES}${lan:-未探测到}"
                read -r -p "请输入访问地址 (默认公网 IP ${pub}): " ACCESS_HOST
                [ -z "$ACCESS_HOST" ] && ACCESS_HOST="$pub"
            elif [ -n "$lan" ]; then
                warn "未探测到公网 IP（可能被 NAT/防火墙挡住），只能确定内网 IP $lan"
                read -r -p "请输入访问地址 (默认 ${lan}): " ACCESS_HOST
                [ -z "$ACCESS_HOST" ] && ACCESS_HOST="$lan"
            else
                read -r -p "请输入访问地址（如 203.0.113.10 或 192.168.1.10）: " ACCESS_HOST
            fi
            read -r -p "HTTPS 端口 (默认 ${DEFAULT_HTTPS_PORT}): " HTTPS_PORT
            HTTPS_PORT="${HTTPS_PORT:-$DEFAULT_HTTPS_PORT}"
            case "$HTTPS_PORT" in ''|*[!0-9]*) fail "错误：端口必须是数字"; return 1 ;; esac
        fi
    fi

    valid_host "$ACCESS_HOST" || return 1

    read -r -p "镜像 tag (默认 latest): " tag_input
    DSH_IMAGE_TAG="${tag_input:-latest}"

    # 汇总
    echo
    echo -e "${CYAN_COLOR}即将部署：${RES}"
    echo -e "  ${GREEN_COLOR}访问地址${RES}  $(entry_url)"
    echo -e "  ${GREEN_COLOR}证书    ${RES}  $([ "$TLS_MODE" = "acme" ] && echo "Let's Encrypt（Caddy 自动申请）" || echo "自签（容器内部 CA）")"
    [ "$TLS_MODE" = "acme" ] && echo -e "  ${GREEN_COLOR}邮箱    ${RES}  ${ACME_EMAIL:-未填}"
    echo -e "  ${GREEN_COLOR}镜像    ${RES}  ${DSH_IMAGE}:${DSH_IMAGE_TAG}"
    echo -e "  ${GREEN_COLOR}端口    ${RES}  $([ "$TLS_MODE" = "acme" ] && echo "80, 443" || echo "$HTTPS_PORT")"
    echo -e "  ${GREEN_COLOR}认证    ${RES}  dsh 自带 token（部署后给登录链接）"
    echo -e "  ${GREEN_COLOR}目录    ${RES}  $INSTALL_PATH"
    echo
    if ! confirm "确认以上配置并开始部署？" y; then
        echo -e "${YELLOW_COLOR}已取消${RES}"
        exit 0
    fi
    return 0
}

WRITE_FILES() {
    mkdir -p "$INSTALL_PATH/data/dsh" "$INSTALL_PATH/data/workspace" "$INSTALL_PATH/data/caddy"

    local ports_block
    if [ "$TLS_MODE" = "acme" ]; then
        ports_block='      - "80:80"
      - "443:443"'
    else
        ports_block="      - \"${HTTPS_PORT}:8443\""
    fi

    cat > "$COMPOSE_FILE" <<EOF
# DeepSeek Harness (dsh) — 由 dsh-harness 管理脚本生成，改 .env 即可生效。
#   docker compose up -d    ->  $(entry_url)
name: deepseek-harness

services:
  deepseek-harness:
    image: \${DSH_IMAGE:-${DSH_IMAGE}}:\${DSH_TAG:-${DSH_IMAGE_TAG}}
    container_name: \${CONTAINER_NAME:-${DSH_CONTAINER_NAME}}
    restart: unless-stopped
    networks:
      - dsh-network
    environment:
      # 浏览器输入的名字：打印访问地址、/api 信任围栏、容器内部 CA 的签名对象
      HTTPS_ACCESS_HOST: \${HTTPS_ACCESS_HOST:-${ACCESS_HOST}}
      DSH_TLS_MODE: \${DSH_TLS_MODE:-${TLS_MODE}}
      DSH_ACME_EMAIL: \${DSH_ACME_EMAIL:-${ACME_EMAIL}}
      DSH_HOME: /data/dsh
      DSH_TELEMETRY_DISABLED: "1"
      # 额外需要信任的 authority（逗号分隔），仅严格模式需要
      DSH_TRUSTED_HOSTS: \${DSH_TRUSTED_HOSTS:-}
      # 凭据预置：这里给的密钥在设置页显示为只读来源；留空则进 UI 自己配
      DEEPSEEK_API_KEY: \${DEEPSEEK_API_KEY:-}
      TZ: \${TZ:-Asia/Shanghai}
    volumes:
      - ./data/dsh:/data/dsh
      - ./data/workspace:/workspace
      - ./data/caddy:/data/caddy
      - /etc/localtime:/etc/localtime:ro
    ports:
# HTTPS 前门（容器内 Caddy 监听 8443；域名模式占 80/443 用于 ACME）
${ports_block}
      # 取消注释可绕过 Caddy 直连 dsh（明文 HTTP，token 认证）：
      # - "3080:3080"
    # harness 只往 /data 与 /workspace 写东西，因此根文件系统可以只读
    read_only: true
    tmpfs:
      - /tmp:mode=1777,size=256m
    security_opt:
      - no-new-privileges:true
    healthcheck:
      # 不能用 curl -f：UI 有 token 门禁，未登录会返回 401
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
    name: \${DSH_NETWORK:-${DSH_NETWORK}}
EOF

    cat > "$ENV_FILE" <<EOF
# DeepSeek Harness 部署配置（dsh-harness 生成）
DSH_INSTALL_DIR=${INSTALL_PATH}
CONTAINER_NAME=${DSH_CONTAINER_NAME}
DSH_IMAGE=${DSH_IMAGE}
DSH_TAG=${DSH_IMAGE_TAG}

# ── 访问与证书 ────────────────────────────────────────────────────────────────
# 浏览器要输入的名字：域名 → Caddy 自动申请 Let's Encrypt（映射 80/443）
#                       IP → 容器内部 CA 自签（映射 DSH_HTTPS_PORT）
HTTPS_ACCESS_HOST=${ACCESS_HOST}
DSH_TLS_MODE=${TLS_MODE}
DSH_ACME_EMAIL=${ACME_EMAIL}
DSH_HTTPS_PORT=${HTTPS_PORT}

# ── 网络 ─────────────────────────────────────────────────────────────────────
DSH_NETWORK=${DSH_NETWORK}
# 额外需要信任的 authority（逗号分隔），例如再套一层反代
DSH_TRUSTED_HOSTS=
# 1 = 恢复上游原样围栏（只认回环/容器 IP/声明的 authority）
DSH_STRICT_HOST_FENCE=0

# ── 模型凭据（可选）──────────────────────────────────────────────────────────
DEEPSEEK_API_KEY=
OPENAI_API_KEY=
ANTHROPIC_API_KEY=

# ── 其它 ─────────────────────────────────────────────────────────────────────
TZ=Asia/Shanghai
EOF

    chmod 600 "$ENV_FILE"
    echo compose > "$MARKER_FILE"
    ok "已生成 $COMPOSE_FILE"
    ok "已生成 $ENV_FILE (权限 600)"
}

PULL_IMAGE() {
    if [ "${DSH_NO_MIRROR:-0}" = "1" ]; then
        spin "拉取镜像 ${DSH_IMAGE}:${DSH_IMAGE_TAG}" docker pull "${DSH_IMAGE}:${DSH_IMAGE_TAG}" || {
            fail "拉取失败，请检查网络或稍后重试"
            return 1
        }
        return 0
    fi

    if spin "拉取镜像 ${DSH_IMAGE}:${DSH_IMAGE_TAG}" docker pull "${DSH_IMAGE}:${DSH_IMAGE_TAG}"; then
        return 0
    fi

    warn "直连拉取失败，尝试国内镜像加速"
    local mirror
    for mirror in docker.1ms.run dockerproxy.net docker.m.daocloud.io; do
        if spin "经 $mirror 拉取" docker pull "${mirror}/${DSH_IMAGE}:${DSH_IMAGE_TAG}"; then
            docker tag "${mirror}/${DSH_IMAGE}:${DSH_IMAGE_TAG}" "${DSH_IMAGE}:${DSH_IMAGE_TAG}" 2>/dev/null
            ok "已通过镜像源拉取并重打标签：$mirror"
            return 0
        fi
    done
    fail "拉取失败，请检查网络或稍后重试"
    return 1
}

WAIT_HEALTHY() {
    local waited=0 health start=$SECONDS spinner=0
    while [ "$waited" -lt 120 ]; do
        health=$(container_health)
        if [ "$health" = "healthy" ]; then
            [ "$COLOR_LEVEL" -gt 0 ] && [ -t 1 ] && printf '\r\033[K'
            ok "容器就绪：healthy（$((SECONDS - start))s）"
            return 0
        fi
        if [ "$health" = "unhealthy" ]; then
            [ "$COLOR_LEVEL" -gt 0 ] && [ -t 1 ] && printf '\r\033[K'
            fail "容器不健康，最近日志："
            docker logs --tail 25 "$DSH_CONTAINER_NAME" 2>&1 | sed 's/^/      /'
            return 1
        fi
        if [ "$COLOR_LEVEL" -gt 0 ] && [ -t 1 ]; then
            printf '\r  %s◌%s 等待容器就绪 %s%ss%s\033[K' "$CYAN_COLOR" "$RES" "$DIM" "$((SECONDS - start))" "$RES"
        fi
        sleep 3
        waited=$((waited + 3))
    done
    [ "$COLOR_LEVEL" -gt 0 ] && [ -t 1 ] && printf '\r\033[K'
    warn "等待超时，容器还没报告健康（可能仍在初始化），可执行 dsh-harness logs 查看"
    return 1
}

# 检查目录与已安装状态
CHECK() {
    if [ ! -d "$(dirname "$INSTALL_PATH")" ]; then
        echo -e "${GREEN_COLOR}目录不存在，正在创建...${RES}"
        mkdir -p "$(dirname "$INSTALL_PATH")" || {
            fail "错误：无法创建目录 $(dirname "$INSTALL_PATH")"
            exit 1
        }
    fi

    if [ -f "$MARKER_FILE" ] && [ "${DSH_FORCE:-0}" != "1" ]; then
        echo -e "${YELLOW_COLOR}此位置已经安装（$INSTALL_PATH），将覆盖重建（数据保留）${RES}"
        confirm "继续？" y || exit 0
    fi

    mkdir -p "$INSTALL_PATH" || {
        fail "错误：无法创建安装目录 $INSTALL_PATH"
        exit 1
    }
    ok "安装目录准备就绪：$INSTALL_PATH"
}

# ─────────────────────────────── 安装 ───────────────────────────────

INSTALL() {
    local total=6
    step_head 1 "$total" "环境与 Docker"
    check_docker || return 1

    step_head 2 "$total" "安装目录"
    CHECK || return 1

    step_head 3 "$total" "配置向导"
    SELECT_ACCESS || return 1

    step_head 4 "$total" "生成 docker-compose.yml 与 .env"
    WRITE_FILES || return 1

    step_head 5 "$total" "拉取镜像"
    PULL_IMAGE || return 1

    step_head 6 "$total" "启动容器"
    if ! spin "创建并启动容器" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d; then
        fail "启动失败，最近日志："
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail 30 2>&1 | sed 's/^/      /'
        return 1
    fi
    WAIT_HEALTHY
    return 0
}

SUCCESS() {
    clear_screen
    load_env 2>/dev/null || true
    deploy_panel "✦ DeepSeek Harness 安装成功"

    if ! INSTALL_CLI; then
        warn "命令行工具安装失败，但不影响使用（完整路径 $MANAGER_PATH）"
    fi
    echo
    info "管理：在任意目录输入 ${BOLD}dsh-harness${RES} 打开管理菜单"
    info "常用：dsh-harness status | url | logs | update | backup"
    warn "端口打不开先查云厂商安全组 / 防火墙是否放行"
    echo
    if [ "${DSH_KEEP_SHELL:-0}" != "1" ]; then
        exit 0
    fi
    return 0
}

# ─────────────────────────────── 更新 ───────────────────────────────

UPDATE() {
    [ -f "$MARKER_FILE" ] || {
        fail "错误：未在 $INSTALL_PATH 找到 DeepSeek Harness 部署"
        exit 1
    }
    check_docker || return 1
    load_env 2>/dev/null || true

    # 已是最新摘要则直接跳过（docker manifest 查不到就不判断，照常更新）
    if [ "${DSH_NO_PULL:-0}" != "1" ]; then
        local remote_digest local_digest
        remote_digest=$(docker manifest inspect "${DSH_IMAGE}:${DSH_IMAGE_TAG}" 2>/dev/null | grep -m1 '"digest"' | sed 's/.*"digest": *"\([^"]*\)".*/\1/')
        local_digest=$(docker image inspect "${DSH_IMAGE}:${DSH_IMAGE_TAG}" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//')
        if [ -n "$remote_digest" ] && [ "$remote_digest" = "$local_digest" ]; then
            deploy_panel "✦ 已是最新镜像（${DSH_IMAGE_TAG}）"
            echo
            return 0
        fi
    fi

    if ! confirm "拉取最新镜像并重建容器？（数据保留）" y; then
        dim "已取消"
        return 0
    fi

    local total=3
    step_head 1 "$total" "拉取镜像"
    PULL_IMAGE || {
        fail "更新终止：镜像拉取失败"
        return 1
    }
    step_head 2 "$total" "重建容器"
    if ! spin "重建容器" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d; then
        fail "更新失败，最近日志："
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail 30 2>&1 | sed 's/^/      /'
        return 1
    fi
    step_head 3 "$total" "等待就绪"
    WAIT_HEALTHY
    deploy_panel "✦ 更新完成"
    echo
}

RECONFIG() {
    [ -f "$MARKER_FILE" ] || {
        fail "错误：未在 $INSTALL_PATH 找到 DeepSeek Harness 部署"
        exit 1
    }
    check_docker || return 1
    load_env 2>/dev/null || true
    dim "重新配置会重写 .env 与 compose，并重建容器（数据保留）"

    ACCESS_HOST=""          # 重新走一遍访问方式选择
    local total=4
    step_head 1 "$total" "配置向导"
    SELECT_ACCESS || return 1
    step_head 2 "$total" "写入配置"
    WRITE_FILES || return 1
    step_head 3 "$total" "拉取镜像"
    PULL_IMAGE || return 1
    step_head 4 "$total" "重建容器"
    if ! spin "重建容器" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d; then
        fail "重建失败，最近日志："
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail 30 2>&1 | sed 's/^/      /'
        return 1
    fi
    WAIT_HEALTHY
    deploy_panel "✦ 重新配置完成"
    echo
}

STATUS() {
    [ -f "$ENV_FILE" ] || {
        fail "错误：系统未安装 DeepSeek Harness，请先安装！"
        return 1
    }
    load_env || true
    echo -e "${GREEN_COLOR}运行状态${RES}"
    local st hl
    st=$(container_state); hl=$(container_health)
    case "$st" in
        running) [ "$hl" = "healthy" ] && ok "容器：运行中 · 健康" || ok "容器：运行中（$hl）" ;;
        absent)  fail "● 容器：不存在" ;;
        *)       fail "● 容器：$st" ;;
    esac
    echo -e "${GREEN_COLOR}● 容器名：${RES}$DSH_CONTAINER_NAME"
    echo -e "${GREEN_COLOR}● 访问入口：${RES}$(entry_url)"
    echo -e "${GREEN_COLOR}● 证书模式：${RES}$([ "$TLS_MODE" = "acme" ] && echo "Let's Encrypt" || echo "自签")"
    echo -e "${GREEN_COLOR}● 镜像版本：${RES}${DSH_IMAGE}:${DSH_IMAGE_TAG}"
    echo -e "${GREEN_COLOR}● 数据目录：${RES}$INSTALL_PATH/data"
    echo
}

SHOW_URL() {
    [ -f "$ENV_FILE" ] || {
        fail "错误：系统未安装 DeepSeek Harness，请先安装！"
        return 1
    }
    load_env || true
    echo -e "${GREEN_COLOR}访问入口${RES}"
    echo -e "  HTTPS：$(entry_url)"
    echo -e "  认证 ：dsh 自带 token（下面链接打开一次即可）"
    if [ "$TLS_MODE" = "acme" ]; then
        echo -e "  证书 ：Let's Encrypt（Caddy 自动申请，首次访问可能要等几秒）"
    else
        echo -e "  证书 ：自签（浏览器提示一次风险，继续访问即可）"
    fi
    local login_url
    if login_url=$(token_url); then
        echo -e "  登录 ：$login_url"
        echo -e "${YELLOW_COLOR}  提示：token 每次重启都会变，打开一次即可换到持久 cookie${RES}"
    else
        echo -e "  登录 ：容器日志里还没有 token，稍后重试"
    fi
    echo
}

LOGS() {
    [ -f "$MARKER_FILE" ] || {
        fail "错误：系统未安装 DeepSeek Harness，请先安装！"
        return 1
    }
    check_docker || return 1
    echo -e "${GREEN_COLOR}实时跟踪容器输出（Ctrl+C 退出）${RES}"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f --tail 120
}

SERVICE_ACTION() { # SERVICE_ACTION start|stop|restart
    local action="$1"
    [ -f "$MARKER_FILE" ] || {
        fail "错误：系统未安装 DeepSeek Harness，请先安装！"
        return 1
    }
    check_docker || return 1
    case "$action" in
        start)   docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" start >/dev/null 2>&1 || docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d >/dev/null 2>&1 ;;
        stop)    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" stop >/dev/null 2>&1 ;;
        restart) docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" restart >/dev/null 2>&1 ;;
    esac
    ok "容器已$([ "$action" = "start" ] && echo 启动 || { [ "$action" = "stop" ] && echo 停止 || echo 重启; })"
    [ "$action" != "stop" ] && { load_env 2>/dev/null || true; echo -e "${GREEN_COLOR}● 访问入口：${RES}$(entry_url)"; }
    return 0
}

UNINSTALL() {
    [ -f "$MARKER_FILE" ] || {
        fail "错误：系统未安装 DeepSeek Harness"
        return 1
    }
    load_env 2>/dev/null || true

    fail "警告：卸载后将删除容器与命令行工具（数据可选择保留）"
    if ! confirm "是否确认卸载？"; then
        echo -e "${YELLOW_COLOR}已取消卸载${RES}"
        return 0
    fi

    check_docker && docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down >/dev/null 2>&1 || true

    if confirm "同时删除镜像 ${DSH_IMAGE}:${DSH_IMAGE_TAG}？"; then
        docker rmi "${DSH_IMAGE}:${DSH_IMAGE_TAG}" >/dev/null 2>&1 && ok "镜像已删除"
    fi

    if confirm "同时删除安装目录（含数据 $INSTALL_PATH/data）？"; then
        rm -rf "$INSTALL_PATH"
        ok "已删除 $INSTALL_PATH"
    else
        rm -f "$COMPOSE_FILE" "$MARKER_FILE" "$ENV_FILE"
        ok "已保留数据目录 $INSTALL_PATH/data"
    fi

    # 删除定时更新
    if crontab -l 2>/dev/null | grep -q "$CRON_TAG"; then
        crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab -
        ok "已移除定时更新任务"
    fi

    # 删除命令行工具
    if [ -f "$MANAGER_PATH" ] || [ -L "$COMMAND_LINK" ]; then
        rm -f "$MANAGER_PATH" "$COMMAND_LINK" || warn "删除命令行工具失败，请手动删除：$MANAGER_PATH / $COMMAND_LINK"
        ok "已删除命令行工具"
    fi

    ok "DeepSeek Harness 已卸载"
    exit 0
}

# ─────────────────────────── Docker 子菜单 ───────────────────────────

DOCKER_MENU() {
    echo -e "\n${GREEN_COLOR}Docker 管理${RES}"
    echo -e "${GREEN_COLOR}1${RES} - 查看容器状态"
    echo -e "${GREEN_COLOR}2${RES} - 进入容器 Shell"
    echo -e "${GREEN_COLOR}3${RES} - 查看容器内进程"
    echo -e "${GREEN_COLOR}4${RES} - 启动容器"
    echo -e "${GREEN_COLOR}5${RES} - 停止容器"
    echo -e "${GREEN_COLOR}6${RES} - 重启容器"
    echo -e "${GREEN_COLOR}7${RES} - 删除容器"
    echo -e "${GREEN_COLOR}8${RES} - 安装 / 检查 Docker"
    echo -e "${GREEN_COLOR}0${RES} - 返回主菜单"
    echo
    read -r -p "请输入选项 [0-8]: " docker_choice

    case "$docker_choice" in
        1)
            check_docker && docker ps -a --filter "name=${DSH_CONTAINER_NAME}" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
            ;;
        2)
            check_docker && docker exec -it "$DSH_CONTAINER_NAME" /bin/bash 2>/dev/null || docker exec -it "$DSH_CONTAINER_NAME" /bin/sh
            ;;
        3)
            check_docker && docker top "$DSH_CONTAINER_NAME"
            ;;
        4) SERVICE_ACTION start ;;
        5) SERVICE_ACTION stop ;;
        6) SERVICE_ACTION restart ;;
        7)
            if check_docker && confirm "确认删除容器？"; then
                docker stop "$DSH_CONTAINER_NAME" >/dev/null 2>&1
                docker rm "$DSH_CONTAINER_NAME" >/dev/null 2>&1 && ok "容器已删除"
            fi
            ;;
        8) INSTALL_DOCKER ;;
        0) ;;
        *) fail "无效的选项" ;;
    esac
    return 0
}

# ─────────────────────────── 关于 / CLI ───────────────────────────

SHOW_ABOUT() {
    clear_screen
    banner
    draw_box --title "✦ 关于本脚本" \
        "DeepSeek Harness Manage Script   v1.0.0" \
        "更新日期 2026-09-11" \
        "" \
        "✦ 组件" \
        "   上游   @deepseek-ai/dsh（官方 Web UI）" \
        "   镜像   dockorae/deepseek-harness" \
        "   仓库   https://github.com/MinimaxFlora/deepseek-harness" \
        "   前门   容器内 Caddy：域名走 Let's Encrypt，IP 走内部 CA 自签" \
        "" \
        "✦ 认证" \
        "   dsh 自带「进程 token + 持久 cookie」，本脚本不引入 Basic Auth" \
        "" \
        "✦ 支持的访问方式" \
        "   IP 模式    映射 8443（可改），自签证书，首次部署默认探测公网 IP" \
        "   域名模式   映射 80 + 443，Caddy 自动申请并续期真证书" \
        "   两者可随时用菜单「切换访问方式」互切（数据保留）" \
        "" \
        "✦ 许可证" \
        "   MIT License"
    echo
    printf '  %s维护：MinimaxFlora  ·  上游作者：DeepSeek%s\n' "$DIM" "$RES"
    echo
}

INSTALL_CLI() {
    if [ "$(id -u)" != "0" ]; then
        fail "错误：安装命令行工具需要 root 权限"
        return 1
    fi

    local script_dir script_path
    script_dir=$(cd "$(dirname "$0")" && pwd)
    script_path="$script_dir/$(basename "$0")"
    if [ ! -f "$script_path" ]; then
        fail "错误：找不到源脚本文件：$script_path"
        return 1
    fi

    mkdir -p "$(dirname "$MANAGER_PATH")" || {
        fail "错误：无法创建目录 $(dirname "$MANAGER_PATH")"
        return 1
    }
    cp "$script_path" "$MANAGER_PATH" || {
        fail "错误：无法复制管理脚本到 $MANAGER_PATH"
        return 1
    }
    chmod 755 "$MANAGER_PATH" || {
        fail "错误：设置权限失败"
        rm -f "$MANAGER_PATH"
        return 1
    }

    mkdir -p "$(dirname "$COMMAND_LINK")" || {
        fail "错误：无法创建目录 $(dirname "$COMMAND_LINK")"
        rm -f "$MANAGER_PATH"
        return 1
    }
    ln -sf "$MANAGER_PATH" "$COMMAND_LINK" || {
        fail "错误：创建命令链接失败"
        rm -f "$MANAGER_PATH"
        return 1
    }

    ok "命令行工具安装成功！"
    echo -e "1. ${GREEN_COLOR}$(pad 'dsh-harness' 25)${RES}- 快捷命令（打开管理菜单）"
    echo -e "2. ${GREEN_COLOR}$(pad 'deepseek-harness-manager' 25)${RES}- 完整管理命令"
    return 0
}

# 部署完成后的成框信息（更新 / 重新配置也用它）
deploy_panel() { # deploy_panel <标题> —— 成框部署信息：地址 / 登录链接 / 认证证书 / 数据与命令
    local title="${1:-✦ 部署完成}" pub lan login_url size avail cert
    load_env 2>/dev/null || true
    [ -n "$HTTPS_PORT" ] || HTTPS_PORT="$DEFAULT_HTTPS_PORT"
    [ -n "$ACCESS_HOST" ] || ACCESS_HOST="$(get_public_ip || get_local_ip || true)"
    pub=$(get_public_ip || true)
    lan=$(get_local_ip || true)
    login_url=$(token_url || true)
    size=$(du -sh "$INSTALL_PATH/data" 2>/dev/null | awk '{print $1}')
    avail=$(df -h "$INSTALL_PATH" 2>/dev/null | awk 'NR==2 {print $4" 可用"}')
    if [ "$TLS_MODE" = "acme" ]; then
        cert="Let's Encrypt（Caddy 自动申请 / 续期）"
    else
        cert="自签（容器内部 CA，浏览器提示一次风险）"
    fi

    local -a b=()
    b+=("✦ 访问地址")
    if [ "$TLS_MODE" = "acme" ]; then
        b+=("     https://${ACCESS_HOST}/")
    else
        [ -n "$lan" ] && b+=("   内网  https://${lan}:${HTTPS_PORT}/")
        b+=("   公网  https://${pub:-$ACCESS_HOST}:${HTTPS_PORT}/")
    fi
    b+=("")
    b+=("✦ 首次登录链接")
    b+=("     ${login_url:-稍后执行 dsh-harness url 获取}")
    b+=("")
    b+=("✦ 认证与证书")
    b+=("   认证  dsh 自带 token + cookie（无需额外账号密码）")
    b+=("   证书  ${cert}")
    b+=("   镜像  ${DSH_IMAGE}:${DSH_IMAGE_TAG:-latest}")
    b+=("")
    b+=("✦ 数据与命令")
    b+=("   目录  ${INSTALL_PATH}/data${size:+（已用 ${size}${avail:+，磁盘 ${avail}}）}")
    b+=("   命令  dsh-harness  ← 菜单 / 状态 / 日志 / 更新 / 备份")

    echo
    draw_box --title "$title" "${b[@]}"
    echo
    dim "带 token 的链接等于钥匙，不要外发；token 每次重启都会变。"
}

deploy_result() { deploy_panel "✦ $1"; }

# ─────────────────────────────── 主菜单 ───────────────────────────────

menu_section() { # 菜单分组标题
    printf '\n  %s▌%s %s%s%s\n' "$(grad_esc 0 2)" "$RES" "$BOLD" "$1" "$RES"
}

menu_item() { # menu_item <编号> <名称> [说明]
    local num="$1" name="$2" note="${3:-}"
    printf '   %s%2s%s  %s%s%s  %s%s%s\n' \
        "$(grad_esc "$num" 18)" "$num" "$RES" \
        "$BOLD" "$(pad "$name" 22)" "$RES" \
        "$DIM" "$note" "$RES"
}

# ────────────────── 访问方式切换（IP ⇄ 域名，数据保留）──────────────────

port_owner() { # port_owner <端口> → 占用者（没有则空）
    local p=":$1"
    ss -lntp 2>/dev/null | awk -v p="$p" '$4 ~ (p "$") {print $NF; exit}' && return 0
    netstat -lntp 2>/dev/null | awk -v p="$p" '$4 ~ (p "$") {print $NF; exit}'
}

check_port_free() { # check_port_free <端口...> —— 有占用返回 1
    local rc=0 p who
    for p in "$@"; do
        who=$(port_owner "$p")
        if [ -n "$who" ]; then
            fail "端口 $p 已被占用：$who"
            rc=1
        fi
    done
    [ "$rc" -eq 0 ] && ok "端口 $* 空闲"
    return "$rc"
}

ADD_DOMAIN() { # ADD_DOMAIN [域名] [邮箱] —— 切到域名 + Let's Encrypt（按选择：IP 入口随之关闭）
    local domain="${1:-}" email="${2:-}"
    if [ -z "$domain" ]; then
        read -r -p "请输入域名（如 dsh.example.com）: " domain
    fi
    domain="${domain#http://}"; domain="${domain#https://}"; domain="${domain%%/*}"
    is_domain "$domain" || {
        fail "域名格式不正确：$domain"
        return 1
    }

    local pub dns_ip
    pub=$(get_public_ip || true)
    dns_ip=$(getent hosts "$domain" 2>/dev/null | awk '{print $1}' | head -1)
    if [ -z "$dns_ip" ]; then
        warn "域名 $domain 暂时解析不到 A 记录，Caddy 申请证书会失败（先指向本机公网 IP ${pub:-?}）"
    elif [ -n "$pub" ] && [ "$dns_ip" != "$pub" ]; then
        warn "域名解析到 $dns_ip，而本机公网 IP 是 $pub —— 不一致时证书申请会失败"
    else
        ok "域名解析正常：$domain → $dns_ip"
    fi

    if [ -z "$email" ]; then
        read -r -p "ACME 通知邮箱（可留空）: " email
    fi

    dim "切换后只保留域名入口（IP 地址不再提供服务），并且需要 80 / 443 对外可达"
    if ! confirm "确认切换为域名访问？" y; then
        dim "已取消"
        return 0
    fi

    check_port_free 80 443 || {
        fail "请先释放 80 / 443（占用者见上）再切换"
        return 1
    }

    ACCESS_HOST="$domain"
    ACME_EMAIL="${email:-$ACME_EMAIL}"
    TLS_MODE="acme"
    DEPLOY_MODE="domain"
    HTTPS_PORT="$DEFAULT_HTTPS_PORT"

    local total=3
    step_head 1 "$total" "写入配置（80 / 443 + ACME）"
    WRITE_FILES || return 1
    step_head 2 "$total" "重建容器"
    if ! spin "重建容器（域名 + Let's Encrypt）" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d; then
        fail "重建失败，最近日志："
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail 30 2>&1 | sed 's/^/      /'
        return 1
    fi
    step_head 3 "$total" "等待就绪（首次签发证书可能需要几秒）"
    WAIT_HEALTHY
    deploy_panel "✦ 已切换为域名访问（Let's Encrypt）"
    echo
}

SWITCH_TO_IP() { # SWITCH_TO_IP [地址] [端口] —— 切回 IP + 自签
    local host="${1:-}" port="${2:-}" pub lan
    pub=$(get_public_ip || true); lan=$(get_local_ip || true)

    if [ -z "$host" ]; then
        read -r -p "访问地址（默认公网 IP ${pub:-$lan}）: " host
        host="${host:-${pub:-$lan}}"
    fi
    valid_host "$host" || return 1
    if [ -z "$port" ]; then
        read -r -p "HTTPS 端口（默认 $DEFAULT_HTTPS_PORT）: " port
        port="${port:-$DEFAULT_HTTPS_PORT}"
    fi
    case "$port" in ''|*[!0-9]*) fail "端口必须是数字"; return 1 ;; esac

    dim "切回 IP 模式后域名入口不再提供服务"
    if ! confirm "确认切换为 IP 访问？" y; then
        dim "已取消"
        return 0
    fi
    check_port_free "$port" || {
        fail "请先释放端口 $port 再切换"
        return 1
    }

    ACCESS_HOST="$host"
    TLS_MODE="internal"
    DEPLOY_MODE="ip"
    HTTPS_PORT="$port"

    local total=3
    step_head 1 "$total" "写入配置（$port + 自签）"
    WRITE_FILES || return 1
    step_head 2 "$total" "重建容器"
    if ! spin "重建容器（IP + 自签证书）" docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d; then
        fail "重建失败，最近日志："
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail 30 2>&1 | sed 's/^/      /'
        return 1
    fi
    step_head 3 "$total" "等待就绪"
    WAIT_HEALTHY
    deploy_panel "✦ 已切换为 IP 访问（自签证书）"
    echo
}

SWITCH_ACCESS() { # 交互入口：先 IP 后加域名 / 也可切回 IP
    [ -f "$MARKER_FILE" ] || {
        fail "错误：系统未安装 DeepSeek Harness，请先安装！"
        return 1
    }
    check_docker || return 1
    load_env 2>/dev/null || true

    echo -e "${CYAN_COLOR}切换访问方式${RES}"
    if [ "$TLS_MODE" = "acme" ]; then
        info "当前：域名模式 · https://${ACCESS_HOST}/"
        echo -e "${GREEN_COLOR}1${RES} - 换一个域名（重新申请证书）"
        echo -e "${GREEN_COLOR}2${RES} - 切回 IP 模式（自签证书）"
        echo -e "${GREEN_COLOR}0${RES} - 返回主菜单"
        echo
        read -r -p "请输入选项 [0-2]: " choice
        case "$choice" in
            1) ADD_DOMAIN ;;
            2) SWITCH_TO_IP ;;
            0) ;;
            *) fail "无效的选项" ;;
        esac
    else
        info "当前：IP 模式 · $(entry_url)"
        echo -e "${GREEN_COLOR}1${RES} - 添加域名并切到 Let's Encrypt（推荐，需域名解析 + 80/443 放行）"
        echo -e "${GREEN_COLOR}2${RES} - 改 IP 地址 / 端口（仍是自签）"
        echo -e "${GREEN_COLOR}0${RES} - 返回主菜单"
        echo
        read -r -p "请输入选项 [0-2]: " choice
        case "$choice" in
            1) ADD_DOMAIN ;;
            2) SWITCH_TO_IP ;;
            0) ;;
            *) fail "无效的选项" ;;
        esac
    fi
    return 0
}

SHOW_MENU() {
    banner
    printf '  %s输入编号后回车，菜单随时可用 dsh-harness 调出%s\n' "$DIM" "$RES"

    menu_section "基础功能"
    menu_item 1  "安装 DeepSeek Harness" "域名 / IP 向导式部署"
    menu_item 2  "切换访问方式" "IP ⇄ 域名（后加域名走这里）"
    menu_item 3  "重新配置" "端口 / 镜像 tag"
    menu_item 4  "更新镜像并重建" "数据保留"
    menu_item 5  "卸载" "数据可选保留"

    menu_section "服务管理"
    menu_item 6  "查看运行状态" "容器健康 + 访问入口"
    menu_item 7  "访问入口 / 登录链接" "带 token，打开一次即可"
    menu_item 8  "启动容器"
    menu_item 9  "停止容器"
    menu_item 10 "重启容器"
    menu_item 11 "查看日志" "Ctrl+C 退出"

    menu_section "配置管理"
    menu_item 12 "备份数据" "data + .env + compose"
    menu_item 13 "恢复数据" "默认取最新备份"

    menu_section "高级选项"
    menu_item 14 "Docker 容器管理" "状态 / 进容器 / 启停 / 删除"
    menu_item 15 "定时更新镜像" "写入 crontab"
    menu_item 16 "系统状态" "容器 / 端口 / 磁盘 / 内存"
    menu_item 17 "关于"
    menu_item 0  "退出脚本"
    echo
    printf '  %s请输入选项 [0-17]:%s ' "$BOLD" "$RES"
    read -r choice || { printf '\n'; return 0; }   # stdin 到 EOF（自动化/管道）直接返回，避免空转
    case "$choice" in "") printf '\n'; return 0 ;; esac

    case "$choice" in
        1)  DSH_KEEP_SHELL=1; INSTALL && SUCCESS ;;
        2)  SWITCH_ACCESS ;;
        3)  RECONFIG ;;
        4)  UPDATE ;;
        5)  UNINSTALL ;;
        6)  STATUS ;;
        7)  SHOW_URL ;;
        8)  SERVICE_ACTION start ;;
        9)  SERVICE_ACTION stop ;;
        10) SERVICE_ACTION restart ;;
        11) LOGS ;;
        12) backup_config ;;
        13) restore_config ;;
        14) DOCKER_MENU ;;
        15) setup_auto_update ;;
        16) check_system_status ;;
        17) SHOW_ABOUT ;;
        0)  exit 0 ;;
        *)  fail "无效的选项" ;;
    esac
}

# ─────────────────────────────── 入口 ───────────────────────────────

if [ $# -eq 0 ]; then
    while true; do
        SHOW_MENU
        echo
        read -r -s -n1 -p "按任意键继续 ... " || { echo; exit 0; }
        clear_screen
    done
elif [ "$1" = "install" ]; then
    check_disk_space || exit 1
    INSTALL && { DSH_KEEP_SHELL="${DSH_KEEP_SHELL:-0}" SUCCESS; } || exit 1
elif [ "$1" = "update" ]; then
    check_disk_space || exit 1
    UPDATE && { DSH_KEEP_SHELL=1 deploy_result "更新完成！"; exit 0; }
elif [ "$1" = "uninstall" ]; then
    UNINSTALL
elif [ "$1" = "config" ]; then
    RECONFIG
elif [ "$1" = "switch" ]; then
    SWITCH_ACCESS
elif [ "$1" = "domain" ]; then
    load_env 2>/dev/null || true
    ADD_DOMAIN "${2:-}" "${3:-}"
elif [ "$1" = "ip" ]; then
    load_env 2>/dev/null || true
    SWITCH_TO_IP "${2:-}" "${3:-}"
elif [ "$1" = "status" ]; then
    STATUS
elif [ "$1" = "url" ]; then
    SHOW_URL
elif [ "$1" = "logs" ]; then
    LOGS
elif [ "$1" = "start" ] || [ "$1" = "stop" ] || [ "$1" = "restart" ]; then
    SERVICE_ACTION "$1"
elif [ "$1" = "backup" ]; then
    backup_config
elif [ "$1" = "restore" ]; then
    restore_config
elif [ "$1" = "docker" ]; then
    DOCKER_MENU
elif [ "$1" = "docker-install" ]; then
    INSTALL_DOCKER
elif [ "$1" = "about" ]; then
    SHOW_ABOUT
elif [ "$1" = "--help" ] || [ "$1" = "-h" ] || [ "$1" = "help" ]; then
    cat <<EOF
DeepSeek Harness Manage Script v1.0.0

用法: $0 [命令] [安装路径]

  $0                        显示交互菜单
  $0 install [安装路径]      安装（默认 $DEFAULT_INSTALL_PATH）
  $0 update                 拉取最新镜像并重建（数据保留）
  $0 uninstall              卸载（数据可选择保留）
  $0 config                 重新配置（域名 / 端口 / 镜像 tag）
  $0 switch                 交互式切换访问方式（IP ⇄ 域名）
  $0 domain <域名> [邮箱]    切到域名访问：Caddy 申请 Let's Encrypt，映射 80/443
  $0 ip [地址] [端口]        切回 IP 访问：自签证书（端口默认 8443）
  $0 status                 运行状态
  $0 url                    访问入口 + 首次登录链接
  $0 logs                   实时日志
  $0 start|stop|restart     容器启停
  $0 backup|restore         数据备份 / 恢复
  $0 docker-install         安装 / 检查 Docker
  $0 about                  关于本脚本

环境变量（跳过向导，适合自动化）:
  DSH_DOMAIN        域名，例如 dsh.example.com（配 DSH_ACME_EMAIL 走 Let's Encrypt）
  DSH_HOST          显式访问地址（域名或 IP），优先于 DSH_DOMAIN
  DSH_ACME_EMAIL    ACME 通知邮箱
  DSH_HTTPS_PORT    IP 模式的 HTTPS 端口，默认 $DEFAULT_HTTPS_PORT
  DSH_TAG           镜像 tag，默认 latest
  DSH_IMAGE         镜像名，默认 $DSH_IMAGE
  DSH_INSTALL_DIR   安装目录，默认 $DEFAULT_INSTALL_PATH
  DSH_NETWORK       复用已有 docker 网络时的网络名
  DSH_NO_MIRROR=1   强制直连拉镜像
  DSH_COLOR_LEVEL   0/1/2/3 强制颜色能力（测试用；0 = 无颜色）
  NO_COLOR=1        关闭颜色（遵循 NO_COLOR 约定）
  DSH_YES=1         所有确认自动回答 yes（定时更新任务用）
  DSH_FORCE=1       已安装时直接覆盖重装，不再询问

认证说明：不做 Basic Auth。dsh 自带「进程 token + 持久 cookie」，
部署完用带 ?token= 的地址打开一次即可（$0 url 会打印可用链接）。
EOF
else
    fail "错误的命令：$1"
    echo -e "用法: $0 install [安装路径]   # 安装 DeepSeek Harness"
    echo -e "     $0 update               # 拉取最新镜像并重建"
    echo -e "     $0 uninstall            # 卸载"
    echo -e "     $0                      # 显示交互菜单"
    echo -e "     $0 --help               # 查看全部命令"
    exit 1
fi
