#!/usr/bin/env bash

# --- Internal Logging Functions ---
msg_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
msg_ok() { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }
msg_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

# --- Rotate DB Password ---
rotate_db_password() {
    echo -e "\e[1;34m--- Web-App-Deployer: Rotate DB Password ---\e[0m"
    echo ""

    # Load config
    if [ -f "./vm_config.conf" ]; then
        source ./vm_config.conf
    else
        msg_error "vm_config.conf not found next to script."
    fi

    # Validate required fields
    for VAR in DB_LXC_ID DB_USER DB_PASS; do
        if [ -z "${!VAR}" ]; then
            msg_error "Required config field '$VAR' is not set in vm_config.conf."
        fi
    done

    # Warn about special characters
    echo ""
    msg_warn "Only alphanumeric characters (a-z, A-Z, 0-9) are supported in the password."
    msg_warn "Special characters such as @, /, !, #, etc. will break the sed substitution and are not allowed."
    echo ""

    # Prompt for new password (with confirmation)
    while true; do
        read -s -p "Enter new DB password: " NEW_PASS
        echo ""
        read -s -p "Confirm new DB password: " NEW_PASS_CONFIRM
        echo ""
        if [ "$NEW_PASS" != "$NEW_PASS_CONFIRM" ]; then
            msg_warn "Passwords do not match. Try again."
            echo ""
            continue
        fi
        if [ -z "$NEW_PASS" ]; then
            msg_warn "Password cannot be empty. Try again."
            echo ""
            continue
        fi
        if [[ "$NEW_PASS" =~ [^a-zA-Z0-9] ]]; then
            msg_error "Password contains unsupported special characters. Only a-z, A-Z, 0-9 are allowed."
        fi
        break
    done

    # Change postgres role password inside the DB LXC
    msg_info "Updating PostgreSQL role password for user '$DB_USER' in LXC $DB_LXC_ID..."
    pct exec "$DB_LXC_ID" -- su -s /bin/sh -c "psql -U postgres -c \"ALTER ROLE \\\"$DB_USER\\\" PASSWORD '$NEW_PASS';\"" postgres \
        || msg_error "Failed to update PostgreSQL password. vm_config.conf has NOT been changed."
    msg_ok "PostgreSQL password updated."

    # Update DB_PASS in vm_config.conf
    msg_info "Updating DB_PASS in vm_config.conf..."
    sed -i "s|^DB_PASS=.*|DB_PASS=\"$NEW_PASS\"|" ./vm_config.conf
    msg_ok "vm_config.conf updated."

    # Discover web LXCs by tag, excluding the DB LXC
    msg_info "Discovering web LXCs with tag '$var_tag'..."
    UPDATED=()
    SKIPPED=()

    while IFS= read -r VMID; do
        [ "$VMID" = "$DB_LXC_ID" ] && continue

        # Check tag via pct config
        TAGS=$(pct config "$VMID" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
        if [[ "$TAGS" != *"$var_tag"* ]]; then
            continue
        fi

        # Check container is running
        STATUS=$(pct status "$VMID" 2>/dev/null | awk '{print $2}')
        if [ "$STATUS" != "running" ]; then
            msg_info "LXC $VMID is not running — skipping."
            SKIPPED+=("$VMID (not running)")
            continue
        fi

        # Check if /root/app/.env exists
        if ! pct exec "$VMID" -- test -f /root/app/.env 2>/dev/null; then
            msg_info "LXC $VMID has no /root/app/.env — skipping."
            SKIPPED+=("$VMID (no .env)")
            continue
        fi

        # Rewrite password in DATABASE_URL using sed
        msg_info "Updating DATABASE_URL in LXC $VMID..."
        pct exec "$VMID" -- sed -i "s|\\(postgresql://$DB_USER:\\)[^@]*\\(@\\)|\\1$NEW_PASS\\2|" /root/app/.env \
            || { msg_warn "Failed to update .env in LXC $VMID — skipping restart."; SKIPPED+=("$VMID (sed failed)"); continue; }

        # Restart docker compose
        msg_info "Restarting app in LXC $VMID..."
        pct exec "$VMID" -- sh -c "cd /root/app && docker compose up -d" \
            || { msg_warn "Failed to restart compose in LXC $VMID."; SKIPPED+=("$VMID (restart failed)"); continue; }

        msg_ok "LXC $VMID updated and restarted."
        UPDATED+=("$VMID")

    done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')

    # Summary
    echo ""
    echo -e "\e[1;34m--- Summary ---\e[0m"
    if [ ${#UPDATED[@]} -gt 0 ]; then
        msg_ok "Updated containers: ${UPDATED[*]}"
    else
        msg_info "No containers were updated."
    fi
    if [ ${#SKIPPED[@]} -gt 0 ]; then
        msg_info "Skipped: ${SKIPPED[*]}"
    fi
}

# --- CLI Argument Handling ---
if [ "$1" = "rotate-db-password" ]; then
    rotate_db_password
    exit 0
fi

echo -e "\e[1;34m--- Web-App-Deployer (Debian + Docker Hub) Deployment ---\e[0m"
echo ""
echo "Select deployment mode:"
echo "  1) Full deployment (Docker + app config, .env, compose, Docker Hub login)"
echo "  2) Docker only    (bare Debian LXC with Docker installed, no app setup)"
echo ""
read -p "Enter choice [1/2]: " DEPLOY_MODE
case "$DEPLOY_MODE" in
    1|2) ;;
    *) echo "Invalid choice. Exiting."; exit 1 ;;
esac
echo ""

# 1. Load configs from local file
if [ -f "./vm_config.conf" ]; then
    source ./vm_config.conf
else
    msg_error "vm_config.conf not found next to script. Create it first."
fi

# Validate required config fields
REQUIRED_VARS=(TEMPLATE STORAGE)
if [ "$DEPLOY_MODE" = "1" ]; then
    REQUIRED_VARS+=(DB_HOST DB_USER DB_PASS DOCKER_USERNAME DOCKER_PASSWORD DOCKER_IMAGE)
fi
for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR}" ]; then
        msg_error "Required config field '$VAR' is not set in vm_config.conf."
    fi
done

# 2. User Inputs
read -p "Enter Container Name (Hostname): " CUSTOM_HOSTNAME
if [ "$DEPLOY_MODE" = "1" ]; then
    read -p "Enter Database Name: " DB_NAME
fi

# --- Identify ID and Network ---
CTID=$(pvesh get /cluster/nextid)
[ -z "$CTID" ] && msg_error "Failed to obtain a container ID from pvesh."
IP="${IP_BASE}${CTID}"

# --- Cleanup trap (runs on any error after container is created) ---
CTID_CREATED=false
cleanup() {
    if [ "$CTID_CREATED" = true ]; then
        echo ""
        msg_info "Error detected. Destroying incomplete container $CTID..."
        pct stop "$CTID" 2>/dev/null || true
        pct destroy "$CTID" 2>/dev/null || true
    fi
}
trap cleanup ERR

# --- Create Container ---
msg_info "Creating Debian LXC $CTID ($CUSTOM_HOSTNAME) with DNS $DNS..."
pct create $CTID "$STORAGE:vztmpl/$TEMPLATE" \
  --hostname "$CUSTOM_HOSTNAME" \
  --cores "$var_cpu" \
  --memory "$var_ram" \
  --net0 "name=eth0,bridge=$BRIDGE,ip=$IP/24,gw=$GW" \
  --nameserver "$DNS" \
  --rootfs "$STORAGE:$var_disk" \
  --onboot 1 \
  --unprivileged 1 \
  --tags "$var_tag" \
  --features "nesting=1,keyctl=1" || msg_error "Failed to create container."
CTID_CREATED=true

# --- Start and Initialize ---
msg_info "Starting Container..."
pct start $CTID || msg_error "Failed to start container."
msg_info "Waiting for container to start..."
until pct status $CTID | grep -q "status: running"; do
    sleep 1
done

# --- Install Base Packages & Docker (Debian/Apt) ---
msg_info "Updating system and installing dependencies (Quiet Mode)..."

# Redirects standard output to /dev/null, so only errors are shown in the console
pct exec $CTID -- sh -c "apt-get update -qq > /dev/null && apt-get -y upgrade -qq > /dev/null && apt-get install -y -qq ca-certificates curl gnupg openssh-client > /dev/null" || msg_error "Package installation failed."

msg_info "Installing Docker..."
# official setup for Docker on Debian 13
pct exec $CTID -- sh -c "install -m 0755 -d /etc/apt/keyrings"
pct exec $CTID -- sh -c "curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
pct exec $CTID -- sh -c "chmod a+r /etc/apt/keyrings/docker.gpg"
pct exec $CTID -- sh -c "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \$(. /etc/os-release && echo \"\$VERSION_CODENAME\") stable\" > /etc/apt/sources.list.d/docker.list"

# Silent install for Docker packages
pct exec $CTID -- sh -c "apt-get update -qq > /dev/null && apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin > /dev/null" || msg_error "Docker installation failed."

# --- Finalize Container Environment ---
msg_info "Configuring Docker..."
pct exec $CTID -- usermod -aG docker root

# --- Inject SSH Public Key ---
if [ -n "$SSH_PUBLIC_KEY" ]; then
    msg_info "Adding SSH public key to root's authorized_keys..."
    pct exec $CTID -- sh -c "mkdir -p /root/.ssh && chmod 700 /root/.ssh"
    pct exec $CTID -- sh -c "echo '$SSH_PUBLIC_KEY' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
    msg_ok "SSH public key added."
fi

if [ "$DEPLOY_MODE" = "1" ]; then
    # --- Create App Directory & Files ---
    msg_info "Creating app folder and configuration files..."
    pct exec $CTID -- mkdir -p /root/app

    # Generate .env file
    DATABASE_URL="postgresql://${DB_USER}:${DB_PASS}@${DB_HOST}:5432/${DB_NAME}"
    cat <<EOF > ./temp_env
DATABASE_URL="$DATABASE_URL"
PORT=80
PROJECT_NAME="$CUSTOM_HOSTNAME"
EOF
    pct push $CTID ./temp_env /root/app/.env
    rm ./temp_env

    # Generate docker-compose.yml
    cat <<EOF > ./temp_compose
services:
  service-backend:
    container_name: \${PROJECT_NAME}
    image: $DOCKER_IMAGE
    pull_policy: always
    volumes:
      - ./themes:/app/storage/themes
      - ./plugins:/app/storage/plugins
      - ./uploads:/app/storage/uploads
      - ./logs:/app/storage/logs
    env_file:
      - .env
    environment:
      - NODE_ENV=production
      - STORAGE_PATH=/app/storage
    restart: unless-stopped
    ports:
      - "\${PORT:-80}:\${PORT:-80}"
EOF
    pct push $CTID ./temp_compose /root/app/docker-compose.yml
    rm ./temp_compose

    # --- Docker Login ---
    msg_info "Authenticating with Docker Hub..."
    pct exec $CTID -- sh -c "docker login -u $DOCKER_USERNAME -p $DOCKER_PASSWORD"

    # --- Reboot the pct ---
    msg_info "Rebooting for updates..."
    pct reboot $CTID

    msg_info "Waiting for container to come back online..."
    until pct status $CTID | grep -q "status: running"; do
        sleep 1
    done

    until pct exec $CTID -- ip addr show eth0 | grep -q "inet "; do
        sleep 1
    done

    msg_ok "Container is back online!"

    # --- Optional Container Start ---
    echo ""
    read -p "Would you like to pull and start the container now? (y/N): " START_NOW

    if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
        msg_info "Pulling image and starting container..."
        pct exec $CTID -- sh -c "cd /root/app && docker compose pull && docker compose up -d"
        msg_ok "Container started successfully!"
    else
        msg_info "Skipping container start. You can start it later by running: pct enter $CTID"
    fi
fi

trap - ERR
msg_ok "Deployment complete!"
msg_info "LXC ID: $CTID | Name: $CUSTOM_HOSTNAME | IP: $IP | DNS: $DNS"