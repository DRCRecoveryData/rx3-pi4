# RX3 on Raspberry Pi 4 + 5" Waveshare DSI

Runs the Pioneer XDJ-RX3 firmware on a Raspberry Pi 4, driving a 5-inch
800×480 Waveshare DSI panel. The on-screen border (12 buttons + 6 sliders)
is always visible; the firmware canvas is drawn letterboxed in the middle
at 768×480.

Audio is routed to a DDJ-FLX4 / DDJ-400 if one is plugged in, otherwise
to an ALSA loopback (silent).

**Verified on:** Raspberry Pi 4B Rev 1.5, Debian 13 (Trixie) aarch64,
Waveshare 5" DSI panel with `raspberrypi-ts` touch controller.

---

## Quick start

```bash
cd ~/rx3-pi4
chmod +x rx3-pi4-install.sh
bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log
```

The installer:

1. Adds `usb-storage.quirks=174c:2362:u vt.global_cursor_default=0 consoleblank=0` to `/boot/firmware/cmdline.txt`
2. Installs build + runtime dependencies (`gcc-arm-linux-gnueabi`, `libfreetype-dev`, `fuse-overlayfs`, `uhubctl`, `evtest`, …)
3. Clones `mutlisensor/Rx3-flx4` to `~/Rx3-flx4`
4. Applies **three critical patches** to `rx3-start.sh`:
   - disables the `uhubctl` USB power-cycle block (this is what was corrupting USB boot drives)
   - shortens the DJ-controller wait loop from 30 s to 1 s
   - adds an `fb0/blank` unblank line so the DSI panel never stays dark
5. Writes `~/Rx3-flx4/rx3-handoff/rx3.conf` (framebuffer, rotation, font)
6. Blacklists the buggy `edt_ft5x06` driver so `raspberrypi-ts` is the only touch device
7. Recovers the RX3 v1.19 firmware from Pioneer's official source packages
8. Builds the ARM32 chroot (~110 MB)
9. Builds host binaries `rx3-fb-present` and `rx3-touch-bridge`
10. Runs the upstream `install.sh` (systemd unit + udev rules)
11. **Enables `rx3.service` so it auto-starts on every boot**
12. **Reboots automatically after 10 s**

The script is idempotent — safe to re-run. If everything is already done, it
finishes in seconds and just reboots.

**Skip the reboot** (to inspect first):

```bash
AUTO_REBOOT=0 bash rx3-pi4-install.sh
```

---

## After reboot

The installer reboots the Pi. **You do not need to start rx3 manually** —
systemd starts it about 30–60 s after boot. The DSI panel will show:

- A dark blue-grey **border** with **6 sliders** on the left and right
  (DECK 1 / MASTER / HP MIX — DECK 2 / HP LEVEL / CROSS)
- A strip of **12 buttons** along the bottom
  (SOURCE, BROWSE, BACK, UP, DOWN, ENTER, LOAD 1, USB STOP 1, PLAY 1,
  LOAD 2, USB STOP 2, PLAY 2)
- The firmware's RX3 canvas (768×480) letterboxed in the middle

If it doesn't appear, check:

```bash
systemctl status rx3 --no-pager -l
journalctl -u rx3 -n 80 --no-pager
tail -40 ~/rx3-player.log
```

---

## Manual start / stop

Even with auto-start enabled, you can control it:

```bash
# Status
systemctl status rx3 --no-pager -l

# Stop
sudo systemctl stop rx3

# Start (without reboot)
sudo systemctl start rx3

# Disable auto-start on boot
sudo systemctl disable rx3

# Re-enable auto-start
sudo systemctl enable rx3

# Run the launcher by hand (bypasses systemd)
cd ~/Rx3-flx4/rx3-handoff
sudo ./rx3-start.sh 2>&1 | tee /tmp/rx3-run.log
```

---

## Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 4B | 2 GB+ recommended; 1 GB will run but is tight |
| Waveshare 5" DSI panel | 800×480, `raspberrypi-ts` touch |
| Boot storage | SD card (preferred) or NVMe via USB |
| DDJ-FLX4 / DDJ-400 | Optional; audio falls back to ALSA Loopback |

### ⚠️ USB storage stability — read this before using an NVMe enclosure

Two failure modes corrupt USB boot drives on Pi 4:

1. **`uhubctl -a cycle` in `rx3-start.sh`** — the upstream project has a
   block meant for Pi 5's `USB_VBUS_EN` line that falls back to `uhubctl`
   on Pi 4, cutting power to *all* USB ports for 5 s. If the boot drive is
   USB, its ext4 journal is interrupted and the filesystem aborts. **The
   installer disables this block.** If you `git pull` the repo, re-run the
   installer to re-apply the patch.

2. **ASMedia 174c:2362 NVMe enclosures** — this specific bridge chipset
   drops off the Pi 4's xHCI controller under sustained mixed I/O. The
   installer adds `usb-storage.quirks=174c:2362:u` to force the older,
   stable `usb-storage` driver instead of UAS. If the drive still drops,
   move it to USB 2.0 (tape over the 5 inner USB 3.0 pins on the USB-A
   plug, or use a USB 2.0 extension/hub), or replace the enclosure with
   a JMicron JMS583 or Realtek RTL9210 model.

**Other USB 3.0 devices (like the Genesys Logic SD card reader) are
perfectly stable** — the problem is chipset-specific, not speed-related.

---

## Configuration

`~/Rx3-flx4/rx3-handoff/rx3.conf`:

```ini
RX3_FB=/dev/fb0
RX3_ROTATE=0
RX3_FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
```

- `RX3_FB` — the panel framebuffer (leave as `/dev/fb0` for the DSI panel)
- `RX3_ROTATE` — `0` (landscape, default), `90`, `180`, or `270`
- `RX3_FONT` — path to a `.ttf` for the on-screen labels

After changing: `sudo systemctl restart rx3`

---

## What runs where

| Path | Contents |
|---|---|
| `~/Rx3-flx4/rx3-handoff/` | Source + scripts |
| `~/Rx3-flx4/rx3-handoff/rx3.conf` | Per-machine settings |
| `~/rx3-rootfs/` | ARM32 chroot with firmware |
| `~/rx3-rootfs/dev/fb0` | Firmware's virtual framebuffer (1280×800×4) |
| `~/rx3-rootfs/dev/rx3-ui-state` | Shared state (levels, buttons) |
| `~/rx3-rootfs/dev/rx3-control` | Control FIFO (keycodes into firmware) |
| `~/rx3-rootfs/dev/tsc2007_2-0048` | Touch FIFO (reports into firmware) |
| `~/rx3-usb/` | Copy-on-write overlays for USB media |
| `~/rx3-fb-present` | Host binary: chroot fb0 → real `/dev/fb0` |
| `~/rx3-touch-bridge` | Host binary: `/dev/input/event0` → chroot FIFO |
| `/etc/systemd/system/rx3.service` | systemd unit (enabled) |
| `/etc/udev/rules.d/*rx3*` | Controller hotplug rules |
| `/etc/modprobe.d/blacklist-edt-ft5x06.conf` | Keeps `raspberrypi-ts` as the only touch device |

---

## Logs

| File | Contents |
|---|---|
| `~/rx3-player.log` | Firmware stdout (DirectFB, mixer routing, USB mounts) |
| `~/rx3-present.log` | Framebuffer presenter |
| `/tmp/rx3-run.log` | Latest manual `rx3-start.sh` output |
| `journalctl -u rx3` | systemd service logs |

---

## Common commands

```bash
# Is rx3 running?
systemctl status rx3 --no-pager -l
pgrep -af 'rbp-pi|rx3-fb-present|rx3-touch-bridge'

# Is the screen unblanked?
cat /sys/class/graphics/fb0/blank          # must be 0
echo 0 | sudo tee /sys/class/graphics/fb0/blank   # force unblank

# Which touch devices exist?
sudo evtest

# Firmware's audio card
cat ~/rx3-rootfs/etc/rx3-ctl

# Control the player from the CLI
cd ~/Rx3-flx4/rx3-handoff
python3 rx3-control.py query
python3 rx3-control.py load 1 && python3 rx3-control.py play 1
python3 rx3-control.py load 2 && python3 rx3-control.py play 2
python3 rx3-control.py source
python3 rx3-control.py usb1
```

Channel mapping for `rx3-control.py`: `1` → Deck 1, `2` → Deck 2,
`0` → global (source / crossfader).

---

## Troubleshooting

### Screen is black after boot

```bash
cat /sys/class/graphics/fb0/blank          # if 4, panel was blanked
echo 0 | sudo tee /sys/class/graphics/fb0/blank
systemctl restart rx3
```

If it flips back to 4, `consoleblank=0` is missing from
`/boot/firmware/cmdline.txt`. Re-run the installer and reboot.

### rx3.service failed at boot

```bash
systemctl status rx3 --no-pager -l
journalctl -u rx3 -b --no-pager | tail -80
tail -40 ~/rx3-player.log
```

Common causes:

- `rbp-pi` exited early — check `~/rx3-player.log` for a library / DirectFB error
- Framebuffer busy — check `/sys/class/graphics/fb0/blank`
- OOM on 1 GB Pi — check `dmesg | grep -i oom`

### Touch doesn't respond

```bash
# Only raspberrypi-ts should appear
sudo evtest

# Bridge running?
pgrep -af rx3-touch-bridge

# Manual test
sudo systemctl stop rx3
cd ~/Rx3-flx4/rx3-handoff
sudo -u "$USER" ~/rx3-touch-bridge /dev/input/event0 \
    ~/rx3-rootfs/dev/tsc2007_2-0048
```

Tap the screen. You should see `touch begin slot=0 screen=X,Y region=0`.
`region=0` = firmware canvas; `region=1..12` = button strip;
`region=20..25` = sliders.

### Controller not detected

```bash
cd ~/Rx3-flx4/rx3-handoff
python3 controllers.py detect
python3 controllers.py detect --all
```

If the FLX4 shows up but audio is silent, check the `audio card:` line in
`~/rx3-player.log`. If it says `Loopback`, restart with the controller
plugged in.

### USB drive drops / filesystem corrupts

```bash
dmesg | grep -iE '174c|quirks match'
```

Expected: `usb-storage 2-2:1.0: Quirks match for vid 174c pid 2362: 800000`.

If the drive still drops, it's the enclosure. Move it to USB 2.0 (tape /
extension / hub) or replace it.

### Recover a corrupted boot drive

Boot from another SD/USB, then:

```bash
sudo fsck.ext4 -f -y /dev/sda2      # adjust device
```

### Rebuild the host helpers only

```bash
cd ~/Rx3-flx4/rx3-handoff
gcc -O2 -DRX3_ROOT_PATH="\"$HOME/rx3-rootfs\"" \
    $(pkg-config --cflags freetype2) \
    -o "$HOME/rx3-fb-present" fb-present.c \
    $(pkg-config --libs freetype2)
gcc -O2 -DRX3_ROOT_PATH="\"$HOME/rx3-rootfs\"" \
    -o "$HOME/rx3-touch-bridge" touch-bridge.c
sudo systemctl restart rx3
```

### Full clean reinstall

```bash
sudo systemctl disable --now rx3
rm -rf ~/Rx3-flx4 ~/rx3-rootfs ~/rx3-usb \
       ~/rx3-fb-present ~/rx3-touch-bridge ~/rx3-player.log ~/rx3-present.log

cd ~/rx3-pi4
bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log
```

---

## Notes

- The installer targets **Pi 4 + 5" DSI**. Pi 5 has different
  `uhubctl`/`USB_VBUS_EN` behavior and needs a different `rx3-start.sh`
  patch.
- Rotation: set `RX3_ROTATE` in `rx3.conf`, then
  `sudo systemctl restart rx3`.
- The presenter always draws the border. There is **no** auto-hide or
  swipe-up overlay in this build.
- Firmware is **not** included; the installer fetches Pioneer's official
  GPL source packages.
