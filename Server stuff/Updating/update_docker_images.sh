#!/usr/bin/env bash

# Update docker images inside all tagged LXC containers.
# - Discovers LXCs by tag (var_tag) from vm_config.conf
# - For each matching, running LXC with /root/app/docker-compose.yml:
#     * docker compose pull
#     * docker compose up -d
#     * If images changed, prompt user to verify the site before continuing
#     * docker image prune -af
#
# Usage:
#   ./update_docker_images.sh [options] [<ctid|hostname>]
#
# Options:
#   --ct <id|hostname>   Only update this single container (by LXC id or hostname).
#   --config <path>      Path to vm_config.conf (auto-detected by default).
#   --dry-run            Show what would happen, do nothing.
#   --no-prune           Skip 'docker image prune -af'.
#   -y, --yes            Skip the initial confirmation prompt.
#   -h, --help           Show this help.
#
# Examples:
#   ./update_docker_images.sh                # all tagged containers
#   ./update_docker_images.sh --ct 105       # only LXC 105
#   ./update_docker_images.sh my-site        # only the LXC with hostname 'my-site'

msg_info() { echo -e "\e[34m[INFO]\e[0m $1"; }
msg_ok()   { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error(){ echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }
msg_warn() { echo -e "\e[33m[WARN]\e[0m $1"; }

# --- Defaults ---
CONFIG_PATH=""
ONLY_CT=""
DRY_RUN=false
NO_PRUNE=false
ASSUME_YES=false

# --- Parse args ---
while [ $# -gt 0 ]; do
    case "$1" in
        --config)   CONFIG_PATH="$2"; shift 2 ;;
        --ct)       ONLY_CT="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true; shift ;;
        --no-prune) NO_PRUNE=true; shift ;;
        -y|--yes)   ASSUME_YES=true; shift ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        --) shift; ONLY_CT="$1"; shift ;;
        -*) msg_error "Unknown argument: $1" ;;
        *)
            if [ -z "$ONLY_CT" ]; then
                ONLY_CT="$1"; shift
            else
                msg_error "Unexpected argument: $1"
            fi
            ;;
    esac
done

echo -e "\e[1;34m--- Update Docker Images in Tagged LXCs ---\e[0m"
echo ""

# --- Locate and load config ---
if [ -z "$CONFIG_PATH" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CANDIDATES=(
        "$SCRIPT_DIR/../../Installation/Deploy WebVM/vm_config.conf"
        "$SCRIPT_DIR/vm_config.conf"
        "./vm_config.conf"
    )
    for C in "${CANDIDATES[@]}"; do
        if [ -f "$C" ]; then CONFIG_PATH="$C"; break; fi
    done
fi

if [ -z "$CONFIG_PATH" ] || [ ! -f "$CONFIG_PATH" ]; then
    msg_error "vm_config.conf not found. Use --config <path>."
fi

# shellcheck disable=SC1090
source "$CONFIG_PATH"
msg_info "Loaded config: $CONFIG_PATH"

if [ -z "$var_tag" ]; then
    msg_error "Required config field 'var_tag' is not set in $CONFIG_PATH."
fi
msg_info "Looking for LXCs with tag: $var_tag"
[ -n "$ONLY_CT" ] && msg_info "Restricted to: $ONLY_CT"

# --- Confirm ---
if [ "$DRY_RUN" = false ] && [ "$ASSUME_YES" = false ]; then
    echo ""
    read -p "Proceed with pulling and restarting containers? (y/N): " GO
    [[ "$GO" =~ ^[Yy]$ ]] || { msg_info "Aborted."; exit 0; }
fi

UPDATED=()
UNCHANGED=()
SKIPPED=()
MATCHED=0

# --- Iterate LXCs ---
while IFS= read -r VMID; do
    [ -z "$VMID" ] && continue
    [ -n "$DB_LXC_ID" ] && [ "$VMID" = "$DB_LXC_ID" ] && continue

    # Tag check (exact match against semicolon-separated tag list)
    TAGS=$(pct config "$VMID" 2>/dev/null | awk -F': ' '/^tags:/{print $2}')
    TAG_MATCH=false
    IFS=';' read -ra TAG_LIST <<< "$TAGS"
    for T in "${TAG_LIST[@]}"; do
        if [ "$T" = "$var_tag" ]; then
            TAG_MATCH=true
            break
        fi
    done
    if [ "$TAG_MATCH" = false ]; then
        continue
    fi

    # Hostname for friendly messages
    HOSTNAME=$(pct config "$VMID" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')
    [ -z "$HOSTNAME" ] && HOSTNAME="ct$VMID"
    LABEL="$VMID ($HOSTNAME)"

    # Restrict to a single container by id or hostname
    if [ -n "$ONLY_CT" ] && [ "$VMID" != "$ONLY_CT" ] && [ "$HOSTNAME" != "$ONLY_CT" ]; then
        continue
    fi

    MATCHED=$((MATCHED + 1))

    # Running check
    STATUS=$(pct status "$VMID" 2>/dev/null | awk '{print $2}')
    if [ "$STATUS" != "running" ]; then
        msg_info "LXC $LABEL is not running — skipping."
        SKIPPED+=("$LABEL (not running)")
        continue
    fi

    # docker-compose.yml check
    if ! pct exec "$VMID" -- test -f /root/app/docker-compose.yml 2>/dev/null; then
        msg_info "LXC $LABEL has no /root/app/docker-compose.yml — skipping."
        SKIPPED+=("$LABEL (no compose file)")
        continue
    fi

    echo ""
    msg_info "Processing LXC $LABEL..."

    if [ "$DRY_RUN" = true ]; then
        msg_info "[dry-run] would pull, restart and prune in $LABEL"
        UPDATED+=("$LABEL (dry-run)")
        continue
    fi

    # Capture before-state image IDs for change detection
    BEFORE=$(pct exec "$VMID" -- sh -c "cd /root/app && docker compose images -q 2>/dev/null | sort -u")

    # Pull latest
    msg_info "Pulling latest images in $LABEL..."
    if ! pct exec "$VMID" -- sh -c "cd /root/app && docker compose pull"; then
        msg_warn "docker compose pull failed in $LABEL — skipping."
        SKIPPED+=("$LABEL (pull failed)")
        continue
    fi

    # Capture after-state image IDs
    AFTER=$(pct exec "$VMID" -- sh -c "cd /root/app && docker compose images -q 2>/dev/null | sort -u")

    # Always bring containers up to ensure they are running
    msg_info "Running 'docker compose up -d' in $LABEL..."
    if ! pct exec "$VMID" -- sh -c "cd /root/app && docker compose up -d"; then
        msg_warn "docker compose up -d failed in $LABEL."
        SKIPPED+=("$LABEL (up failed)")
        continue
    fi

    if [ "$BEFORE" != "$AFTER" ]; then
        msg_ok "Images updated in $LABEL."
        UPDATED+=("$LABEL")

        # Verification prompt
        echo ""
        echo -e "\e[1;33m>>> Please verify the site for container '$HOSTNAME' (LXC $VMID) is working correctly.\e[0m"
        while true; do
            read -p "Type 'ok' to continue, or 'abort' to stop: " VERIFY
            case "$VERIFY" in
                ok|OK|y|Y|yes|YES) break ;;
                abort|ABORT|n|N|no|NO)
                    msg_warn "Aborted by user after $LABEL."
                    echo ""
                    echo -e "\e[1;34m--- Summary (partial) ---\e[0m"
                    [ ${#UPDATED[@]}   -gt 0 ] && msg_ok   "Updated:   ${UPDATED[*]}"
                    [ ${#UNCHANGED[@]} -gt 0 ] && msg_info "Unchanged: ${UNCHANGED[*]}"
                    [ ${#SKIPPED[@]}   -gt 0 ] && msg_info "Skipped:   ${SKIPPED[*]}"
                    exit 1
                    ;;
                *) msg_warn "Please type 'ok' or 'abort'." ;;
            esac
        done
    else
        msg_info "No image changes for $LABEL."
        UNCHANGED+=("$LABEL")
    fi

    # Prune unused images
    if [ "$NO_PRUNE" = false ]; then
        msg_info "Pruning unused images in $LABEL..."
        pct exec "$VMID" -- sh -c "docker image prune -a -f" \
            || msg_warn "Prune failed in $LABEL (continuing)."
    fi

done < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')

# --- Summary ---
echo ""
echo -e "\e[1;34m--- Summary ---\e[0m"
if [ "$MATCHED" -eq 0 ]; then
    if [ -n "$ONLY_CT" ]; then
        msg_warn "No tagged LXC matched '$ONLY_CT' (id or hostname)."
    else
        msg_warn "No LXCs found with tag '$var_tag'."
    fi
    exit 1
fi
if [ ${#UPDATED[@]} -gt 0 ]; then
    msg_ok "Updated:   ${UPDATED[*]}"
else
    msg_info "No containers were updated."
fi
[ ${#UNCHANGED[@]} -gt 0 ] && msg_info "Unchanged: ${UNCHANGED[*]}"
[ ${#SKIPPED[@]}   -gt 0 ] && msg_info "Skipped:   ${SKIPPED[*]}"

msg_ok "Done."
