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

mode_deploy() {
    echo ""
    read -p "Enter Customer/User Name (e.g., dehaas-digital): " CUSTOMER_NAME
    [ -z "$CUSTOMER_NAME" ] && msg_error "Customer name cannot be empty."

    msg_info "Finding an available port starting from 3000..."
    APP_PORT=$(find_free_port 3000)
    msg_ok "Assigning Port: $APP_PORT"

    read -p "Enter Database Name (default: ${CUSTOMER_NAME//-/_}_db): " DB_NAME
    [ -z "$DB_NAME" ] && DB_NAME="${CUSTOMER_NAME//-/_}_db"

    local CUST_HOME
    CUST_HOME=$(eval echo "~$CUSTOMER_NAME")
    local APP_DIR="$CUST_HOME/app"

    create_user "$CUSTOMER_NAME"
    open_firewall_port "$APP_PORT"

    msg_info "Creating application directory structure..."
    su - "$CUSTOMER_NAME" -c "mkdir -p ~/app/{themes,plugins,uploads,logs}"

    write_env "$APP_DIR" "$CUSTOMER_NAME" "$APP_PORT" "$DB_NAME"
    write_compose "$APP_DIR"

    msg_info "Setting correct ownership..."
    chown -R "$CUSTOMER_NAME:$CUSTOMER_NAME" "$APP_DIR"

    configure_bashrc "$CUST_HOME"
    start_container "$CUSTOMER_NAME"

    echo ""
    echo -e "\e[1;34m--- Deployment Complete ---\e[0m"
    msg_ok "Customer: $CUSTOMER_NAME"
    msg_ok "Port:     $APP_PORT"
    msg_ok "Database: $DB_NAME"
    msg_ok "Image:    $DOCKER_IMAGE"
    print_manage_hint "$CUSTOMER_NAME"
}

mode_restore_new() {
    echo ""
    read -p "Enter Customer/User Name (e.g., dehaas-digital): " CUSTOMER_NAME
    [ -z "$CUSTOMER_NAME" ] && msg_error "Customer name cannot be empty."

    msg_info "Finding an available port starting from 3000..."
    APP_PORT=$(find_free_port 3000)
    msg_ok "Assigning Port: $APP_PORT"

    read -p "Enter Database Name (default: ${CUSTOMER_NAME//-/_}_db): " DB_NAME
    [ -z "$DB_NAME" ] && DB_NAME="${CUSTOMER_NAME//-/_}_db"

    read -p "Enter full path to backup tar.gz (e.g., /tmp/backup.tar.gz): " BACKUP_FILE
    [ ! -f "$BACKUP_FILE" ] && msg_error "Backup file not found at $BACKUP_FILE"

    local CUST_HOME
    CUST_HOME=$(eval echo "~$CUSTOMER_NAME")
    local APP_DIR="$CUST_HOME/app"

    create_user "$CUSTOMER_NAME"
    open_firewall_port "$APP_PORT"

    msg_info "Creating application directory..."
    mkdir -p "$APP_DIR"

    msg_info "Extracting backup archive to $APP_DIR..."
    tar -xzf "$BACKUP_FILE" -C "$APP_DIR" || msg_error "Failed to extract archive."
    msg_ok "Extraction complete."

    write_env "$APP_DIR" "$CUSTOMER_NAME" "$APP_PORT" "$DB_NAME"
    write_compose "$APP_DIR"

    msg_info "Setting correct ownership..."
    chown -R "$CUSTOMER_NAME:$CUSTOMER_NAME" "$APP_DIR"

    configure_bashrc "$CUST_HOME"
    start_container "$CUSTOMER_NAME" "pull"

    echo ""
    echo -e "\e[1;34m--- Restore Complete ---\e[0m"
    msg_ok "Customer: $CUSTOMER_NAME"
    msg_ok "Port:     $APP_PORT"
    msg_ok "Database: $DB_NAME"
    msg_ok "Backup:   $BACKUP_FILE"
    print_manage_hint "$CUSTOMER_NAME"
}
