#!/bin/bash
# Set maintenance mode
BACKUP_DIR="/mnt/nvme/tmp/proxmox_backup"
RCLONE_REMOTE="gdrive:Server/vm-backup"
DATE=$(/bin/date +%d-%m-%Y)
LOG_FILE="/mnt/nvme/scripts/logs/proxmox_backup.log"
COMPRESS=true  # Set to false if you want to disable compression
VM_IDS=(101)  # List VM IDs to back up, e.g., (100 101 102)

# Log function
log() {
  echo "[$(/bin/date '+%Y-%m-%d %H:%M:%S')] $1" | /usr/bin/tee -a "$LOG_FILE"
}

log "Starting Proxmox backup..."

#To-Do: Make this a fucking function :)
/mnt/nvme/scripts/toggle_maintenance.sh enable

# Get list of specified VMs
for VMID in "${VM_IDS[@]}"; do
  if ! /usr/sbin/qm list | /usr/bin/awk '{print $1}' | /bin/grep -q "^$VMID$"; then
    log "VM $VMID not found, skipping..."
    continue
  fi
  
  VM_NAME=$(/usr/sbin/qm config $VMID | /bin/grep name | /usr/bin/cut -d' ' -f2)
  log "Backing up VM $VMID ($VM_NAME)..."
  
  VM_BACKUP_DIR="${BACKUP_DIR}/${VMID}_${VM_NAME}"
  /bin/mkdir -p "$VM_BACKUP_DIR"
  
  DATE_BACKUP_DIR="${VM_BACKUP_DIR}/${DATE}"
  /bin/mkdir -p "$DATE_BACKUP_DIR"
  
  if /usr/sbin/qm status $VMID | /bin/grep -q "status: running"; then
    log "Suspending VM $VMID..."
    /usr/sbin/qm suspend $VMID
  fi
  
  /usr/sbin/qm config $VMID > "$DATE_BACKUP_DIR/vm-${VMID}-config.conf"
  
  DISK_PATHS=$(/usr/sbin/qm config $VMID | /bin/grep -E 'scsi|sata|ide|virtio' | /bin/grep disk | /usr/bin/awk '{print $2}' | /usr/bin/cut -d',' -f1)
  
  if [ -z "$DISK_PATHS" ]; then
    log "No disks found for VM $VMID, skipping..."
    continue
  fi
  
  DISK_COUNT=0
  for DISK in $DISK_PATHS; do
    DISK_PATH=$(/usr/sbin/pvesm path $DISK)
    
    if [ -z "$DISK_PATH" ]; then
      log "Could not resolve path for disk $DISK, skipping..."
      continue
    fi
    
    if [ "$COMPRESS" = true ]; then
      OUTPUT_IMAGE="$DATE_BACKUP_DIR/vm-${VMID}-disk-${DISK_COUNT}.raw.gz"
      log "Copying and compressing $DISK_PATH to $OUTPUT_IMAGE..."
      /bin/cat "$DISK_PATH" | /bin/gzip -c > "$OUTPUT_IMAGE"
    else
      OUTPUT_IMAGE="$DATE_BACKUP_DIR/vm-${VMID}-disk-${DISK_COUNT}.raw"
      log "Copying $DISK_PATH to $OUTPUT_IMAGE..."
      /bin/cp "$DISK_PATH" "$OUTPUT_IMAGE"
    fi
    
    DISK_COUNT=$((DISK_COUNT+1))
  done
  
  log "Uploading $DATE_BACKUP_DIR to $RCLONE_REMOTE/${VMID}_${VM_NAME}/${DATE}/..."
  /usr/bin/rclone copy "$DATE_BACKUP_DIR" "$RCLONE_REMOTE/${VMID}_${VM_NAME}/${DATE}/"
  log "Resuming VM $VMID..."
  /usr/sbin/qm resume $VMID
  
  log "Cleaning up local backup directory for VM $VMID..."
  /bin/rm -rf "$DATE_BACKUP_DIR"
done

/mnt/nvme/scripts/toggle_maintenance.sh disable

log "Proxmox backup completed!"
