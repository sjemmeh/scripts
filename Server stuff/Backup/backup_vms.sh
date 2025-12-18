#!/bin/bash

# --- Configuration ---
BACKUP_DIR="/mnt/fast-nvme/backup-tmp"
RCLONE_REMOTE="gdrive:Server/vm-backup"
LOG_FILE="/opt/logs/proxmox_backup/proxmox_backup.log"
VM_IDS=(101) 

# Ensure strict error handling
set -e                # Exit immediately if a command exits with a non-zero status
set -o pipefail       # Return exit status of the last command in the pipe that failed

# --- Functions ---

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

ensure_dependencies() {
  for cmd in lz4 rclone qm; do
    if ! command -v "$cmd" &> /dev/null; then
      log "ERROR: $cmd could not be found. Please install it."
      exit 1
    fi
  done
}

# --- Main Script ---

ensure_dependencies

start_time=$(date +%s)
log "Starting Proxmox backup workflow..."

# Create main backup dir if it doesn't exist
mkdir -p "$BACKUP_DIR"

for VMID in "${VM_IDS[@]}"; do
  # Validate VM exists
  if ! /usr/sbin/qm list | awk '{print $1}' | grep -q "^$VMID$"; then
    log "WARNING: VM $VMID not found, skipping..."
    continue
  fi

  # Get VM Name and setup paths
  VM_NAME=$(/usr/sbin/qm config "$VMID" | grep name | cut -d' ' -f2)
  DATE=$(date +%d-%m-%Y)
  # Structure: /mnt/fast-nvme/backup-tmp/101_MyVM/18-12-2025
  TEMP_VM_DIR="${BACKUP_DIR}/${VMID}_${VM_NAME}/${DATE}"

  log "Processing VM $VMID ($VM_NAME)..."
  mkdir -p "$TEMP_VM_DIR"

  # 1. Handle VM State (Suspend if running)
  VM_WAS_RUNNING=false
  if /usr/sbin/qm status "$VMID" | grep -q "status: running"; then
    log "Suspending VM $VMID to ensure disk consistency..."
    /usr/sbin/qm suspend "$VMID"
    VM_WAS_RUNNING=true
  fi

  # 2. Backup Config
  log "Backing up config..."
  /usr/sbin/qm config "$VMID" > "$TEMP_VM_DIR/vm-${VMID}-config.conf"

  # 3. Identify and Backup Disks
  # optimization: exclude CD-ROMs explicitly if they appear as ide/sata
  DISK_PATHS=$(/usr/sbin/qm config "$VMID" | grep -E 'scsi|sata|ide|virtio' | grep disk | grep -v 'media=cdrom' | awk '{print $2}' | cut -d',' -f1)

  if [ -z "$DISK_PATHS" ]; then
    log "WARNING: No disks found for VM $VMID."
  else
    DISK_COUNT=0
    for DISK in $DISK_PATHS; do
      DISK_PATH=$(/usr/sbin/pvesm path "$DISK")

      if [ -z "$DISK_PATH" ]; then
        log "WARNING: Could not resolve path for disk $DISK, skipping..."
        continue
      fi

      OUTPUT_IMAGE="$TEMP_VM_DIR/vm-${VMID}-disk-${DISK_COUNT}.raw.lz4"
      log "Backing up disk: $DISK_PATH -> $OUTPUT_IMAGE"
      
      # Using cat is fine, but we ensure pipefail catches lz4 errors
      cat "$DISK_PATH" | lz4 -1 -c > "$OUTPUT_IMAGE"

      DISK_COUNT=$((DISK_COUNT+1))
    done
  fi

  # 4. Resume VM immediately after disk reads are done
  if [ "$VM_WAS_RUNNING" = true ]; then
    log "Resuming VM $VMID..."
    /usr/sbin/qm resume "$VMID"
  fi

  # 5. Upload to Rclone
  REMOTE_PATH="$RCLONE_REMOTE/${VMID}_${VM_NAME}/${DATE}/"
  log "Uploading backup to $REMOTE_PATH..."
  
  if /usr/bin/rclone copy "$TEMP_VM_DIR" "$REMOTE_PATH"; then
    log "Upload successful. Cleaning up local files..."
    rm -rf "${BACKUP_DIR:?}/${VMID}_${VM_NAME}" # Safe delete
  else
    log "ERROR: Rclone upload failed! Keeping local files at $TEMP_VM_DIR for safety."
  fi

done

end_time=$(date +%s)
duration=$((end_time - start_time))

log "Backup completed in ${duration} seconds."
