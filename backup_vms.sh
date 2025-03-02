#!/bin/bash

# Set maintenance mode
/scripts/toggle_maintenance.sh enable

BACKUP_DIR="/mnt/nvme/tmp/kvm_backup"
RCLONE_REMOTE="gdrive:/vm-backup"
DATE=$(date +%Y-%m-%d)
LOG_FILE="/scripts/log/kvm_backup.log"


# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

mkdir -p "$BACKUP_DIR"

log "Starting KVM backup..."

for VM in $(virsh list --name); do
   log "Backing up $VM..."

    # Create VM-specific backup directory
    VM_BACKUP_DIR="$BACKUP_DIR/$VM"
    mkdir -p "$VM_BACKUP_DIR"

    # Suspend the VM if running
    virsh domstate "$VM" | grep -q "running" && {
       log "Suspending $VM..."
        virsh suspend "$VM"
    }

    # Backup VM XML configuration
    virsh dumpxml "$VM" > "$VM_BACKUP_DIR/${VM}.xml"

    # Get VM disk path
    DISK_PATH=$(virsh domblklist "$VM" | awk '/\.qcow2/ {print $2}')

    if [ -z "$DISK_PATH" ]; then
       log "No qcow2 disk found for $VM, skipping..." 
        continue
    fi

    # Copy the disk without compression
    OUTPUT_IMAGE="$VM_BACKUP_DIR/${VM}_${DATE}.qcow2"
   log "Copying $DISK_PATH to $OUTPUT_IMAGE..." 
    cp "$DISK_PATH" "$OUTPUT_IMAGE"

   log "Uploading $VM_BACKUP_DIR to $RCLONE_REMOTE/$VM/..." 
    rclone copy "$VM_BACKUP_DIR" "$RCLONE_REMOTE/$VM/"

    # Resume the VM if it was suspended
    virsh domstate "$VM" | grep -q "paused" && {
       log "Resuming $VM..." 
        virsh resume "$VM"
    }

    # Cleanup local backup
    rm -rf "$VM_BACKUP_DIR"

    # Remove old backups, keeping only the last 7
   log "Removing old backups for $VM, keeping only the last 7..." 
    rclone lsf "$RCLONE_REMOTE/$VM/" --files-only | sort -r | tail -n +8 | while read FILE; do
       log "Deleting $RCLONE_REMOTE/$VM/$FILE..." 
        rclone delete "$RCLONE_REMOTE/$VM/$FILE"
    done

done

# Disabling maintenance mode
/scripts/toggle_maintenance.sh disable

log "KVM backup completed!" 