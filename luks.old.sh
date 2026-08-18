# !/bin/bash
set -euo pipefail

ROOT_DEVICE="/dev/vda"
ROOT_PART="2"
BOOT_DEVICE="/dev/vda"
BOOT_PART="3"
ROOT_DEVPART="${ROOT_DEVICE}${ROOT_PART}"
BOOT_DEVPART="${BOOT_DEVICE}${BOOT_PART}"
PASSWORD="123"
DB_PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7+65BKcLJ32R7QiMNHjo3r1A/9l9FWD5MtpG0qjdKB"
DB_PORT="45055"

umount "$ROOT_DEVPART" 2>/dev/null || true

setup-apkrepos -1
setup-apkrepos -r
apk update
apk add cryptsetup e2fsprogs-extra lsblk parted udev

e2fsck -fy "$ROOT_DEVPART"

RESERVE_GRUB_MB=512
RESERVE_LUKS_MB=8
RESERVE_TOTAL=$((RESERVE_GRUB_MB + RESERVE_LUKS_MB))

BLOCKS=$(dumpe2fs -h "$ROOT_DEVPART" 2>/dev/null | awk -F': ' '/Block count/ {print $2}')
BLOCK_SIZE=$(dumpe2fs -h "$ROOT_DEVPART" 2>/dev/null | awk -F': ' '/Block size/ {print $2}')
REMOVE=$((RESERVE_TOTAL * 1024 * 1024 / BLOCK_SIZE))
NEW_BLOCKS=$((BLOCKS - REMOVE))

resize2fs "$ROOT_DEVPART" $NEW_BLOCKS

SECTOR_END=$(parted -s "$ROOT_DEVICE" unit MiB print | awk -v p="$ROOT_PART" '$1==p {gsub(/MiB$/,"",$3); print $3}')
echo yes | parted "$ROOT_DEVICE" ---pretend-input-tty resizepart "$ROOT_PART" $((SECTOR_END-RESERVE_GRUB_MB))MiB
partprobe "$ROOT_DEVICE"
udevadm settle

parted -s "$ROOT_DEVICE" mkpart primary ext4 $((SECTOR_END-RESERVE_GRUB_MB))MiB 100%
partprobe "$ROOT_DEVICE"
udevadm settle

cryptsetup reencrypt \
	--encrypt \
	--type luks2 \
	--reduce-device-size "${RESERVE_LUKS_MB}M" \
	--batch-mode \
	--verbose \
	--progress-frequency 5 \
	--key-file <(echo -n "$PASSWORD") \
	"$ROOT_DEVPART"
cryptsetup open --key-file <(echo -n "$PASSWORD") "$ROOT_DEVPART" cryptroot
e2fsck -fy /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt

mkdir /mnt/boot.old
cp -a /mnt/boot/. /mnt/boot.old/
mkfs.ext4 -F "$BOOT_DEVPART"
mount "$BOOT_DEVPART" /mnt/boot

cp -a /mnt/boot.old/. /mnt/boot/


mount --bind /dev /mnt/dev
mount --bind /proc /mnt/proc
mount --bind /sys /mnt/sys

chroot /mnt /bin/bash
apt update
apt install -yq --reinstall grub-pc grub-common cryptsetup-initramfs dropbear-initramfs

# echo "GRUB_PRELOAD_MODULES=\"part_gpt part_msdos cryptodisk luks2\"" >> /etc/default/grub
# echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub

# echo "GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=$ROOT_UUID:cryptroot root=/dev/mapper/cryptroot\"" >> /etc/default/grub

echo "cryptroot UUID=$ROOT_UUID none luks" > /etc/crypttab

sed -i '\| / |d' /etc/fstab
echo "UUID=$BOOT_UUID /boot ext4 defaults 0 2" >> /etc/fstab
echo "/dev/mapper/cryptroot / ext4 defaults 0 1" >> /etc/fstab
# echo "UUID=$ROOT_UUID / ext4 defaults 0 1" >> /etc/fstab

echo "$DB_PUB_KEY" >> /etc/dropbear/initramfs/authorized_keys
chmod 600 /etc/dropbear/initramfs/authorized_keys
echo "DROPBEAR_OPTIONS=\"-I 60 -j -k -p $DB_PORT -s -c cryptroot-unlock\"" >> /etc/dropbear/initramfs/dropbear.conf
echo "IP=94.103.3.109::94.103.3.1:255.255.255.0::ens3:none:1.1.1.1:8.8.8.8" >> /etc/initramfs-tools/initramfs.conf
# echo "IP=:::::eth0:dhcp" >> /etc/initramfs-tools/initramfs.conf
update-initramfs -u -k all
update-grub
grub-install --recheck $BOOT_DEVICE

exit

umount /mnt/boot 2>/dev/null
umount /mnt/dev 2>/dev/null
umount /mnt/proc 2>/dev/null
umount /mnt/sys 2>/dev/null
umount /mnt
cryptsetup close cryptroot













# 	-- pbkdf pbkdf2 \

# MIN=$(resize2fs -P "$DEVPART" 2>/dev/null | awk -F': ' '{print $2}')





# reboot

# e2fsck -f "$DEVPART"

# START_SECTOR=$(fdisk -l /dev/vda | awk '$1 == 2 {print $2}')
# END_SECTOR=$(fdisk -l /dev/vda | awk '$1 == 2 {print $3}')
# SECTOR_SIZE=$(fdisk -l /dev/vda | awk -F': ' '/Logical sector size/ {print $2}')
# FS_BYTES=$((NEW_BLOCKS * BLOCK_SIZE))
# FS_SECTORS=$((FS_BYTES / SECTOR_SIZE))
# NEW_END_SECTOR=$((START_SECTOR + FS_SECTORS - 1))
# NEW_END_SECTOR=$((NEW_END_SECTOR + 2048))

# fdisk /dev/vda <<EOF
# d
# 2
# n
# 2
# $START_SECTOR
# $NEW_END_SECTOR
# w
# EOF

# grub-install $DEVICE
# update-grub

# exit
# sudo umount -R /mnt
# sudo cryptsetup close cryptroot

# lsblk -f
# mkdir -p /mnt/boot/efi
# mount "$BOOT" /mnt/boot/efi

# mount --bind /dev/pts /mnt/dev/pts
# mount --bind /run /mnt/run


# chroot /mnt /bin/bash <<CH_EOF
# apt update
# apt install -y cryptsetup-initramfs dropbear-initramfs

# cat > /etc/crypttab <<EOF
# cryptroot UUID=$UUID none luks
# EOF

# update-initramfs -u -k all
# update-grub
# CH_EOF




# /usr/bin/luks-if