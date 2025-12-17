#!/bin/bash

# ==============================================================================
#  N8N ADVANCED MANAGEMENT SCRIPT
#  Features: Auto-Docker, Cloudflare Tunnel, Multi-Architecture (Basic/DB/Queue)
#  Author: vnROM - AI & Automation
# ==============================================================================

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# === 1. ROOT PERMISSION CHECK (Fix theo yêu cầu) ===
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}⚠️  LỖI: Script cần quyền Root để cài đặt Docker và cấu hình hệ thống!${NC}"
    echo ""
    echo -e "${YELLOW}👉 Vui lòng chạy lệnh sau để chuyển sang quyền Root:${NC}"
    echo -e "   sudo su"
    echo ""
    echo -e "${YELLOW}👉 Sau đó chạy lại lệnh cài đặt:${NC}"
    echo -e "   curl -fsSL https://vnrom.me/n8n | sudo bash"
    echo ""
    exit 1
fi

# === Configuration ===
N8N_BASE_DIR="$HOME/n8n"
N8N_VOLUME_DIR="$N8N_BASE_DIR/n8n_local_data"
POSTGRES_VOLUME_DIR="$N8N_BASE_DIR/postgres_data"
REDIS_VOLUME_DIR="$N8N_BASE_DIR/redis_data"
DOCKER_COMPOSE_FILE="$N8N_BASE_DIR/docker-compose.yml"
CLOUDFLARED_CONFIG_FILE="/etc/cloudflared/config.yml"
DEFAULT_TZ="Asia/Ho_Chi_Minh"

# Backup configuration
BACKUP_DIR="$HOME/n8n-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Config file
CONFIG_FILE="$HOME/.n8n_install_config"

# Fail on error
set -e
set -o pipefail

# === Helper Functions ===
print_section() { echo -e "${BLUE}>>> $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}"; }

# === Docker Management ===
check_and_install_docker() {
    print_section "Kiểm tra Docker & Docker Compose"
    
    if ! command -v docker &> /dev/null; then
        echo ">>> Docker chưa được cài đặt. Đang tiến hành cài đặt tự động..."
        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release

        mkdir -p /etc/apt/keyrings
        if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
            curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        fi

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

        print_success "Docker đã được cài đặt thành công!"
    else
        print_success "Docker đã được cài đặt sẵn."
    fi
    systemctl start docker
    systemctl enable docker
}

# === Config Management ===
save_config() {
    local cf_token="$1"
    local cf_hostname="$2"
    local install_type="$3"
    local pg_pass="$4"
    local enc_key="$5"
    
    cat > "$CONFIG_FILE" << EOF
# n8n Configuration
CF_TOKEN="$cf_token"
CF_HOSTNAME="$cf_hostname"
INSTALL_TYPE="$install_type"
POSTGRES_PASSWORD="$pg_pass"
N8N_ENCRYPTION_KEY="$enc_key"
INSTALL_DATE="$(date)"
EOF
    chmod 600 "$CONFIG_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

# === Cloudflare Logic ===
get_cloudflare_input() {
    echo ""
    echo -e "${BLUE}--- CẤU HÌNH CLOUDFLARE ---${NC}"
    
    if load_config; then
        echo "Tìm thấy cấu hình cũ: $CF_HOSTNAME"
        # FIX: Thêm < /dev/tty để đọc từ bàn phím khi chạy qua pipe
        read -p "Bạn có muốn dùng lại Token cũ không? (Y/n): " reuse < /dev/tty
        if [[ "$reuse" != "n" && "$reuse" != "N" ]]; then
            return 0
        fi
    fi

    echo "Truy cập https://one.dash.cloudflare.com > Access > Tunnels để lấy Token."
    while true; do
        # FIX: Thêm < /dev/tty
        read -p "Nhập Cloudflare Tunnel Token: " CF_TOKEN < /dev/tty
        if [[ "$CF_TOKEN" =~ ^eyJ ]]; then break; else print_warning "Token không hợp lệ (phải bắt đầu bằng eyJ)"; fi
    done
    
    while true; do
        # FIX: Thêm < /dev/tty
        read -p "Nhập Hostname (vd: n8n.vnrom.net): " CF_HOSTNAME < /dev/tty
        if [[ "$CF_HOSTNAME" =~ \. ]]; then break; else print_warning "Hostname không hợp lệ"; fi
    done
}

install_cloudflared() {
    if ! command -v cloudflared &> /dev/null; then
        print_section "Cài đặt Cloudflared"
        ARCH=$(dpkg --print-architecture)
        case "$ARCH" in
            amd64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" ;;
            arm64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb" ;;
            armhf) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-armhf.deb" ;;
            *) print_error "Kiến trúc $ARCH không hỗ trợ tự động cài Cloudflared."; exit 1 ;;
        esac
        wget -q "$URL" -O /tmp/cloudflared.deb
        dpkg -i /tmp/cloudflared.deb
        rm /tmp/cloudflared.deb
    fi

    mkdir -p /etc/cloudflared
    cat <<EOF > "$CLOUDFLARED_CONFIG_FILE"
ingress:
  - hostname: ${CF_HOSTNAME}
    service: http://localhost:5678
  - service: http_status:404
EOF

    cloudflared service install "$CF_TOKEN" 2>/dev/null || true
    systemctl enable cloudflared
    systemctl restart cloudflared
}

# === Generators ===
generate_dockerfile() {
    local type="$1"
    local path="$N8N_BASE_DIR/Dockerfile"
    
    if [[ "$type" == "puppeteer" ]]; then
        cat <<EOF > "$path"
FROM n8nio/n8n:latest
USER root
RUN apk add --no-cache chromium nss freetype harfbuzz ca-certificates ttf-freefont nodejs yarn
ENV PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=true \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser
USER node
EOF
    elif [[ "$type" == "ffmpeg" ]]; then
        cat <<EOF > "$path"
FROM n8nio/n8n:latest
USER root
RUN apk add --no-cache ffmpeg
USER node
EOF
    else
        rm -f "$path" 2>/dev/null
    fi
}

generate_compose() {
    local type="$1"
    local pg_pass="$2"
    local enc_key="$3"
    
    echo ">>> Tạo docker-compose.yml cho chế độ: $type"
    
    cat <<EOF > "$DOCKER_COMPOSE_FILE"
services:
EOF

    if [[ "$type" == "db" || "$type" == "scaling" ]]; then
        cat <<EOF >> "$DOCKER_COMPOSE_FILE"
  postgres:
    image: postgres:16-alpine
    restart: always
    environment:
      - POSTGRES_USER=n8n
      - POSTGRES_PASSWORD=${pg_pass}
      - POSTGRES_DB=n8n
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U n8n"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:alpine
    restart: always
    volumes:
      - ./redis_data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

EOF
    fi

    cat <<EOF >> "$DOCKER_COMPOSE_FILE"
  n8n:
EOF
    
    if [[ "$type" == "puppeteer" || "$type" == "ffmpeg" ]]; then
        generate_dockerfile "$type"
        cat <<EOF >> "$DOCKER_COMPOSE_FILE"
    build:
      context: .
      dockerfile: Dockerfile
EOF
    else
        cat <<EOF >> "$DOCKER_COMPOSE_FILE"
    image: n8nio/n8n:latest
EOF
    fi

    cat <<EOF >> "$DOCKER_COMPOSE_FILE"
    restart: unless-stopped
    ports:
      - "127.0.0.1:5678:5678"
    environment:
      - TZ=${DEFAULT_TZ}
      - N8N_HOST=${CF_HOSTNAME}
      - WEBHOOK_URL=https://${CF_HOSTNAME}/
EOF

    if [[ "$type" == "db" || "$type" == "scaling" ]]; then
        cat <<EOF >> "$DOCKER_COMPOSE_FILE"
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${pg_pass}
EOF
    fi

    if [[ "$type" == "scaling" ]]; then
        cat <<EOF >> "$DOCKER_COMPOSE_FILE"
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - N8N_ENCRYPTION_KEY=${enc_key}
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
EOF
    elif [[ "$type" == "db" ]]; then
        cat <<EOF >> "$DOCKER_COMPOSE_FILE"
    depends_on:
      - postgres
EOF
    fi

    cat <<EOF >> "$DOCKER_COMPOSE_FILE"
    volumes:
      - ./n8n_local_data:/home/node/.n8n

EOF

    if [[ "$type" == "scaling" ]]; then
        cat <<EOF >> "$DOCKER_COMPOSE_FILE"
  n8n-worker:
    image: n8nio/n8n:latest
    command: worker
    restart: always
    environment:
      - TZ=${DEFAULT_TZ}
      - DB_TYPE=postgresdb
      - DB_POSTGRESDB_HOST=postgres
      - DB_POSTGRESDB_PORT=5432
      - DB_POSTGRESDB_DATABASE=n8n
      - DB_POSTGRESDB_USER=n8n
      - DB_POSTGRESDB_PASSWORD=${pg_pass}
      - EXECUTIONS_MODE=queue
      - QUEUE_BULL_REDIS_HOST=redis
      - QUEUE_BULL_REDIS_PORT=6379
      - N8N_ENCRYPTION_KEY=${enc_key}
    depends_on:
      - n8n
      - redis
      - postgres
    volumes:
      - ./n8n_local_data:/home/node/.n8n
EOF
    fi
}

# === Main Actions ===
install_n8n() {
    check_and_install_docker

    echo ""
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}   CHỌN PHIÊN BẢN N8N MUỐN CÀI ĐẶT${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo "1. Cơ bản (SQLite - Nhẹ, cho người mới)"
    echo "2. Cơ bản + Puppeteer (Hỗ trợ Automation Website)"
    echo "3. Cơ bản + FFmpeg (Hỗ trợ Xử lý Video)"
    echo "4. Nâng cao (Postgres + Redis - Ổn định cao)"
    echo "5. Scaling (Postgres + Redis + Worker - Tải nặng)"
    echo ""
    # FIX: Thêm < /dev/tty
    read -p "Nhập lựa chọn (1-5): " choice < /dev/tty
    
    local type="basic"
    case $choice in
        1) type="basic" ;;
        2) type="puppeteer" ;;
        3) type="ffmpeg" ;;
        4) type="db" ;;
        5) type="scaling" ;;
        *) type="basic" ;;
    esac

    get_cloudflare_input

    if load_config; then
        local pg_pass="${POSTGRES_PASSWORD:-$(openssl rand -hex 12)}"
        local enc_key="${N8N_ENCRYPTION_KEY:-$(openssl rand -hex 16)}"
    else
        local pg_pass=$(openssl rand -hex 12)
        local enc_key=$(openssl rand -hex 16)
    fi

    save_config "$CF_TOKEN" "$CF_HOSTNAME" "$type" "$pg_pass" "$enc_key"

    mkdir -p "$N8N_BASE_DIR" "$N8N_VOLUME_DIR"
    if [[ "$type" == "db" || "$type" == "scaling" ]]; then
        mkdir -p "$POSTGRES_VOLUME_DIR" "$REDIS_VOLUME_DIR"
    fi
    chown -R 1000:1000 "$N8N_VOLUME_DIR"

    cd "$N8N_BASE_DIR"
    generate_compose "$type" "$pg_pass" "$enc_key"

    install_cloudflared
    
    echo ">>> Khởi chạy n8n ($type)..."
    if [[ "$type" == "puppeteer" || "$type" == "ffmpeg" ]]; then
        echo "⚠️  Đang build image (mất 3-5 phút)..."
        docker compose up --build -d
    else
        docker compose up -d
    fi

    print_success "Cài đặt hoàn tất! Truy cập: https://$CF_HOSTNAME"
}

backup_n8n() {
    print_section "Backup hệ thống"
    load_config
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="n8n_backup_${TIMESTAMP}.tar.gz"

    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        docker compose -f "$DOCKER_COMPOSE_FILE" stop
    fi

    echo "📦 Đang nén dữ liệu..."
    tar -czf "$BACKUP_DIR/$BACKUP_FILE" \
        -C "$(dirname "$N8N_BASE_DIR")" "$(basename "$N8N_BASE_DIR")" \
        -C /etc cloudflared/ \
        -C "$HOME" .n8n_install_config \
        2>/dev/null || true

    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        docker compose -f "$DOCKER_COMPOSE_FILE" start
    fi

    ls -t "$BACKUP_DIR"/*.tar.gz | tail -n +6 | xargs rm -f 2>/dev/null
    print_success "Backup thành công: $BACKUP_DIR/$BACKUP_FILE"
}

update_n8n() {
    print_section "Cập nhật n8n"
    if ! load_config; then
        print_error "Không tìm thấy cấu hình. Vui lòng cài đặt trước."
        exit 1
    fi
    
    cd "$N8N_BASE_DIR"
    generate_compose "$INSTALL_TYPE" "$POSTGRES_PASSWORD" "$N8N_ENCRYPTION_KEY"

    echo ">>> Pulling latest images..."
    docker compose pull

    echo ">>> Recreating containers..."
    if [[ "$INSTALL_TYPE" == "puppeteer" || "$INSTALL_TYPE" == "ffmpeg" ]]; then
        docker compose up --build -d
    else
        docker compose up -d
    fi
    print_success "Đã cập nhật lên phiên bản mới nhất ($INSTALL_TYPE)"
}

show_status() {
    print_section "Trạng thái hệ thống"
    load_config
    echo "Hostname: $CF_HOSTNAME"
    echo "Type: $INSTALL_TYPE"
    echo ""
    if [ -f "$DOCKER_COMPOSE_FILE" ]; then
        cd "$N8N_BASE_DIR"
        docker compose ps
    else
        echo "n8n chưa được cài đặt."
    fi
    echo ""
    echo "Cloudflared Status:"
    systemctl status cloudflared --no-pager | head -3
}

# === Menu ===
show_menu() {
    echo -e "${BLUE}================================================${NC}"
    echo -e "${BLUE}   n8n MANAGER (v2.1 Advanced)${NC}"
    echo -e "${BLUE}================================================${NC}"
    echo "1. 🚀 Cài đặt n8n (Tùy chọn phiên bản)"
    echo "2. 💾 Backup dữ liệu"
    echo "3. 🔄 Update n8n"
    echo "4. 📊 Kiểm tra trạng thái"
    echo "0. ❌ Thoát"
    echo ""
    # FIX: Thêm < /dev/tty
    read -p "Nhập lựa chọn: " choice < /dev/tty
    case $choice in
        1) install_n8n ;;
        2) backup_n8n ;;
        3) update_n8n ;;
        4) show_status ;;
        0) exit 0 ;;
        *) echo "Sai lựa chọn" ;;
    esac
}

# === Entry Point ===
if [ $# -gt 0 ]; then
    case $1 in
        install) install_n8n ;;
        backup) backup_n8n ;;
        update) update_n8n ;;
        status) show_status ;;
        *) echo "Usage: $0 {install|backup|update|status}"; exit 1 ;;
    esac
else
    while true; do
        show_menu
        echo ""
        # FIX: Thêm < /dev/tty để dừng màn hình chờ enter
        read -p "Nhấn Enter để tiếp tục..." < /dev/tty
    done
fi