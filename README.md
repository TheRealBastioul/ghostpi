# GhostPi

Passive wireless reconnaissance tool built on a Raspberry Pi Zero WH with an
Adafruit 2.13" e-ink bonnet. Captures 802.11 management frames, logs networks,
clients, and probe requests, and serves a live dashboard over USB.

---

## Legal Disclaimer

> **This tool is for authorized security assessments only.**
>
> Passive monitoring of 802.11 frames may be regulated by local law.
> Deauthentication attacks (active mode) are illegal against networks you
> do not own or do not have explicit written permission to test. This
> includes penetration-test scope-of-work agreements, bug-bounty rules of
> engagement, or written consent from the network owner.
>
> Active mode is **disabled by default** (`ACTIVE_MODE_ENABLED = False` in
> `ghostpi/config.py`). Enabling it is your legal responsibility.
>
> The authors accept no liability for unauthorized or unlawful use.

---

## Hardware

| Component | Detail |
|-----------|--------|
| Board | Raspberry Pi Zero WH |
| Display | Adafruit 2.13" Monochrome E-Ink Bonnet for Raspberry Pi — [product 4687](https://www.adafruit.com/product/4687) |
| Panel | GDEY0213B74 (SSD1680 driver chip) |
| Resolution | 250 × 122 px landscape |
| Wiring | **Direct plug-in to 40-pin GPIO header** — no wiring needed |
| Buttons | GPIO 5 (mode cycle) · GPIO 6 (context action) — on the bonnet |

The bonnet plugs directly onto the Pi Zero WH GPIO header.
No breadboard, no jumper wires.

> **Panel note:** As of August 2024, Adafruit ships the GDEY0213B74 panel.
> This requires the `Adafruit_SSD1680B` driver (not `Adafruit_SSD1680`).
> GhostPi uses the correct driver automatically.

### Pin reference

These are set by the bonnet hardware — do not change them.

| Signal | BCM GPIO | Board label |
|--------|----------|-------------|
| SPI SCLK | 11 | — |
| SPI MOSI | 10 | — |
| SPI CS   | 8  | SPI+CE0 |
| EPD DC   | 22 | DC:22 |
| EPD RST  | 27 | Reset:27 |
| EPD BUSY | 17 | Busy:17 |
| Button MODE | 5  | — |
| Button ACTION | 6  | — |

---

## Boot flow

Understanding how GhostPi starts helps when troubleshooting:

```
Power on
  └─ ghostpi-splash.service (oneshot)
       Draws "GhostPi | BOOTING" + "Configuring USB gadget..." to e-ink
  └─ ghostpi.service
       Stage 1: display + buttons start
                E-ink shows: "USB gadget active / SSH: 192.168.7.1 / Press ACTION → Web UI"
       Stage 2: WAIT — operator must press ACTION (GPIO 6) to continue
                (prevents Flask from starting until someone is physically present)
       Stage 3: Flask web UI starts
                E-ink shows: "Web UI: 192.168.7.1:80 / Press ACTION to capture"
       Stage 4: Press ACTION again to start WiFi capture
                E-ink shows REC badge while capturing
```

---

## Installation

### Prerequisites

- A Linux machine (Ubuntu, Debian, Kali, or similar)
- A microSD card (8 GB minimum)
- The Pi Zero WH with Adafruit e-ink bonnet attached

---

### Step 1 — Flash Raspberry Pi OS Lite

Download and flash using [Raspberry Pi Imager](https://www.raspberrypi.com/software/):

- **OS:** Raspberry Pi OS Lite (32-bit) — Trixie / 2026-04-13 release
- **Storage:** your microSD card
- **Advanced options / customisation:** leave blank — `prepare-sd.sh` sets everything

> Do **not** set username, password, SSH, or WiFi in Imager.
> `prepare-sd.sh` handles all of this via Pi OS's `custom.toml` mechanism.

Write and wait for the flash to complete. **Do not eject yet.**

---

### Step 2 — Find the SD card device

```bash
lsblk
```

Look for two partitions (bootfs + rootfs) whose total size matches your SD card:

```
sdb      8:16   1  29.7G  0 disk
├─sdb1   8:17   1   512M  0 part  /run/media/yourname/bootfs
└─sdb2   8:18   1  29.2G  0 part  /run/media/yourname/rootfs
```

Your device is the disk entry — in this example **`/dev/sdb`**.
**Do not use your main system drive.**

---

### Step 3 — Run the preparation script

Clone this repo:

```bash
git clone https://github.com/TheRealBastioul/ghostpi.git
cd ghostpi
```

Run the script:

```bash
sudo bash setup/prepare-sd.sh --device /dev/sdb
```

This takes **5–15 minutes** and handles:
- Installing all apt packages and Python libraries via QEMU ARM chroot
- Enabling SPI and USB OTG in `config.txt` / `cmdline.txt`
- Writing static IP config and dnsmasq DHCP for the USB gadget interface
- Installing and enabling all systemd services (ghostpi, ghostpi-splash, dnsmasq, ssh)
- Writing `custom.toml` with default credentials (`admin` / `ghostpi`)
- Enabling SSH via the Pi OS `sshswitch.service` mechanism

---

### Step 4 — Pre-boot checks (optional but recommended)

Before inserting the card, verify the setup from your Linux machine:

**Check all settings are correct:**
```bash
sudo bash setup/sdcard-repair.sh --status --boot /run/media/yourname/bootfs \
                                            --root /run/media/yourname/rootfs
```

**Preview what the e-ink display will show:**
```bash
python3 tools/preview-display.py --out /tmp/preview.png
# Open /tmp/preview.png in any image viewer
```

```bash
# Show the boot splash:
python3 tools/preview-display.py --status "USB gadget active\nSSH: 192.168.7.1\nPress ACTION → Web UI" \
    --out /tmp/preview-boot.png

# Show a demo with fake capture data:
python3 tools/preview-display.py --demo --out /tmp/preview-demo.png
```

Requires only Pillow (`pip install pillow`) — no Pi hardware needed.

---

### Step 5 — Eject and boot

```bash
sudo eject /dev/sdb
```

Insert the SD card into your Pi Zero WH and plug in power.
GhostPi starts automatically — watch the e-ink display for the boot sequence.

---

### Connecting over USB

1. Plug the Pi's **data Micro-USB port** (the port closer to the HDMI jack, **not** the PWR port) into your laptop.
2. Wait ~30 seconds for the USB gadget interface to appear.
3. **SSH:** `ssh admin@192.168.7.1` — password: `ghostpi`
4. **Web UI:** press ACTION (GPIO 6) on the bonnet first, then open `http://192.168.7.1`

> **Change the default password immediately:** `passwd`

**Windows:** may need an RNDIS driver. Use "Remote NDIS Compatible Device" (built into Windows 10+) or install the Raspberry Pi RNDIS driver.

**macOS:** the interface appears automatically as an RNDIS/ECM device.

---

### Method B — Direct install on a running Pi (fallback)

Use this if the Pi is already booted and has network access.

```bash
ssh admin@<pi-ip>
git clone https://github.com/TheRealBastioul/ghostpi.git ~/ghostpi
cd ~/ghostpi
sudo bash setup/install.sh
sudo reboot
```

---

## Troubleshooting

### SSH won't connect

**Fix from the SD card** (no Pi needed — insert card into Linux machine):

```bash
# Check what's wrong:
sudo bash setup/sdcard-repair.sh --status --boot /run/media/you/bootfs \
                                           --root /run/media/you/rootfs

# Fix everything:
sudo bash setup/sdcard-repair.sh --device /dev/sdb
```

The repair script fixes: user account, SSH service, `cmdline.txt`,
`config.txt`, `dhcpcd.conf`, and dnsmasq config.

**Common SSH errors:**

| Error | Likely cause | Fix |
|-------|-------------|-----|
| `Connection refused` | SSH not enabled | Run sdcard-repair.sh |
| `No route to host` | usb0 not up — dwc2 missing from cmdline.txt | Run sdcard-repair.sh |
| `Permission denied` | Wrong password | Re-run `sdcard-repair.sh` — rewrites passwd/shadow with default credentials |
| Interface doesn't appear on laptop | Wrong USB port (power not data) | Use the port closer to HDMI |

**Check on the Pi (if you can SSH):**
```bash
ip addr show usb0          # should show 192.168.7.1
systemctl status ssh       # should be active
journalctl -u dnsmasq -f   # DHCP log
```

---

### E-ink display blank or wrong

**Test display rendering without Pi hardware:**
```bash
python3 tools/preview-display.py --demo --out /tmp/preview.png
```
This tests the PIL rendering pipeline. If the PNG looks correct, the
issue is hardware/driver (not rendering logic).

**Run hardware diagnostics on the Pi:**
```bash
sudo bash ~/ghostpi/setup/diag-display.sh
```

**Common display issues:**

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| Completely blank | SPI not enabled or libraries missing | Check `dtparam=spi=on` in config.txt; run `repair.sh` to install adafruit libs |
| Import error in logs | Libraries not installed | `sudo pip3 install --break-system-packages adafruit-blinka rpi-lgpio adafruit-circuitpython-epd` |
| Content shifted/garbled | Wrong driver class | Must use `Adafruit_SSD1680B` from `adafruit_epd.ssd1680b` — not `Adafruit_SSD1680` |
| Hangs on BUSY pin | Wrong RST/BUSY pin assignment | RST=GPIO27, BUSY=GPIO17 (matches bonnet label DC:22 / Reset:27 / Busy:17) |

**Check logs:**
```bash
journalctl -u ghostpi-splash -n 50    # boot splash errors
journalctl -u ghostpi -f              # main service
```

---

### Monitor mode fails

Some Pi Zero WiFi firmware blocks monitor mode. Use an external USB WiFi
adapter that supports monitor mode (e.g. Alfa AWUS036ACH) and update
`WIFI_INTERFACE` and `MON_INTERFACE` in `ghostpi/config.py`.

---

### Web UI unreachable

- Press ACTION (GPIO 6) on the bonnet — Web UI only starts after button press.
- Confirm you are on the **data** USB port (not power).
- Check `ip addr show usb0` on the Pi shows `192.168.7.1`.
- Check `journalctl -u dnsmasq -f` for DHCP issues.
- Your laptop interface may show as RNDIS/ECM — verify it got a `192.168.7.x` address.

---

## Operating modes

Switch modes with **GPIO 5** (left button).

| Mode | Description | GPIO 6 action |
|------|-------------|---------------|
| `PASSIVE` | Listen-only, no transmit | Toggle capture on/off |
| `ACTIVE`  | Enables deauth (requires `ACTIVE_MODE_ENABLED=True`) | Send deauth burst to selected target |
| `REVIEW`  | Page through captured networks on e-ink | Next network |

---

## Enabling active mode (authorized engagements only)

Edit `ghostpi/config.py`:

```python
ACTIVE_MODE_ENABLED = True   # set only under written authorization
```

Restart:

```bash
sudo systemctl restart ghostpi
```

Select a target network from the web UI at `http://192.168.7.1`, then press GPIO 6.

---

## On-Pi repair

If the service is broken but you can SSH in:

```bash
sudo bash ~/ghostpi/setup/repair.sh --status   # diagnose
sudo bash ~/ghostpi/setup/repair.sh            # full repair
```

---

## File layout

```
ghostpi/
├── setup/
│   ├── prepare-sd.sh       SD card installer — run on Linux host (primary)
│   ├── install.sh          On-Pi installer (fallback)
│   ├── repair.sh           On-Pi repair tool
│   ├── sdcard-repair.sh    SD card repair from Linux host (SSH broken?)
│   ├── diag-display.sh     Hardware display diagnostics (run on Pi)
│   └── boot_config.txt     config.txt additions
├── ghostpi/
│   ├── config.py           All tunable constants
│   ├── main.py             Entry point
│   ├── display.py          E-ink display manager (SSD1680B / GDEY0213B74)
│   ├── splash.py           One-shot boot splash (runs before main service)
│   ├── capture.py          airodump-ng wrapper and CSV parser
│   ├── buttons.py          GPIO button handler
│   └── webui/
│       ├── app.py          Flask routes + JSON API
│       └── templates/
│           └── index.html  Dashboard UI
├── systemd/
│   ├── ghostpi.service     Main systemd unit
│   └── ghostpi-splash.service  Boot splash unit (oneshot)
├── tools/
│   └── preview-display.py  Render display to PNG (no hardware needed)
├── logs/                   Capture output (auto-created)
│   └── handshakes/
└── README.md
```

---

## Service management

```bash
sudo systemctl status ghostpi
journalctl -u ghostpi -f

sudo systemctl start ghostpi
sudo systemctl stop ghostpi
sudo systemctl restart ghostpi
```

---

## Configuration reference (`ghostpi/config.py`)

| Key | Default | Description |
|-----|---------|-------------|
| `ACTIVE_MODE_ENABLED` | `False` | Master switch for deauth features |
| `WIFI_INTERFACE` | `wlan0` | Physical wireless interface |
| `MON_INTERFACE` | `wlan0mon` | Monitor-mode interface |
| `DISPLAY_REFRESH_INTERVAL` | `30` | Seconds between e-ink refreshes |
| `EPD_RST_PIN` | `27` | BCM GPIO for e-ink reset (matches bonnet label) |
| `EPD_BUSY_PIN` | `17` | BCM GPIO for e-ink busy (matches bonnet label) |
| `BUTTON_MODE_PIN` | `5` | BCM GPIO for mode-cycle button |
| `BUTTON_ACTION_PIN` | `6` | BCM GPIO for action button |
| `WEBUI_HOST` | `0.0.0.0` | Web UI bind address |
| `WEBUI_PORT` | `80` | Web UI port |

---

## Captured data

Capture files are written to `~/ghostpi/logs/`:

| File | Contents |
|------|----------|
| `capture-<ts>-01.csv` | Networks + clients (airodump-ng CSV) |
| `capture-<ts>-01.cap` | Full PCAP including WPA handshakes |
| `ghostpi.log` | Application log |

Download any file from the web UI's **Capture Files** section, or:

```bash
scp admin@192.168.7.1:~/ghostpi/logs/capture-*-01.cap .
aircrack-ng capture-*-01.cap
```
