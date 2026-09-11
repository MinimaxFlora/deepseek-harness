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
RED_COLOR=$'[1;31m'
GREEN_COLOR=$'[1;32m'
YELLOW_COLOR=$'[1;33m'
BLUE_COLOR=$'[1;34m'
CYAN_COLOR=$'[1;36m'
PURPLE_COLOR=$'[1;35m'
RES=$'[0m'

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
   [ "$1" = "start" ] || [ "$1" = "stop" ] || [ "$1" = "restart" ]; then
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

print_line() { # 成框输出用的一行（对齐到 box 宽度）
    local text="$1" width="${2:-50}"
    printf '│ %s%s │\n' "$text" "$(pad '' $((width - $(str_width "$text"))))"
}

draw_box() { # draw_box <行...>：自动按显示宽度对齐的方框
    local -a lines=("$@")
    local max=50 i w
    for i in "${!lines[@]}"; do
        w=$(str_width "${lines[$i]}")
        [ "$w" -gt "$max" ] && max=$w
    done
    echo -e "${GREEN_COLOR}┌$(rule $((max + 2)))┐${RES}"
    for i in "${!lines[@]}"; do
        w=$(str_width "${lines[$i]}")
        printf '%s│ %s%s │%s\n' "$GREEN_COLOR" "${lines[$i]}" "$(pad '' $((max - w)))" "$RES"
    done
    echo -e "${GREEN_COLOR}└$(rule $((max + 2)))┘${RES}"
}

ok()   { echo -e "${GREEN_COLOR}●${RES} $*"; }
info() { echo -e "${CYAN_COLOR}→${RES} $*"; }
warn() { echo -e "${YELLOW_COLOR}温馨提示：$*${RES}"; }
fail() { echo -e "${RED_COLOR}$*${RES}"; }

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
    echo -e "${GREEN_COLOR}拉取镜像 ${DSH_IMAGE}:${DSH_IMAGE_TAG} ...${RES}"
    if [ "${DSH_NO_MIRROR:-0}" = "1" ]; then
        docker pull "${DSH_IMAGE}:${DSH_IMAGE_TAG}" || {
            fail "拉取失败"
            return 1
        }
        return 0
    fi

    # 国内机器先试镜像加速，失败再直连
    if docker pull "${DSH_IMAGE}:${DSH_IMAGE_TAG}"; then
        return 0
    fi
    warn "直连拉取失败，尝试走镜像加速"
    local mirror
    for mirror in docker.1ms.run dockerproxy.net docker.m.daocloud.io; do
        if docker pull "${mirror}/${DSH_IMAGE}:${DSH_IMAGE_TAG}" >/dev/null 2>&1; then
            docker tag "${mirror}/${DSH_IMAGE}:${DSH_IMAGE_TAG}" "${DSH_IMAGE}:${DSH_IMAGE_TAG}"
            ok "已通过镜像源拉取：$mirror"
            return 0
        fi
    done
    fail "拉取失败，请检查网络或稍后重试"
    return 1
}

WAIT_HEALTHY() {
    local waited=0 health
    echo -e "${GREEN_COLOR}等待容器就绪...${RES}"
    while [ "$waited" -lt 120 ]; do
        health=$(container_health)
        [ "$health" = "healthy" ] && { ok "容器状态：healthy"; return 0; }
        case "$health" in
            unhealthy)
                fail "容器不健康，最近日志："
                docker logs --tail 25 "$DSH_CONTAINER_NAME" 2>&1 | sed 's/^/    /'
                return 1
                ;;
        esac
        sleep 3
        waited=$((waited + 3))
        printf '\r  %s已等待 %ss%s' "$YELLOW_COLOR" "$waited" "$RES"
    done
    printf '\n'
    warn "等待超时，容器还没报告健康（可能还在初始化），可执行 dsh-harness logs 查看"
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
    check_docker || return 1
    CHECK || return 1
    SELECT_ACCESS || return 1
    WRITE_FILES || return 1
    PULL_IMAGE || return 1

    echo -e "${GREEN_COLOR}创建并启动容器...${RES}"
    if ! docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d; then
        fail "启动失败，最近日志："
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail 30 2>&1 | sed 's/^/    /'
        return 1
    fi
    WAIT_HEALTHY
    return 0
}

SUCCESS() {
    clear_screen

    local pub lan login_url
    load_env 2>/dev/null || true
    pub=$(get_public_ip || true)
    lan=$(get_local_ip || true)
    login_url=$(token_url || true)
    [ -n "$HTTPS_PORT" ] || HTTPS_PORT="$DEFAULT_HTTPS_PORT"
    [ -n "$ACCESS_HOST" ] || ACCESS_HOST="${pub:-$lan}"

    draw_box \
        "DeepSeek Harness 安装成功！" \
        "" \
        "镜像信息：${DSH_IMAGE}:${DSH_IMAGE_TAG:-latest}" \
        "" \
        "访问地址：" \
        "  公网：$([ "$TLS_MODE" = "acme" ] && echo "https://${ACCESS_HOST}/" || echo "https://${pub:-$ACCESS_HOST}:${HTTPS_PORT}/")" \
        "  内网：$([ "$TLS_MODE" = "acme" ] && echo "https://${ACCESS_HOST}/" || echo "https://${lan:-$ACCESS_HOST}:${HTTPS_PORT}/")" \
        "" \
        "证书模式：$([ "$TLS_MODE" = "acme" ] && echo "Let's Encrypt（acme）" || echo "自签（internal，浏览器提示一次风险）")" \
        "数据目录：$INSTALL_PATH" \
        "认证方式：dsh 自带 token（无额外账号密码）" \
        "" \
        "首次登录（打开一次即可换持久 cookie）：" \
        "  ${login_url:-稍后执行 dsh-harness url 获取}"

    # 安装命令行工具
    if ! INSTALL_CLI; then
        warn "命令行工具安装失败，但不影响使用（可用完整路径 $MANAGER_PATH）"
    fi

    echo -e "\n管理: 在任意目录输入 ${GREEN_COLOR}dsh-harness${RES} 打开管理菜单"
    echo -e "常用: ${GREEN_COLOR}dsh-harness status | url | logs | update${RES}"
    echo
    warn "如果端口无法访问，请检查服务器安全组、防火墙和服务状态"
    echo
    if [ "${DSH_KEEP_SHELL:-0}" != "1" ]; then
        exit 0
    fi
}

# ─────────────────────────────── 更新 ───────────────────────────────

UPDATE() {
    [ -f "$MARKER_FILE" ] || {
        fail "错误：未在 $INSTALL_PATH 找到 DeepSeek Harness 部署"
        exit 1
    }
    check_docker || return 1
    load_env 2>/dev/null || true

    echo -e "${GREEN_COLOR}开始更新 DeepSeek Harness ...${RES}"

    # 读取当前 / 最新镜像摘要，判断是否需要更新
    local need_pull=0
    if [ "${DSH_NO_PULL:-0}" = "1" ]; then
        need_pull=0
    else
        local remote_digest local_digest
        remote_digest=$(docker manifest inspect "${DSH_IMAGE}:${DSH_IMAGE_TAG}" 2>/dev/null | grep -m1 '"digest"' | sed 's/.*"digest": *"\([^"]*\)".*/\1/')
        local_digest=$(docker image inspect "${DSH_IMAGE}:${DSH_IMAGE_TAG}" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//')
        if [ -n "$remote_digest" ] && [ "$remote_digest" = "$local_digest" ]; then
            ok "当前已是最新镜像（${DSH_IMAGE_TAG}，${local_digest:0:19}…），无需更新"
            return 0
        fi
        need_pull=1
    fi

    if ! confirm "拉取最新镜像并重建容器？（数据保留）" y; then
        echo -e "${YELLOW_COLOR}已取消${RES}"
        return 0
    fi

    if [ "$need_pull" = "1" ]; then
        PULL_IMAGE || {
            fail "更新终止：镜像拉取失败"
            return 1
        }
    fi

    echo -e "${GREEN_COLOR}重建容器...${RES}"
    if ! docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d; then
        fail "更新失败，最近日志："
        docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs --tail 30 2>&1 | sed 's/^/    /'
        return 1
    fi
    WAIT_HEALTHY
    deploy_result "更新完成！"
}

RECONFIG() {
    [ -f "$MARKER_FILE" ] || {
        fail "错误：未在 $INSTALL_PATH 找到 DeepSeek Harness 部署"
        exit 1
    }
    check_docker || return 1
    load_env 2>/dev/null || true
    echo -e "${GREEN_COLOR}重新配置会重写 .env 与 compose，并重建容器（数据保留）${RES}"

    # 允许重新选择访问方式
    ACCESS_HOST=""
    SELECT_ACCESS || return 1
    WRITE_FILES || return 1
    PULL_IMAGE || return 1
    if ! docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d; then
        fail "重建失败"
        return 1
    fi
    WAIT_HEALTHY
    deploy_result "重新配置完成！"
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
    draw_box \
        "DeepSeek Harness Manage Script" \
        "" \
        "版本信息：" \
        "  脚本版本: 1.0.0" \
        "  更新日期: 2026-09-11" \
        "" \
        "DeepSeek Harness：" \
        "  上游包  : @deepseek-ai/dsh" \
        "  镜像    : dockorae/deepseek-harness" \
        "  仓库    : https://github.com/MinimaxFlora/deepseek-harness" \
        "" \
        "作者信息：" \
        "  维护: MinimaxFlora" \
        "" \
        "许可证：" \
        "  MIT License" \
        "" \
        "支持平台：" \
        "  架构: x86_64（arm64 需自行构建镜像）" \
        "  系统: Linux + Docker（不限 init）"
    echo
    echo -e "${YELLOW_COLOR}感谢使用 DeepSeek Harness 管理脚本！${RES}"
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
deploy_result() {
    local title="$1" pub lan login_url
    load_env 2>/dev/null || true
    pub=$(get_public_ip || true)
    lan=$(get_local_ip || true)
    login_url=$(token_url || true)
    echo
    draw_box \
        "$title" \
        "" \
        "镜像信息：${DSH_IMAGE}:${DSH_IMAGE_TAG:-latest}" \
        "" \
        "访问地址：" \
        "  公网：$([ "$TLS_MODE" = "acme" ] && echo "https://${ACCESS_HOST}/" || echo "https://${pub:-$ACCESS_HOST}:${HTTPS_PORT}/")" \
        "  内网：$([ "$TLS_MODE" = "acme" ] && echo "https://${ACCESS_HOST}/" || echo "https://${lan:-$ACCESS_HOST}:${HTTPS_PORT}/")" \
        "" \
        "首次登录（打开一次即可换持久 cookie）：" \
        "  ${login_url:-稍后执行 dsh-harness url 获取}" \
        "" \
        "数据目录：$INSTALL_PATH"
    echo
    warn "如果端口无法访问，请检查服务器安全组、防火墙和服务状态"
    echo
}

# ─────────────────────────────── 主菜单 ───────────────────────────────

SHOW_MENU() {
    echo -e "\n欢迎使用 DeepSeek Harness 管理脚本 \n"
    echo -e "${GREEN_COLOR}基础功能：${RES}"
    echo -e "${GREEN_COLOR}1${RES} - 安装 DeepSeek Harness"
    echo -e "${GREEN_COLOR}2${RES} - 重新配置（域名 / 端口 / 镜像 tag）"
    echo -e "${GREEN_COLOR}3${RES} - 更新镜像并重建"
    echo -e "${GREEN_COLOR}4${RES} - 卸载 DeepSeek Harness"
    echo -e "${GREEN_COLOR}-------------------${RES}"
    echo -e "${GREEN_COLOR}服务管理：${RES}"
    echo -e "${GREEN_COLOR}5${RES} - 查看运行状态"
    echo -e "${GREEN_COLOR}6${RES} - 查看访问入口 / 登录链接"
    echo -e "${GREEN_COLOR}7${RES} - 启动容器"
    echo -e "${GREEN_COLOR}8${RES} - 停止容器"
    echo -e "${GREEN_COLOR}9${RES} - 重启容器"
    echo -e "${GREEN_COLOR}10${RES} - 查看日志"
    echo -e "${GREEN_COLOR}-------------------${RES}"
    echo -e "${GREEN_COLOR}配置管理：${RES}"
    echo -e "${GREEN_COLOR}11${RES} - 备份数据"
    echo -e "${GREEN_COLOR}12${RES} - 恢复数据"
    echo -e "${GREEN_COLOR}-------------------${RES}"
    echo -e "${GREEN_COLOR}高级选项：${RES}"
    echo -e "${GREEN_COLOR}13${RES} - Docker 容器管理"
    echo -e "${GREEN_COLOR}14${RES} - 定时更新镜像"
    echo -e "${GREEN_COLOR}15${RES} - 系统状态"
    echo -e "${GREEN_COLOR}16${RES} - 关于"
    echo -e "${GREEN_COLOR}-------------------${RES}"
    echo -e "${GREEN_COLOR}0${RES} - 退出脚本"
    echo
    read -r -p "请输入选项 [0-16]: " choice

    case "$choice" in
        1)  DSH_KEEP_SHELL=1; INSTALL && SUCCESS ;;
        2)  RECONFIG ;;
        3)  UPDATE ;;
        4)  UNINSTALL ;;
        5)  STATUS ;;
        6)  SHOW_URL ;;
        7)  SERVICE_ACTION start ;;
        8)  SERVICE_ACTION stop ;;
        9)  SERVICE_ACTION restart ;;
        10) LOGS ;;
        11) backup_config ;;
        12) restore_config ;;
        13) DOCKER_MENU ;;
        14) setup_auto_update ;;
        15) check_system_status ;;
        16) SHOW_ABOUT ;;
        0)  exit 0 ;;
        *)  fail "无效的选项" ;;
    esac
}

# ─────────────────────────────── 入口 ───────────────────────────────

if [ $# -eq 0 ]; then
    while true; do
        SHOW_MENU
        echo
        read -r -s -n1 -p "按任意键继续 ... "
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
