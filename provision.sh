#!/bin/bash
set -e  # Exit immediately if a command exits with a non-zero status.
set -u  # Treat unset variables as an error when substituting.
set -v  # Print shell input lines as they are read.

sudo dnf install -y mdadm gdisk jq partclone

# при наличии нескольких дисков /dev/sda не обязательно системный диск...

# системный диск это блочное устройство, с типом disk в lsblk, на любом из
# разделов которого расположено устройство с точкой монтирования /
DISKS=$(lsblk --json --tree --bytes -o NAME,TYPE,SIZE,MOUNTPOINT \
  | jq -r '.blockdevices | sort_by(.size)[] | select(.type=="disk")')
SYS_DISK=$(echo "${DISKS}" \
  | jq -r 'select([recurse(.children[]?)] | any(.mountpoint=="/"))')
SYS_DISK_NAME=$(echo "${SYS_DISK}" | jq -r '.name')
SYS_DISK_SIZE=$(echo "${SYS_DISK}" | jq -r '.size')
SYS_DISK_KB=$(($SYS_DISK_SIZE / 1024 - 1024))

# несистемные диски:
NONSYS_DISKS=$(echo "${DISKS}" | jq -r 'select(.name!="'${SYS_DISK_NAME}'")')

# диск подходящий для зеркала это первый диск такого же (или большего)
# размера, как системный:
MIR_DISK=$(echo "${NONSYS_DISKS}" \
  | jq -sr 'map(select(.size>='${SYS_DISK_SIZE}')) | first')
MIR_DISK_NAME=$(echo "${MIR_DISK}" | jq -r '.name')

RAID_DISKS=$(echo "${NONSYS_DISKS}" \
  | jq -r 'select(.name!="'${MIR_DISK_NAME}'")')
RAID_DISKS_NAMES=$(echo "${RAID_DISKS}" | jq -r '.name')
RAID_DISKS_COUNT=$(echo "${RAID_DISKS_NAMES}" | wc -l)

# получаем размер диска массива (он будет минимальным из-за сортировки ранее)
RAID_DISK_SIZE=$(echo "${RAID_DISKS}" | jq -r '.size' | head -n 1)
RAID_DISK_MB=$(($RAID_DISK_SIZE / (1024*1024) - 1))

# создаём разделы под RAID массив:
DEVS=$(echo "${RAID_DISKS_NAMES}" | sed 's|^|/dev/|')

set -x  # Print commands and their arguments as they are executed.

for dev in ${DEVS}; do sudo sgdisk --clear "${dev}" & done
wait
for dev in ${DEVS}; do sudo sgdisk --new="0:0:${RAID_DISK_MB}M" ${dev} & done
wait
for dev in ${DEVS}; do sudo sgdisk --typecode=1:fd00 "${dev}" & done
wait
n=0;
for dev in ${DEVS}; do
  ((n=n+1))
  sudo sgdisk --change-name="1:md-raid-disk$(printf '%02d' ${n})" "${dev}" &
done
wait

# создаём RAID10 массив, layout far, 3 копии каждого блока данных
sudo mdadm --create "/dev/md/raid" \
  $(echo "${DEVS}" | sed 's|$|1|') \
  --level=10 \
  --raid-devices="${RAID_DISKS_COUNT}" \
  --spare-devices=0 \
  --layout=f3 \
  --bitmap=internal

sudo mdadm --verbose --detail --scan | grep ^ARRAY | sudo tee /etc/mdadm.conf

# создаём партиции:
sudo sgdisk --clear "/dev/md/raid"
for i in {1..5}; do
  sudo sgdisk --new="0:0:+$((
      (95*${RAID_DISK_MB}/100)*${RAID_DISKS_COUNT}/15
    ))M" "/dev/md/raid"
  sudo sgdisk --typecode="${i}:8300" "/dev/md/raid"
  sudo sgdisk --change-name="${i}:raid-part${i}" "/dev/md/raid"
done

# монтируем разделы через systemd.mount (ждём 5 секунд, чтобы они появились)
sleep 5
for i in {1..5}; do
  sudo mkfs.xfs "/dev/md/raid${i}"
  cat <<EOF | sudo tee "/etc/systemd/system/raid-${i}.mount"
[Unit]
Description=Mount /raid/${i}

[Mount]
What=/dev/md/raid${i}
Where=/raid/${i}
Type=xfs

[Install]
WantedBy=local-fs.target
EOF
  sudo mkdir -p "/raid/${i}"
  sudo systemctl enable "raid-${i}.mount"
  sudo systemctl start "raid-${i}.mount"
done

##############################################################################
# теперь приступаем к переносу системы на RAID
##############################################################################

# создаём RAID (metadata 1.0 в конце диска возможности загрузки с RAID)
sudo mdadm --create "/dev/md0" \
  "/dev/${MIR_DISK_NAME}" missing \
  --metadata="1.0" \
  --level=1 \
  --raid-devices=2 \
  --spare-devices=0 \
  --size=${SYS_DISK_KB} \
  --bitmap=internal
sudo mdadm --verbose --detail --scan | grep ^ARRAY | sudo tee /etc/mdadm.conf

# добавляем поддержку raid1 в загрузчик и initramfs
cat <<EOF | sudo tee "/etc/dracut.conf.d/raid1.conf"
add_dracutmodules+=" mdraid "
add_drivers+=" raid1 dm_mirror "
mdadmconf="yes"
EOF
UUID=$(sudo mdadm --detail /dev/md0 | grep UUID | awk '{print $3}')
sudo sed \
  "/GRUB_CMDLINE_LINUX=/ s/ rd[.]/ rd.retry=18 rd.md.uuid=${UUID} rd./" \
  -i "/etc/default/grub"
sudo grub2-mkconfig -o "/boot/grub2/grub.cfg"
sudo dracut --regenerate-all --force

# копируем таблицу разделов с системного диска на RAID
sudo dd if="/dev/${SYS_DISK_NAME}" of="/dev/md0" bs=512 count=1

# исправляем размер последнего раздела
sudo sfdisk --delete "/dev/md0" 2
echo ",,8e" | sudo sfdisk --append "/dev/md0"

# перемещаем систему на RAID
sudo lvmdevices --yes --deldev "/dev/${SYS_DISK_NAME}2"
sudo lvmdevices --yes --adddev "/dev/${SYS_DISK_NAME}2"
sudo pvcreate --yes "/dev/md0p2"
sudo vgextend --yes "centos9s" "/dev/md0p2"
sudo swapoff "/dev/mapper/centos9s-swap"
sudo lvremove --yes "centos9s/swap"
sudo pvmove --yes "/dev/${SYS_DISK_NAME}2"
sudo vgreduce --yes "centos9s" "/dev/${SYS_DISK_NAME}2"
sudo lvcreate --name "swap" --extents "100%FREE" "centos9s"
sudo mkswap "/dev/mapper/centos9s-swap"
sudo swapon "/dev/mapper/centos9s-swap"

# переносим /boot на RAID
sudo umount "/boot"
sudo partclone.xfs --force \
  --quiet \
  --dev-to-dev \
  --source "/dev/${SYS_DISK_NAME}1" \
  --output "/dev/md0p1"
sudo mount "/dev/md0p1" "/boot"

# добавляем системный диск в RAID массив
sudo mdadm --add "/dev/md0" "/dev/${SYS_DISK_NAME}"

# на всякий случай переустанавливаем GRUB на оба диска в RAID1
sudo grub2-install "/dev/${MIR_DISK_NAME}"
sudo grub2-install "/dev/${SYS_DISK_NAME}"
