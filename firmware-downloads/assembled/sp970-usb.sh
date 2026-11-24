#!/bin/sh
set -eu
mountpoint -q /sys/kernel/config || mount -t configfs configfs /sys/kernel/config
G=/sys/kernel/config/usb_gadget/sp970
[ -d "$G" ] && exit 0
mkdir -p "$G"
echo 0x1d6b > "$G/idVendor"
echo 0x0104 > "$G/idProduct"
mkdir -p "$G/strings/0x409"
echo SP970V9Debian12 > "$G/strings/0x409/serialnumber"
echo OpenStick > "$G/strings/0x409/manufacturer"
echo 'SP970 Debian 12' > "$G/strings/0x409/product"
mkdir -p "$G/configs/c.1" "$G/functions/ncm.usb0"
echo 250 > "$G/configs/c.1/MaxPower"
echo 02:53:50:97:00:01 > "$G/functions/ncm.usb0/dev_addr"
echo 02:53:50:97:00:02 > "$G/functions/ncm.usb0/host_addr"
ln -s "$G/functions/ncm.usb0" "$G/configs/c.1/ncm.usb0"
for attempt in $(seq 1 30); do
 for controller in /sys/class/udc/*; do
  [ -e "$controller" ] || continue
  basename "$controller" > "$G/UDC"
  exit 0
 done
 sleep 1
done
exit 1
