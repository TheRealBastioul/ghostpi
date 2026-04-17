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
The Pi just boots and runs — no SSH install step, no waiting for `apt` on
the Pi Zero's slow single core.

**Requirements:** Debian/Ubuntu Linux host with root access.
`qemu-user-static` and `binfmt-support` are installed automatically.

#### 1. Flash the OS

Flash **Raspberry Pi OS Lite 32-bit** (Trixie / 2026-04-13 release)
to a microSD card using [Raspberry Pi Imager](https://www.raspberrypi.com/software/).

In Imager's **advanced options** (gear icon):
- Set hostname, username (`admin`), and password
- Optionally enable SSH if you want remote access later

Do **not** eject the SD card yet.

#### 2. Run the host-side preparation script

```bash
# Identify your SD card device — check dmesg or lsblk after inserting
lsblk

# Run as root (replace /dev/sdX with your actual device)
sudo bash setup/prepare-sd.sh --device /dev/sdX
```

If you have already mounted the partitions yourself:

```bash
sudo bash setup/prepare-sd.sh --boot /mnt/sdboot --root /mnt/sdroot
```

This script will:
1. Install `qemu-user-static` on your host (for ARM emulation)
2. Download and install all apt packages into the SD card rootfs via ARM chroot
3. Install Python packages (`adafruit-circuitpython-epd`, `ssd1680`)
4. Copy the GhostPi application to `/home/admin/ghostpi`
5. Write network configs (dhcpcd static IP, dnsmasq DHCP)
6. Install and enable the `ghostpi` and `dnsmasq` systemd services
7. Write `config.txt` and `cmdline.txt` boot settings

#### 3. Eject and boot

```bash
sudo eject /dev/sdX
```

Insert the SD card into the Pi Zero WH and power on.
GhostPi starts automatically — no further setup required.

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
