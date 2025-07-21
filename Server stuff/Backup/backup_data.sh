#!/bin/bash

# Define source and destination
SOURCE="/mnt/Data/Backup/"
DESTINATION="gdrive:Server/jaimie-backup"
LOGFILE="/mnt/nvme/scripts/logs/backup.log"

# Function to check if rclone is running
is_rclone_running() {
    pgrep -f "rclone sync" > /dev/null
    return $?
}

# Check if rclone is running
if is_rclone_running; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Backup already running, skipping this hour" >> "$LOGFILE"
    exit 0
fi

# Run rclone if not running
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting backup" >> "$LOGFILE"
rclone sync "$SOURCE" "$DESTINATION" --progress --log-file="$LOGFILE" --log-level INFO

# Log completion
echo "$(date '+%Y-%m-%d %H:%M:%S') - Backup completed" >> "$LOGFILE"
