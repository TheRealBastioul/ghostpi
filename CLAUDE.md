# CLAUDE.md — GhostPi project context

This file is read automatically by Claude Code at the start of every session.
Use it to get up to speed without re-exploring the codebase from scratch.

---

## What this project is

GhostPi is a passive WiFi reconnaissance tool for authorized security assessments.
It runs on a Raspberry Pi Zero WH with an Adafruit 2.13" e-ink bonnet (SSD1680 /
GDEY0213B74 panel).  It captures 802.11 management frames via airodump-ng and
serves a live dashboard over USB ethernet gadget (usb0 → 192.168.7.1).

Active mode (deauth) is **disabled by default** and gated by two independent
checks in `ghostpi/config.py` (`ACTIVE_MODE_ENABLED = False`) and in the
runtime code.  Never enable it without explicit written authorization.

---

## Architecture

Four threads, one shared state dict protected by `threading.Lock`:

| Thread | File | Role |
|--------|------|------|
| CaptureDaemon | `ghostpi/capture.py` | Runs airodump-ng, parses CSV every 30s |
| DisplayManager | `ghostpi/display.py` | SSD1680 e-ink via SPI, refreshes every 30s |
| ButtonHandler | `ghostpi/buttons.py` | GPIO 5 (mode cycle) · GPIO 6 (action) |
| Flask web UI | `ghostpi/webui/app.py` | Binds to 192.168.7.1:80 over usb0 only |

Entry point: `ghostpi/main.py`.  Config: `ghostpi/config.py`.

The service runs as **root** (required for raw WiFi socket / monitor mode).
WorkingDirectory is `/home/admin/ghostpi`.

---

## Key hardware details

- Pi Zero WH — ARMv6 (armhf), single core 1 GHz, 512 MB RAM
- E-ink panel has a **16-pixel gate memory offset** — `DISPLAY_Y_OFFSET = 16` in
  config.py compensates for this.  Do not remove it.
- SPI pins: CS=8, DC=22, RST=17, BUSY=4
- Buttons: MODE=GPIO5, ACTION=GPIO6 (on the bonnet, no external wiring)
- USB OTG data port (not the power port) provides the usb0 interface

---

## File layout

```
ghostpi/
├── CLAUDE.md                   this file
├── README.md                   user-facing docs
├── ghostpi/
│   ├── config.py               all tuneable constants
│   ├── main.py                 entry point, starts all threads
│   ├── capture.py              airodump-ng wrapper + CSV parser
│   ├── display.py              SSD1680 e-ink driver
│   ├── buttons.py              GPIO interrupt handler
│   └── webui/
│       ├── app.py              Flask routes + JSON API
│       └── templates/index.html  dashboard UI
├── setup/
│   ├── prepare-sd.sh           PRIMARY installer — runs on Linux host, not Pi
│   ├── install.sh              fallback — runs directly on Pi via SSH
│   ├── repair.sh               on-Pi repair tool (no apt/pip, runs in seconds)
│   └── boot_config.txt         appended to /boot/firmware/config.txt
└── systemd/
    └── ghostpi.service         systemd unit (User=root, Restart=always)
```

---

## Installation overview

**Primary path** — SD card prep on a Linux machine before first boot:
```bash
sudo bash setup/prepare-sd.sh --device /dev/sdX
```
Uses QEMU ARM chroot to install armhf packages directly into the SD card
rootfs.  Pi boots fully configured with no SSH install step.

**Fallback** — direct install on a running Pi:
```bash
sudo bash setup/install.sh
```

**Repair** — fix a broken install on a running Pi (no internet needed):
```bash
sudo bash ~/ghostpi/setup/repair.sh           # full repair
sudo bash ~/ghostpi/setup/repair.sh --status  # diagnostics only
```

---

## Dependencies

**apt (armhf):** aircrack-ng, python3, python3-pip, python3-dev, python3-rpi.gpio,
python3-pillow, python3-flask, dnsmasq, iw, wireless-tools, net-tools,
libopenjp2-7, fonts-dejavu-core

**pip:** adafruit-circuitpython-epd, adafruit-circuitpython-ssd1680

---

## Networking

| Interface | IP | Purpose |
|-----------|----|---------|
| wlan0 | (scanning only) | put into monitor mode as wlan0mon |
| usb0 | 192.168.7.1/24 | USB ethernet gadget — operator dashboard access |

dnsmasq hands out 192.168.7.2–192.168.7.10 to the connected laptop.
Configured via `/etc/dnsmasq.d/ghostpi-usb.conf`.
Static IP via `/etc/dhcpcd.conf` (interface usb0 block).

---

## Common debug commands (on the Pi)

```bash
journalctl -u ghostpi -f            # live app log
journalctl -u dnsmasq -f            # DHCP log
systemctl status ghostpi            # service state
ip addr show usb0                   # USB interface IP
iwconfig wlan0mon                   # confirm monitor mode is up
sudo airmon-ng start wlan0          # manually start monitor mode
```

---

## Known quirks

- `DISPLAY_Y_OFFSET = 16` — GDEY0213B74 panel gate memory offset.  Content
  renders 16px low without it.  Do not "fix" this.
- `g_ether` module must load at boot via cmdline.txt (`modules-load=dwc2,g_ether`).
  If usb0 is missing after boot, this line is likely absent from cmdline.txt.
- On Bookworm, boot files are at `/boot/firmware/` on the Pi, but the first SD
  partition root when mounted on a Linux host — prepare-sd.sh handles both.
- `pip3 install --break-system-packages` is intentional on Bookworm for the
  adafruit libraries.  The Pi is a dedicated appliance, not a shared system.

---

## Changelog

### 2026-04-17

**Redesigned installation to be SD-card-first (host-side prep)**

Problem: `apt` + `pip` on Pi Zero is painfully slow and requires the Pi to have
network access on first boot.

**`setup/prepare-sd.sh` (new — primary installer)**
- Runs on a Linux host machine with the SD card mounted
- Spins up a QEMU ARM chroot (`qemu-user-static` + `binfmt-support`) against
  the SD card's root partition
- Downloads and installs all armhf apt packages into the chroot
- Installs pip packages inside the chroot
- Copies GhostPi app files via tar (excludes .git, logs, __pycache__)
- Writes dhcpcd static IP config and dnsmasq DHCP config directly to rootfs
- Installs ghostpi.service and dnsmasq.service by creating the systemd
  `multi-user.target.wants/` symlinks manually (no systemctl needed)
- Appends boot_config.txt to config.txt and adds `modules-load=dwc2,g_ether`
  to cmdline.txt on the boot partition
- Usage: `sudo bash setup/prepare-sd.sh --device /dev/sdX [--user <name>]`
- Also accepts `--boot` / `--root` if partitions are already mounted

**`setup/repair.sh` (new — on-Pi repair tool)**
- Runs on the Pi via SSH after boot; no apt/pip so it completes in seconds
- `--status` mode: read-only diagnostics (service state, usb0 IP, aircrack-ng
  tools, Python package importability, config file presence, last 10 log lines)
- Full repair (default): stops service, kills stray airodump-ng/airmon-ng
  processes, removes stuck wlan0mon if wedged, reinstalls systemd unit,
  rewrites dnsmasq config, patches dhcpcd if usb0 entry is missing, patches
  boot config if OTG/SPI settings are absent, restarts everything, prints
  final status
- Directs user to `prepare-sd.sh` if the issue is broken packages

**`README.md` (updated)**
- Installation section restructured: Method A (prepare-sd.sh, primary) and
  Method B (install.sh, fallback)
- File layout table updated with new scripts
