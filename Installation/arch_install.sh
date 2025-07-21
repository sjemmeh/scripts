#!/usr/bin/env bash
# Author: Jaimie de Haas
# Arch KDE + Nvidia + Gaming essentials

# Partition layout:
# 1 = EFI
# 2 = Windows (if enabled)
# 3 = Swap
# 4 = Root
# 5 = Home


set -euo pipefail

### ──────────────────────────────────────────────
# 0. Ask for user inputs
### ──────────────────────────────────────────────
read -rp "Enter the target disk (e.g. /dev/nvme0n1 or /dev/sda): " DISK
read -rp "Enter desired hostname: " HOSTNAME
read -rp "Enter desired username: " USERNAME
read -rsp "Enter password for $USERNAME: " PASS1 && echo
read -rsp "Confirm password: " PASS2 && echo
[[ "$PASS1" == "$PASS2" ]] || { echo "Passwords do not match."; exit 1; }

read -rp "Swap size in GiB (e.g. 16): " SWAP_GIB
read -rp "Enable dual boot with Windows? (y/N): " DUALBOOT
DUALBOOT=${DUALBOOT,,} 

if [[ "$DUALBOOT" == "y" ]]; then
  read -rp "What percentage of the disk should be reserved for Windows (e.g. 40): " WIN_PERCENT
else
  WIN_PERCENT=0
fi

### ──────────────────────────────────────────────
# 1. Calculate partition sizes
### ──────────────────────────────────────────────
EFI_SIZE_MB=512
SWAP_SIZE_MB=$((SWAP_GIB * 1024))

DISK_SIZE=$(lsblk -bno SIZE "$DISK")
DISK_SIZE_MB=$((DISK_SIZE / 1024 / 1024))

WIN_SIZE_MB=$((DISK_SIZE_MB * WIN_PERCENT / 100))
FREE_MB=$((DISK_SIZE_MB - EFI_SIZE_MB - WIN_SIZE_MB - SWAP_SIZE_MB))

ROOT_SIZE_MB=$((FREE_MB / 3))
HOME_SIZE_MB=$((FREE_MB - ROOT_SIZE_MB))

### ──────────────────────────────────────────────
# 2. Partition the disk
### ──────────────────────────────────────────────
echo "→ Creating partitions on $DISK..."
parted -s "$DISK" mklabel gpt

START=1

EFI_END=$((START + EFI_SIZE_MB))
parted -s "$DISK" mkpart ESP fat32 ${START}MiB ${EFI_END}MiB
parted -s "$DISK" set 1 esp on

if [[ "$DUALBOOT" == "y" ]]; then
  WIN_START=$EFI_END
  WIN_END=$((WIN_START + WIN_SIZE_MB))
  parted -s "$DISK" mkpart primary ntfs ${WIN_START}MiB ${WIN_END}MiB
  SWAP_START=$WIN_END
else
  SWAP_START=$EFI_END
fi

SWAP_END=$((SWAP_START + SWAP_SIZE_MB))
parted -s "$DISK" mkpart primary linux-swap ${SWAP_START}MiB ${SWAP_END}MiB

ROOT_START=$SWAP_END
ROOT_END=$((ROOT_START + ROOT_SIZE_MB))
parted -s "$DISK" mkpart primary ext4 ${ROOT_START}MiB ${ROOT_END}MiB

HOME_START=$ROOT_END
parted -s "$DISK" mkpart primary ext4 ${HOME_START}MiB 100%

### ──────────────────────────────────────────────
# 3. Format partitions and mount
### ──────────────────────────────────────────────
echo "→ Formatting filesystems..."
mkfs.fat -F32 "${DISK}p1"
[[ "$DUALBOOT" == "y" ]] && echo "→ Reserving Windows space (${WIN_SIZE_MB}MiB)"
mkswap "${DISK}p3" && swapon "${DISK}p3"
mkfs.ext4 "${DISK}p4"
mkfs.ext4 "${DISK}p5"

echo "→ Mounting..."
mount "${DISK}p4" /mnt
mkdir -p /mnt/{boot,home}
mount "${DISK}p1" /mnt/boot
mount "${DISK}p5" /mnt/home

### ──────────────────────────────────────────────
# 4. Install base system
### ──────────────────────────────────────────────
echo "→ Installing base system..."
pacstrap -K /mnt \
  base base-devel linux linux-firmware \
  sudo networkmanager git vim nano \
  nvidia nvidia-utils nvidia-dkms \
  plasma-meta sddm kde-applications-meta \
  steam lutris heroic-games-launcher gamemode \
  wine-staging winetricks protontricks --noconfirm

genfstab -U /mnt >> /mnt/etc/fstab

### ──────────────────────────────────────────────
# 5. Chroot configuration
### ──────────────────────────────────────────────
echo "→ Configuring system in chroot..."
arch-chroot /mnt /bin/bash <<EOF
set -e
echo "→ Setting timezone and locale"
ln -sf /usr/share/zoneinfo/Europe/Amsterdam /etc/localtime
hwclock --systohc
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "$HOSTNAME" > /etc/hostname
cat >> /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

echo "→ Creating user: $USERNAME"
useradd -m -G wheel,audio,video,storage,games -s /bin/bash $USERNAME
echo "$USERNAME:$PASS1" | chpasswd
echo "root:$PASS1" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

systemctl enable NetworkManager sddm

echo "→ Installing bootloader"
pacman -S --noconfirm grub efibootmgr os-prober ntfs-3g
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg
EOF

echo "Installation complete. You can now reboot!"
