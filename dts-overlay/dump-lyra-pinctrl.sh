#!/bin/bash
# Run this ON the live Lyra Zero W board (over SSH/console) to dump the
# information needed to fill in lyra-zero-w-pi-spi0-lora.dts.template with
# real bank/pin/RMIO values. See dts-overlay/README.md for full context.
#
# Usage: ssh lyra@<lyra-ip> 'bash -s' < dump-lyra-pinctrl.sh > lyra-pinctrl-dump.txt

set -uo pipefail

echo "=== armbianEnv.txt ==="
cat /boot/armbianEnv.txt 2>/dev/null

echo
echo "=== Compiled DTB decompiled (pinctrl + spi0 nodes) ==="
if command -v dtc >/dev/null 2>&1; then
    dtc -I fs -O dts /proc/device-tree 2>/dev/null > /tmp/live-dt.dts
    echo "--- pinctrl-related nodes ---"
    grep -n -A 5 -i "pinctrl\|rmio\|spi0" /tmp/live-dt.dts | head -400
else
    echo "dtc not installed - install with: sudo apt-get install -y device-tree-compiler"
fi

echo
echo "=== gpioinfo (all gpiochips + line names) ==="
if command -v gpioinfo >/dev/null 2>&1; then
    gpioinfo
else
    echo "gpioinfo not installed - install with: sudo apt-get install -y gpiod"
fi

echo
echo "=== Existing /dev/spidev* nodes ==="
ls -la /dev/spidev* 2>&1

echo
echo "=== Header-relevant /sys/kernel/debug/pinctrl (if debugfs mounted) ==="
if [ -d /sys/kernel/debug/pinctrl ]; then
    for d in /sys/kernel/debug/pinctrl/*/; do
        echo "--- $d ---"
        sudo cat "${d}pinmux-pins" 2>/dev/null | head -100
    done
else
    echo "debugfs pinctrl not mounted - try: sudo mount -t debugfs none /sys/kernel/debug"
fi

echo
echo "=== Done. Send this output back for filling in the overlay template. ==="
