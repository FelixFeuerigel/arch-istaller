#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
# This script can be run by executing the following:
### curl -sL https://tinyurl.com/24tht5j5 | bash ###
## if you need to use WiFi use "iwctl" for setup

set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

# REPO_URL="https://s3.eu-west-2.amazonaws.com/mdaffin-arch/repo/x86_64"

pacman -Sy dialog --noconfirm

### Get infomation from user ###
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

user=$(dialog --stdout --inputbox "Enter admin username" 0 0 "felix_feuerigel") || exit 1
clear
: ${user:?"user cannot be empty"}

password=$(dialog --stdout --insecure --passwordbox "Enter admin password" 0 0) || exit 1
clear
: ${password:?"password cannot be empty"}
password2=$(dialog --stdout --insecure --passwordbox "Enter admin password again" 0 0) || exit 1
clear
[[ "$password" == "$password2" ]] || ( echo "Passwords did not match"; exit 1; )

devicelist=$(lsblk -dplnx size -o name,size | grep -Ev "boot|rpmb|loop" | tac)
device=$(dialog --stdout --menu "Select installtion disk" 0 0 0 ${devicelist}) || exit 1
clear

### Check boot mode
if [ -d /sys/firmware/efi/efivars ]
  then
    boot_mode="EFI"
  else
    boot_mode="BIOS"
fi

### Set up logging ###
exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")


timedatectl set-ntp true

### Setup the disk and partitions for GPT/UEFI###
if [ "$boot_mode" == "EFI" ]
  then
    swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
    swap_end=$(( $swap_size + 300 + 1 ))MiB

    parted --script "${device}" -- mklabel gpt \
      mkpart ESP fat32 1Mib 300MiB \
      set 1 boot on \
      mkpart primary linux-swap 300MiB ${swap_end} \
      mkpart primary ext4 ${swap_end} 100%

    # Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
    # but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
    part_boot="$(ls ${device}* | grep -E "^${device}p?1$")"
    part_swap="$(ls ${device}* | grep -E "^${device}p?2$")"
    part_root="$(ls ${device}* | grep -E "^${device}p?3$")"

    wipefs "${part_boot}"
    wipefs "${part_swap}"
    wipefs "${part_root}"

    mkfs.fat -F 32 "${part_boot}"
    mkswap "${part_swap}"
    mkfs.ext4 "${part_root}"

    swapon "${part_swap}"
    mount "${part_root}" /mnt
    mount --mkdir "${part_boot}" /mnt/boot
fi

### Setup the disk and partitions for MBR/BIOS###
if [ "$boot_mode" == "BIOS" ]
  then
    swap_size=$(free --mebi | awk '/Mem:/ {print $2}')
    swap_end=$(( $swap_size + 1 ))MiB

    parted --script "${device}" -- mklabel msdos \
      mkpart primary linux-swap 1MiB ${swap_end} \
      mkpart primary ext4 ${swap_end} 100% \
      set 2 boot on

    # Simple globbing was not enough as on one device I needed to match /dev/mmcblk0p1 
    # but not /dev/mmcblk0boot1 while being able to match /dev/sda1 on other devices.
    part_swap="$(ls ${device}* | grep -E "^${device}p?1$")"
    part_root="$(ls ${device}* | grep -E "^${device}p?2$")"

    wipefs "${part_swap}"
    wipefs "${part_root}"

    mkswap "${part_swap}"
    mkfs.ext4 "${part_root}"

    swapon "${part_swap}"
    mount "${part_root}" /mnt
fi

### Install and configure the basic system ###
# cat >>/etc/pacman.conf <<EOF
# [mdaffin]
# SigLevel = Optional TrustAll
# Server = $REPO_URL
# EOF

# pacstrap /mnt mdaffin-desktop
pacstrap /mnt base base-devel linux linux-firmware intel-ucode nano sudo networkmanager git
genfstab -U /mnt >> /mnt/etc/fstab


echo "${hostname}" > /mnt/etc/hostname


# cat >>/mnt/etc/pacman.conf <<EOF
# [mdaffin]
# SigLevel = Optional TrustAll
# Server = $REPO_URL
# EOF


# Setzen der Zeitzone & Kalibrieren der Hardware-Uhr
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime && hwclock --systohc


# generating & setting the locale
cat >>/mnt/etc/locale.gen <<EOF
en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
EOF

arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" >> /mnt/etc/locale.conf
echo "KEYMAP=de-latin1" >> /mnt/etc/vconsole.conf

### installing the boot loader for GPT/UEFI ###
if [ "$boot_mode" == "EFI" ]
then
arch-chroot /mnt bootctl --path=/boot install

cat <<EOF > /mnt/boot/loader/loader.conf
default arch
EOF

cat <<EOF > /mnt/boot/loader/entries/arch.conf
title    Arch Linux
linux    /vmlinuz-linux
initrd   /intel-ucode.img
initrd   /initramfs-linux.img
options  root=PARTUUID=$(blkid -s PARTUUID -o value "$part_root") rw
EOF
fi

if [ "$boot_mode" == "BIOS" ]
  then
    pacstrap /mnt grub
    arch-chroot /mnt grub-install --target=i386-pc "${device}"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi

### adding the user ###
arch-chroot /mnt useradd -mG wheel "$user"

echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt

## enableing sudo for the wheel group
sed -i "s/# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/ %wheel ALL=(ALL:ALL) NOPASSWD: ALL" /mnt/etc/sudoers
