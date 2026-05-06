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
