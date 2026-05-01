#!/usr/bin/env bash

# --- Internal Logging Functions ---
msg_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
msg_ok() { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }
msg_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

echo -e "\e[1;34m--- RHEL Podman Web-App-Deployer (Rootless) ---\e[0m"
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

# Validate required config fields (Now includes DB vars)
REQUIRED_VARS=(DOCKER_USERNAME DOCKER_PASSWORD DOCKER_IMAGE DB_HOST DB_USER DB_PASS)
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        msg_error "Required config field '$VAR' is not set in vm_config.conf."
    fi
done

# --- 2. Gather Inputs ---
read -p "Enter Customer/User Name (e.g., dehaas-digital): " CUSTOMER_NAME
if [ -z "$CUSTOMER_NAME" ]; then msg_error "Customer name cannot be empty."; fi

read -p "Enter Target Port (e.g., 3000): " APP_PORT
if [[ ! "$APP_PORT" =~ ^[0-9]+$ ]]; then msg_error "Port must be a number."; fi

read -p "Enter Database Name (e.g., ${CUSTOMER_NAME//-/_}_db): " DB_NAME
if [ -z "$DB_NAME" ]; then msg_error "Database name cannot be empty."; fi

# --- 3. Create System User & Enable Linger ---
if id "$CUSTOMER_NAME" &>/dev/null; then
    msg_warn "User $CUSTOMER_NAME already exists. Skipping user creation."
else
    msg_info "Creating user '$CUSTOMER_NAME'..."
    useradd -m "$CUSTOMER_NAME" || msg_error "Failed to create user."
    msg_ok "User created."
fi

msg_info "Enabling systemd linger for $CUSTOMER_NAME..."
loginctl enable-linger "$CUSTOMER_NAME" || msg_error "Failed to enable linger."

# --- 4. Firewall Configuration ---
msg_info "Opening port $APP_PORT/tcp in firewalld..."
firewall-cmd --permanent --add-port="${APP_PORT}/tcp" >/dev/null 2>&1
firewall-cmd --reload >/dev/null 2>&1
msg_ok "Firewall updated."

# --- 5. Setup Directories & Files ---
CUST_HOME=$(eval echo "~$CUSTOMER_NAME")
APP_DIR="$CUST_HOME/app"

msg_info "Creating application directory structure..."
su - "$CUSTOMER_NAME" -c "mkdir -p $APP_DIR/{themes,plugins,uploads,logs}"

msg_info "Generating .env file..."
DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:5432/${DB_NAME}"
cat <<EOF > "$APP_DIR/.env"
PROJECT_NAME=$CUSTOMER_NAME
PORT=$APP_PORT
DATABASE_URL="$DATABASE_URL"
EOF

msg_info "Generating docker-compose.yml..."
cat <<EOF > "$APP_DIR/docker-compose.yml"
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

msg_info "Setting correct ownership..."
chown -R "$CUSTOMER_NAME:$CUSTOMER_NAME" "$APP_DIR"

# --- 6. Configure User Bash Profile ---
msg_info "Configuring .bashrc for rootless podman..."
if ! grep -q "DOCKER_HOST" "$CUST_HOME/.bashrc"; then
cat <<EOF >> "$CUST_HOME/.bashrc"

# Podman Rootless Environment
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
EOF
fi

# --- 7. Initialize Podman, Setup Auth, & Start Container ---
msg_info "Authenticating to Docker Hub and starting container natively as $CUSTOMER_NAME..."

su - "$CUSTOMER_NAME" -c "
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/podman/podman.sock
    
    # Start and enable the Podman socket
    systemctl --user enable --now podman.socket
    
    # Authenticate with Docker Hub via Podman
    echo \"$DOCKER_PASSWORD\" | podman login docker.io -u \"$DOCKER_USERNAME\" --password-stdin
    
    # Native Fix: Convert Podman auth formatting to Docker Compose formatting
    mkdir -p ~/.docker
    sed 's|\"docker.io\"|\"https://index.docker.io/v1/\"|' \${XDG_RUNTIME_DIR}/containers/auth.json > ~/.docker/config.json
    
    # Navigate to app directory and bring up the container
    cd ~/app
    docker-compose up -d
" || msg_error "Failed to start the container application."

# --- Summary ---
echo ""
echo -e "\e[1;34m--- Deployment Complete ---\e[0m"
msg_ok "Customer: $CUSTOMER_NAME"
msg_ok "Port:     $APP_PORT"
msg_ok "Database: $DB_NAME"
msg_ok "Image:    $DOCKER_IMAGE"
echo "---------------------------------------------------"
echo "To manage this container later, log in as the user:"
echo "  sudo su - $CUSTOMER_NAME"
echo "  cd ~/app"
echo "  docker-compose logs -f"
echo "---------------------------------------------------"