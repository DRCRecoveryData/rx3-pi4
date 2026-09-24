#!/bin/bash
# rx3-pi4-install.sh
# XDJ-RX3 firmware emulation on Raspberry Pi 4 + 5" Waveshare DSI (800x480).
# Border/controls always visible (no hide/swipe overlay).
#
# Installs, patches, enables rx3.service, and reboots automatically.
# After reboot, rx3 starts on its own and the RX3 UI appears on the DSI panel.
#
# Run as your normal user (NOT root):
#   cd ~/rx3-pi4
#   chmod +x rx3-pi4-install.sh
#   bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log

set -euo pipefail

REPO="https://github.com/mutlisensor/Rx3-flx4.git"
W="$HOME/Rx3-flx4"
H="$W/rx3-handoff"
R="$HOME/rx3-rootfs"
ROT=0
USB_QUIRK="usb-storage.quirks=174c:2362:u"
CMDLINE_ADD="$USB_QUIRK vt.global_cursor_default=0 consoleblank=0"
AUTO_REBOOT="${AUTO_REBOOT:-1}"     # 1 = reboot at end, 0 = don't
REBOOT_DELAY=10                      # seconds to wait before reboot

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. sanity ---------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "Do not run as root — the installer calls sudo itself."
[ -n "${HOME:-}" ] && [ -d "$HOME" ] || die "HOME unset."
command -v apt >/dev/null || die "Debian / Raspberry Pi OS required."

say "Pi 4 RX3 installer"
echo "    Host: $(uname -srm)"
echo "    User: $(id -un) (uid $(id -u))"
echo "    Home: $HOME"
echo "    fb:   $(cat /sys/class/graphics/fb0/name 2>/dev/null) $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"
echo "    Auto-reboot: $AUTO_REBOOT (set AUTO_REBOOT=0 to skip)"

# Ask for sudo up front so the rest runs unattended
say "Requesting sudo (needed for kernel config, packages, systemd)"
sudo -v || die "sudo failed"

# --- 1. kernel cmdline -------------------------------------------------------
say "Patching /boot/firmware/cmdline.txt"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
[ -f "$CMDLINE" ] || die "cmdline.txt not found"

if ! grep -q "$USB_QUIRK" "$CMDLINE"; then
    sudo cp "$CMDLINE" "$CMDLINE.bak.$(date +%s)"
    sudo sed -i "s|\$| $CMDLINE_ADD|" "$CMDLINE"
    echo "    added: $CMDLINE_ADD"
else
    echo "    already present"
fi
echo "    current: $(cat "$CMDLINE")"

# --- 2. packages -------------------------------------------------------------
say "Installing build dependencies"
sudo apt update
sudo apt install -y \
    git build-essential gcc gcc-arm-linux-gnueabi \
    libfreetype6-dev pkg-config fonts-dejavu-core \
    fuse-overlayfs exfatprogs alsa-utils uhubctl gpiod \
    python3 python3-pil python3-cryptography rsync p7zip-full \
    evtest curl

# --- 3. clone or update ------------------------------------------------------
say "Cloning / updating repo"
if [ -d "$W/.git" ]; then
    git -C "$W" fetch --all --prune || warn "fetch failed; using local copy"
else
    git clone "$REPO" "$W"
fi
cd "$H"
chmod +x *.sh

# --- 4. restore pristine upstream sources -----------------------------------
say "Restoring pristine upstream sources"
git -C "$W" checkout -- \
    rx3-handoff/fb-present.c \
    rx3-handoff/touch-bridge.c \
    rx3-handoff/pi-controls.h \
    rx3-handoff/rx3-start.sh 2>/dev/null || true

# --- 5. patch rx3-start.sh (3 critical fixes) --------------------------------
say "Patching rx3-start.sh"
python3 - <<'PYEOF'
from pathlib import Path
p = Path.home() / "Rx3-flx4/rx3-handoff/rx3-start.sh"
s = p.read_text()

# A. Disable the uhubctl USB power-cycle block — corrupts any USB boot drive
old = "if { [ $wait = 10 ] || [ $wait = 22 ]; }"
new = "if false && { [ $wait = 10 ] || [ $wait = 22 ]; }"
if old in s:
    s = s.replace(old, new, 1); print("    A) USB power-cycle disabled")
elif new in s:
    print("    A) already disabled")
else:
    print("    A) MISS — check manually")

# B. Shorten the 30s controller wait to 1s
old = "for wait in $(seq 1 30); do"
new = "for wait in $(seq 1 1); do"
if old in s:
    s = s.replace(old, new, 1); print("    B) wait loop shortened")
elif new in s:
    print("    B) already short")
else:
    print("    B) MISS")

# C. Add fb0 unblank line
anchor = "[ -w /sys/class/graphics/fbcon/cursor_blink ] && echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null"
add = anchor + "\n[ -w /sys/class/graphics/fb0/blank ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null"
if "fb0/blank" not in s and anchor in s:
    s = s.replace(anchor, add, 1); print("    C) unblank line added")
elif "fb0/blank" in s:
    print("    C) already present")
else:
    print("    C) MISS")

p.write_text(s)
PYEOF
grep -n 'if false && {\|seq 1 1\|fb0/blank' "$H/rx3-start.sh" || true

# --- 6. rx3.conf -------------------------------------------------------------
say "Writing rx3.conf"
cat > "$H/rx3.conf" <<EOF
# RX3 per-machine settings — 5" Waveshare DSI, 800x480 landscape
RX3_FB=/dev/fb0
RX3_ROTATE=$ROT
RX3_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
EOF
cat "$H/rx3.conf"

# --- 7. blacklist broken native touch driver --------------------------------
say "Blacklisting edt_ft5x06 (only raspberrypi-ts will remain)"
printf 'blacklist edt_ft5x06\nblacklist edt-ft5x06\n' | \
    sudo tee /etc/modprobe.d/blacklist-edt-ft5x06.conf >/dev/null
sudo update-initramfs -u || true

# --- 8. firmware recovery ----------------------------------------------------
if [ -f "$H/runtime-symlinks.json" ] && [ -d "$H/extracted/runtime-files" ]; then
    say "Firmware already extracted"
else
    say "Recovering firmware (~110 MB download from Pioneer)"
    python3 "$H/recover-firmware.py" || die "recover-firmware.py failed"
    python3 "$H/extract_cramfs.py" | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract_cramfs.py incomplete"
fi

# --- 9. build chroot ---------------------------------------------------------
if [ -f "$R/etc/rx3-ctl" ] && [ -d "$R/root/pdj" ]; then
    say "Chroot already built ($(du -sh "$R" | cut -f1))"
else
    say "Building chroot"
    for m in $(mount | awk -v r="$R" 'index($3,r)==1{print $3}' | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
    "$H/build-rootfs.sh" | tee /tmp/build.log
    grep -q '^== done' /tmp/build.log || die "build-rootfs.sh failed"
    say "Chroot size: $(du -sh "$R" | cut -f1)"
fi

# --- 10. host install --------------------------------------------------------
say "Running upstream install.sh (builds helpers, unit, udev rules)"
"$H/install.sh"

# --- 11. enable rx3 to start on boot ----------------------------------------
say "Enabling rx3.service for auto-start on boot"
sudo systemctl daemon-reload
sudo systemctl enable rx3.service
sudo systemctl is-enabled rx3.service

# --- 12. final doctor --------------------------------------------------------
say "Final doctor"
"$H/install.sh" doctor || true

echo
echo "============================================================"
echo "  INSTALL COMPLETE"
echo "============================================================"
echo
echo "  Repo:      $W"
echo "  Chroot:    $R  ($(du -sh "$R" 2>/dev/null | cut -f1))"
echo "  Presenter: $HOME/rx3-fb-present"
echo "  Touch:     $HOME/rx3-touch-bridge"
echo "  Config:    $H/rx3.conf"
echo "  Service:   rx3.service (enabled, will start on boot)"
echo

# --- 13. reboot --------------------------------------------------------------
if [ "$AUTO_REBOOT" = "1" ]; then
    echo "Rebooting in $REBOOT_DELAY seconds — press Ctrl+C to cancel."
    echo "After reboot, rx3 will start automatically on the DSI panel."
    for i in $(seq "$REBOOT_DELAY" -1 1); do
        printf "\r    rebooting in %2d s ... " "$i"
        sleep 1
    done
    printf "\r    rebooting now          \n"
    sudo systemctl reboot
else
    echo "Skipping reboot (AUTO_REBOOT=0)."
    echo "Run: sudo reboot"
    echo "Then: systemctl status rx3"
fi
