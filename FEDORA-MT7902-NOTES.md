# Fedora MT7902 Notes

Hardware on this machine:
- PCI device: MediaTek MT7902, `14c3:7902`
- Subsystem: AzureWave `1a3b:6040`
- Kernel during original setup: `7.0.4-200.fc44.x86_64`
- Current temporary fix supports Wi-Fi and Bluetooth by rebuilding local modules for the running kernel.

Why this exists:
- Fedora's in-tree `mt7921e` / Bluetooth stack may not fully support this MT7902 device yet.
- Upstream linux-wireless has an MT7902 patch series from Sean Wang dated 2026-02-19.
- Until Fedora carries the needed support, this machine uses `OnlineLearningTutorials/mt7902_temp` as an out-of-tree backport.

Install or rebuild after every kernel update:

```bash
cd /home/ez/src/mt7902_temp
git pull --ff-only
sudo bash ./install-fedora-mt7902.sh
```

What the Fedora installer does:
- Selects the repo source tree matching the running kernel major/minor, e.g. `linux-7.0` for `7.0.x`.
- Builds Wi-Fi modules:
  - `mt76.ko`
  - `mt76-connac-lib.ko`
  - `mt792x-lib.ko`
  - `mt7921-common.ko`
  - `mt7921e.ko`
- Builds Bluetooth modules:
  - `btmtk.ko`
  - `btusb.ko`
- Installs MT7902 Wi-Fi/Bluetooth firmware into `/lib/firmware/mediatek`.
- Installs all custom modules into `/lib/modules/$(uname -r)/extra/mt7902`.
- Installs `/usr/local/sbin/mt7902-load` and enables `mt7902.service` so the custom modules are loaded on boot.
- Orders `bluetooth.service` after `mt7902.service` and queues Bluetooth restart without blocking, avoiding a systemd deadlock.

Verify Wi-Fi:

```bash
lspci -nnk -d 14c3:7902
nmcli device status
journalctl -u mt7902.service -b --no-pager
```

Verify Bluetooth:

```bash
bluetoothctl list
rfkill list bluetooth
lsmod | grep -E 'btusb|btmtk|bluetooth'
journalctl -u bluetooth -b --no-pager
```

Remove temporary custom setup once Fedora supports MT7902 in-tree:

```bash
sudo systemctl disable --now mt7902.service
sudo rm -f /etc/systemd/system/mt7902.service /usr/local/sbin/mt7902-load
sudo rm -rf /lib/modules/$(uname -r)/extra/mt7902
sudo depmod -a
```

Caveats:
- These are unsigned local modules. Secure Boot must stay disabled unless modules are signed/enrolled.
- Kernel updates require rebuilding modules for the new `uname -r`.
- The repo must contain a source tree for the running kernel major/minor, e.g. `linux-7.0` for `7.0.x`.
- If module loading fails, boot still works; Wi-Fi/Bluetooth may remain unavailable until rebuilt or disabled.
