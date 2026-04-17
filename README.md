# GhostPi

Passive wireless reconnaissance tool built on a Raspberry Pi Zero WH with an
Adafruit 2.13" e-ink bonnet.  Captures 802.11 management frames, logs
networks, clients, and probe requests, and serves a live dashboard over USB.

---

## Legal Disclaimer

> **This tool is for authorized security assessments only.**
>
> Passive monitoring of 802.11 frames may be regulated by local law.
> Deauthentication attacks (active mode) are illegal against networks you
> do not own or do not have explicit written permission to test.  This
> includes penetration-test scope-of-work agreements, bug-bounty rules of
> engagement, or written consent from the network owner.
>
> Active mode is **disabled by default** (`ACTIVE_MODE_ENABLED = False` in
> `ghostpi/config.py`).  Enabling it is your legal responsibility.
>
> The authors accept no liability for unauthorized or unlawful use.

---

## Hardware

| Component | Detail |
|-----------|--------|
| Board | Raspberry Pi Zero WH |
| Display | Adafruit 2.13" Monochrome E-Ink Bonnet |
| Driver | SSD1680 (GDEY0213B74 panel variant) |
| Resolution | 250 × 122 px |
| Wiring | **Direct plug-in to 40-pin GPIO header** – no wiring needed |
| Buttons | GPIO 5 (mode cycle) · GPIO 6 (context action) – on the bonnet |

The bonnet plugs directly onto the Pi Zero WH GPIO header.
No breadboard, no jumper wires.

### Pin reference (informational only)

| Signal | BCM GPIO | Header pin |
|--------|----------|------------|
| SPI SCLK | 11 | 23 |
| SPI MOSI | 10 | 19 |
| SPI CS   | 8  | 24 |
| EPD DC   | 22 | 15 |
| EPD RST  | 17 | 11 |
| EPD BUSY | 4  | 7  |
| Button 1 | 5  | 29 |
| Button 2 | 6  | 31 |

---

## Installation

### Method A — SD card prep on your Linux machine (recommended)

Everything is installed from your Linux machine directly onto the SD card.
The Pi just boots and runs — no SSH required, no waiting for `apt` on the
Pi Zero's slow single core.

**Requirements:** A Linux machine running Ubuntu or Debian with internet access.
You do **not** need anything else pre-installed — the script handles it.

---

#### Step 1 — Flash the OS

1. Download and install [Raspberry Pi Imager](https://www.raspberrypi.com/software/) on your Linux machine.
2. Open Imager, click **Choose OS** → **Raspberry Pi OS (other)** →
   **Raspberry Pi OS Lite (32-bit)** (Trixie / 2026-04-13 release).
3. Click **Choose Storage** and select your microSD card.
4. Click the **gear icon** (advanced options) and set:
   - Hostname: anything you like (e.g. `ghostpi`)
   - Username: `admin`  ← **must match this exactly**
   - Password: your choice
   - Enable SSH: yes (lets you log in later if needed)
5. Click **Write** and wait for it to finish.
6. **Do not eject the SD card yet.**

---

#### Step 2 — Find your SD card device name

Open a terminal and run:

```bash
lsblk
```

Look for your SD card in the output. It will look something like this:

```
sdb      8:16   1  29.7G  0 disk
├─sdb1   8:17   1   512M  0 part  /run/media/yourname/bootfs
└─sdb2   8:18   1  29.2G  0 part  /run/media/yourname/rootfs
```

Your SD card device is the disk entry — in this example **`/dev/sdb`**.
The two partitions (`sdb1`, `sdb2`) are the boot and root filesystems.

> **How to tell it's the right device:** it should be roughly the size of
> your SD card, have two partitions, and one of them will be labelled
> `bootfs` or `rootfs`. **Do not pick your main system drive.**

---

#### Step 3 — Run the preparation script

Clone this repo if you haven't already:

```bash
git clone https://github.com/TheRealBastioul/ghostpi.git
cd ghostpi
```

Then run the script as root, using the device name you found above:

```bash
# Replace /dev/sdb with YOUR device name from Step 2
sudo bash setup/prepare-sd.sh --device /dev/sdb
```

The script will automatically detect whether your system has already
auto-mounted the SD card partitions (Linux desktops often do this on
insert) and work with them either way — you don't need to unmount anything.

This will take **5–15 minutes** depending on your internet speed. You will
see progress output as it downloads packages and installs everything.

---

#### Step 4 — Eject and boot

Once the script finishes, safely eject the SD card:

```bash
# Replace /dev/sdb with your device name
sudo eject /dev/sdb
```

Insert the SD card into your **Raspberry Pi Zero WH** and plug in power.
GhostPi will start automatically on first boot — nothing else to do.

---

### Method B — Direct install on the Pi (fallback)

Use this if you're installing onto a Pi that is already running and
has network access.

#### 1. Flash OS and SSH in

Flash Raspberry Pi OS Lite 32-bit, enable SSH on the boot partition, then:

```bash
ssh admin@<pi-ip>
```

#### 2. Clone and run the installer

```bash
git clone <your-repo-url> ~/ghostpi
cd ~/ghostpi
sudo bash setup/install.sh
```

#### 3. Append boot configuration

```bash
sudo cat setup/boot_config.txt >> /boot/firmware/config.txt
```

#### 4. Reboot

```bash
sudo reboot
```

---

## Accessing the Web UI over USB

1. Connect the Pi Zero to your laptop via the **data Micro-USB port**
   (the port closer to the HDMI jack; *not* the PWR port).

2. The Pi will appear as a USB ethernet adapter.  Your OS should
   auto-configure via DHCP – your laptop will receive an IP in
   `192.168.7.0/24`.

3. Open **http://192.168.7.1** in a browser.

4. If the page doesn't load, check that the interface is up:
   ```bash
   # On Linux
   ip link show  # look for usb0 or enp0s20u1 etc.

   # On macOS
   ifconfig | grep -A4 "RNDIS\|ECM"
   ```

### Windows driver note

Windows may need an RNDIS/USB-ethernet driver.  A `linux.inf` driver file
is available from the Raspberry Pi foundation or you can use the "Remote
NDIS Compatible Device" driver built into Windows 10+.

---

## Operating modes

Switch modes with **GPIO 5** (left button on bonnet).

| Mode | Description | GPIO 6 action |
|------|-------------|---------------|
| `PASSIVE` | Listen-only, no transmit | Force e-ink refresh |
| `ACTIVE`  | Enables deauth (requires `ACTIVE_MODE_ENABLED=True`) | Send deauth burst to selected target |
| `REVIEW`  | Page through captured networks on e-ink display | Next network |

Active mode is gated by two independent checks:
1. `ACTIVE_MODE_ENABLED = True` in `ghostpi/config.py`
2. The check is repeated at the moment the deauth command runs

---

## Enabling active mode (authorized engagements only)

Edit `ghostpi/config.py`:

```python
ACTIVE_MODE_ENABLED = True   # set only under written authorization
```

Then restart the service:

```bash
sudo systemctl restart ghostpi
```

Select a target network from the web UI at http://192.168.7.1, then
press GPIO 6 to send a deauth burst.

---

## File layout

```
ghostpi/
├── setup/
│   ├── prepare-sd.sh       host-side SD card installer (primary)
│   ├── install.sh          on-Pi installer (fallback)
│   ├── repair.sh           on-Pi repair / reinstall tool
│   └── boot_config.txt     /boot/firmware/config.txt additions
├── ghostpi/
│   ├── config.py           central config
│   ├── main.py             entry point
│   ├── display.py          e-ink display manager (SSD1680 / GDEY0213B74)
│   ├── capture.py          airodump-ng wrapper and CSV parser
│   ├── buttons.py          GPIO button handler
│   └── webui/
│       ├── app.py          Flask web application
│       └── templates/
│           └── index.html  dashboard UI
├── systemd/
│   └── ghostpi.service     systemd unit file
├── logs/                   capture files (auto-created)
│   └── handshakes/
└── README.md
```

---

## Service management

```bash
# Check status / recent logs
sudo systemctl status ghostpi
journalctl -u ghostpi -f

# Start / stop / restart
sudo systemctl start ghostpi
sudo systemctl stop ghostpi
sudo systemctl restart ghostpi

# Disable autostart
sudo systemctl disable ghostpi
```

---

## Captured data

Capture files are written to `~/ghostpi/logs/`:

| File | Contents |
|------|----------|
| `capture-<ts>-01.csv` | Networks + clients (airodump-ng CSV) |
| `capture-<ts>-01.cap` | Full PCAP including WPA handshakes |
| `ghostpi.log`         | Application log |

Download any file from the web UI's **Capture Files** section.

To inspect a PCAP for WPA handshakes:

```bash
aircrack-ng logs/capture-*-01.cap
```

---

## Configuration reference (`ghostpi/config.py`)

| Key | Default | Description |
|-----|---------|-------------|
| `ACTIVE_MODE_ENABLED` | `False` | Master switch for transmit/attack features |
| `WIFI_INTERFACE` | `wlan0` | Physical wireless interface |
| `MON_INTERFACE` | `wlan0mon` | Monitor-mode interface (created by airmon-ng) |
| `DISPLAY_Y_OFFSET` | `16` | GDEY0213B74 gate memory offset (pixels) |
| `DISPLAY_REFRESH_INTERVAL` | `30` | Seconds between e-ink refreshes |
| `BUTTON_MODE_PIN` | `5` | BCM GPIO for mode-cycle button |
| `BUTTON_ACTION_PIN` | `6` | BCM GPIO for action button |
| `DEAUTH_COUNT` | `5` | Frames per deauth burst (active mode) |
| `WEBUI_HOST` | `192.168.7.1` | Web UI bind address |
| `WEBUI_PORT` | `80` | Web UI port |

---

## Troubleshooting

**E-ink display blank or content shifted**
The GDEY0213B74 has a 16-pixel gate memory offset.  If content appears
off-screen, adjust `DISPLAY_Y_OFFSET` in `config.py`.

**Monitor mode fails**
Some internal Pi WiFi firmware builds block monitor mode.  Try an
external USB WiFi adapter that supports monitor mode (e.g. Alfa AWUS036ACH)
and update `WIFI_INTERFACE` and `MON_INTERFACE` in `config.py`.

**Web UI unreachable**
- Confirm you're on the *data* USB port (not the power port).
- Check `ip link` for the `usb0` interface on the Pi: `ip addr show usb0`.
- Check dnsmasq: `journalctl -u dnsmasq -f`.
- Your laptop may show the interface as RNDIS/ECM – verify it obtained
  a `192.168.7.x` address.

**airodump-ng writes no CSV**
Confirm the monitor interface exists: `iwconfig wlan0mon`.  If missing,
run `sudo airmon-ng start wlan0` manually and check for driver errors.
