#!/usr/bin/env bash
set -euo pipefail

KERNEL_VER="$(uname -r)"
IFS=. read -r KERNEL_MAJ KERNEL_MIN _ <<<"$KERNEL_VER"
KERNEL_MM="$KERNEL_MAJ.$KERNEL_MIN"

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_SRC_DIR="$SRC_DIR/linux-$KERNEL_MM"
WIFI_DIR="$KERNEL_SRC_DIR/drivers/net/wireless/mediatek/mt76"
BT_DIR="$KERNEL_SRC_DIR/drivers/bluetooth"
FW_DIR="$SRC_DIR/firmware"
MODULE_DIR="/lib/modules/$KERNEL_VER/extra/mt7902"
LOADER="/usr/local/sbin/mt7902-load"
SERVICE="/etc/systemd/system/mt7902.service"

if [[ $EUID -ne 0 ]]; then
  printf 'Run as root: sudo bash %s\n' "$0" >&2
  exit 1
fi

if [[ ! -d "/lib/modules/$KERNEL_VER/build" ]]; then
  printf 'Missing kernel build tree: /lib/modules/%s/build\n' "$KERNEL_VER" >&2
  printf 'Install it first, e.g.: sudo dnf install kernel-devel-%s\n' "$KERNEL_VER" >&2
  exit 1
fi

for dir in "$WIFI_DIR" "$BT_DIR"; do
  if [[ ! -f "$dir/Makefile" ]]; then
    printf 'Missing source Makefile: %s/Makefile\n' "$dir" >&2
    printf 'This repo has no linux-%s source tree for the running kernel %s.\n' "$KERNEL_MM" "$KERNEL_VER" >&2
    exit 1
  fi
done

printf 'Building MT7902 Wi-Fi modules for %s from %s\n' "$KERNEL_VER" "$WIFI_DIR"
make -C "$WIFI_DIR" clean
make -C "$WIFI_DIR" module_compile

printf 'Building MT7902 Bluetooth modules for %s from %s\n' "$KERNEL_VER" "$BT_DIR"
make -C "$BT_DIR" clean
make -C "$BT_DIR" module_compile

wifi_modules=(
  "$WIFI_DIR/mt76.ko"
  "$WIFI_DIR/mt76-connac-lib.ko"
  "$WIFI_DIR/mt792x-lib.ko"
  "$WIFI_DIR/mt7921/mt7921-common.ko"
  "$WIFI_DIR/mt7921/mt7921e.ko"
)

bt_modules=(
  "$BT_DIR/btmtk.ko"
  "$BT_DIR/btusb.ko"
)

printf 'Verifying built modules\n'
for module in "${wifi_modules[@]}" "${bt_modules[@]}"; do
  if [[ ! -f "$module" ]]; then
    printf 'Expected module was not built: %s\n' "$module" >&2
    exit 1
  fi
  vermagic="$(modinfo -F vermagic "$module" 2>/dev/null || true)"
  if [[ "$vermagic" != "$KERNEL_VER "* ]]; then
    printf 'Bad vermagic for %s\n  got: %s\n  want: %s\n' "$module" "$vermagic" "$KERNEL_VER" >&2
    exit 1
  fi
done

printf 'Installing firmware to /lib/firmware/mediatek\n'
install -d -m 0755 /lib/firmware/mediatek
install -m 0644 \
  "$FW_DIR/WIFI_MT7902_patch_mcu_1_1_hdr.bin.zst" \
  "$FW_DIR/WIFI_RAM_CODE_MT7902_1.bin.zst" \
  "$FW_DIR/BT_RAM_CODE_MT7902_1_1_hdr.bin.zst" \
  /lib/firmware/mediatek/

printf 'Installing modules to %s\n' "$MODULE_DIR"
install -d -m 0755 "$MODULE_DIR"
install -m 0644 "${wifi_modules[@]}" "${bt_modules[@]}" "$MODULE_DIR/"

printf 'Writing loader %s\n' "$LOADER"
cat > "$LOADER" <<'EOF_LOADER'
#!/usr/bin/env bash
set -euo pipefail

KERNEL_VER="$(uname -r)"
MODULE_DIR="/lib/modules/$KERNEL_VER/extra/mt7902"
required_modules=(
  mt76.ko
  mt76-connac-lib.ko
  mt792x-lib.ko
  mt7921-common.ko
  mt7921e.ko
  btmtk.ko
  btusb.ko
)

for module in "${required_modules[@]}"; do
  if [[ ! -f "$MODULE_DIR/$module" ]]; then
    printf 'MT7902 module missing for kernel %s: %s/%s\n' "$KERNEL_VER" "$MODULE_DIR" "$module" >&2
    exit 1
  fi
done

bluetooth_was_active=0
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet bluetooth.service; then
  bluetooth_was_active=1
  systemctl stop bluetooth.service 2>/dev/null || true
fi

# Unload stock/conflicting MediaTek Wi-Fi/Bluetooth modules if present.
rmmod btusb btmtk mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76 2>/dev/null || true

# Wi-Fi stack.
modprobe cfg80211
modprobe mac80211
insmod "$MODULE_DIR/mt76.ko"
insmod "$MODULE_DIR/mt76-connac-lib.ko"
insmod "$MODULE_DIR/mt792x-lib.ko"
insmod "$MODULE_DIR/mt7921-common.ko"
insmod "$MODULE_DIR/mt7921e.ko"

# Bluetooth stack. Do not modprobe btmtk/btusb here; load the custom copies.
modprobe bluetooth
modprobe btrtl
modprobe btintel
modprobe btbcm
insmod "$MODULE_DIR/btmtk.ko"
insmod "$MODULE_DIR/btusb.ko"

# Queue bluetooth.service after this oneshot exits. Do not wait here: mt7902.service
# is ordered Before=bluetooth.service, so a blocking start from inside this service deadlocks.
if command -v systemctl >/dev/null 2>&1; then
  systemctl --no-block start bluetooth.service 2>/dev/null || true
fi
EOF_LOADER
chmod 0755 "$LOADER"

printf 'Writing systemd service %s\n' "$SERVICE"
cat > "$SERVICE" <<'EOF_SERVICE'
[Unit]
Description=Load custom MediaTek MT7902 Wi-Fi and Bluetooth drivers
After=systemd-modules-load.service
Before=network-pre.target bluetooth.service
Wants=network-pre.target bluetooth.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mt7902-load
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

depmod -a "$KERNEL_VER"
systemctl daemon-reload
systemctl enable mt7902.service

printf 'Loading MT7902 Wi-Fi and Bluetooth modules now\n'
systemctl restart mt7902.service

printf 'Done. Check with:\n'
printf '  lspci -nnk -d 14c3:7902\n'
printf '  nmcli device status\n'
printf '  bluetoothctl list\n'
printf '  journalctl -u mt7902.service -b --no-pager\n'
