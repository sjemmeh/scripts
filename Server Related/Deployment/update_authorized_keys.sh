#!/usr/bin/env bash

set -euo pipefail

# --- Internal Logging Functions ---
msg_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
msg_ok()   { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error(){ echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }
msg_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

# Determine the directory where this script resides
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/vm_config.conf"

echo -e "\e[1;34m--- Update Authorized SSH Keys ---\e[0m"
echo ""

# --- Root Guard ---
if [ "$EUID" -ne 0 ]; then
    msg_error "This script must be run as root to update authorized_keys for all users."
fi

# --- Load Config ---
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=./vm_config.conf
    source "$CONFIG_FILE"
    msg_info "Loaded config from $CONFIG_FILE"
else
    msg_error "Config file not found at $CONFIG_FILE."
fi

if [ -z "${AUTHORIZED_KEYS_URL:-}" ]; then
    msg_error "Required config field 'AUTHORIZED_KEYS_URL' is not set in vm_config.conf."
fi

# --- Fetch Remote Authorized Keys ---
msg_info "Fetching authorized keys from $AUTHORIZED_KEYS_URL ..."

REMOTE_KEYS=$(curl -fsSL --connect-timeout 10 --max-time 30 "$AUTHORIZED_KEYS_URL" 2>&1) || {
    msg_error "Failed to fetch authorized keys from $AUTHORIZED_KEYS_URL — no local keys were modified."
}

if [ -z "$REMOTE_KEYS" ]; then
    msg_error "Fetched authorized keys content is empty — refusing to wipe all local keys."
fi

msg_ok "Fetched $(echo "$REMOTE_KEYS" | wc -l | tr -d ' ') line(s) from remote."

# --- Build User List ---
USERS=("root")

if [ -d /home ]; then
    for user_home in /home/*/; do
        [ -d "$user_home" ] || continue
        user=$(basename "$user_home")
        if [ "$user" = "root" ]; then
            continue
        fi
        if id "$user" &>/dev/null; then
            USERS+=("$user")
        fi
    done
fi

msg_info "Target users: ${USERS[*]}"

# --- Sync Loop ---
UPDATED=0
SKIPPED=0
ALREADY_OK=0

for user in "${USERS[@]}"; do
    # Resolve home directory reliably
    if [ "$user" = "root" ]; then
        USER_HOME="/root"
    else
        USER_HOME=$(eval echo "~$user")
    fi

    if [ ! -d "$USER_HOME" ]; then
        msg_warn "Home directory for '$user' does not exist at $USER_HOME — skipping."
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Ensure .ssh directory exists with correct permissions
    SSH_DIR="$USER_HOME/.ssh"
    if [ ! -d "$SSH_DIR" ]; then
        msg_info "Creating $SSH_DIR for $user ..."
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
        chown "$user:$user" "$SSH_DIR"
    else
        # Defensive: fix permissions if wrong
        chmod 700 "$SSH_DIR" 2>/dev/null || true
        chown "$user:$user" "$SSH_DIR" 2>/dev/null || true
    fi

    AUTH_KEYS_FILE="$SSH_DIR/authorized_keys"

    # Compare existing vs. remote
    if [ -f "$AUTH_KEYS_FILE" ]; then
        EXISTING_KEYS=$(cat "$AUTH_KEYS_FILE")
        if [ "$EXISTING_KEYS" = "$REMOTE_KEYS" ]; then
            ALREADY_OK=$((ALREADY_OK + 1))
            # Defensive: still fix permissions/ownership
            chmod 600 "$AUTH_KEYS_FILE" 2>/dev/null || true
            chown "$user:$user" "$AUTH_KEYS_FILE" 2>/dev/null || true
            continue
        fi
    fi

    # Write new keys
    echo "$REMOTE_KEYS" > "$AUTH_KEYS_FILE"
    chmod 600 "$AUTH_KEYS_FILE"
    chown "$user:$user" "$AUTH_KEYS_FILE"
    msg_ok "Updated authorized_keys for $user"
    UPDATED=$((UPDATED + 1))
done

# --- Summary ---
echo ""
echo -e "\e[1;34m--- Summary ---\e[0m"
msg_ok "Updated:   $UPDATED"
msg_info "Up-to-date: $ALREADY_OK"
if [ "$SKIPPED" -gt 0 ]; then
    msg_warn "Skipped:   $SKIPPED"
fi
