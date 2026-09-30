#!/bin/bash
# Restore stock partitions. Run this whenever the device ends up in fastboot.
#
# Usage:
#   STOCK_BOOT=/path/to/boot.img ./rollback.sh
#   # 如果之前动过 vbmeta：
#   STOCK_BOOT=... STOCK_VBMETA=... STOCK_VBMETA_SYSTEM=... ./rollback.sh
set -euo pipefail

STOCK_BOOT=${STOCK_BOOT:?需要指定原厂 boot.img}
STOCK_INIT_BOOT=${STOCK_INIT_BOOT:-}
STOCK_VBMETA=${STOCK_VBMETA:-}
STOCK_VBMETA_SYSTEM=${STOCK_VBMETA_SYSTEM:-}
SLOT=${SLOT:-a}

echo "== reboot to bootloader =="
if adb devices 2>/dev/null | grep -q "device$"; then
  adb reboot bootloader
else
  echo "（假设已在 bootloader）"
fi
sleep 10
fastboot devices

echo "== flash stock boot_$SLOT =="
fastboot flash "boot_$SLOT" "$STOCK_BOOT"

if [ -n "$STOCK_INIT_BOOT" ]; then
  echo "== flash stock init_boot_$SLOT =="
  fastboot flash "init_boot_$SLOT" "$STOCK_INIT_BOOT"
fi

if [ -n "$STOCK_VBMETA" ]; then
  echo "== flash stock vbmeta =="
  fastboot flash vbmeta "$STOCK_VBMETA"
fi

if [ -n "$STOCK_VBMETA_SYSTEM" ]; then
  echo "== flash stock vbmeta_system =="
  fastboot flash vbmeta_system "$STOCK_VBMETA_SYSTEM"
fi

echo "== clear unbootable flag and reboot =="
fastboot set_active "$SLOT"
fastboot reboot
echo ROLLBACK_DONE
