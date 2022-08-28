#!/bin/bash
# WARNING: this script will destroy data on the selected disk.
#
# This script can be run by executing the following:
# ### curl -sL https://bit.ly/3aSie4S | bash ###
#
# ## if you need to use WiFi use "iwctl" for setup  ##
#

### Custom Arch Repository ###
REPO_URL="https://s3.eu-west-2.amazonaws.com/mdaffin-arch/repo/x86_64"


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
hostname=$(dialog --stdout --inputbox "Enter hostname" 0 0) || exit 1
clear
: ${hostname:?"hostname cannot be empty"}

desktop=$(dialog --stdout --no-items --checklist "Enter hostname" 0 0 0 "AwsomeWM" off "Openbox" off "KDE" off "Custom" off) || exit 1
clear

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

### set up pacman ###
echo "Searching for pacman mirrors"
reflector -a 48 -f 25 -l 30 -n 50 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf


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

### Add custom repo ###
# cat >> /etc/pacman.conf << EOF
# [mdaffin]
# SigLevel = Optional TrustAll
# Server = $REPO_URL
# EOF

### enable multilib repo ###
sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf

##-------------------------------------------------##

##### Start of Config for New System #####
#### Install and configure the basic system ####
pacstrap /mnt base base-devel linux linux-firmware sudo networkmanager alsa-ucm-conf sof-firmware alsa-ucm-conf

genfstab -U /mnt >> /mnt/etc/fstab

### Edit the pacman.conf ###
## add own repo
# cat >> /mnt/etc/pacman.conf << EOF
# [mdaffin]
# SigLevel = Optional TrustAll
# Server = $REPO_URL
# EOF

## enable multilib
sed -i "/\[multilib\]/,/Include/"'s/^#//' /mnt/etc/pacman.conf

## enable parallel downloads
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /mnt/etc/pacman.conf

## enable pacman colors
sed -i 's/^#Color/Color/' /mnt/etc/pacman.conf

### network setup ###
echo "${hostname}" > /mnt/etc/hostname

cat >> /mnt/etc/hosts << EOF
# The following lines are desirable for IPv4 capable hosts
127.0.0.1       localhost
127.0.1.1       $hostname
# The following lines are desirable for IPv6 capable hosts
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

arch-chroot /mnt systemctl enable NetworkManager


### seting the timezone and calibrating the hardware clock ###
arch-chroot /mnt ln -sf /usr/share/zoneinfo/Europe/Berlin /etc/localtime
arch-chroot /mnt hwclock --systohc


### generating & setting the locale ###
cat >> /mnt/etc/locale.gen << EOF
en_US.UTF-8 UTF-8
de_DE.UTF-8 UTF-8
de_DE ISO-8859-1
de_DE@euro ISO-8859-15
EOF
arch-chroot /mnt locale-gen

cat >> /mnt/etc/locale.conf << EOF
LANG=de_DE.UTF-8
LC_CTYPE="de_DE.UTF-8"
LC_NUMERIC="de_DE.UTF-8"
LC_TIME="de_DE.UTF-8"
LC_COLLATE="de_DE.UTF-8"
LC_MONETARY="de_DE.UTF-8"
LC_MESSAGES="de_DE.UTF-8"
LC_PAPER="de_DE.UTF-8"
LC_NAME="de_DE.UTF-8"
LC_ADDRESS="de_DE.UTF-8"
LC_TELEPHONE="de_DE.UTF-8"
LC_MEASUREMENT="de_DE.UTF-8"
LC_IDENTIFICATION="de_DE.UTF-8"
EOF
echo "KEYMAP=de-latin1" >> /mnt/etc/vconsole.conf


### determine processor type and install microcode
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
if [ "$BOOT_MODE" == "EFI" ]
then
arch-chroot /mnt bootctl --path=/boot install
#todo: add the missing pacman hook for automaticaly updating the bootloader
#todo: add fallback bootloader entry (initramfs-linux-fallback.img)
#todo: auto install an efi shell for x64 devices

cat << EOF > /mnt/boot/loader/loader.conf
default arch
EOF

cat << EOF > /mnt/boot/loader/entries/arch.conf
title    Arch Linux
linux    /vmlinuz-linux
initrd   /$PROC_UCODE
initrd   /initramfs-linux.img
options  root=PARTUUID=$(blkid -s PARTUUID -o value "$part_root") rw
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
    pacstrap /mnt nvidia nvidia-xconfig nvidia-utils lib32-nvidia-utils
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


## enableing sudo for the wheel group
sed -i "s/# %wheel ALL=(ALL:ALL) NOPASSWD: ALL/ %wheel ALL=(ALL:ALL) NOPASSWD: ALL/" /mnt/etc/sudoers


### Install Desktop
if [[ "$desktop" =~ "AwsomeWM" ]]; then ## missing programs for notifications
    pacstrap /mnt sddm awesome nitrogen dmenu rofi pcmanfm neovim nano gedit lxappearance xterm alacritty fish git firefox picom lxsession polkit \
    pipewire lib32-pipewire pipewire-alsa pipewire-pulse pipewire-jack lib32-pipewire-jack wireplumber \
    bluez bluez-utils blueman

    ## parts of the audio programs might not start automatically
    arch-chroot /mnt systemctl enable sddm.service
    arch-chroot /mnt systemctl enable bluetooth.service
fi

if [[ "$desktop" =~ "Openbox" ]]; then
    pacstrap /mnt sddm sddm-kcm openbox obconf git neovim alacritty fish nano
    arch-chroot /mnt systemctl enable sddm.service
fi

if [[ "$desktop" =~ "KDE" ]]; then
    pacstrap /mnt sddm sddm-kcm plasma-meta kde-applications-meta git nano
    arch-chroot /mnt systemctl enable sddm.service
fi

if [[ "$desktop" =~ "Custom" ]]; then
    pacstrap /mnt fefe-desktop
    
fi

arch-chroot /mnt localectl --no-convert set-x11-keymap de