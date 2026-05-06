# Scripts

A personal collection of automation scripts. Feel free to use any :)

## Structure

```
scripts/
├── Installation/
│   ├── arch_install.sh          # Full Arch Linux install (KDE + Nvidia + gaming)
│   └── build_gasket.sh          # Build & install Google Gasket driver on Ubuntu
├── Server Related/
│   ├── Deployment/
│   │   ├── manage.sh            # Interactive RHEL Podman Web-App Manager (deploy, restore)
│   │   ├── vm_config.conf       # Config file for manage.sh (DB, Docker, authorized keys)
│   │   ├── backup_customer.sh   # Create tar.gz backup of a customer's app data
│   │   ├── remove_user.sh       # Completely remove a WebVM user account
│   │   └── update_authorized_keys.sh  # Sync authorized_keys from URL to root + /home/* users
│   ├── VM or CT/
│   │   ├── backup_vm.sh         # Backup Proxmox VMs/CTs to Google Drive via rclone
│   │   └── restore_vm.sh        # Restore Proxmox VMs/CTs from backup
│   ├── Mailcow/
│   │   └── add_mailcow_san.sh   # Add a Subject Alternative Name to Mailcow's TLS cert
│   └── proxmox-resize-disk      # Expand Proxmox root disk after resizing in hypervisor
```

## Quick Reference

| Script | Description |
|---|---|
| [`arch_install.sh`](Installation/arch_install.sh) | Interactive Arch Linux installer with KDE, Nvidia, and gaming tools. Supports dual-boot. |
| [`build_gasket.sh`](Installation/build_gasket.sh) | Builds and installs the Google Gasket DKMS driver from source on Ubuntu. |
| [`manage.sh`](Server%20Related/Deployment/manage.sh) | Interactive RHEL Podman web-app manager — deploys new customers, restores from backup. |
| [`backup_customer.sh`](Server%20Related/Deployment/backup_customer.sh) | Creates a tar.gz backup of a customer's themes, plugins, uploads, and logs. |
| [`remove_user.sh`](Server%20Related/Deployment/remove_user.sh) | Forcefully kills all processes, disables lingering, and deletes a WebVM user account. |
| [`update_authorized_keys.sh`](Server%20Related/Deployment/update_authorized_keys.sh) | Fetches SSH authorized_keys from `AUTHORIZED_KEYS_URL` and syncs to root + all `/home/*/` users. Safe for cron. |
| [`backup_vm.sh`](Server%20Related/VM%20or%20CT/backup_vm.sh) | Backs up all (or a single) Proxmox VM/CT via vzdump and uploads to Google Drive. |
| [`restore_vm.sh`](Server%20Related/VM%20or%20CT/restore_vm.sh) | Restores a Proxmox VM/CT from a vzdump backup. |
| [`add_mailcow_san.sh`](Server%20Related/Mailcow/add_mailcow_san.sh) | Adds a Subject Alternative Name (SAN) to a Mailcow TLS certificate. |
| [`proxmox-resize-disk`](Server%20Related/proxmox-resize-disk) | Commands to reclaim disk space after resizing a Proxmox VM's disk in the hypervisor. |
