#!/bin/bash

# --- Configuration ---
BACKUP_DIR="/mnt/storagebox/tmp"
RCLONE_REMOTE="gdrive:Server/vm-backup-hetzner"
LOG_FILE="/opt/logs/proxmox_backup/proxmox_backup.log"
RETENTION_DAYS="30d"

# --- Setup ---
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
LOCK_FILE="/var/run/proxmox_backup.lock"
exec 200>$LOCK_FILE
flock -n 200 || { echo "Backup already running. Exiting." >> "$LOG_FILE"; exit 1; }

set -e
set -o pipefail

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

ensure_dependencies() {
  for cmd in rclone vzdump zstd qm pct; do
    if ! command -v "$cmd" &> /dev/null; then
      log "ERROR: $cmd could not be found."
      exit 1
    fi
  done
}

ensure_dependencies
mkdir -p "$BACKUP_DIR"
mkdir -p "$(dirname "$LOG_FILE")"

# --- Determine target IDs ---
if [ $# -eq 1 ]; then
    # Single ID provided — back up only that VM/CT
    VM_IDS=("$1")
    FULL_BACKUP=false
    log "Starting single backup for ID $1..."
elif [ $# -eq 0 ]; then
    # No args — discover all VMs and CTs
    FULL_BACKUP=true
    mapfile -t QEMU_IDS < <(qm list | awk 'NR>1 {print $1}')
    mapfile -t LXC_IDS  < <(pct list | awk 'NR>1 {print $1}')
    VM_IDS=("${QEMU_IDS[@]}" "${LXC_IDS[@]}")
    log "Starting full backup for ${#VM_IDS[@]} guests: ${VM_IDS[*]}"
else
    echo "Usage: $0 [VMID]"
    exit 1
fi

for VMID in "${VM_IDS[@]}"; do
    log "Processing ID $VMID..."

    # Detect if it's a QEMU VM or LXC Container
    if qm status "$VMID" &>/dev/null; then
        GUEST_TYPE="qemu"
        EXTENSION="vma.zst"
    elif pct status "$VMID" &>/dev/null; then
        GUEST_TYPE="lxc"
        EXTENSION="tar.zst"
    else
        log "ERROR: ID $VMID is neither a VM nor a Container. Skipping."
        continue
    fi

    log "Detected $GUEST_TYPE for ID $VMID. Starting vzdump..."

    if vzdump "$VMID" --dumpdir "$BACKUP_DIR" --mode snapshot --compress zstd --stdexcludes; then
        # Dynamically find the file based on the detected guest type
        BACKUP_FILE=$(find "$BACKUP_DIR" -name "vzdump-$GUEST_TYPE-$VMID-*.${EXTENSION}" -printf "%T@ %p\n" | sort -n | tail -1 | cut -d' ' -f2)

        if [ -f "$BACKUP_FILE" ]; then
            REMOTE_DEST="$RCLONE_REMOTE/${VMID}/"
            VZDUMP_LOG="${BACKUP_FILE%.${EXTENSION}}.log"

            log "Uploading $(basename "$BACKUP_FILE") to $REMOTE_DEST..."
            rclone copy "$BACKUP_FILE" "$REMOTE_DEST"

            log "Upload complete. Cleaning up local files."
            rm "$BACKUP_FILE"

            if [ -f "$VZDUMP_LOG" ]; then
                rm "$VZDUMP_LOG"
            fi
        else
            log "ERROR: Backup file for $GUEST_TYPE $VMID not found."
        fi
    else
        log "ERROR: vzdump failed for ID $VMID"
    fi
done

if [ "$FULL_BACKUP" = true ]; then
    log "Running Retention Policy (> $RETENTION_DAYS)..."
    rclone delete "$RCLONE_REMOTE" --min-age "$RETENTION_DAYS" --verbose 2>> "$LOG_FILE"
    rclone rmdirs "$RCLONE_REMOTE" --leave-root --verbose 2>> "$LOG_FILE"
fi

log "Backup and Cleanup Completed."