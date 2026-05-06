#!/usr/bin/env bash

# --- Logging ---
msg_info()  { echo -e "\e[34m[INFO]\e[0m $1"; }
msg_ok()    { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }
msg_warn()  { echo -e "\e[33m[WARN]\e[0m $1"; }

# --- Helpers ---
find_free_port() {
    local port=$1
    while ss -tuln | grep -q ":$port "; do
        msg_warn "Port $port is in use, checking next..."
        ((port++))
        [ "$port" -gt 65535 ] && msg_error "No available ports found in range $1-65535."
    done
    echo "$port"
}

load_config() {
    if [ -f "./vm_config.conf" ]; then
        source ./vm_config.conf
        msg_ok "Loaded vm_config.conf"
    else
        msg_error "vm_config.conf not found next to script. Create it first."
    fi
    local required=(DOCKER_USERNAME DOCKER_PASSWORD DOCKER_IMAGE DB_HOST DB_USER DB_PASS)
    for VAR in "${required[@]}"; do
        if [ -z "${!VAR}" ]; then
            msg_error "Required config field '$VAR' is not set in vm_config.conf."
        fi
    done
}

create_user() {
    local name="$1"
    if id "$name" &>/dev/null; then
        msg_warn "User $name already exists. Skipping user creation."
    else
        msg_info "Creating user '$name'..."
        useradd -m "$name" || msg_error "Failed to create user."
        msg_ok "User created."
    fi
    msg_info "Enabling systemd linger for $name..."
    loginctl enable-linger "$name" || msg_error "Failed to enable linger."
}

open_firewall_port() {
    local port="$1"
    msg_info "Opening port $port/tcp in firewalld..."
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || msg_error "Failed to add port $port to firewall."
    firewall-cmd --reload >/dev/null 2>&1 || msg_error "Failed to reload firewall."
    msg_ok "Firewall updated."
}

write_env() {
    local app_dir="$1" customer_name="$2" port="$3" db_name="$4"
    local database_url="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:5432/${db_name}"
    msg_info "Generating .env file..."
    cat <<EOF > "$app_dir/.env"
PROJECT_NAME=$customer_name
PORT=$port
DATABASE_URL="$database_url"
EOF
}

write_compose() {
    local app_dir="$1"
    msg_info "Generating docker-compose.yml..."
    cat <<EOF > "$app_dir/docker-compose.yml"
services:
  service-backend:
    container_name: \${PROJECT_NAME}
    image: $DOCKER_IMAGE
    pull_policy: always
    volumes:
      - ./themes:/app/storage/themes:Z
      - ./plugins:/app/storage/plugins:Z
      - ./uploads:/app/storage/uploads:Z
      - ./logs:/app/storage/logs:Z
    env_file:
      - .env
    environment:
      - NODE_ENV=production
      - STORAGE_PATH=/app/storage
    restart: unless-stopped
    ports:
      - "\${PORT}:\${PORT}"
EOF
}

configure_bashrc() {
    local cust_home="$1"
    msg_info "Configuring .bashrc for rootless podman..."
    if ! grep -q "DOCKER_HOST" "$cust_home/.bashrc"; then
        cat <<EOF >> "$cust_home/.bashrc"

# Podman Rootless Environment
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
EOF
    fi
}

stop_container() {
    local name="$1"
    msg_info "Stopping container for user '$name'..."
    su - "$name" -c "
        export XDG_RUNTIME_DIR=/run/user/\$(id -u)
        export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
        cd ~/app && docker-compose down
    " && msg_ok "Container stopped." || msg_warn "Could not stop container (may not have been running)."
}

start_container() {
    local name="$1"
    local pull="${2:-}"
    local pull_cmd=""
    [ "$pull" = "pull" ] && pull_cmd="docker-compose pull"
    msg_info "Authenticating to Docker Hub and starting container as $name..."
    su - "$name" -c "
        export XDG_RUNTIME_DIR=/run/user/\$(id -u)
        export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
        systemctl --user enable --now podman.socket
        echo \"$DOCKER_PASSWORD\" | podman login docker.io -u \"$DOCKER_USERNAME\" --password-stdin
        mkdir -p ~/.docker
        sed 's|\"docker.io\"|\"https://index.docker.io/v1/\"|' \${XDG_RUNTIME_DIR}/containers/auth.json > ~/.docker/config.json
        cd ~/app
        $pull_cmd
        docker-compose up -d
    " || msg_error "Failed to start the container application."
}

print_manage_hint() {
    local name="$1"
    echo "---------------------------------------------------"
    echo "To manage this container, log in as the user:"
    echo "  sudo su - $name"
    echo "  cd ~/app"
    echo "  docker-compose logs -f"
    echo "---------------------------------------------------"
}
