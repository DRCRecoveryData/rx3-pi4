# RX3 on Raspberry Pi 4 + 5" Waveshare DSI

Runs the Pioneer XDJ-RX3 firmware on a Raspberry Pi 4, driving a 5-inch
800×480 Waveshare DSI panel. The on-screen border (12 buttons + 6 sliders)
is always visible; the firmware canvas is drawn letterboxed in the middle
at 768×480. Audio is routed to a DDJ-FLX4 if one is plugged in, otherwise
to an ALSA loopback.

Verified on: **Raspberry Pi 4B Rev 1.5, Debian 13 (Trixie) aarch64**,
Waveshare 5" DSI panel (raspberrypi-ts touch controller).

---

## Hardware

| Part | Notes |
|---|---|
| Raspberry Pi 4B | 2 GB+ recommended; 1 GB will run but is tight |
| Waveshare 5" DSI panel | 800×480, `raspberrypi-ts` touch device |
| Boot storage | SD card (232 GB) or NVMe via USB — see note below |
| DDJ-FLX4 or DDJ-400 | Optional; audio falls back to ALSA Loopback |

### ⚠️ Important — USB storage stability

Two things will corrupt your boot drive if you skip them:

1. **ASMedia 174c:2362 NVMe enclosures** drop off the bus under load. The
   installer adds `usb-storage.quirks=174c:2362:u` to `cmdline.txt` to force
   the older, stable `usb-storage` driver instead of UAS.

2. **`rx3-start.sh`'s USB power-cycle block** (the `uhubctl -a cycle` call
   meant for Pi 5's `USB_VBUS_EN`) will cut power to the boot drive for 5 s,
   killing the filesystem journal. The installer disables this block. **If
   you update the repo with `git pull`, re-run the installer or manually
   re-apply this patch**, or your SD/SSD will corrupt.

If your drive still drops, the enclosure's USB 3.0 link is the problem.
Move it to USB 2.0:
- Tape over the 5 inner USB 3.0 pins on the enclosure's USB-A plug, or
- Use a USB 2.0 extension cable / hub, or
- Replace with a JMicron JMS583 or Realtek RTL9210 enclosure.

---

## Install

```bash
cd ~/rx3-pi4
chmod +x rx3-pi4-install.sh
bash rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log
```

The installer:

1. Adds `usb-storage.quirks=174c:2362:u vt.global_cursor_default=0
   consoleblank=0` to `/boot/firmware/cmdline.txt`
2. Installs Debian build packages (`gcc-arm-linux-gnueabi`, `libfreetype-dev`,
   `fuse-overlayfs`, `uhubctl`, `evtest`, …)
3. Clones `mutlisensor/Rx3-flx4`
4. Applies three patches to `rx3-start.sh`:
   - disables the `uhubctl` USB power-cycle block
   - shortens the controller wait from 30 s to 1 s
   - adds an `fb0/blank` unblank line
5. Writes `rx3.conf` (framebuffer, rotation, font)
6. Blacklists the broken `edt_ft5x06` driver so only `raspberrypi-ts` remains
7. Recovers the RX3 v1.19 firmware from Pioneer's official source packages
8. Builds the ARM32 chroot (~110 MB)
9. Builds the host helpers `rx3-fb-present` and `rx3-touch-bridge`
10. Runs the upstream `install.sh` (systemd unit, udev rules, console mode)

The script is idempotent — safe to re-run. It skips steps already done.

---

## Start rx3

Manual start (recommended for first run):

```bash
cd ~/Rx3-flx4/rx3-handoff
sudo ./rx3-start.sh 2>&1 | tee /tmp/rx3-run.log
```

Auto-start on every boot:

```bash
sudo systemctl enable --now rx3
```

Stop:

```bash
sudo ./rx3-stop.sh
# or
sudo systemctl stop rx3
```

---

## What you should see

**On start:** the 5" screen shows
- a dark blue-grey **border** with **6 sliders** on the left and right
  (DECK 1 / MASTER / HP MIX — DECK 2 / HP LEVEL / CROSS)
- a strip of **12 buttons** along the bottom (SOURCE, BROWSE, BACK, UP,
  DOWN, ENTER, LOAD 1, USB STOP 1, PLAY 1, LOAD 2, USB STOP 2, PLAY 2)
- the firmware's RX3 canvas (768×480) letterboxed in the middle

**Tapping the buttons** sends the corresponding keycodes into the firmware
via `/dev/rx3-control`.

**Tapping the canvas** sends touch reports into the firmware's tsc2007 FIFO
at `~/rx3-rootfs/dev/tsc2007_2-0048`.

**Audio:**
- FLX4/DDJ-400 plugged in → `audio card: DDJFLX4 (DDJ-FLX4)`, real audio out
- Nothing plugged in → `audio card: Loopback`, silent (firmware still runs)

---

## Logs

| File | Contents |
|---|---|
| `~/rx3-player.log` | Firmware stdout (DirectFB init, mixer routing, USB mounts) |
| `~/rx3-present.log` | Framebuffer presenter (geometry line + errors) |
| `/tmp/rx3-run.log` | Latest `rx3-start.sh` output |
| `journalctl -u rx3` | systemd service logs (if enabled) |

---

## Common commands

```bash
# Is it running?
pgrep -af 'rbp-pi|rx3-fb-present|rx3-touch-bridge'

# Is the screen unblanked?
cat /sys/class/graphics/fb0/blank     # must be 0

# Unblank manually
echo 0 | sudo tee /sys/class/graphics/fb0/blank

# Which touch devices exist?
sudo evtest

# Firmware's audio card
cat ~/rx3-rootfs/etc/rx3-ctl
```

### Control the player from the CLI

```bash
cd ~/Rx3-flx4/rx3-handoff
python3 rx3-control.py query
python3 rx3-control.py load 1 && python3 rx3-control.py play 1
python3 rx3-control.py load 2 && python3 rx3-control.py play 2
python3 rx3-control.py source
python3 rx3-control.py usb1
```

Channel mapping: `1` → Deck 1, `2` → Deck 2, `0` → global
(source/crossfader).

---

## Troubleshooting

### Screen is black

```bash
cat /sys/class/graphics/fb0/blank
echo 0 | sudo tee /sys/class/graphics/fb0/blank
```

If it flips back to 4, `consoleblank=0` isn't in `cmdline.txt` — re-run the
installer and reboot.

### Touch doesn't respond

```bash
# Only raspberrypi-ts should appear
sudo evtest

# Touch bridge running?
pgrep -af rx3-touch-bridge

# Manual test (bridge writes to the chroot FIFO)
sudo pkill -f rx3-touch-bridge
sudo -u drclab ~/rx3-touch-bridge /dev/input/event0 \
    ~/rx3-rootfs/dev/tsc2007_2-0048
```

Tap the screen; you should see `touch begin slot=0 screen=X,Y region=0`.
`region=0` = firmware canvas, `region=1..12` = button strip,
`region=20..25` = sliders.

### Controller not detected

```bash
cd ~/Rx3-flx4/rx3-handoff
python3 controllers.py detect
python3 controllers.py detect --all
```

If the FLX4 shows up but audio is silent, check `~/rx3-player.log` for the
`audio card:` line. If it says `Loopback`, restart with the controller
plugged in.

### USB drive drops / filesystem corrupts

Confirm the quirk is active:

```bash
dmesg | grep -iE '174c|quirks match'
```

Expected: `usb-storage 2-2:1.0: Quirks match for vid 174c pid 2362: 800000`.

If the drive still drops, it's the enclosure — see **USB storage stability**
above.

### Recover a corrupted boot drive

Boot from another SD/USB, then:

```bash
sudo fsck.ext4 -f -y /dev/sda2
```

### Rebuild just the presenter or touch bridge

```bash
cd ~/Rx3-flx4/rx3-handoff
gcc -O2 -DRX3_ROOT_PATH="\"$HOME/rx3-rootfs\"" \
    $(pkg-config --cflags freetype2) \
    -o "$HOME/rx3-fb-present" fb-present.c \
    $(pkg-config --libs freetype2)
gcc -O2 -DRX3_ROOT_PATH="\"$HOME/rx3-rootfs\"" \
    -o "$HOME/rx3-touch-bridge" touch-bridge.c
```

---

## Where things live

| Path | Contents |
|---|---|
| `~/Rx3-flx4/rx3-handoff/` | Source, scripts, firmware archives |
| `~/Rx3-flx4/rx3-handoff/rx3.conf` | Per-machine settings (fb, rotation, font) |
| `~/rx3-rootfs/` | ARM32 chroot with firmware |
| `~/rx3-rootfs/dev/fb0` | Firmware's virtual framebuffer (1280×800×4) |
| `~/rx3-rootfs/dev/rx3-ui-state` | Shared state struct (levels, buttons) |
| `~/rx3-rootfs/dev/rx3-control` | Control FIFO (keycodes into firmware) |
| `~/rx3-rootfs/dev/tsc2007_2-0048` | Touch FIFO (reports into firmware) |
| `~/rx3-usb/` | Copy-on-write overlays for USB media |
| `~/rx3-fb-present` | Host binary: chroot fb0 → real /dev/fb0 |
| `~/rx3-touch-bridge` | Host binary: /dev/input/event0 → chroot FIFO |
| `/etc/systemd/system/rx3.service` | systemd unit |
| `/etc/udev/rules.d/*rx3*` | Controller hotplug rules |
| `/etc/modprobe.d/blacklist-edt-ft5x06.conf` | Keeps `raspberrypi-ts` as the only touch device |

---

## Notes

- The installer targets **Pi 4 + DSI**. Other platforms (Pi 5, Lenovo Duet)
  have different `uhubctl`/`USB_VBUS_EN` behavior — the `rx3-start.sh` patch
  may need adjusting.
- Rotation: set `RX3_ROTATE` in `rx3.conf` to `0` (landscape, default), or
  `90/180/270`. Restart with `rx3-stop.sh` then `rx3-start.sh`.
- The presenter always draws the border. If you want the border to
  auto-hide and swipe-up to reveal it, that's a separate patch — do **not**
  use it on this build.
- Firmware is **not** included; the installer fetches Pioneer's official
  GPL source packages.
```

---

### 🚀 How to Use

```bash
# Save both files
nano ~/rx3-pi4-install.sh    # paste the install script
nano ~/Rx3-flx4/rx3-handoff/README-Pi4.md    # paste the README (after install)

# Make the installer executable
chmod +x ~/rx3-pi4-install.sh

# Run it
bash ~/rx3-pi4-install.sh 2>&1 | tee ~/rx3-install.log

# Reboot once for cmdline + driver blacklist to take effect
sudo reboot

# Then start
cd ~/Rx3-flx4/rx3-handoff
sudo ./rx3-start.sh
```

### 📌 Key Differences From Your Current Setup

| Feature | This install | What you had |
|---|---|---|
| Border hide on idle | **No** — always visible | Attempted, buggy |
| Swipe-up to reveal | **No** | Attempted, buggy |
| `-hidable` flag on presenter | **No** | Yes |
| `overlay_visible` state field | **Not added** | Added, then reverted |
| USB power-cycle block | **Disabled** (critical) | Was corrupting the drive |
| Wait loop | 1 iteration | Was 30 iterations |
| fb0 unblank in start script | **Yes** | Yes |
| `consoleblank=0` in cmdline | **Yes** | Yes |
| `usb-storage.quirks` in cmdline | **Yes** | Yes |
| `edt_ft5x06` blacklisted | **Yes** | Was intermittent |

The installer gives you the clean, working baseline. The border-hide overlay was the last unfinished piece — it's now removed entirely, so what you get is exactly what's proven to work.
