#!/bin/bash
# The Zero as the T420 sees it: ONE USB device with a disk (the desk's boot disk, its log and its
# command channel), a boot keyboard (/dev/hidg0), a boot mouse with a wheel (/dev/hidg1) and a
# serial port.  usb-gadget.service runs this at boot.  Re-running it disconnects the disk from
# the T420 for a moment: a running desk loses its disk until it restarts.
#   setup-gadget.sh [DISK-IMAGE]   the disk: DISK-IMAGE, else the one served now, else modus.img
set -ex
G=/sys/kernel/config/usb_gadget/modus
LUN=${1:-$(cat $G/functions/mass_storage.0/lun.0/file 2>/dev/null || true)}
LUN=${LUN:-/home/modus/modus.img}

# Clean up
if [ -d $G ]; then
    echo "" > $G/UDC 2>/dev/null || true
    for f in mass_storage.0 hid.0 hid.1 acm.0; do rm -f $G/configs/c.1/$f; done
    rmdir $G/configs/c.1/strings/0x409 2>/dev/null || true
    rmdir $G/configs/c.1 2>/dev/null || true
    for f in mass_storage.0 hid.0 hid.1 acm.0; do rmdir $G/functions/$f 2>/dev/null || true; done
    rmdir $G/strings/0x409 2>/dev/null || true
    rmdir $G 2>/dev/null || true
fi

modprobe libcomposite

mkdir $G && cd $G

echo 0x1d6b > idVendor
echo 0x0104 > idProduct
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
echo "modus-001" > strings/0x409/serialnumber
echo "Modus" > strings/0x409/manufacturer
echo "ModusDev" > strings/0x409/product

# Mass storage function
mkdir -p functions/mass_storage.0
echo 1 > functions/mass_storage.0/stall
echo 1 > functions/mass_storage.0/lun.0/removable
echo "$LUN" > functions/mass_storage.0/lun.0/file

# HID keyboard function (boot protocol, 8-byte reports): /dev/hidg0
mkdir -p functions/hid.0
echo 1 > functions/hid.0/protocol
echo 1 > functions/hid.0/subclass
echo 8 > functions/hid.0/report_length
printf '\x05\x01\x09\x06\xa1\x01\x05\x07\x19\xe0\x29\xe7\x15\x00\x25\x01\x75\x01\x95\x08\x81\x02\x95\x01\x75\x08\x81\x01\x95\x06\x75\x08\x15\x00\x25\x65\x05\x07\x19\x00\x29\x65\x81\x00\xc0' > functions/hid.0/report_desc

# HID mouse function (boot protocol: buttons, dx, dy; then a wheel byte): /dev/hidg1
mkdir -p functions/hid.1
echo 2 > functions/hid.1/protocol
echo 1 > functions/hid.1/subclass
echo 4 > functions/hid.1/report_length
echo 1 > functions/hid.1/no_out_endpoint
printf '\x05\x01\x09\x02\xa1\x01\x09\x01\xa1\x00\x05\x09\x19\x01\x29\x03\x15\x00\x25\x01\x95\x03\x75\x01\x81\x02\x95\x01\x75\x05\x81\x01\x05\x01\x09\x30\x09\x31\x09\x38\x15\x81\x25\x7f\x75\x08\x95\x03\x81\x06\xc0\xc0' > functions/hid.1/report_desc

# Config
mkdir -p configs/c.1/strings/0x409
echo "Config1" > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower
ln -sf functions/mass_storage.0 configs/c.1/
ln -sf functions/hid.0 configs/c.1/
ln -sf functions/hid.1 configs/c.1/

# CDC ACM serial
mkdir -p functions/acm.0
ln -sf functions/acm.0 configs/c.1/

# Activate
echo "3f980000.usb" > UDC

echo "=== Gadget active ==="
echo "State: $(cat /sys/class/udc/3f980000.usb/state)"
echo "Disk: $(cat functions/mass_storage.0/lun.0/file)"
ls -la /dev/hidg0 /dev/hidg1
