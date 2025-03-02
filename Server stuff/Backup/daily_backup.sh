#!/bin/bash

# Define source and destination
SOURCE="/mnt/Data/Backup/"
DESTINATION="gdrive:daily-backup"
LOG_FILE="/scripts/logs/daily_backup.log"

# Log function
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to check if rclone is running
is_rclone_running() {
    pgrep -f "rclone sync" > /dev/null
    return $?
}

# Check if rclone is running
if is_rclone_running; then
    log "Backup already running, skipping this hour"
    exit 0
fi

# Run rclone if not running
log "Starting backup"
rclone sync "$SOURCE" "$DESTINATION" --progress --log-file="$LOGFILE" --log-level INFO

# Log completion
log "Backup completed"