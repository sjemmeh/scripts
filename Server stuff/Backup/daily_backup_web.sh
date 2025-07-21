#!/bin/bash

# Set safe PATH for cron
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# Log file
LOG_FILE="/scripts/log/website_backup.log"
exec >> "$LOG_FILE" 2>&1

echo "=== Website Backup Started: $(date) ==="

# Variables
DATE=$(date +%d-%m-%Y)
BACKUP_DIR="/website_backups/$DATE"
SJEMMEH_DIR="$BACKUP_DIR/sjemmeh"
ROCKMANIAC_DIR="$BACKUP_DIR/rockmaniac"

# Create backup directories
mkdir -p "$ROCKMANIAC_DIR" "$SJEMMEH_DIR"

# Get all non-system databases
DBS=$(/usr/bin/mysql -u root -e 'SHOW DATABASES;' | grep -Ev 'Database|information_schema|performance_schema|mysql|sys')

# Dump each database into the appropriate folder
for DB in $DBS; do
    case "$DB" in
        jaimie_*)
            echo "Dumping $DB to sjemmeh folder..."
            /usr/bin/mysqldump -u root "$DB" > "$SJEMMEH_DIR/$DB.sql"
            ;;
        rockmaniac_*)
            echo "Dumping $DB to rockmaniac folder..."
            /usr/bin/mysqldump -u root "$DB" > "$ROCKMANIAC_DIR/$DB.sql"
            ;;
        *)
            echo "Skipping unrecognized database: $DB"
            ;;
    esac
done

# Compress web directories
echo "Compressing web directories..."
/usr/bin/tar -czf "$ROCKMANIAC_DIR/rockmaniac.tar.gz" /usr/local/lsws/RockManiacRecords
/usr/bin/tar -czf "$SJEMMEH_DIR/sjemmeh_html.tar.gz" /usr/local/lsws/sjemmeh

# Upload using rclone
echo "Uploading backup to Google Drive..."
/usr/bin/rclone copy "$BACKUP_DIR" gdrive:Server/website-backups/$DATE --quiet

# Cleanup
echo "Cleaning up local backup..."
rm -rf "$BACKUP_DIR"

echo "Backup completed: $(date)"