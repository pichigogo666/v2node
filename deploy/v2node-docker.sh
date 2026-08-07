#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME='v2node'
DEFAULT_INSTALL_DIR='/opt/v2node-docker'
DEFAULT_IMAGE_REPO='ghcr.io/pichigogo666/v2node'
DEFAULT_IMAGE_TAG='latest'

COMMAND='install'
INSTALL_DIR="${V2NODE_INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
IMAGE_REPO="${V2NODE_IMAGE_REPO:-$DEFAULT_IMAGE_REPO}"
IMAGE_TAG="${V2NODE_IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
IMAGE_REPO_EXPLICIT=0
IMAGE_TAG_EXPLICIT=0
API_HOST=''
NODE_ID=''
API_KEY=''
NODE_PROTOCOL=''
NODE_PORT=''
REPLACE_NATIVE=0
OPEN_FIREWALL=1
PURGE=0
ASSUME_YES=0
FOLLOW_LOGS=0

log() {
    printf '[%s] %s\n' "$APP_NAME" "$*"
}

warn() {
    printf '[%s] 警告：%s\n' "$APP_NAME" "$*" >&2
}

die() {
    printf '[%s] 错误：%s\n' "$APP_NAME" "$*" >&2
    exit 1
}

usage() {
    cat <<'EOF'
v2node Docker 一键部署脚本

用法：
  sudo bash v2node-docker.sh install [选项]
  sudo bash v2node-docker.sh update [--image-repo REPO] [--image-tag TAG]
  sudo bash v2node-docker.sh status
  sudo bash v2node-docker.sh logs [-f]
  sudo bash v2node-docker.sh restart
  sudo bash v2node-docker.sh uninstall [--purge] [--yes]

install 选项：
  --api-host URL       V2Board 节点 API 地址，例如 https://panel.example.com
  --node-id ID         V2Board 中 v2node 类型的节点 ID
  --api-key KEY        节点通信密钥；省略时会隐藏输入，避免写进命令历史
  --image-repo REPO    Docker 镜像仓库，默认 ghcr.io/pichigogo666/v2node
  --image-tag TAG      自有 GHCR 镜像标签，默认 latest
  --install-dir DIR    安装目录，默认 /opt/v2node-docker
  --replace-native     停止并禁用已有的原生 v2node systemd 服务
  --no-firewall        不自动放行系统防火墙中的节点端口

uninstall 选项：
  --purge              同时删除配置和备份；默认只删除容器、保留文件
  --yes, -y            跳过删除确认

示例：
  sudo bash v2node-docker.sh install \
    --api-host https://panel.example.com \
    --node-id 1

说明：
  脚本使用 host 网络，节点真实监听端口由 V2Board 后台配置决定。
  通信密钥不会显示在部署结果或日志摘要中。
EOF
}

parse_args() {
    if [[ $# -gt 0 && "$1" != --* && "$1" != '-f' && "$1" != '-y' ]]; then
        COMMAND="$1"
        shift
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --api-host)
                [[ $# -ge 2 ]] || die '--api-host 缺少值'
                API_HOST="$2"
                shift 2
                ;;
            --node-id)
                [[ $# -ge 2 ]] || die '--node-id 缺少值'
                NODE_ID="$2"
                shift 2
                ;;
            --api-key)
                [[ $# -ge 2 ]] || die '--api-key 缺少值'
                API_KEY="$2"
                shift 2
                ;;
            --image-tag)
                [[ $# -ge 2 ]] || die '--image-tag 缺少值'
                IMAGE_TAG="$2"
                IMAGE_TAG_EXPLICIT=1
                shift 2
                ;;
            --image-repo)
                [[ $# -ge 2 ]] || die '--image-repo 缺少值'
                IMAGE_REPO="$2"
                IMAGE_REPO_EXPLICIT=1
                shift 2
                ;;
            --install-dir)
                [[ $# -ge 2 ]] || die '--install-dir 缺少值'
                INSTALL_DIR="$2"
                shift 2
                ;;
            --replace-native)
                REPLACE_NATIVE=1
                shift
                ;;
            --no-firewall)
                OPEN_FIREWALL=0
                shift
                ;;
            --purge)
                PURGE=1
                shift
                ;;
            --yes|-y)
                ASSUME_YES=1
                shift
                ;;
            --follow|-f)
                FOLLOW_LOGS=1
                shift
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "未知参数：$1"
                ;;
        esac
    done
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die '请使用 root 或 sudo 运行'
}

validate_install_dir() {
    [[ "$INSTALL_DIR" == /* ]] || die '--install-dir 必须是绝对路径'
    case "$INSTALL_DIR" in
        /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            die "拒绝使用危险安装目录：$INSTALL_DIR"
            ;;
    esac
}

validate_architecture() {
    case "$(uname -m)" in
        x86_64|amd64|aarch64|arm64)
            ;;
        *)
            die "当前 Docker 镜像不支持该架构：$(uname -m)"
            ;;
    esac
}

install_base_tools() {
    if command -v curl >/dev/null 2>&1; then
        return
    fi

    log '安装 curl 和 CA 证书'
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache curl ca-certificates
    else
        die '未找到支持的包管理器，请先安装 curl'
    fi
}

ensure_docker() {
    install_base_tools

    if ! command -v docker >/dev/null 2>&1; then
        local docker_installer
        docker_installer="$(mktemp /tmp/v2node-get-docker.XXXXXX.sh)"
        chmod 700 "$docker_installer"
        log '安装 Docker Engine 和 Compose 插件'
        if ! curl -fsSL --retry 3 https://get.docker.com -o "$docker_installer"; then
            rm -f -- "$docker_installer"
            die 'Docker 官方安装脚本下载失败'
        fi
        if ! sh "$docker_installer"; then
            rm -f -- "$docker_installer"
            die 'Docker 安装失败'
        fi
        rm -f -- "$docker_installer"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker >/dev/null 2>&1
    elif command -v service >/dev/null 2>&1; then
        service docker start >/dev/null 2>&1 || true
    fi

    docker info >/dev/null 2>&1 || die 'Docker 服务未正常运行'

    if ! docker compose version >/dev/null 2>&1; then
        log '安装 Docker Compose 插件'
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y docker-compose-plugin
        elif command -v yum >/dev/null 2>&1; then
            yum install -y docker-compose-plugin
        fi
    fi

    docker compose version >/dev/null 2>&1 || die 'Docker Compose 插件不可用'
}

compose() {
    docker compose --project-directory "$INSTALL_DIR" -f "$INSTALL_DIR/compose.yml" "$@"
}

json_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    printf '%s' "$value"
}

curl_config_escape() {
    local value="$1"
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/}
    value=${value//$'\r'/}
    printf '%s' "$value"
}

collect_install_parameters() {
    if [[ -z "$API_HOST" ]]; then
        read -r -p 'V2Board 节点 API 地址（例如 https://panel.example.com）：' API_HOST
    fi
    API_HOST="${API_HOST%/}"
    [[ "$API_HOST" =~ ^https?://[^[:space:]]+$ ]] || die 'API 地址格式不正确'

    if [[ -z "$NODE_ID" ]]; then
        read -r -p 'v2node 节点 ID：' NODE_ID
    fi
    [[ "$NODE_ID" =~ ^[1-9][0-9]*$ ]] || die '节点 ID 必须是正整数'

    if [[ -z "$API_KEY" ]]; then
        read -r -s -p '节点通信密钥：' API_KEY
        printf '\n'
    fi
    [[ -n "$API_KEY" ]] || die '通信密钥不能为空'
    [[ "$API_KEY" != *$'\n'* && "$API_KEY" != *$'\r'* ]] || die '通信密钥不能包含换行符'

    [[ "$IMAGE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || die '镜像标签格式不正确'
    [[ "$IMAGE_REPO" =~ ^[A-Za-z0-9._:/-]+$ ]] || die '镜像仓库格式不正确'
}

fetch_node_info() {
    local response_file curl_config message api_host_escaped api_key_escaped
    response_file="$(mktemp /tmp/v2node-api-response.XXXXXX)"
    curl_config="$(mktemp /tmp/v2node-curl-config.XXXXXX)"
    chmod 600 "$response_file" "$curl_config"

    api_host_escaped="$(curl_config_escape "$API_HOST")"
    api_key_escaped="$(curl_config_escape "$API_KEY")"
    cat > "$curl_config" <<EOF
url = "${api_host_escaped}/api/v2/server/config"
get
data-urlencode = "node_type=v2node"
data-urlencode = "node_id=${NODE_ID}"
data-urlencode = "token=${api_key_escaped}"
connect-timeout = 10
max-time = 30
retry = 2
silent
show-error
fail
EOF

    log '验证 V2Board 节点接口'
    if ! curl --config "$curl_config" --output "$response_file"; then
        rm -f -- "$curl_config" "$response_file"
        die '无法连接 V2Board 节点接口，请检查地址、证书和网络'
    fi
    rm -f -- "$curl_config"

    if ! grep -Eq '"protocol"[[:space:]]*:' "$response_file"; then
        message="$(sed -nE 's/.*"message"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$response_file" | head -n 1)"
        rm -f -- "$response_file"
        die "面板未返回有效节点配置${message:+：$message}"
    fi

    NODE_PROTOCOL="$(sed -nE 's/.*"protocol"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$response_file" | head -n 1)"
    NODE_PORT="$(sed -nE 's/.*"server_port"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$response_file" | head -n 1)"
    rm -f -- "$response_file"

    [[ -n "$NODE_PROTOCOL" ]] || die '无法识别面板返回的协议'
    [[ "$NODE_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || die '无法识别面板返回的服务端口'
    (( NODE_PORT <= 65535 )) || die '面板返回的服务端口超出范围'
}

handle_native_service() {
    if ! command -v systemctl >/dev/null 2>&1 || ! systemctl is-active --quiet v2node 2>/dev/null; then
        return
    fi

    if [[ $REPLACE_NATIVE -ne 1 ]]; then
        die '检测到原生 v2node 服务正在运行。如需迁移到 Docker，请增加 --replace-native'
    fi

    log '停止并禁用原生 v2node 服务（原文件保留，可回退）'
    systemctl disable --now v2node
}

docker_container_exists() {
    docker inspect v2node >/dev/null 2>&1
}

validate_existing_container() {
    local compose_project
    docker_container_exists || return 0
    compose_project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' v2node 2>/dev/null || true)"
    [[ "$compose_project" == 'v2node-docker' ]] || die '已存在名称为 v2node 的其他容器，请先确认并处理，脚本不会覆盖它'
}

check_port_conflict() {
    if docker_container_exists; then
        return
    fi
    if command -v ss >/dev/null 2>&1 && ss -H -lntup 2>/dev/null | grep -Eq ":${NODE_PORT}[[:space:]]"; then
        ss -H -lntup 2>/dev/null | grep -E ":${NODE_PORT}[[:space:]]" >&2 || true
        die "端口 ${NODE_PORT} 已被其他程序占用"
    fi
}

backup_existing_files() {
    local stamp backup_dir copied
    stamp="$(date -u +%Y%m%d-%H%M%S)"
    backup_dir="$INSTALL_DIR/backups/$stamp"
    copied=0

    if [[ -f "$INSTALL_DIR/config/config.json" || -f "$INSTALL_DIR/compose.yml" || -f "$INSTALL_DIR/deployment.env" ]]; then
        mkdir -p "$backup_dir"
        chmod 700 "$INSTALL_DIR/backups" "$backup_dir"
        for file in config/config.json compose.yml deployment.env; do
            if [[ -f "$INSTALL_DIR/$file" ]]; then
                mkdir -p "$backup_dir/$(dirname "$file")"
                cp -a "$INSTALL_DIR/$file" "$backup_dir/$file"
                copied=1
            fi
        done
    fi

    if [[ $copied -eq 1 ]]; then
        log "原配置已备份到 $backup_dir"
    fi
}

write_config() {
    local api_host_json api_key_json
    api_host_json="$(json_escape "$API_HOST")"
    api_key_json="$(json_escape "$API_KEY")"

    mkdir -p "$INSTALL_DIR/config" "$INSTALL_DIR/backups"
    chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/config" "$INSTALL_DIR/backups"
    umask 077
    cat > "$INSTALL_DIR/config/config.json" <<EOF
{
  "Log": {
    "Level": "warning",
    "Output": "",
    "Access": "none"
  },
  "Nodes": [
    {
      "ApiHost": "${api_host_json}",
      "NodeID": ${NODE_ID},
      "ApiKey": "${api_key_json}",
      "Timeout": 15
    }
  ]
}
EOF
    chmod 600 "$INSTALL_DIR/config/config.json"
}

download_rule_data() {
    local name url temp_file target
    for name in geoip geosite; do
        target="$INSTALL_DIR/config/${name}.dat"
        if [[ -s "$target" ]]; then
            continue
        fi
        url="https://github.com/pichigogo666/v2node/releases/download/rules-latest/${name}.dat"
        temp_file="$INSTALL_DIR/config/.${name}.dat.tmp"
        log "下载 ${name}.dat"
        if ! curl -fL --retry 3 --connect-timeout 10 --max-time 180 "$url" -o "$temp_file"; then
            rm -f -- "$temp_file"
            die "${name}.dat 下载失败"
        fi
        chmod 644 "$temp_file"
        mv -f -- "$temp_file" "$target"
    done
}

write_compose_file() {
    cat > "$INSTALL_DIR/compose.yml" <<EOF
name: v2node-docker

services:
  v2node:
    image: ${IMAGE_REPO}:${IMAGE_TAG}
    container_name: v2node
    network_mode: host
    restart: unless-stopped
    init: true
    volumes:
      - ./config:/etc/v2node
    environment:
      TZ: Asia/Shanghai
    stop_grace_period: 30s
    healthcheck:
      test: ["CMD-SHELL", "kill -0 1"]
      interval: 15s
      timeout: 3s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options:
        max-size: 10m
        max-file: "3"
EOF
    chmod 644 "$INSTALL_DIR/compose.yml"

    umask 077
    {
        printf 'API_HOST=%q\n' "$API_HOST"
        printf 'NODE_ID=%q\n' "$NODE_ID"
        printf 'NODE_PROTOCOL=%q\n' "$NODE_PROTOCOL"
        printf 'NODE_PORT=%q\n' "$NODE_PORT"
        printf 'IMAGE_REPO=%q\n' "$IMAGE_REPO"
        printf 'IMAGE_TAG=%q\n' "$IMAGE_TAG"
    } > "$INSTALL_DIR/deployment.env"
    chmod 600 "$INSTALL_DIR/deployment.env"
}

open_system_firewall() {
    local transports=()
    [[ $OPEN_FIREWALL -eq 1 ]] || return 0

    case "$NODE_PROTOCOL" in
        tuic|hysteria|hysteria2)
            transports=(udp)
            ;;
        shadowsocks)
            transports=(tcp udp)
            ;;
        *)
            transports=(tcp)
            ;;
    esac

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
        for transport in "${transports[@]}"; do
            ufw allow "${NODE_PORT}/${transport}" comment 'v2node' >/dev/null
        done
        log "已在 UFW 放行 ${NODE_PORT}/${transports[*]}"
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for transport in "${transports[@]}"; do
            firewall-cmd --permanent --add-port="${NODE_PORT}/${transport}" >/dev/null
        done
        firewall-cmd --reload >/dev/null
        log "已在 firewalld 放行 ${NODE_PORT}/${transports[*]}"
    else
        log '未检测到启用中的 UFW/firewalld；未修改系统防火墙'
    fi
}

start_stack() {
    log "拉取自有镜像 ${IMAGE_REPO}:${IMAGE_TAG}"
    docker pull "${IMAGE_REPO}:${IMAGE_TAG}"
    log '启动 v2node 容器'
    compose up -d --force-recreate --remove-orphans

    local attempt running restarts health
    for attempt in {1..12}; do
        sleep 2
        running="$(docker inspect -f '{{.State.Running}}' v2node 2>/dev/null || true)"
        restarts="$(docker inspect -f '{{.RestartCount}}' v2node 2>/dev/null || printf '0')"
        if [[ "$running" == 'true' && "$restarts" == '0' ]]; then
            break
        fi
    done

    running="$(docker inspect -f '{{.State.Running}}' v2node 2>/dev/null || true)"
    restarts="$(docker inspect -f '{{.RestartCount}}' v2node 2>/dev/null || printf '0')"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}未配置{{end}}' v2node 2>/dev/null || true)"

    if [[ "$running" != 'true' ]]; then
        compose logs --tail 100 v2node >&2 || true
        die 'v2node 容器未能保持运行，请根据上面的日志排查'
    fi
    if [[ "$restarts" != '0' ]]; then
        compose logs --tail 100 v2node >&2 || true
        die "v2node 容器发生了 ${restarts} 次重启，请检查面板节点和用户配置"
    fi

    log "容器运行正常，健康状态：$health"
}

show_summary() {
    cat <<EOF

部署完成
  面板地址：$API_HOST
  节点 ID：$NODE_ID
  协议：$NODE_PROTOCOL
  服务端口：$NODE_PORT
  镜像：${IMAGE_REPO}:${IMAGE_TAG}
  安装目录：$INSTALL_DIR

常用命令
  bash $INSTALL_DIR/v2node-docker.sh status
  bash $INSTALL_DIR/v2node-docker.sh logs -f
  bash $INSTALL_DIR/v2node-docker.sh update
  bash $INSTALL_DIR/v2node-docker.sh restart
EOF
}

install_flow() {
    validate_architecture
    collect_install_parameters
    ensure_docker
    fetch_node_info
    handle_native_service
    validate_existing_container
    check_port_conflict
    mkdir -p "$INSTALL_DIR"
    chmod 700 "$INSTALL_DIR"
    backup_existing_files
    write_config
    download_rule_data
    write_compose_file
    cp -f -- "$0" "$INSTALL_DIR/v2node-docker.sh"
    chmod 700 "$INSTALL_DIR/v2node-docker.sh"
    open_system_firewall
    start_stack
    show_summary
}

load_deployment_state() {
    local requested_image_repo="$IMAGE_REPO"
    local requested_image_tag="$IMAGE_TAG"
    [[ -f "$INSTALL_DIR/deployment.env" ]] || die "未找到部署状态：$INSTALL_DIR/deployment.env"
    # 该文件由本脚本生成、目录仅 root 可写。
    # shellcheck disable=SC1090
    source "$INSTALL_DIR/deployment.env"
    if [[ $IMAGE_REPO_EXPLICIT -eq 1 ]]; then
        IMAGE_REPO="$requested_image_repo"
    fi
    if [[ $IMAGE_TAG_EXPLICIT -eq 1 ]]; then
        IMAGE_TAG="$requested_image_tag"
    fi
}

update_flow() {
    ensure_docker
    [[ -f "$INSTALL_DIR/compose.yml" ]] || die "未找到部署：$INSTALL_DIR/compose.yml"
    load_deployment_state
    validate_existing_container
    backup_existing_files
    write_compose_file
    start_stack
    log '镜像更新完成'
}

status_flow() {
    ensure_docker
    [[ -f "$INSTALL_DIR/compose.yml" ]] || die "未找到部署：$INSTALL_DIR/compose.yml"
    compose ps
    if docker_container_exists; then
        docker inspect -f '运行={{.State.Running}} 健康={{if .State.Health}}{{.State.Health.Status}}{{else}}未配置{{end}} 重启次数={{.RestartCount}} 启动时间={{.State.StartedAt}}' v2node
    fi
}

logs_flow() {
    ensure_docker
    [[ -f "$INSTALL_DIR/compose.yml" ]] || die "未找到部署：$INSTALL_DIR/compose.yml"
    if [[ $FOLLOW_LOGS -eq 1 ]]; then
        compose logs --tail 200 -f v2node
    else
        compose logs --tail 200 v2node
    fi
}

restart_flow() {
    ensure_docker
    [[ -f "$INSTALL_DIR/compose.yml" ]] || die "未找到部署：$INSTALL_DIR/compose.yml"
    compose restart v2node
    status_flow
}

uninstall_flow() {
    ensure_docker
    if [[ -f "$INSTALL_DIR/compose.yml" ]]; then
        compose down --remove-orphans
        log 'v2node 容器已删除'
    else
        warn "未找到 $INSTALL_DIR/compose.yml"
    fi

    if [[ $PURGE -ne 1 ]]; then
        log "配置和备份仍保留在 $INSTALL_DIR"
        return
    fi

    if [[ $ASSUME_YES -ne 1 ]]; then
        local answer
        read -r -p "确认永久删除 $INSTALL_DIR 内的配置和备份？请输入 yes：" answer
        [[ "$answer" == 'yes' ]] || die '已取消彻底删除'
    fi

    validate_install_dir
    [[ -d "$INSTALL_DIR" ]] || return 0
    rm -rf -- "$INSTALL_DIR"
    log "已永久删除 $INSTALL_DIR"
}

main() {
    parse_args "$@"
    if [[ "$COMMAND" == 'help' ]]; then
        usage
        return
    fi

    require_root
    validate_install_dir

    case "$COMMAND" in
        install|reconfigure)
            install_flow
            ;;
        update)
            update_flow
            ;;
        status)
            status_flow
            ;;
        logs)
            logs_flow
            ;;
        restart)
            restart_flow
            ;;
        uninstall)
            uninstall_flow
            ;;
        *)
            usage >&2
            die "未知命令：$COMMAND"
            ;;
    esac
}

main "$@"
