#!/bin/bash

# Arch Linux Automated Installation Script
# Based on guide by Jaimie de Haas

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Functions
print_section() {
    echo -e "\n${BLUE}==>${NC} ${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}ERROR:${NC} $1"
}

print_info() {
    echo -e "${YELLOW}INFO:${NC} $1"
}

# Detect the disk type and select the appropriate device
detect_disk() {
    print_section "Detecting available disks"
    
    # List available disks - fixed the command
    echo "Available disks:"
    lsblk -dp | grep -E "disk"
    
    # Ask user to select a disk
    echo -e "\nPlease enter the disk device (e.g., /dev/nvme0n1 or /dev/sda):"
    read DISK
    
    if [[ ! -b "$DISK" ]]; then
        print_error "Invalid disk device: $DISK"
        exit 1
    fi
    
    # Extract just the device name (e.g., nvme0n1 or sda)
    DISK_NAME=$(basename $DISK)
    
    # Set part1 and part2 based on disk type
    if [[ "$DISK_NAME" == nvme* ]]; then
        PART1="${DISK}p1"
        PART2="${DISK}p2"
        print_info "NVMe disk detected: $DISK"
    else
        PART1="${DISK}1"
        PART2="${DISK}2"
        print_info "SATA/IDE disk detected: $DISK"
    fi
}

# Confirm with the user before proceeding
confirm() {
    print_section "WARNING: This will erase all data on $DISK"
    echo -e "EFI partition will be ${YELLOW}$PART1${NC}"
    echo -e "Root partition will be ${YELLOW}$PART2${NC}"
    echo -e "\nDo you want to continue? (yes/no):"
    read CONFIRM
    
    if [[ ! "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
        print_error "Installation aborted by user"
        exit 1
    fi
}

# Create partitions
create_partitions() {
    print_section "Creating partitions on $DISK"
    
    # Wipe existing partition table
    print_info "Wiping existing partition table"
    sgdisk --zap-all $DISK
    
    # Create EFI partition (512MB)
    print_info "Creating EFI partition"
    sgdisk --new=1:0:+512M --typecode=1:ef00 $DISK
    
    # Create root partition (rest of the disk)
    print_info "Creating root partition"
    sgdisk --new=2:0:0 --typecode=2:8300 $DISK
    
    # Wait for partitions to be recognized by the kernel
    print_info "Waiting for partitions to be recognized"
    sleep 3
}

# Format partitions
format_partitions() {
    print_section "Formatting partitions"
    
    # Format EFI partition as FAT32
    print_info "Formatting EFI partition as FAT32"
    mkfs.fat -F 32 $PART1
    
    # Format root partition as Btrfs
    print_info "Formatting root partition as Btrfs"
    mkfs.btrfs -f $PART2
}

# Create Btrfs subvolumes
create_subvolumes() {
    print_section "Creating Btrfs subvolumes"
    
    # Mount root partition
    print_info "Mounting root partition"
    mount $PART2 /mnt
    
    # Create subvolumes
    print_info "Creating @ subvolume"
    btrfs subvolume create /mnt/@
    
    print_info "Creating @home subvolume"
    btrfs subvolume create /mnt/@home
    
    # Unmount
    print_info "Unmounting root partition"
    umount /mnt
}

# Mount filesystems
mount_filesystems() {
    print_section "Mounting filesystems"
    
    # Mount root subvolume
    print_info "Mounting @ subvolume to /mnt"
    mount -o compress=zstd,subvol=@ $PART2 /mnt
    
    # Create and mount home directory
    print_info "Creating and mounting home directory"
    mkdir -p /mnt/home
    mount -o compress=zstd,subvol=@home $PART2 /mnt/home
    
    # Create and mount EFI directory
    print_info "Creating and mounting EFI directory"
    mkdir -p /mnt/efi
    mount $PART1 /mnt/efi
}

# Enable multilib repository
enable_multilib() {
    print_section "Enabling multilib repository"
    
    # Check if multilib is already enabled
    if grep -q "^\[multilib\]" /etc/pacman.conf; then
        print_info "Multilib repository already enabled"
    else
        print_info "Enabling multilib repository"
        # Uncomment multilib section in pacman.conf
        sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
        print_info "Updating package database with multilib"
        pacman -Syy
    fi
}

# Install base system
install_base_system() {
    print_section "Installing base system"
    
    # Update package database
    print_info "Updating package database"
    pacman -Syy
    
    # Install base packages
    print_info "Installing base packages (this may take a while)"
    pacstrap -K /mnt base base-devel linux linux-firmware git btrfs-progs grub efibootmgr grub-btrfs \
        inotify-tools timeshift nano git networkmanager amd-ucode pipewire pipewire-alsa pipewire-pulse \
        pipewire-jack wireplumber cifs-utils zsh zsh-completions zsh-autosuggestions man sudo xorg sddm \
        plasma dolphin alacritty ntfs-3g spectacle kcalc nvidia-open nvidia-utils lib32-nvidia-utils
}

# Generate fstab
generate_fstab() {
    print_section "Generating fstab"
    genfstab -U /mnt >> /mnt/etc/fstab
    cat /mnt/etc/fstab
}

# Configure system
configure_system() {
    print_section "Configuring the system"
    
    # Create configuration script to run inside the chroot
    cat > /mnt/configure.sh << 'EOF'
#!/bin/bash

# Set timezone
echo "Setting timezone to Europe/Amsterdam"
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
hwclock --systohc

# Configure locale
echo "Configuring locale"
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "nl_NL.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

# Set locale preferences
echo "Setting language preferences"
cat > /etc/locale.conf << 'END'
LANG=nl_NL.UTF-8
LC_MESSAGES=en_US.UTF-8
END

# Set hostname
echo "Setting hostname"
read -p "Enter hostname: " HOSTNAME
echo "$HOSTNAME" > /etc/hostname

# Configure hosts file
cat > /etc/hosts << END
127.0.0.1 localhost
::1 localhost
127.0.1.1 $HOSTNAME
END

# Set root password
echo "Setting root password"
passwd

# Create user
echo "Creating user account"
read -p "Enter username: " USERNAME
useradd -mG wheel "$USERNAME"
passwd "$USERNAME"

# Configure sudo
echo "Configuring sudo"
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# Enable services
echo "Enabling services"
systemctl enable NetworkManager sddm

# Configure environment for NVIDIA
echo "Configuring environment for NVIDIA"
cat > /etc/environment << 'END'
GBM_BACKEND=nvidia-drm
__GLX_VENDOR_LIBRARY_NAME=nvidia
END

# Configure mkinitcpio.conf for NVIDIA
echo "Configuring initramfs for NVIDIA"
sed -i 's/MODULES=().*/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' /etc/mkinitcpio.conf
sed -i 's/HOOKS=.*kms.*/HOOKS=(base udev autodetect modconf block filesystems keyboard fsck)/' /etc/mkinitcpio.conf

# Configure GRUB for NVIDIA
echo "Configuring GRUB for NVIDIA"
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=".*"/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash nvidia-drm.modeset=1 nvidia_drm.fbdev=1 nvidia.NVreg_EnableGpuFirmware=0"/' /etc/default/grub

# Regenerate initramfs
echo "Regenerating initramfs"
mkinitcpio -P

# Install GRUB
echo "Installing GRUB"
grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# Set ZSH as default shell for user
echo "Setting ZSH as default shell"
chsh -s /usr/bin/zsh "$USERNAME"

echo "System configuration complete!"
echo "After reboot, log in as your user and run the post-install script to install additional software."
EOF

    # Create post-install script for additional software
    cat > /mnt/post-install.sh << 'EOF'
#!/bin/bash

echo "Installing AUR helper (yay)"
cd ~/
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si

echo "Installing additional applications"
yay -S brave termius discord 1password spotify visual-studio-code-bin p7zip-gui lutris steam

echo "Installing OnlyOffice"
cd ~/
git clone https://aur.archlinux.org/onlyoffice-bin.git
cd onlyoffice-bin && makepkg -si

echo "Installing Oh My Zsh"
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"

echo "Post-installation complete!"
EOF

    # Make the scripts executable
    chmod +x /mnt/configure.sh
    chmod +x /mnt/post-install.sh
    
    print_info "Chrooting into the new system to continue configuration"
    arch-chroot /mnt /configure.sh
}

# Finalize installation
finalize_installation() {
    print_section "Finalizing installation"
    
    # Unmount all partitions
    print_info "Unmounting all partitions"
    umount -R /mnt
    
    print_section "Installation complete!"
    echo "You can now reboot into your new Arch Linux system."
    echo "After reboot, log in and run the post-install.sh script to install additional software."
    echo -e "\nWould you like to reboot now? (yes/no):"
    read REBOOT
    
    if [[ "$REBOOT" =~ ^[Yy][Ee][Ss]$ ]]; then
        print_info "Rebooting system..."
        reboot
    fi
}

# Main script execution
clear
echo -e "${GREEN}Arch Linux Automated Installation Script${NC}"
echo -e "${YELLOW}Based on guide by Jaimie de Haas${NC}"
echo -e "\nThis script will automate the installation of Arch Linux with BTRFS and NVIDIA drivers."

# Run the installation steps
detect_disk
confirm
create_partitions
format_partitions
create_subvolumes
mount_filesystems
enable_multilib
install_base_system
generate_fstab
configure_system
finalize_installation