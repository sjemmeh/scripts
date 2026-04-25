#!/usr/bin/env bash

# Add a proxied hostname to mailcow NGINX and ADDITIONAL_SAN.
# - Creates or updates a mailcow NGINX config for the requested hostname
# - Proxies traffic for that hostname to the requested backend ip:port
# - Validates the running nginx-mailcow configuration before restarting NGINX
# - Adds the requested hostname to ADDITIONAL_SAN if it is not already present
# - Runs docker compose up -d so mailcow picks up config changes
# - Restarts acme-mailcow to request or renew the certificate
# - Always uses /opt/mailcow as the mailcow-dockerized directory
#
# Usage:
#   ./add_mailcow_san.sh <hostname> <ip:port>
#
# Arguments:
#   <hostname>   Domain name to proxy and add to ADDITIONAL_SAN, e.g. app.example.com
#   <ip:port>    Backend target for NGINX proxy_pass, e.g. 10.0.0.25:3000
#
# Examples:
#   ./add_mailcow_san.sh app.example.com 10.0.0.25:3000
#   ./add_mailcow_san.sh status.example.com 192.168.1.50:8080
#
# After running:
#   docker compose logs -f acme-mailcow

set -euo pipefail

msg_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
msg_ok()   { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error(){ echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }
msg_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

usage() {
    cat <<EOF
Usage: $0 <hostname> <ip:port>

Creates or updates a mailcow NGINX proxy config, adds the hostname to
mailcow.conf ADDITIONAL_SAN, validates NGINX syntax, and restarts the
mailcow ACME container to request the certificate.

Arguments:
  hostname   Domain to proxy and add to ADDITIONAL_SAN
  ip:port    Backend target for NGINX proxy_pass

Examples:
  $0 app.example.com 10.0.0.25:3000
  $0 status.example.com 192.168.1.50:8080
EOF
}

if [ $# -ne 2 ]; then
    usage
    exit 2
fi

HOSTNAME="$1"
BACKEND="$2"
MAILCOW_DIR="/opt/mailcow"
MAILCOW_CONF="$MAILCOW_DIR/mailcow.conf"
NGINX_CONF_DIR="$MAILCOW_DIR/data/conf/nginx"
CONF_FILE="$NGINX_CONF_DIR/${HOSTNAME}.conf"

echo -e "\e[1;34m--- Mailcow ADDITIONAL_SAN Update ---\e[0m"
echo ""

[ -d "$MAILCOW_DIR" ] || msg_error "Mailcow directory not found: $MAILCOW_DIR"
[ -f "$MAILCOW_CONF" ] || msg_error "mailcow.conf not found: $MAILCOW_CONF"
[ -d "$NGINX_CONF_DIR" ] || msg_error "NGINX config directory not found: $NGINX_CONF_DIR"

[[ "$BACKEND" =~ ^[A-Za-z0-9._-]+:[0-9]+$ ]] || msg_error "Backend must be in ip:port or host:port format. Got: $BACKEND"

command -v docker >/dev/null 2>&1 || msg_error "docker is required."

msg_info "Using mailcow directory: $MAILCOW_DIR"
msg_info "Using mailcow config: $MAILCOW_CONF"
msg_info "Using NGINX config: $CONF_FILE"
msg_info "Using backend target: $BACKEND"

cd "$MAILCOW_DIR" || msg_error "Failed to enter mailcow directory: $MAILCOW_DIR"

msg_info "Writing NGINX proxy config for $HOSTNAME..."
cat > "$CONF_FILE" <<EOF
server {
  listen 80;
  listen [::]:80;
  listen 443 ssl http2;
  listen [::]:443 ssl http2;

  server_name $HOSTNAME;

  include /etc/nginx/conf.d/listen_plain.active;
  include /etc/nginx/conf.d/listen_ssl.active;
  include /etc/nginx/conf.d/server_name.active;
  include /etc/nginx/conf.d/ssl.active;

  location / {
    proxy_pass http://$BACKEND;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }
}
EOF
msg_ok "Wrote NGINX proxy config."

msg_info "Validating NGINX syntax..."
if docker compose exec nginx-mailcow nginx -t; then
    msg_ok "NGINX syntax is valid."
    msg_info "Restarting nginx-mailcow..."
    docker compose restart nginx-mailcow \
        || msg_error "Failed to restart nginx-mailcow."
else
    msg_error "NGINX syntax check failed. Check $CONF_FILE"
fi

echo ""
echo -e "\e[1;34m--- Updating mailcow.conf ADDITIONAL_SAN ---\e[0m"

CURRENT_SAN=$(grep "^ADDITIONAL_SAN=" "$MAILCOW_CONF" | cut -d'=' -f2- || true)

if [[ "$CURRENT_SAN" == *"$HOSTNAME"* ]]; then
    msg_info "Domain $HOSTNAME is already in ADDITIONAL_SAN. Skipping update."
else
    if [ -z "$CURRENT_SAN" ]; then
        NEW_SAN="$HOSTNAME"
    else
        NEW_SAN="$CURRENT_SAN,$HOSTNAME"
    fi

    msg_info "Adding $HOSTNAME to ADDITIONAL_SAN..."
    sed -i "s|^ADDITIONAL_SAN=.*|ADDITIONAL_SAN=$NEW_SAN|" "$MAILCOW_CONF" \
        || msg_error "Failed to update ADDITIONAL_SAN in $MAILCOW_CONF."

    msg_ok "Added $HOSTNAME to ADDITIONAL_SAN."

    msg_info "Restarting mailcow services to request certificate..."
    docker compose up -d \
        || msg_error "Failed to run docker compose up -d."

    docker compose restart acme-mailcow \
        || msg_error "Failed to restart acme-mailcow."

    msg_ok "ACME container restarted."
fi

echo ""
echo -e "\e[1;34m--- Summary ---\e[0m"
msg_ok "Mailcow SAN update complete."
msg_info "Check ACME logs with: docker compose logs -f acme-mailcow"
