#!/usr/bin/env bash

# --- Internal Logging Functions ---
msg_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
msg_ok() { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }
msg_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

echo -e "\e[1;34m--- RHEL Podman Web-App Restorer (Rootless) ---\e[0m"
echo ""

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  msg_error "This script must be run as root to create users and configure the firewall."
fi

# --- 1. Load Configuration ---
if [ -f "./vm_config.conf" ]; then
    source ./vm_config.conf
    msg_ok "Loaded vm_config.conf"
else
    msg_error "vm_config.conf not found next to script. Create it first."
fi

REQUIRED_VARS=(DOCKER_USERNAME DOCKER_PASSWORD DOCKER_IMAGE DB_HOST DB_USER DB_PASS)
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        msg_error "Required config field '$VAR' is not set in vm_config.conf."
    fi
done

# --- 2. Select Restore Mode ---
echo "Select restore mode:"
echo "  1) Restore to new user"
echo "  2) Restore existing user"
echo ""
read -p "Enter choice [1/2]: " RESTORE_MODE

if [[ "$RESTORE_MODE" != "1" && "$RESTORE_MODE" != "2" ]]; then
    msg_error "Invalid choice. Enter 1 or 2."
fi

# --- 3a. Existing User Mode ---
if [[ "$RESTORE_MODE" == "2" ]]; then
    echo ""
    msg_info "Scanning for existing WebVM users..."

    WEBVM_USERS=()
    for user_home in /home/*/; do
        [ -d "$user_home" ] || continue
        user=$(basename "$user_home")
        if [ -d "$user_home/app" ]; then
            WEBVM_USERS+=("$user")
        fi
    done

    if [ ${#WEBVM_USERS[@]} -eq 0 ]; then
        msg_error "No existing WebVM users found (no /home/<user>/app directory)."
    fi

    echo ""
    echo "Existing WebVM users:"
    for i in "${!WEBVM_USERS[@]}"; do
        echo "  $((i+1))) ${WEBVM_USERS[$i]}"
    done
    echo ""

    read -p "Select user [1-${#WEBVM_USERS[@]}]: " USER_CHOICE
    if ! [[ "$USER_CHOICE" =~ ^[0-9]+$ ]] || \
       [ "$USER_CHOICE" -lt 1 ] || \
       [ "$USER_CHOICE" -gt "${#WEBVM_USERS[@]}" ]; then
        msg_error "Invalid selection."
    fi

    CUSTOMER_NAME="${WEBVM_USERS[$((USER_CHOICE-1))]}"
    CUST_HOME=$(eval echo "~$CUSTOMER_NAME")
    APP_DIR="$CUST_HOME/app"

    read -p "Enter full path to backup tar.gz (e.g., /tmp/backup.tar.gz): " BACKUP_FILE
    if [ ! -f "$BACKUP_FILE" ]; then msg_error "Backup file not found at $BACKUP_FILE"; fi

    # Stop the running container
    echo ""
    msg_info "Stopping container for user '$CUSTOMER_NAME'..."
    su - "$CUSTOMER_NAME" -c "
        export XDG_RUNTIME_DIR=/run/user/\$(id -u)
        export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
        cd ~/app && docker-compose down
    " && msg_ok "Container stopped." || msg_warn "Could not stop container (may not have been running)."

    # Replace app directory with archive contents
    echo ""
    msg_info "Removing existing app directory..."
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"

    msg_info "Extracting backup archive to $APP_DIR..."
    tar -xzf "$BACKUP_FILE" -C "$APP_DIR" || msg_error "Failed to extract archive."
    msg_ok "Extraction complete."

    chown -R "$CUSTOMER_NAME:$CUSTOMER_NAME" "$APP_DIR"

    # Restart container
    msg_info "Starting container as '$CUSTOMER_NAME'..."
    su - "$CUSTOMER_NAME" -c "
        export XDG_RUNTIME_DIR=/run/user/\$(id -u)
        export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
        cd ~/app
        docker-compose up -d
    " || msg_error "Failed to start the container."

# --- 3b. New User Mode ---
else
    echo ""
    read -p "Enter Customer/User Name (e.g., dehaas-digital): " CUSTOMER_NAME
    if [ -z "$CUSTOMER_NAME" ]; then msg_error "Customer name cannot be empty."; fi

    read -p "Enter Target Port (e.g., 3000): " APP_PORT
    if [[ ! "$APP_PORT" =~ ^[0-9]+$ ]]; then msg_error "Port must be a number."; fi

    read -p "Enter Database Name (e.g., ${CUSTOMER_NAME//-/_}_db): " DB_NAME
    if [ -z "$DB_NAME" ]; then msg_error "Database name cannot be empty."; fi

    read -p "Enter full path to backup tar.gz (e.g., /tmp/backup.tar.gz): " BACKUP_FILE
    if [ ! -f "$BACKUP_FILE" ]; then msg_error "Backup file not found at $BACKUP_FILE"; fi

    CUST_HOME=$(eval echo "~$CUSTOMER_NAME")
    APP_DIR="$CUST_HOME/app"

    # Create system user if needed
    if id "$CUSTOMER_NAME" &>/dev/null; then
        msg_warn "User $CUSTOMER_NAME already exists. Proceeding with restore on existing user."
    else
        msg_info "Creating user '$CUSTOMER_NAME'..."
        useradd -m "$CUSTOMER_NAME" || msg_error "Failed to create user."
        msg_ok "User created."
    fi

    msg_info "Enabling systemd linger for $CUSTOMER_NAME..."
    loginctl enable-linger "$CUSTOMER_NAME" || msg_error "Failed to enable linger."

    # Firewall
    msg_info "Opening port $APP_PORT/tcp in firewalld..."
    firewall-cmd --permanent --add-port="${APP_PORT}/tcp" >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
    msg_ok "Firewall updated."

    # Extract backup
    msg_info "Creating base application directory..."
    mkdir -p "$APP_DIR"

    msg_info "Extracting backup archive to $APP_DIR..."
    tar -xzf "$BACKUP_FILE" -C "$APP_DIR" || msg_error "Failed to extract archive."
    msg_ok "Extraction complete."

    # Generate config files
    msg_info "Regenerating RHEL-specific .env file..."
    DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:5432/${DB_NAME}"
    cat <<EOF > "$APP_DIR/.env"
PROJECT_NAME=$CUSTOMER_NAME
PORT=$APP_PORT
DATABASE_URL="$DATABASE_URL"
EOF

    msg_info "Regenerating RHEL-specific docker-compose.yml..."
    cat <<EOF > "$APP_DIR/docker-compose.yml"
services:
  service-backend:
    container_name: \${PROJECT_NAME}
    image: $DOCKER_IMAGE
    user: "0:0"
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

    msg_info "Setting correct ownership for rootless podman..."
    chown -R "$CUSTOMER_NAME:$CUSTOMER_NAME" "$APP_DIR"

    # Configure bash profile
    msg_info "Configuring .bashrc for rootless podman..."
    if ! grep -q "DOCKER_HOST" "$CUST_HOME/.bashrc"; then
    cat <<EOF >> "$CUST_HOME/.bashrc"

# Podman Rootless Environment
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
EOF
    fi

    # Start container
    msg_info "Authenticating to Docker Hub and starting container as $CUSTOMER_NAME..."
    su - "$CUSTOMER_NAME" -c "
        export XDG_RUNTIME_DIR=/run/user/\$(id -u)
        export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
        systemctl --user enable --now podman.socket
        echo \"$DOCKER_PASSWORD\" | podman login docker.io -u \"$DOCKER_USERNAME\" --password-stdin
        mkdir -p ~/.docker
        sed 's|\"docker.io\"|\"https://index.docker.io/v1/\"|' \${XDG_RUNTIME_DIR}/containers/auth.json > ~/.docker/config.json
        cd ~/app
        docker-compose pull
        docker-compose up -d
    " || msg_error "Failed to start the container application."
fi

# --- Summary ---
echo ""
echo -e "\e[1;34m--- Restore Complete ---\e[0m"
msg_ok "Customer: $CUSTOMER_NAME"
msg_ok "Backup:   $BACKUP_FILE"
[ -n "${APP_PORT:-}" ] && msg_ok "Port:     $APP_PORT"
[ -n "${DB_NAME:-}" ]  && msg_ok "Database: $DB_NAME"
echo "---------------------------------------------------"
echo "To view the logs for this restored container:"
echo "  sudo su - $CUSTOMER_NAME"
echo "  cd ~/app"
echo "  docker-compose logs -f"
echo "---------------------------------------------------"
