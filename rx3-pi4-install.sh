#!/bin/bash
# rx3-pi4-install.sh
# Install XDJ-RX3 firmware emulation on Raspberry Pi 4 + 5" Waveshare DSI (800x480).
# Border/controls always visible (no hide/swipe overlay).
# Run as your normal user, NOT root.
# Usage: bash ~/rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log

set -euo pipefail

REPO="https://github.com/mutlisensor/Rx3-flx4.git"
W="$HOME/Rx3-flx4"
H="$W/rx3-handoff"
R="$HOME/rx3-rootfs"
ROT=0
USB_QUIRK="usb-storage.quirks=174c:2362:u"
CMDLINE_ADD="$USB_QUIRK vt.global_cursor_default=0 consoleblank=0"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[FATAL] %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. sanity ---------------------------------------------------------------
[ "$(id -u)" -ne 0 ] || die "Do not run as root"
[ -d "$HOME" ] || die "HOME unset"
command -v apt >/dev/null || die "Debian/Raspberry Pi OS required"

say "Pi 4 RX3 installer"
echo "    Host: $(uname -srm)"
echo "    User: $(id -un) (uid $(id -u))"
echo "    fb:   $(cat /sys/class/graphics/fb0/name 2>/dev/null) $(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null)"

# --- 1. kernel cmdline -------------------------------------------------------
say "Patching /boot/firmware/cmdline.txt"
CMDLINE=/boot/firmware/cmdline.txt
[ -f "$CMDLINE" ] || CMDLINE=/boot/cmdline.txt
[ -f "$CMDLINE" ] || die "cmdline.txt not found"

if ! grep -q "$USB_QUIRK" "$CMDLINE"; then
    sudo cp "$CMDLINE" "$CMDLINE.bak.$(date +%s)"
    sudo sed -i "s|\$| $CMDLINE_ADD|" "$CMDLINE"
    echo "    added quirks + consoleblank"
else
    echo "    already present"
fi
cat "$CMDLINE"

# --- 2. packages -------------------------------------------------------------
say "Installing build dependencies"
sudo apt update
sudo apt install -y \
    git build-essential gcc gcc-arm-linux-gnueabi \
    libfreetype6-dev pkg-config fonts-dejavu-core \
    fuse-overlayfs exfatprogs alsa-utils uhubctl gpiod \
    python3 python3-pil python3-cryptography rsync p7zip-full \
    evtest

# --- 3. clone or update ------------------------------------------------------
say "Cloning repo"
if [ -d "$W/.git" ]; then
    git -C "$W" fetch --all --prune || warn "fetch failed; using local copy"
    git -C "$W" reset --hard origin/HEAD 2>/dev/null || true
else
    git clone "$REPO" "$W"
fi
cd "$H"
chmod +x *.sh

# --- 4. ensure pristine upstream sources ------------------------------------
say "Restoring pristine upstream sources"
git -C "$W" checkout -- \
    rx3-handoff/fb-present.c \
    rx3-handoff/touch-bridge.c \
    rx3-handoff/pi-controls.h \
    rx3-handoff/rx3-start.sh 2>/dev/null || true

# --- 5. patch rx3-start.sh (3 critical fixes) --------------------------------
say "Patching rx3-start.sh (USB power-cycle, wait loop, unblank)"
python3 - <<'PYEOF'
from pathlib import Path
p = Path.home() / "Rx3-flx4/rx3-handoff/rx3-start.sh"
s = p.read_text()

# A. Disable the uhubctl USB power-cycle — this is what was corrupting the SD/SSD
old = "if { [ $wait = 10 ] || [ $wait = 22 ]; }"
new = "if false && { [ $wait = 10 ] || [ $wait = 22 ]; }"
if old in s:
    s = s.replace(old, new, 1)
    print("    A) USB power-cycle disabled")
elif new in s:
    print("    A) already disabled")
else:
    print("    A) MISS")

# B. Shorten the controller wait from 30s to 1s
old = "for wait in $(seq 1 30); do"
new = "for wait in $(seq 1 1); do"
if old in s:
    s = s.replace(old, new, 1)
    print("    B) wait loop shortened")
elif new in s:
    print("    B) already short")
else:
    print("    B) MISS")

# C. Add an fb0 unblank line right after the cursor_blink line
anchor = "[ -w /sys/class/graphics/fbcon/cursor_blink ] && echo 0 > /sys/class/graphics/fbcon/cursor_blink 2>/dev/null"
add = anchor + "\n[ -w /sys/class/graphics/fb0/blank ] && echo 0 > /sys/class/graphics/fb0/blank 2>/dev/null"
if "fb0/blank" not in s and anchor in s:
    s = s.replace(anchor, add, 1)
    print("    C) unblank line added")
elif "fb0/blank" in s:
    print("    C) already present")
else:
    print("    C) MISS")

p.write_text(s)
PYEOF

# Sanity check
grep -n 'if false && {\|seq 1 1\|fb0/blank' "$H/rx3-start.sh"

# --- 6. rx3.conf -------------------------------------------------------------
say "Writing rx3.conf"
cat > "$H/rx3.conf" <<EOF
# RX3 per-machine settings — 5" Waveshare DSI, 800x480 landscape
RX3_FB=/dev/fb0
RX3_ROTATE=$ROT
RX3_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
EOF
cat "$H/rx3.conf"

# --- 7. blacklist the broken native touch driver ----------------------------
say "Blacklisting edt_ft5x06 (keep only raspberrypi-ts)"
printf 'blacklist edt_ft5x06\nblacklist edt-ft5x06\n' | \
    sudo tee /etc/modprobe.d/blacklist-edt-ft5x06.conf >/dev/null
sudo update-initramfs -u || true

# --- 8. firmware recovery ----------------------------------------------------
if [ -f "$H/runtime-symlinks.json" ] && [ -d "$H/extracted/runtime-files" ]; then
    say "Firmware already extracted"
else
    say "Recovering firmware (may take a few minutes)"
    python3 "$H/recover-firmware.py" || die "recover-firmware.py failed"
    python3 "$H/extract_cramfs.py" | tee /tmp/extract.log
    grep -q "Extraction complete." /tmp/extract.log || die "extract_cramfs.py incomplete"
fi

# --- 9. build chroot ---------------------------------------------------------
if [ -f "$R/etc/rx3-ctl" ] && [ -d "$R/root/pdj" ]; then
    say "Chroot already built ($(du -sh "$R" | cut -f1))"
else
    say "Building chroot"
    # Clean any stale mounts
    for m in $(mount | awk -v r="$R" 'index($3,r)==1{print $3}' | sort -r); do
        sudo umount -l "$m" 2>/dev/null || true
    done
    "$H/build-rootfs.sh" | tee /tmp/build.log
    grep -q '^== done' /tmp/build.log || die "build-rootfs.sh failed"
    say "Chroot size: $(du -sh "$R" | cut -f1)"
fi

# --- 10. host install (builds rx3-fb-present + rx3-touch-bridge, unit, udev) -
say "Running upstream install.sh"
"$H/install.sh"
sudo systemctl daemon-reload

# --- 11. final sanity --------------------------------------------------------
say "Verifying"
"$H/install.sh" doctor || true

echo
echo "============================================================"
echo "  INSTALL COMPLETE"
echo "============================================================"
echo
echo "  Repo:      $W"
echo "  Chroot:    $R  ($(du -sh "$R" 2>/dev/null | cut -f1))"
echo "  Presenter: $HOME/rx3-fb-present     (border always visible)"
echo "  Touch:     $HOME/rx3-touch-bridge   (/dev/input/event0 -> $R/dev/tsc2007_2-0048)"
echo "  Config:    $H/rx3.conf"
echo
echo "Next steps"
echo "----------"
echo "  1. Reboot once so cmdline.txt and the driver blacklist take effect:"
echo "       sudo reboot"
echo ""
echo "  2. After reboot, start rx3:"
echo "       cd $H && sudo ./rx3-start.sh"
echo ""
echo "  3. Watch the 5-inch screen for the RX3 UI. Border + sliders + 12 buttons"
echo "     should appear around the firmware canvas."
echo ""
echo "  4. Plug in a DDJ-FLX4 to use real audio (otherwise ALSA Loopback)."
echo ""
echo "  Logs: $HOME/rx3-player.log, $HOME/rx3-present.log"
echo "  To auto-start on every boot: sudo systemctl enable rx3"
echo

