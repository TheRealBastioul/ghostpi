"""
GhostPi e-ink display manager.

Hardware: Adafruit 2.13" Monochrome E-Ink Bonnet (SSD1680 driver).
Panel variant: GDEY0213B74 – 250×122 visible pixels, landscape.

GDEY0213B74 memory offset note:
  The SSD1680 controller has 296 source and 128 gate lines of frame buffer.
  The GDEY0213B74 panel uses only 122 gate lines but the memory window starts
  at gate address 16, not 0.  We compensate by creating a 250×128 pixel
  canvas and beginning all content at row DISPLAY_Y_OFFSET (16).  Rows 0-15
  are left blank and fall outside the panel's visible gate range.
"""

import time
import threading
import logging
import textwrap

log = logging.getLogger(__name__)

try:
    import board
    import busio
    import digitalio
    from adafruit_epd.ssd1680 import Adafruit_SSD1680
    from PIL import Image, ImageDraw, ImageFont
    EPD_AVAILABLE = True
except ImportError:
    log.warning("E-ink / PIL libraries not available – display running in stub mode")
    EPD_AVAILABLE = False

from config import (
    DISPLAY_WIDTH, DISPLAY_HEIGHT, DISPLAY_Y_OFFSET, DISPLAY_REFRESH_INTERVAL,
    EPD_CS_PIN, EPD_DC_PIN, EPD_RST_PIN, EPD_BUSY_PIN,
    MODE_PASSIVE, MODE_ACTIVE, MODE_REVIEW,
    ACTIVE_MODE_ENABLED,
)

# Full SSD1680 memory height for GDEY0213B74 (gate lines)
_MEM_HEIGHT = DISPLAY_HEIGHT + DISPLAY_Y_OFFSET  # 122 + 16 = 138, padded to 128
# The SSD1680 physical gate max is 296; 128 is the nearest power-of-2 ≥ 122+16.
# In practice adafruit_epd handles gate sizing internally; we just offset drawing.


class DisplayManager:
    """Thread-safe e-ink display manager."""

    def __init__(self, state: dict, state_lock: threading.Lock):
        """
        Args:
            state:      Shared application state dict (updated by capture daemon).
            state_lock: Lock protecting ``state``.
        """
        self._state = state
        self._lock = state_lock
        self._epd = None
        self._stop_event = threading.Event()
        self._thread = None
        self._last_refresh = 0.0

        if EPD_AVAILABLE:
            self._init_display()

    # ── Initialisation ────────────────────────────────────────────────────────

    def _init_display(self):
        """Initialise the SSD1680 via hardware SPI."""
        try:
            spi = busio.SPI(board.SCK, MOSI=board.MOSI, MISO=board.MISO)

            cs   = digitalio.DigitalInOut(getattr(board, f"D{EPD_CS_PIN}"))
            dc   = digitalio.DigitalInOut(getattr(board, f"D{EPD_DC_PIN}"))
            rst  = digitalio.DigitalInOut(getattr(board, f"D{EPD_RST_PIN}"))
            busy = digitalio.DigitalInOut(getattr(board, f"D{EPD_BUSY_PIN}"))

            # Adafruit_SSD1680(height, width, spi, ...)
            # We pass DISPLAY_HEIGHT (122) – the driver uses this for gate sizing.
            # The GDEY0213B74 Y offset is handled by our canvas offset below.
            self._epd = Adafruit_SSD1680(
                DISPLAY_HEIGHT,
                DISPLAY_WIDTH,
                spi,
                cs_pin=cs,
                dc_pin=dc,
                sramcs_pin=None,
                rst_pin=rst,
                busy_pin=busy,
            )
            self._epd.rotation = 1   # landscape
            log.info("E-ink display initialised (SSD1680 / GDEY0213B74)")
        except Exception as exc:
            log.error("Display init failed: %s", exc)
            self._epd = None

    # ── Canvas helpers ────────────────────────────────────────────────────────

    def _new_canvas(self):
        """
        Return a blank white PIL Image sized for the full SSD1680 memory canvas.

        The image is DISPLAY_WIDTH × (DISPLAY_HEIGHT + DISPLAY_Y_OFFSET).
        All drawing helpers add DISPLAY_Y_OFFSET to the y coordinate so that
        content aligns with the GDEY0213B74 visible gate window.
        """
        return Image.new("1", (DISPLAY_WIDTH, DISPLAY_HEIGHT + DISPLAY_Y_OFFSET), 1)

    @staticmethod
    def _y(row: int) -> int:
        """Translate a logical display row to the memory-offset canvas row."""
        return row + DISPLAY_Y_OFFSET

    def _load_font(self, size: int = 10):
        """Load a truetype font or fall back to PIL default."""
        try:
            return ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", size)
        except Exception:
            return ImageFont.load_default()

    # ── Rendering ─────────────────────────────────────────────────────────────

    def _render(self, state_snapshot: dict) -> Image.Image:
        """
        Build the full display image from a snapshot of application state.

        Layout (250×122 visible, all y coords already offset internally):
          Row  0-14  : Header bar (mode, signal icon)
          Row 15     : Separator
          Row 16-70  : Stats block (networks, clients, probes, handshakes)
          Row 71-100 : Status / last-seen ESSID
          Row 101-121: Scrolling status message
        """
        canvas = self._new_canvas()
        draw   = ImageDraw.Draw(canvas)

        font_sm  = self._load_font(9)
        font_med = self._load_font(11)
        font_lg  = self._load_font(14)

        mode        = state_snapshot.get("mode", MODE_PASSIVE)
        net_count   = state_snapshot.get("network_count", 0)
        cli_count   = state_snapshot.get("client_count", 0)
        probe_count = state_snapshot.get("probe_count", 0)
        hs_count    = state_snapshot.get("handshake_count", 0)
        status_msg  = state_snapshot.get("status_message", "Initialising...")
        last_essid  = state_snapshot.get("last_essid", "")

        # ── Header bar ────────────────────────────────────────────────────────
        # Invert header: filled black rectangle, white text
        draw.rectangle([(0, self._y(0)), (DISPLAY_WIDTH - 1, self._y(13))], fill=0)

        mode_label = f"[{mode.upper()}]"
        if mode == MODE_ACTIVE and not ACTIVE_MODE_ENABLED:
            mode_label += " LOCKED"
        draw.text((4, self._y(1)), "GhostPi", font=font_lg, fill=1)
        draw.text((DISPLAY_WIDTH - 80, self._y(3)), mode_label, font=font_sm, fill=1)

        # ── Separator ─────────────────────────────────────────────────────────
        draw.line([(0, self._y(14)), (DISPLAY_WIDTH - 1, self._y(14))], fill=0)

        # ── Stats block ───────────────────────────────────────────────────────
        stats = [
            ("Networks",    net_count,   16),
            ("Clients",     cli_count,   30),
            ("Probes",      probe_count, 44),
            ("Handshakes",  hs_count,    58),
        ]
        for label, value, row in stats:
            draw.text((4, self._y(row)), f"{label}:", font=font_sm, fill=0)
            draw.text((90, self._y(row)), str(value), font=font_med, fill=0)

        # ── Last-seen ESSID ───────────────────────────────────────────────────
        if last_essid:
            draw.line([(0, self._y(72)), (DISPLAY_WIDTH - 1, self._y(72))], fill=0)
            essid_display = last_essid[:28] if len(last_essid) > 28 else last_essid
            draw.text((4, self._y(74)), f"Last: {essid_display}", font=font_sm, fill=0)

        # ── Status message (word-wrapped) ─────────────────────────────────────
        draw.line([(0, self._y(86)), (DISPLAY_WIDTH - 1, self._y(86))], fill=0)
        wrapped = textwrap.wrap(status_msg, width=35)
        for i, line in enumerate(wrapped[:3]):   # max 3 lines in the status area
            draw.text((4, self._y(89 + i * 10)), line, font=font_sm, fill=0)

        # ── Timestamp (bottom-right corner) ──────────────────────────────────
        ts = time.strftime("%H:%M")
        draw.text((DISPLAY_WIDTH - 32, self._y(112)), ts, font=font_sm, fill=0)

        return canvas

    def refresh(self, force: bool = False):
        """Push the current state to the e-ink panel."""
        with self._lock:
            snapshot = dict(self._state)

        image = self._render(snapshot)

        if not EPD_AVAILABLE or self._epd is None:
            log.debug("Display stub: would refresh now (mode=%s)", snapshot.get("mode"))
            return

        try:
            # Crop the canvas back to visible height before sending to driver.
            # The driver expects DISPLAY_HEIGHT rows; we strip the offset padding.
            visible = image.crop((0, DISPLAY_Y_OFFSET,
                                  DISPLAY_WIDTH, DISPLAY_Y_OFFSET + DISPLAY_HEIGHT))
            self._epd.image(visible)
            self._epd.display()
            self._last_refresh = time.monotonic()
            log.debug("Display refreshed")
        except Exception as exc:
            log.error("Display refresh error: %s", exc)

    # ── Thread lifecycle ──────────────────────────────────────────────────────

    def _run(self):
        """Background loop: refresh display on interval or state change."""
        self.refresh(force=True)
        while not self._stop_event.is_set():
            elapsed = time.monotonic() - self._last_refresh
            if elapsed >= DISPLAY_REFRESH_INTERVAL:
                self.refresh()
            self._stop_event.wait(timeout=5)   # check every 5 s

    def start(self):
        """Start the display refresh thread."""
        self._thread = threading.Thread(target=self._run, name="display", daemon=True)
        self._thread.start()
        log.info("Display manager started")

    def stop(self):
        """Signal the display thread to stop."""
        self._stop_event.set()
        if self._thread:
            self._thread.join(timeout=10)
        log.info("Display manager stopped")
