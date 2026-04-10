# Scripts

A personal collection of automation scripts. Feel free to use any :)

## Structure

```
scripts/
├── Installation/
│   ├── arch_install.sh          # Full Arch Linux install (KDE + Nvidia + gaming)
│   ├── build_gasket.sh          # Build & install Google Gasket driver on Ubuntu
│   └── Deploy WebVM/
│       ├── deploy.sh            # Provision a Debian LXC + Docker web app on Proxmox
│       └── vm_config.conf       # Config file for deploy.sh
├── Server stuff/
│   ├── Backup/
│   │   └── backup_vms.sh        # Backup Proxmox VMs/CTs to Google Drive via rclone
│   ├── Generation/
│   │   ├── provision_site.sh    # Provision a Node.js site as a systemd service
│   │   └── traefik-cert.sh      # Generate a self-signed TLS cert with IP SAN
│   └── Updating/
│       ├── proxmox-resize-disk  # Expand Proxmox root disk after resizing in hypervisor
│       └── update_docker.sh     # Check for Docker image updates and restart containers
```

## Quick Reference

| Script | Description |
|---|---|
| [`arch_install.sh`](Installation/arch_install.sh) | Interactive Arch Linux installer with KDE, Nvidia, and gaming tools. Supports dual-boot. |
| [`build_gasket.sh`](Installation/build_gasket.sh) | Builds and installs the Google Gasket DKMS driver from source on Ubuntu. |
| [`deploy.sh`](Installation/Deploy%20WebVM/deploy.sh) | Spins up a Debian LXC on Proxmox, installs Docker, and deploys a Docker Hub image. |
| [`backup_vms.sh`](Server%20stuff/Backup/backup_vms.sh) | Backs up all (or a single) Proxmox VM/CT via vzdump and uploads to Google Drive. |
| [`provision_site.sh`](Server%20stuff/Generation/provision_site.sh) | Creates a user, clones a repo, sets up Node via nvm, and registers a systemd service. |
| [`traefik-cert.sh`](Server%20stuff/Generation/traefik-cert.sh) | Generates a self-signed 4096-bit RSA cert with DNS + IP SAN for use with Traefik. |
| [`proxmox-resize-disk`](Server%20stuff/Updating/proxmox-resize-disk) | Commands to reclaim disk space after resizing a Proxmox VM's disk in the hypervisor. |
| [`update_docker.sh`](Server%20stuff/Updating/update_docker.sh) | Scans a directory for Docker projects, pulls updates, and restarts changed containers. |
