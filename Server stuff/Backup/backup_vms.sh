#!/bin/bash

# --- Configuration ---
BACKUP_DIR="/mnt/nvme/tmp/proxmox_backup"
RCLONE_REMOTE="gdrive:Server/vm-backup"
LOG_FILE="/mnt/logs/proxmox_backup/proxmox_backup.log"
PUSHGATEWAY="10.0.0.5:9091" # 
VM_IDS=(101) # 

# --- Functions ---

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Reports the maintenance mode status to Prometheus
report_maintenance_status() {
  # status: 1=enabled, 0=disabled
  local status=$1
  cat <<EOF | curl --data-binary @- http://$PUSHGATEWAY/metrics/job/maintenance_mode
  # TYPE maintenance_mode_status gauge
  maintenance_mode_status $status
EOF
}

# Toggle maintenance mode (I'm lazy and dont want to change this too much, maintenance mode is now just a metric to see if backups are running)
toggle_maintenance() {
  local MODE=$1 # "enable" or "disable"

  if [[ "$MODE" == "enable" ]]; then
    report_maintenance_status 1
  elif [[ "$MODE" == "disable" ]]; then
    report_maintenance_status 0
  else
    log "Usage: toggle_maintenance [enable|disable]"
    return 1
  fi

}

# Reports the final backup status to Prometheus
report_backup_status() {
  local status=$1
  local duration=$2
  cat <<EOF | curl --data-binary @- http://$PUSHGATEWAY/metrics/job/backup_vms
  # TYPE backup_vms_last_success gauge
  backup_vms_last_success $(date +%s)
  # TYPE backup_vms_last_duration_seconds gauge
  backup_vms_last_duration_seconds $duration
  # TYPE backup_vms_last_exit_code gauge
  backup_vms_last_exit_code $status
EOF
}

# --- Main Script ---

# Make sure lz4 is installed
if ! command -v lz4 &> /dev/null
then
    log "ERROR: lz4 could not be found. Please install it with 'sudo apt-get install lz4'"
    exit 1
fi

start_time=$(date +%s)
log "Starting Proxmox backup using lz4..."

# Enable maintenance mode
toggle_maintenance enable

# Main backup logic
for VMID in "${VM_IDS[@]}"; do
  if ! /usr/sbin/qm list | /usr/bin/awk '{print $1}' | /bin/grep -q "^$VMID$"; then
    log "VM $VMID not found, skipping..."
    continue
  fi

  VM_NAME=$(/usr/sbin/qm config "$VMID" | grep name | cut -d' ' -f2)
  DATE=$(date +%d-%m-%Y)
  VM_BACKUP_DIR="${BACKUP_DIR}/${VMID}_${VM_NAME}"
  DATE_BACKUP_DIR="${VM_BACKUP_DIR}/${DATE}"

  log "Backing up VM $VMID ($VM_NAME)..."
  /bin/mkdir -p "$DATE_BACKUP_DIR"

  if /usr/sbin/qm status "$VMID" | /bin/grep -q "status: running"; then
    log "Suspending VM $VMID..."
    /usr/sbin/qm suspend "$VMID"
  fi

  /usr/sbin/qm config "$VMID" > "$DATE_BACKUP_DIR/vm-${VMID}-config.conf"

  DISK_PATHS=$(/usr/sbin/qm config "$VMID" | grep -E 'scsi|sata|ide|virtio' | grep disk | /usr/bin/awk '{print $2}' | /usr/bin/cut -d',' -f1)

  if [ -z "$DISK_PATHS" ]; then
    log "No disks found for VM $VMID, skipping..."
    continue
  fi

  DISK_COUNT=0
  for DISK in $DISK_PATHS; do
    DISK_PATH=$(/usr/sbin/pvesm path "$DISK")

    if [ -z "$DISK_PATH" ]; then
      log "Could not resolve path for disk $DISK, skipping..."
      continue
    fi

    OUTPUT_IMAGE="$DATE_BACKUP_DIR/vm-${VMID}-disk-${DISK_COUNT}.raw.lz4"
    log "Copying and compressing with lz4: $DISK_PATH to $OUTPUT_IMAGE..."
    /bin/cat "$DISK_PATH" | /usr/bin/lz4 -c > "$OUTPUT_IMAGE"

    DISK_COUNT=$((DISK_COUNT+1))
  done

  log "Uploading $DATE_BACKUP_DIR to $RCLONE_REMOTE/${VMID}_${VM_NAME}/${DATE}/..."
  /usr/bin/rclone copy "$DATE_BACKUP_DIR" "$RCLONE_REMOTE/${VMID}_${VM_NAME}/${DATE}/"
  log "Resuming VM $VMID..."
  /usr/sbin/qm resume "$VMID"

  log "Cleaning up local backup directory for VM $VMID..."
  /bin/rm -rf "$DATE_BACKUP_DIR"
done

# Disable maintenance mode
toggle_maintenance disable

end_time=$(date +%s)
duration=$((end_time - start_time))
report_backup_status 0 "$duration" # Assuming success (exit code 0)

log "Proxmox lz4 backup completed!"