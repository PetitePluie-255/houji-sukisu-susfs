#!/bin/bash
# Repack the built kernel into a flashable boot image and flash it.
#
# The two things this script exists to get right:
#   1. keep the stock AVB footer (make-stale-boot.py) -- a freshly generated
#      unsigned footer makes the bootloader fall back to fastboot;
#   2. `fastboot set_active` afterwards -- a slot that failed once is marked
#      unbootable and every later attempt then goes straight to fastboot.
#
# Usage:
#   STOCK_BOOT=/path/to/stock-boot.img KERNEL=out/arch/arm64/boot/Image ./flash-boot.sh
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

STOCK_BOOT=${STOCK_BOOT:?需要指定原厂 boot.img 的路径}
KERNEL=${KERNEL:-$PWD/out/arch/arm64/boot/Image}
OUT_IMG=${OUT_IMG:-$PWD/houji-sukisu-susfs-boot.img}
SLOT=${SLOT:-a}

echo "== repack (keep stock AVB footer) =="
python3 "$HERE/make-stale-boot.py" \
    --stock  "$STOCK_BOOT" \
    --kernel "$KERNEL" \
    --output "$OUT_IMG"
sha256sum "$OUT_IMG"

echo "== reboot to bootloader =="
adb reboot bootloader
sleep 10
fastboot devices
fastboot getvar current-slot 2>&1 | head -1

echo "== flash boot_$SLOT =="
fastboot flash "boot_$SLOT" "$OUT_IMG"

echo "== clear unbootable flag =="
fastboot set_active "$SLOT"

fastboot reboot
echo
echo "刷写完成。开机后请确认："
echo "  adb shell getprop sys.boot_completed     # 1"
echo "  adb shell su -c id                       # uid=0 context=u:r:ksu:s0"
echo "  adb shell su -c dmesg | grep -i 'susfs is initialized'"
