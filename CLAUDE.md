# CLAUDE.md — GhostPi project context

This file is read automatically by Claude Code at the start of every session.
Use it to get up to speed without re-exploring the codebase from scratch.

> **Standing instruction:** Before ending any session, update the Changelog
> section at the bottom of this file with a dated `### YYYY-MM-DD (session N)`
> entry covering every file changed, what was wrong, and what was done — then
> commit and push it along with the rest of the changes.  Do this automatically
> without being asked.

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
- SPI pins: CS=CE0(GPIO8), DC=22, RST=27, BUSY=17  (matches FPC-A002 board label: Busy=17, Reset=27)
- Driver: `Adafruit_SSD1680B` from `adafruit_epd.ssd1680b` — DO NOT use `Adafruit_SSD1680`; that is for the older panel and produces blank output on the GDEY0213B74
- The GDEY0213B74 16-pixel gate offset is handled inside `Adafruit_SSD1680B` — no application-level Y offset needed
- Canvas mode must be `"1"` (PIL 1-bit); convert with `.convert("L")` before passing to `epd.image()` — the EPD base class only accepts `"RGB"` or `"L"` mode
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

- `DISPLAY_Y_OFFSET = 16` — kept in config.py for reference only.  The offset
  is handled inside `Adafruit_SSD1680B`; application code renders to a plain
  250×122 canvas with no manual offset.
- `g_ether` module must load at boot via cmdline.txt (`modules-load=dwc2,g_ether`).
  If usb0 is missing after boot, this line is likely absent from cmdline.txt.
- On Trixie, boot files are at `/boot/firmware/` on the Pi, but the first SD
  partition root when mounted on a Linux host — prepare-sd.sh handles both.
- `pip3 install --break-system-packages` is intentional on Trixie for the
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

---

### 2026-04-17 (session 2)

**Performance and reliability fixes for Pi Zero WH**

All five application files were audited for blocking calls, CPU waste, and
thread-safety issues on the constrained single-core ARMv6 hardware.

**`ghostpi/capture.py`**
- `_count_handshakes()` was blocking the capture loop every 30s — spawned one
  `aircrack-ng` subprocess per PCAP (10s timeout each), growing worse over time.
  Now runs in a background daemon thread, rate-limited to once per 2 minutes
  (`_HS_CHECK_INTERVAL = 120`). Cached result in `self._hs_count`.
- Probe accumulation changed from `list[-MAX_PROBES_PER_STA:]` (allocates a new
  list on every parse cycle) to `deque(maxlen=MAX_PROBES_PER_STA)` — bounded by
  construction with zero per-cycle allocation.
- airodump-ng unexpected-restart path now has exponential backoff: 5s × restart
  count, capped at 60s. Prevents CPU thrash if the wireless card keeps crashing.
- `_publish_state()`: probes converted from deques to plain lists before writing
  to shared state so Flask can JSON-serialise them.

**`ghostpi/display.py`**
- Fonts (`self._font_sm`, `_font_md`, `_font_lg`) loaded once in `__init__`
  instead of 3× `ImageFont.truetype()` calls on every render.
- New `request_refresh()` method sets a `threading.Event` and returns
  immediately. GPIO callbacks now call this instead of `refresh()` directly,
  which was blocking the callback context for 1–3s during SPI e-ink I/O and
  causing button presses to be dropped during refresh.
- `_run()` loop replaced 5s polling (`_stop_event.wait(timeout=5)`) with a
  single `_refresh_requested.wait(timeout=DISPLAY_REFRESH_INTERVAL)` — wakes
  only on button press event or interval expiry, not every 5s.

**`ghostpi/buttons.py`**
- All 8 direct `self._display.refresh(force=True)` calls replaced with
  `self._display.request_refresh()` to unblock GPIO callback context.

**`ghostpi/main.py`**
- Main loop changed from `time.sleep(1)` (woke 60× per minute) to
  `self._stop_event.wait(timeout=30)` — wakes on signal or every 30s.
- `_handle_signal()` now sets `_stop_event` for immediate shutdown response.
- `_watchdog()` implemented: checks each critical thread (`capture`, `display`,
  `webui`) with `thread.is_alive()` and logs an error if one has died.

**`ghostpi/webui/app.py`**
- `_safe_state_copy()` was calling `json.dumps()` per-key on every `/api/data`
  poll. Replaced with a single `json.loads(json.dumps(state))` pass which also
  produces a proper deep copy, preventing Flask threads from seeing shared
  nested dict objects.

---

### 2026-04-17 (session 3)

**prepare-sd.sh: Kali compatibility, qemu-user-binfmt, minimum packages**

**`setup/prepare-sd.sh`**
- `qemu-user-static` is deprecated (2026). Replaced with `qemu-user-binfmt`
  as the primary method. Key difference: `qemu-user-binfmt` registers ARM
  binfmt entries using the kernel `F` (fix-binary) flag, meaning the host
  kernel holds a reference to the QEMU binary — no binary copy into the
  chroot needed. Chroot calls simplified from
  `chroot DIR /usr/bin/qemu-arm-static /bin/bash` to `chroot DIR /bin/bash`.
- `qemu-user-static` kept as an automatic fallback for older Ubuntu/Debian.
- `QEMU_METHOD` variable (`"binfmt"` or `"static"`) controls binary copy,
  chroot invocation, and cleanup throughout the script.
- `binfmt_misc` kernel module loaded/mounted automatically if not present.
- Resilient per-package apt install: `install_pkg()` tries primary name then
  ordered fallbacks, logs failures to a temp file, never aborts the script.
  `install_optional()` for nice-to-have packages that skip silently if absent.
- `python3-rpi.gpio` fallback chain: `→ python3-rpi-lgpio → python3-lgpio`
  (package was renamed in newer Raspberry Pi OS / Trixie releases).
- Moved `python3-dev`, `wireless-tools`, `net-tools` to optional — `iw` and
  `iproute2` (base package) cover modern kernels; dev headers only needed if
  pip needs to compile C extensions (unlikely with Trixie pre-built wheels).
- pip section wrapped in `set +e / set -e` — failure is reported in the
  final summary rather than killing the script mid-install.
- Final summary shows a warnings block listing any packages that failed,
  with exact commands to fix them on the Pi after first boot.
- README Method A instructions rewritten for new users: step-by-step format,
  `lsblk` output explained, auto-mount behaviour clarified, username warning.

---

### 2026-04-18 (session 4)

**On-demand capture — display and web UI survive independently of airmon-ng**

Root cause: airmon-ng/airodump-ng auto-starting on boot saturated the single
ARMv6 core, crashing the watchdog and taking down display and Flask with it.

**`ghostpi/capture.py`**
- `start()` is now a no-op (logs "ready") — no monitor mode or airodump-ng
  is launched at boot.
- Added `start_capture()`: resets stop event, sets `capture_running=True` in
  shared state, spawns capture thread. Safe to call repeatedly.
- Added `stop_capture()`: sets stop event, joins thread, sets
  `capture_running=False`. Called by button handler and on shutdown.
- Added `is_running()`: returns True if capture thread is alive.
- Removed auto-restart on airodump-ng unexpected exit — crashes log a warning
  and exit cleanly with a "press ACTION to restart" status message. Prevents
  the old CPU thrash loop where crashes triggered immediate restarts.
- `_run()` finally block always clears `capture_running` in shared state.

**`ghostpi/buttons.py`**
- Constructor gains `capture_daemon` parameter (wired from main.py).
- GPIO 6 in passive mode: was `_action_passive_refresh()` (display refresh
  only), now `_action_toggle_capture()` — starts capture if idle, stops it
  if running. Display refresh follows automatically.

**`ghostpi/main.py`**
- `build_initial_state()`: added `capture_running: False`; initial
  `status_message` changed from `"Starting up..."` to `"GhostPi Ready"` so
  the display shows a clean idle state before any capture is triggered.
- `ButtonHandler` construction now passes `self._capture` as `capture_daemon`.
- `create_app()` now passes `self._capture` so web UI routes can reach it.
- `_watchdog()`: rewritten to only check capture thread if `capture_running`
  is True in shared state. Display and Flask threads still always monitored.

**`ghostpi/display.py`**
- `_render()`: reads `capture_running` from state snapshot; when True, draws
  a small `"REC"` label in the header bar (white text, inverted background).

**`ghostpi/webui/app.py`**
- `create_app()` accepts optional `capture_daemon` parameter; stored in
  module-level `_capture`.
- `/api/status` now includes `capture_running` field.
- Added `POST /api/capture/start` and `POST /api/capture/stop` endpoints so
  the web dashboard can trigger capture without a physical button press.

---

### 2026-04-18 (session 5)

**CPU/RAM optimisation + display crash-hardening**

*(see previous entry — this was the session 5 changelog)*

---

### 2026-04-18 (session 6)

**Fix display not rendering + boot confirmation gate + SSH safety**

Root causes identified:
- `_init_display()` was called in `__init__` (main thread) — if SSD1680 BUSY
  pin never asserted, the entire process hung before any thread started
- Import block only caught `ImportError`; `board` module raises `RuntimeError`
  when not on Pi hardware, which propagated and crashed the display module
- Flask started automatically on boot with no user confirmation
- `network-online.target` dependency delayed service start up to 90 s on Pi
  Zero with no WiFi (usb0-only setups)
- `repair.sh` checked wrong Python module names (`adafruit_circuitpython_epd`
  instead of `adafruit_epd`)

**`ghostpi/display.py`**
- Import block now catches `Exception` (was `ImportError` only) — covers
  `RuntimeError` from `board` module, `AttributeError` from `busio`, etc.
  Logs the actual exception message so the operator knows what failed.
- `_init_display()` moved from `__init__` to start of `_run()` thread body.
  Main thread is no longer blocked if SPI/BUSY init hangs; display thread
  absorbs the hang independently while Flask and buttons start normally.
- `_render()`: status_message now splits on `\n` before `textwrap.wrap()` so
  explicit line breaks are preserved (needed for the boot prompt message).

**`ghostpi/buttons.py`**
- Added `_boot_confirm_event: threading.Event | None` field.
- Added `set_boot_mode(confirm_event)`: registers a one-shot boot-confirm
  handler. Next ACTION press fires the event and clears itself; all subsequent
  ACTION presses behave normally (capture toggle).

**`ghostpi/main.py`**
- `build_initial_state()`: `status_message` changed to
  `"Press ACTION (GPIO6)\nto start web UI"` — this is what the e-ink shows
  on first boot before anything else starts.
- `start()` split into three stages:
  1. Display + buttons start (e-ink shows boot prompt immediately)
  2. `_wait_for_boot_confirm()` blocks until GPIO6 pressed — Flask never
     starts until the operator is physically present
  3. Flask + capture-ready start; status updates to
     `"Ready — press ACTION to start capture"`
- Added `_wait_for_boot_confirm()` method.

**`ghostpi/systemd/ghostpi.service`**
- Removed `Wants=network-online.target` and `After=network-online.target
  network-online.target systemd-networkd.service`.
- Now only `After=network.target` — SSH and basic network services are up,
  but ghostpi no longer waits for the "online" check that can time out for
  90 s on a Pi Zero with only usb0.

**`setup/repair.sh`**
- Fixed Python package importability check: was incorrectly testing
  `adafruit_circuitpython_epd` (pip package name) instead of `adafruit_epd`
  (actual import name). Now checks `adafruit_epd`, `flask`, `RPi`, `PIL`.

---

### 2026-04-18 (session 7)

**Boot splash: e-ink shows "GhostPi — Booting" before main service starts**

**`ghostpi/splash.py` (new)**
- Standalone one-shot script that draws a boot screen to the SSD1680 and
  exits. Inlines all config constants — no import dependency on the rest of
  GhostPi. Any exception (missing library, SPI not ready) exits cleanly with
  a log message; the script never blocks or crashes the boot process.
- Renders: inverted header ("GhostPi | BOOTING"), "Initialising..." body,
  instruction text ("Web UI starts after button press (GPIO6)"), SSH hint
  ("SSH: 192.168.7.1 (usb0)").

**`systemd/ghostpi-splash.service` (new)**
- `Type=oneshot` — runs once and exits.
- `After=local-fs.target Before=ghostpi.service` — filesystems mounted,
  Python/fonts readable, runs before the main service.
- `Restart=no` — never restarts; a failed draw is non-fatal.
- `TimeoutStartSec=30` — generous allowance for slow first-boot SPI init.

**`setup/repair.sh`**
- Installs and enables `ghostpi-splash.service` alongside `ghostpi.service`.
- Status display now shows `ghostpi-splash` enabled/disabled state.

**`setup/prepare-sd.sh`**
- Copies and symlinks `ghostpi-splash.service` into the rootfs
  `multi-user.target.wants/` alongside the main service.

**CPU/RAM optimisation + display crash-hardening**

**`ghostpi/config.py`**
- `MAX_PROBES_PER_STA`: 20 → 10 (halves probe RAM, bounded by construction)

**`ghostpi/capture.py`**
- `time.sleep(DISPLAY_REFRESH_INTERVAL)` in parse loop → `_stop_event.wait(timeout=…)`:
  `stop_capture()` now unblocks immediately instead of waiting up to 30 s.
- `_find_csv()`: `glob.glob()` called only once per capture session; path cached
  in `self._csv_path` after first successful find. No more per-cycle filesystem
  glob.
- `_publish_state()`: removed `dict(self._networks)` and `dict(self._clients)`
  shallow copies — stored references directly in shared state. Flask
  deep-copies under the lock in `_safe_state_copy`; the intermediate shallow
  copies were wasted allocations every 30 s.
- Reset `_csv_path = None` in `start_capture()` so a new capture run starts
  fresh.

**`ghostpi/display.py`**
- `refresh()`: consolidated `_render()` call and SPI I/O inside a single
  top-level `try/except`. Previously `_render()` was called before the
  try block — any PIL exception killed the display thread permanently.
  Now the method truly never raises.
- `_run()`: replaced single-level loop with outer try/except so any unexpected
  exception sleeps 5 s and continues instead of exiting the thread. The
  display thread is now unkillable by any Python exception.

**`ghostpi/main.py`**
- Removed unused `import time` (left over from old `time.sleep(1)` main loop).
- Flask `threaded=True` → `threaded=False`: no per-request thread is spawned;
  requests queue and are served sequentially. Appropriate for a single
  operator; eliminates thread creation overhead on every HTTP request.
- `_watchdog()`: if the display thread dies despite the hardening above,
  the watchdog resets `_stop_event` and calls `display.start()` to restart it.

**`ghostpi/webui/templates/index.html`**
- `fetchAll()` consolidated from 5 parallel HTTP requests (`/api/status`,
  `/api/networks`, `/api/clients`, `/api/probes`, `/api/pcaps`) to a single
  `/api/data` call every 30 s (matches capture parse interval — data doesn't
  change faster). PCAP list fetched separately every 60 s (files rarely change).
  Result: from ~5 Flask invocations/15 s to ~1/30 s + 1/60 s.
- JS converts dict format from `/api/data` to sorted arrays client-side
  (networks sorted by power, probes flattened from MAC→[essid] dict).
- Added capture Start/Stop button in the header; calls `/api/capture/start`
  or `/api/capture/stop` and reflects live `capture_running` state with
  colour change.

---

### 2026-04-18 (session 8)

**Fix prepare-sd.sh config.txt not applying SPI and other settings**

Root cause: the boot config section used a single `if ! grep -q 'dtoverlay=dwc2'`
guard around the entire `boot_config.txt` append. If `dtoverlay=dwc2` was already
present for any reason, `dtparam=spi=on` and all other settings were silently
skipped — leaving the Pi with no SPI (e-ink won't work) and no Bluetooth/LED
suppression.

**`setup/prepare-sd.sh`**
- Replaced the single guarded block with a per-setting idempotent loop: reads
  every non-comment, non-blank line from `boot_config.txt`, extracts the key
  (`KEY="${line%%=*}"`), checks `grep -q "^${KEY}" config.txt`, and appends only
  if missing. Safe to re-run; reports how many settings were added.
- `cmdline.txt` handling was already correct (separate idempotent check).
- All other automation (custom.toml, ssh flag, dhcpcd, dnsmasq, systemd symlinks)
  was already correct — no manual user steps needed for any of these.

---

### 2026-04-18 (session 10)

**SSH on SD card, gadget mode UX, display preview tool, sdcard repair script**

**`setup/prepare-sd.sh`**
- Enables SSH automatically: touches `ssh` boot flag, creates systemd symlink
  for `ssh.service`/`sshd.service`, writes `userconf.txt` with default
  credentials (`admin` / `ghostpi`), writes `sshd_config.d/ghostpi.conf`
  to permit password auth. No longer requires Raspberry Pi Imager or
  manual post-boot steps for SSH access.

**`setup/sdcard-repair.sh` (new)**
- Host-side SD card repair script — run from Linux with SD card mounted,
  no Pi or network required.
- `--status` mode: read-only check of SSH flag, sshd symlink, cmdline.txt,
  config.txt, dhcpcd.conf, dnsmasq config, app files.
- Repair mode (default): fixes all of the above, resets SSH credentials,
  copies app files if missing.
- Accepts `--device /dev/sdX`, `--boot /path --root /path`, or auto-detects
  mounted partitions under `/media/` and `/mnt/`.

**`tools/preview-display.py` (new)**
- Standalone PNG renderer — no Pi hardware, no adafruit libs required.
- Duplicates the PIL rendering logic from `display.py`; renders a 250×122
  image and saves it scaled 4× for easy viewing.
- `--demo`: render with fake capture data.
- `--status`, `--mode`, `--capture`, `--networks`, etc.: custom state.
- Useful for: testing layout changes, verifying message text fits,
  troubleshooting display rendering without access to the Pi.

**`ghostpi/splash.py`**
- Boot splash redesigned: shows "Configuring USB gadget...", SSH address
  (`ssh admin@192.168.7.1`), and "Press ACTION (GPIO6) to start Web UI".
  Operator sees exactly what to do and how to connect before anything else.

**`ghostpi/main.py`**
- Boot status message (shown on e-ink after services start):
  `"USB gadget active\nSSH: 192.168.7.1\nPress ACTION → Web UI"`
- Post-confirm status: `"Web UI: 192.168.7.1:80\nPress ACTION to capture"`

---

### 2026-04-18 (session 9)

**Fix e-ink display: wrong driver class, wrong image mode, missing blinka/lgpio**

Root cause analysis against official Adafruit product page (product 4687) and
GitHub source for `Adafruit_CircuitPython_EPD`:

1. **Wrong driver class** — code used `Adafruit_SSD1680` (older panel). The
   GDEY0213B74 shipped since Aug 2024 requires `Adafruit_SSD1680B` from
   `adafruit_epd.ssd1680b`. The two drivers have different init sequences,
   different RAM address setup, and different display-update control bytes.
   Using `Adafruit_SSD1680` on a GDEY0213B74 produces a blank display.

2. **Wrong image mode** — canvas was `Image.new("1", ...)` (1-bit PIL mode).
   The EPD base `image()` method only accepts `"RGB"` or `"L"` and raises
   `ValueError` for anything else. That error was silently swallowed by the
   `except Exception` in `refresh()`, so nothing ever rendered.
   Fix: call `.convert("L")` before `epd.image()`.

3. **Y offset no longer needed at application level** — `Adafruit_SSD1680B`
   handles the 16-pixel GDEY0213B74 gate offset internally. Removed the
   250×138 canvas, the `_y()` helper, and the pre-send crop. Canvas is now
   a plain 250×122 image.

4. **CS pin** — changed from `board.D8` to `board.CE0` to match the official
   Adafruit example and use the proper blinka SPI chip-select constant.

**`ghostpi/display.py`**
- Import `Adafruit_SSD1680B` (was `Adafruit_SSD1680`)
- `_init_display()`: use `Adafruit_SSD1680B`, `board.CE0` for CS
- `_new_canvas()`: 250×122 (was 250×138)
- Removed `_y()` helper; all row coordinates now direct integers
- `refresh()`: `epd.image(image.convert("L"))` — no crop, correct mode

**`ghostpi/splash.py`**
- Import `Adafruit_SSD1680B`; instantiate with same args
- Canvas 250×122, `y=0`; `draw_splash().convert("L")` before `epd.image()`

**`ghostpi/config.py`**
- `DISPLAY_Y_OFFSET` kept but annotated as reference-only (not used in rendering)

**`setup/diag-display.sh`**
- Updated to test `Adafruit_SSD1680B` import and init

### 2026-04-18 (session 8)

**E-ink display pin fix + install dependency audit**

Root causes investigated after display showing nothing on boot:

**`ghostpi/config.py`**
- `EPD_RST_PIN` corrected 17→27, `EPD_BUSY_PIN` corrected 4→17. The FPC-A002
  board label clearly states Busy=17, Reset=27 — the previous values had them
  swapped.

**`ghostpi/splash.py`**
- Same RST/BUSY pin correction applied (inlines constants independently of
  config.py).

**`setup/install.sh`** and **`setup/prepare-sd.sh`**
- Removed `adafruit-circuitpython-ssd1680` (redundant — the `ssd1680` module
  lives inside `adafruit-circuitpython-epd`; the separate package is an unrelated
  newer standalone driver and is not imported anywhere).
- Added `adafruit-blinka` explicitly (was only an implicit transitive dep; on
  Pi OS Trixie with `--break-system-packages`, transitive deps can be skipped).
- Added `rpi-lgpio` pip package — Pi OS Trixie deprecated `RPi.GPIO`; blinka
  needs `lgpio` or `rpi-lgpio` as its GPIO backend on Trixie.

**`setup/diag-display.sh` (new)**
- Standalone diagnostic script: checks SPI device nodes, config.txt flags,
  individual library imports (board, busio, digitalio, adafruit_epd, PIL),
  per-pin accessibility via `digitalio.DigitalInOut`, and a full
  `Adafruit_SSD1680` init attempt with traceback on failure.
