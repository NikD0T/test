luks.sh:
1. Определение дисков
2. Определение сетивых интерфейсов
3. Разметка дисков
4. Монтирование системы
5. Опеделение версии системы
6. Добавление скрипта обновления initramfs
7. Определение сетевых интерфейсов в системе






ROOT_DEVICE="/dev/vda"
ROOT_PART="2"
BOOT_DEVICE="/dev/vda"
BOOT_PART="3"
ROOT_DEVPART="${ROOT_DEVICE}${ROOT_PART}"
BOOT_DEVPART="${BOOT_DEVICE}${BOOT_PART}"
PASSWORD="123"
DB_PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIP7+65BKcLJ32R7QiMNHjo3r1A/9l9FWD5MtpG0qjdKB"
DB_PORT="45055"


1. Включение rescue-режима или монтирование iso
2. Загрузка в systemrescue

## alpine:
1. Проверка доступка к интернету
   1. Если нет:
   ```bash
    sudo ifconfig eth0 192.168.1.100 netmask 255.255.255.0 up
    sudo route add default gw 192.168.1.1
    ip route add default via 192.168.1.254
    echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf
   ```
2. setup-apkrepos -r
3. setup-apkrepos -1
4. apk update
5. apk add cryptsetup lsblk e2fsprogs-extra
6. lsblk cat /proc/partitions
   1. /boot
   2. /
7.  e2fsck -f /dev/sda2
8.  BLOCK_SIZE=$(dumpe2fs -h /dev/sda2 2>/dev/null | awk -F': ' '/Block size/ {print $2}')
9.  BLOCKS=$(dumpe2fs -h /dev/sda2 2>/dev/null | awk -F': ' '/Block count/ {print $2}')
10. NEW_BLOCKS=$(( BLOCKS - 32*1024*1024 / BLOCK_SIZE ))
11. resize2fs /dev/uda2 $NEW_BLOCKS
12. cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size 32M /dev/sdXN
13. cryptsetup open /dev/sdXN root
14. mount /dev/mapper/root /mnt и /boot

IP=<client-ip>::<gateway>:<netmask>:<hostname>:<device>:<autoconf>



curl -fsSL https://lnk.nkfd.net/jge7ez | sh
wget -qO- https://lnk.nkfd.net/jge7ez | sh










1.  cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size 32M /dev/sda2
2.  yes | pswd
3.  cryptsetup open /dev/sda2 root
4.  mount /dev/mapper/root /mnt
5.  mount /dev/sda1 /mnt/boot
6.  chroot /mnt /bin/bash
7.  apt update && apt install dropbear-initramfs
8.  /etc/initramfs-tools/initramfs.conf
9.  /etc/dropbear/initramfs/authorized_keys
10. update-initramfs -u -k all
11. Настройте загрузчик GRUB, добавив параметр cryptdevice=....
12. Выйдите из chroot (exit) и перезагрузите сервер (reboot).








23. Проверка на наличие юзера 1001
   1. Если нет, создать:
      1. adduser -u 1001 -D -g 50 -s /bin/sh -G 50 -h /home/tc -g "Linux User,,," tc
24. Установка cryptsetup:  
   1. chmod 1777 /tmp
   2. tce-setup
   3. su tc
   4. tce-load -wi cryptsetup popt
25. exit (обратно в рута)