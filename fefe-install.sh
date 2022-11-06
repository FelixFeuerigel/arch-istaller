#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
#
# This script can be run by executing the following:
# ### curl -sL bit.ly/3Mm4iP8 | bash ###
#
# ## if you need to use WiFi use "iwctl" for setup  ##
#

### Custom Arch Repository ###
REPO_URL="https://felixfeuerigel.github.io/arch-pkgbuilds/x86_64/"
REPO_NAME="fefe-repo"


### Set up logging and error handling ###
set -uo pipefail
trap 's=$?; echo "$0: Error on line "$LINENO": $BASH_COMMAND"; exit $s' ERR

exec 1> >(tee "stdout.log")
exec 2> >(tee "stderr.log")

### basic pre-install setup ###
timedatectl set-ntp true
loadkeys de-latin1

pacman -Sy --noconfirm archlinux-keyring
pacman -S --noconfirm --needed reflector dialog


### Get infomation from user ###
get_user_info () {
    hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
    clear
    : ${hostname:?"hostname cannot be empty"}

    user=$(dialog --stdout --inputbox "Enter admin username" 0 0 "felix") || exit 1
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
}
get_user_info

### set up pacman ###
set_up_pacman () {
    echo "Searching for pacman mirrors"
    reflector -a 48 -f 20 -l 30 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

    sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf
    
    ## Add custom repo ##
cat >> /etc/pacman.conf << EOF

[$REPO_NAME]
SigLevel = Optional TrustAll
Server = $REPO_URL
EOF

    ## enable multilib repo ##
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf

    pacman -Sy
}
set_up_pacman

### make sure everything is unmounted before we start
if [ -n "$(ls -A /mnt)" ] # if folder is empty
  then
    umount -AR /mnt
fi


### Check boot mode ###
if [ -d /sys/firmware/efi/efivars ]
  then
    BOOT_MODE="EFI"
  else
    BOOT_MODE="BIOS"
fi

### Setup the disk and partitions for GPT/UEFI ###
if [ "$BOOT_MODE" == "EFI" ]
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


### Setup the disk and partitions for MBR/BIOS ###
if [ "$BOOT_MODE" == "BIOS" ]
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


##-------------------------------------------------##

##### Start of Config for New System #####
#### Install and configure the basic system ####
pacstrap /mnt fefe-base

genfstab -U /mnt >> /mnt/etc/fstab

### network setup ###
echo "${hostname}" > /mnt/etc/hostname

### calibrating the hardware clock timezone is set by the fefe-base package ###
arch-chroot /mnt hwclock --systohc


### determine processor type and install corresponding microcode
PROC_TYPE=$(lscpu)
if grep -E "GenuineIntel" <<< ${PROC_TYPE}; then
    echo "Installing Intel microcode"
    pacstrap /mnt intel-ucode
    PROC_UCODE="intel-ucode.img"
elif grep -E "AuthenticAMD" <<< ${PROC_TYPE}; then
    echo "Installing AMD microcode"
    pacstrap /mnt amd-ucode
    PROC_UCODE="amd-ucode.img"
fi


### installing the boot loader for GPT/UEFI ###
if [ "$BOOT_MODE" == "EFI" ]; then
arch-chroot /mnt bootctl --path=/boot install

# configure the boot manager
cat << EOF > /mnt/boot/loader/loader.conf
default @saved
timeout 0
EOF

# create arch boot entry
cat << EOF > /mnt/boot/loader/entries/arch.conf
title    Arch Linux
linux    /vmlinuz-linux
initrd   /$PROC_UCODE
initrd   /initramfs-linux.img
options  root=PARTUUID=$(blkid -s PARTUUID -o value "$part_root") rw
EOF

cat << EOF > /mnt/boot/loader/entries/arch-fallback.conf
title   Arch Linux (fallback initramfs)
linux   /vmlinuz-linux
initrd  /$PROC_UCODE
initrd  /initramfs-linux-fallback.img
options root=PARTUUID=$(blkid -s PARTUUID -o value "$part_root") rw
EOF

# create pacman hook for updating the boot manager
if [[ ! -d /mnt/etc/pacman.d/hooks ]]; then
    mkdir /mnt/etc/pacman.d/hooks
fi

cat << EOF > /mnt/etc/pacman.d/hooks/100-systemd-boot.hook
[Trigger]
Type = Package
Operation = Upgrade
Target = systemd

[Action]
Description = Gracefully upgrading systemd-boot...
When = PostTransaction
Exec = /usr/bin/systemctl restart systemd-boot-update.service
EOF

fi


### installing GRUB for BIOS/MBR systems ###
if [ "$BOOT_MODE" == "BIOS" ]; then
    pacstrap /mnt grub
    arch-chroot /mnt grub-install --target=i386-pc "${device}"
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
fi


### installting graphics drivers
gpu_type=$(lspci)
if grep -E "NVIDIA|GeForce" <<< ${gpu_type}; then
    pacstrap /mnt nvidia nvidia-xconfig nvidia-settings lib32-nvidia-utils
elif lspci | grep 'VGA' | grep -E "Radeon|AMD"; then
    pacstrap /mnt xf86-video-amdgpu lib32-mesa
elif grep -E "Integrated Graphics Controller" <<< ${gpu_type}; then
    pacstrap /mnt libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa
elif grep -E "Intel Corporation UHD" <<< ${gpu_type}; then
    pacstrap /mnt libva-intel-driver libvdpau-va-gl lib32-vulkan-intel vulkan-intel libva-intel-driver libva-utils lib32-mesa
elif grep -E "VMware SVGA II Adapter" <<< ${gpu_type}; then
    pacstrap /mnt xf86-video-vmware xf86-input-vmmouse virtualbox-guest-utils
fi


### adding the user ###
arch-chroot /mnt useradd -m --badname -G wheel "$user"

echo "$user:$password" | chpasswd --root /mnt
echo "root:$password" | chpasswd --root /mnt


echo "##########################"
echo "# installation finished! #"
echo "##########################"