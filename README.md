# Работа с mdadm

## Задание

- добавить в Vagrantfile еще дисков;
- сломать/починить raid;
- собрать R0/R5/R10 на выбор;
- прописать собранный рейд в конф, чтобы рейд собирался при загрузке;
- создать Vagrantfile, который сразу собирает систему с подключенным рейдом и смонтированными разделами. После перезагрузки стенда разделы должны автоматически примонтироваться;
- перенести работающую систему с одним диском на RAID 1.

## Реализация

Задание сделано без даунтайма для **generic/centos9s** благодяря тому, что система изначально установлена на **LVM**.

1. **Vagrant** с версии **v2.2.10** поддерживает автоматическое подключение дисков в **VirtualBox**. Данная возможность поддерживается без дополнительных настроек с версии **2.4.1** или при задании переменной **VAGRANT_EXPERIMENTAL='disks'** в более ранних версиях. Для простоты **Vagrantfile** был переписан с учётом этих возможностей.
2. **Vagrantfile** дополнительно создаёт **1** диск **128GB** под систему (в **RAID1**) и дополнительно подключает **12** дисков по **100MB** под **RAID10**.
3. После загрузки запускается скрипт **[provision.sh](https://github.com/abegorov/linux5/blob/main/provision.sh)**, который переносит систему на **RAID1** и создаёт **RAID10**.

Скрипт **[provision.sh](https://github.com/abegorov/linux5/blob/main/provision.sh)**:

1. Ставит **mdadm gdisk jq partclone**.
2. С помощью **lsblk** и **jq** находит системный диск, подходящее зеркало для него минимального размера, остальные диски, которые будут использоваться под **RAID10**.
3. На дисках под **RAID10** создаётся единственный **GPT** раздел по размеру наименьшего диска с типом **Linux RAID** и ему назначается **GPT PARTLABEL=md-raid-diskXX**, где **XX** - номер диска.
4. На разделах **md-raid-diskXX** создаётся массив **RAID10** с **Layout Far=3** (3 копии каждого блока данных на максимальном удалении друг от друга). Массив называется **/dev/md/raid** и добавляется в **/etc/mdadm.conf**.
5. На массиве **/dev/md/raid** создаётся таблица разделов **GPT** и 5 разделов одинаково размера. Они форматируются и монтируются (в том числе при загрузке) с помощью **systemd.mount**.
6. Под систему, на свободном диске создаётся массив **RAID1** с отсутствующим диском и параметром **metadata=1.0** (метаданные в конце диска) и добавляется в **/etc/mdadm.conf**.
7. В **initramfs** отсутствуют модули ядра, необходимые для загрузки с **RAID1**, поэтому они добавляются в файл **/etc/dracut.conf.d/raid1.conf**, после чего пересобирается **initramfs**.
8. Так как метаданные **RAID1** находятся в конце диска и ядро при загрузке не будет знать о наличии **RAID1** массива, то она не загрузится с **RAID1** (будет загрузка с одного из дисков, минуя драйвер **MD**), если в параметрах ядра явно не указать **UUID** загрузочного устройства (даже, если оно есть в **mdadm.conf**). Поэтому в файл **/etc/default/grub** добавляются параметры **rd.retry=18 rd.md.uuid**. Параметр **rd.retry** позволяет сократить время загрузки при отсутствии одного из дисков.
9. Таблица разделов с системного диска копируется на **RAID** массив, при этом перезсоздаётся последний раздел (так как доступное место могло уменьшиться из-за RAID).
10. Средствами **LVM** последний раздел на **RAID** добавляется в группу **centos9s**, после чего логический том **root** перемещается на него. Логический том **swap** пересоздаётся на новом диске и последний раздел бывшего системного диска выводится из группы **centos9s**.
11. Раздел **/boot** клонируется на **RAID1** с помощью **partclon.xfs** и перемонтируется.
12. Бывший системный диск добавляется в **RAID1** массив вместо отсутствующего и загрузчик **GRUB** переустанавливается на оба диска в массиве.

Результаты:

- [измененный Vagrantfile](https://github.com/abegorov/linux5/blob/main/Vagrantfile);
- [скрипт для создания рейда](https://github.com/abegorov/linux5/blob/main/provision.sh);
- конф для автосборки рейда при загрузке: [mdadm.conf](https://github.com/abegorov/linux5/blob/main/mdadm.conf), [dracut.conf](https://github.com/abegorov/linux5/blob/main/dracut.conf), [grub/default](https://github.com/abegorov/linux5/blob/main/default-grub);
- [вывод команды lsblk до решения](https://github.com/abegorov/linux5/blob/main/lsblk-before.txt);
- [вывод команды lsblk после решения](https://github.com/abegorov/linux5/blob/main/lsblk-after.txt).