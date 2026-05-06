#!/bin/bash

# --- Configuration (mirrors backup_vms.sh) ---
BACKUP_DIR="/mnt/storagebox/tmp"
RCLONE_REMOTE="gdrive:Server/vm-backup-hetzner"
RESTORE_STORAGE="local"   # Proxmox storage target for the restored disk
RETENTION_DAYS=30

# --- Logging ---
msg_info()  { echo -e "\e[34m[INFO]\e[0m $1"; }
msg_ok()    { echo -e "\e[32m[OK]\e[0m $1"; }
msg_error() { echo -e "\e[31m[ERROR]\e[0m $1"; exit 1; }
msg_warn()  { echo -e "\e[33m[WARN]\e[0m $1"; }

# --- Usage ---
if [ $# -ne 1 ]; then
    echo "Usage: $0 <VMID>"
    exit 1
fi

VMID="$1"
REMOTE_PATH="$RCLONE_REMOTE/${VMID}/"

# --- Dependency check ---
for cmd in rclone qmrestore pct; do
    if ! command -v "$cmd" &>/dev/null; then
        msg_error "Required command '$cmd' not found."
    fi
done

echo ""
echo -e "\e[1;34m--- Proxmox Restore: ID $VMID ---\e[0m"
echo ""

# --- Fetch backup list from Google Drive ---
msg_info "Fetching backups for ID $VMID from Google Drive (last ${RETENTION_DAYS} days)..."

CUTOFF_DATE=$(date -d "${RETENTION_DAYS} days ago" '+%Y-%m-%d')

mapfile -t ALL_FILES < <(
    rclone lsf "$REMOTE_PATH" --format "tp" 2>/dev/null \
        | sort -r
)

if [ ${#ALL_FILES[@]} -eq 0 ]; then
    msg_error "No backups found at ${REMOTE_PATH}. Check the VMID or Google Drive remote."
fi

# Filter to last 30 days and collect entries
BACKUP_FILES=()
BACKUP_DATES=()

for entry in "${ALL_FILES[@]}"; do
    # rclone lsf --format "tp" output: "<datetime>;<filename>"
    FILE_DATE=$(echo "$entry" | cut -d';' -f1 | cut -d' ' -f1)
    FILENAME=$(echo "$entry" | cut -d';' -f2)

    # Skip non-backup files
    [[ "$FILENAME" != vzdump-* ]] && continue

    # Skip if older than retention window
    if [[ "$FILE_DATE" < "$CUTOFF_DATE" ]]; then
        continue
    fi

    BACKUP_FILES+=("$FILENAME")
    BACKUP_DATES+=("$FILE_DATE")
done

if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
    msg_error "No backups within the last ${RETENTION_DAYS} days found for ID $VMID."
fi

# --- Detect guest type from first filename ---
FIRST_FILE="${BACKUP_FILES[0]}"
if [[ "$FIRST_FILE" == vzdump-qemu-* ]]; then
    GUEST_TYPE="qemu"
elif [[ "$FIRST_FILE" == vzdump-lxc-* ]]; then
    GUEST_TYPE="lxc"
else
    msg_error "Could not determine guest type from filename: $FIRST_FILE"
fi

msg_ok "Guest type detected: $GUEST_TYPE"
echo ""

# --- Present selection menu ---
echo "Available backups (newest first):"
echo ""
for i in "${!BACKUP_FILES[@]}"; do
    # Extract date and time from filename: vzdump-{type}-{id}-{YYYY_MM_DD}-{HH_MM_SS}.ext
    RAW=$(echo "${BACKUP_FILES[$i]}" | grep -oP '\d{4}_\d{2}_\d{2}-\d{2}_\d{2}_\d{2}')
    DISPLAY_DATE=$(echo "$RAW" | sed 's/_/-/g; s/-\([0-9][0-9]\)-\([0-9][0-9]\)-\([0-9][0-9]\)$/ \1:\2:\3/')
    printf "  %2d) %s\n" "$((i + 1))" "$DISPLAY_DATE"
done

echo ""
read -p "Select backup to restore [1-${#BACKUP_FILES[@]}]: " SELECTION

# Validate selection
if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#BACKUP_FILES[@]}" ]; then
    msg_error "Invalid selection."
fi

SELECTED_FILE="${BACKUP_FILES[$((SELECTION - 1))]}"
msg_info "Selected: $SELECTED_FILE"

# --- Warn if VMID already exists ---
if qm status "$VMID" &>/dev/null || pct status "$VMID" &>/dev/null; then
    echo ""
    msg_warn "A VM/CT with ID $VMID already exists on this host."
    read -p "Overwrite it? This will DESTROY the existing guest. (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        msg_info "Restore cancelled."
        exit 0
    fi
    msg_info "Stopping and destroying existing ID $VMID..."
    if [ "$GUEST_TYPE" = "qemu" ]; then
        qm stop "$VMID" &>/dev/null || true
        qm destroy "$VMID" --purge
    else
        pct stop "$VMID" &>/dev/null || true
        pct destroy "$VMID"
    fi
    msg_ok "Existing guest removed."
fi

# --- Download from Google Drive ---
echo ""
msg_info "Downloading $SELECTED_FILE from Google Drive..."
mkdir -p "$BACKUP_DIR"
rclone copy "${REMOTE_PATH}${SELECTED_FILE}" "$BACKUP_DIR" --progress \
    || msg_error "Failed to download backup from Google Drive."
msg_ok "Download complete."

LOCAL_FILE="${BACKUP_DIR}/${SELECTED_FILE}"

# --- Restore ---
echo ""
msg_info "Restoring $GUEST_TYPE $VMID from $(basename "$LOCAL_FILE")..."

if [ "$GUEST_TYPE" = "qemu" ]; then
    qmrestore "$LOCAL_FILE" "$VMID" --storage "$RESTORE_STORAGE" \
        || { rm -f "$LOCAL_FILE"; msg_error "qmrestore failed."; }
else
    pct restore "$VMID" "$LOCAL_FILE" --storage "$RESTORE_STORAGE" \
        || { rm -f "$LOCAL_FILE"; msg_error "pct restore failed."; }
fi

msg_ok "Restore complete."

# --- Cleanup local download ---
msg_info "Cleaning up local download..."
rm -f "$LOCAL_FILE"
msg_ok "Done."

# --- Start prompt ---
echo ""
read -p "Would you like to start the restored guest now? (y/N): " START_NOW
if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
    if [ "$GUEST_TYPE" = "qemu" ]; then
        qm start "$VMID"
    else
        pct start "$VMID"
    fi
    msg_ok "Guest $VMID started."
else
    msg_info "Guest not started. You can start it manually: $([ "$GUEST_TYPE" = "qemu" ] && echo "qm start $VMID" || echo "pct start $VMID")"
fi

echo ""
msg_ok "Restore of ID $VMID complete!"
