"""
GhostPi central configuration.

LEGAL NOTICE: This tool is designed for authorized security assessments,
penetration testing on networks you own or have explicit written permission
to test, and educational/CTF environments. Unauthorized interception of
network traffic and deauthentication attacks are illegal in most jurisdictions
under laws such as the CFAA (US), Computer Misuse Act (UK), and equivalents.

The ACTIVE_MODE_ENABLED flag must be set to True only when operating under
a valid scope-of-work or rules-of-engagement document.
"""

import os

# ── Authorization gate ────────────────────────────────────────────────────────
# ACTIVE_MODE_ENABLED=False disables all transmit/attack capabilities.
# Set to True ONLY during authorized penetration tests.
ACTIVE_MODE_ENABLED = False

# ── Wireless interface ────────────────────────────────────────────────────────
WIFI_INTERFACE = "wlan0"          # physical interface
MON_INTERFACE = "wlan0mon"        # monitor-mode interface (created by airmon-ng)

# ── Filesystem paths ─────────────────────────────────────────────────────────
BASE_DIR = os.path.expanduser("~/ghostpi")
LOG_DIR = os.path.join(BASE_DIR, "logs")
CAPTURE_PREFIX = os.path.join(LOG_DIR, "capture")   # airodump-ng file prefix
HANDSHAKE_DIR = os.path.join(LOG_DIR, "handshakes")

# ── Display (Adafruit 2.13" e-ink bonnet, SSD1680 / GDEY0213B74) ─────────────
DISPLAY_WIDTH = 250       # visible pixels, landscape
DISPLAY_HEIGHT = 122      # visible pixels, landscape
# The GDEY0213B74 variant has a 16-line gate offset in SSD1680 memory.
# The first 16 rows of the SSD1680 frame buffer map to off-screen memory;
# visible content starts at row 16.  display.py compensates for this.
DISPLAY_Y_OFFSET = 16
DISPLAY_REFRESH_INTERVAL = 30    # seconds between full e-ink refreshes

# SPI / GPIO pins (Adafruit 2.13" bonnet default wiring on Pi GPIO header)
EPD_CS_PIN   = 8    # BCM GPIO 8  (SPI0 CE0)
EPD_DC_PIN   = 22   # BCM GPIO 22
EPD_RST_PIN  = 17   # BCM GPIO 17
EPD_BUSY_PIN = 4    # BCM GPIO 4

# ── Buttons (Adafruit bonnet) ─────────────────────────────────────────────────
BUTTON_MODE_PIN    = 5   # BCM GPIO 5 – cycles mode (passive → active → review)
BUTTON_ACTION_PIN  = 6   # BCM GPIO 6 – context-sensitive action

# Button debounce time in milliseconds
BUTTON_DEBOUNCE_MS = 300

# ── Operating modes ───────────────────────────────────────────────────────────
MODE_PASSIVE = "passive"   # listen only, no transmit
MODE_ACTIVE  = "active"    # deauth / injection (requires ACTIVE_MODE_ENABLED)
MODE_REVIEW  = "review"    # browse captured data on e-ink display
MODES = [MODE_PASSIVE, MODE_ACTIVE, MODE_REVIEW]

# ── Web UI ────────────────────────────────────────────────────────────────────
WEBUI_HOST = "192.168.7.1"   # USB gadget (usb0) interface IP
WEBUI_PORT = 80

# ── Capture settings ──────────────────────────────────────────────────────────
# Channel hopping interval for airodump-ng (seconds).  None = airodump default.
CHANNEL_HOP_INTERVAL = None

# How many recent probe requests to keep in memory per station.
MAX_PROBES_PER_STA = 10

# ── Deauth settings (active mode only) ───────────────────────────────────────
# Number of deauth frames per burst.  Keep low to avoid detection.
DEAUTH_COUNT = 5
