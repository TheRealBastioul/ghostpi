"""
GhostPi e-ink display manager.

Hardware: Adafruit 2.13" Monochrome E-Ink Bonnet for Raspberry Pi (product 4687).
Panel variant: GDEY0213B74 – 250×122 visible pixels, landscape.
Driver: Adafruit_SSD1680B — the dedicated driver for the GDEY0213B74 panel
  (not Adafruit_SSD1680; that is for the older panel and has a different init
  sequence that causes blank output on the B74).
  The 16-pixel gate offset of the GDEY0213B74 is handled inside the driver.
"""

import time
import threading
import logging
import textwrap

log = logging.getLogger(__name__)

# Catch Exception, not just ImportError — board/busio raise RuntimeError when
# not running on Pi hardware, and that would otherwise propagate and crash the module.
try:
    import board
    import busio
    import digitalio
    from adafruit_epd.epd import Adafruit_EPD
    from adafruit_epd.ssd1680b import Adafruit_SSD1680B
    from PIL import Image, ImageDraw, ImageFont
    EPD_AVAILABLE = True
except Exception as exc:
    log.warning("E-ink / PIL libraries not available (%s) – display in stub mode", exc)
    EPD_AVAILABLE = False

from config import (
    DISPLAY_WIDTH, DISPLAY_HEIGHT, DISPLAY_REFRESH_INTERVAL,
    EPD_DC_PIN, EPD_RST_PIN, EPD_BUSY_PIN,
    MODE_PASSIVE, MODE_ACTIVE, MODE_REVIEW,
    ACTIVE_MODE_ENABLED,
)


class DisplayManager:
    """Thread-safe e-ink display manager."""

    def __init__(self, state: dict, state_lock: threading.Lock):
        self._state = state
        self._lock = state_lock
        self._epd = None
        self._stop_event = threading.Event()
        self._refresh_requested = threading.Event()
        self._thread = None
        self._last_refresh = 0.0

        # Fonts loaded once here — ImageFont.truetype() hits the filesystem.
        # Hardware init is deferred to _run() so a slow/hung SPI init never
        # blocks the main thread or delays button/Flask startup.
        self._font_sm = None
        self._font_md = None
        self._font_lg = None

        if EPD_AVAILABLE:
            self._font_sm = self._load_font(9)
            self._font_md = self._load_font(11)
            self._font_lg = self._load_font(14)

    # ── Hardware init (runs in display thread, not main thread) ───────────────

    def _init_display(self):
        """Initialise the SSD1680B (GDEY0213B74) via hardware SPI. Called from _run()."""
        log.info("Initialising SSD1680B e-ink display (GDEY0213B74)...")
        try:
            spi  = busio.SPI(board.SCK, MOSI=board.MOSI, MISO=board.MISO)
            cs   = digitalio.DigitalInOut(board.D8)                          # GPIO 8, SPI0 CE0
            dc   = digitalio.DigitalInOut(getattr(board, f"D{EPD_DC_PIN}"))  # GPIO 22
            rst  = digitalio.DigitalInOut(getattr(board, f"D{EPD_RST_PIN}")) # GPIO 27
            busy = digitalio.DigitalInOut(getattr(board, f"D{EPD_BUSY_PIN}")) # GPIO 17

            self._epd = Adafruit_SSD1680B(
                122, 250, spi,
                cs_pin=cs, dc_pin=dc, sramcs_pin=None,
                rst_pin=rst, busy_pin=busy,
            )
            self._epd.rotation = 1   # landscape: width=250, height=122
            # Clear to known state before first draw (required by panel init sequence)
            self._epd.fill(Adafruit_EPD.WHITE)
            self._epd.display()
            log.info("E-ink display initialised (SSD1680B / GDEY0213B74)")
        except Exception as exc:
            log.error("Display hardware init failed: %s", exc)
            log.error("Check: SPI enabled in config.txt? Correct wiring? Libraries installed?")
            self._epd = None

    # ── Canvas helpers ────────────────────────────────────────────────────────

    def _new_canvas(self):
        return Image.new("RGB", (DISPLAY_WIDTH, DISPLAY_HEIGHT), (255, 255, 255))

    def _load_font(self, size: int = 10):
        try:
            return ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", size
            )
        except Exception:
            return ImageFont.load_default()

    # ── Rendering ─────────────────────────────────────────────────────────────

    def _render(self, state_snapshot: dict) -> Image.Image:
        """
        Build the full display image from a state snapshot.

        Layout (250×122 visible):
          Row  0-13 : Header bar (GhostPi title, mode badge, REC indicator)
          Row 14    : Separator
          Row 16-70 : Stats (networks, clients, probes, handshakes)
          Row 72-84 : Last-seen ESSID (when capture running)
          Row 86-119: Status message (word-wrapped, up to 3 lines)
          Row 112   : Timestamp (bottom-right)
        """
        canvas = self._new_canvas()
        draw   = ImageDraw.Draw(canvas)

        font_sm  = self._font_sm  or self._load_font(9)
        font_med = self._font_md  or self._load_font(11)
        font_lg  = self._font_lg  or self._load_font(14)

        mode            = state_snapshot.get("mode", MODE_PASSIVE)
        capture_running = state_snapshot.get("capture_running", False)
        net_count       = state_snapshot.get("network_count", 0)
        cli_count       = state_snapshot.get("client_count", 0)
        probe_count     = state_snapshot.get("probe_count", 0)
        hs_count        = state_snapshot.get("handshake_count", 0)
        status_msg      = state_snapshot.get("status_message", "Initialising...")
        last_essid      = state_snapshot.get("last_essid", "")

        BLACK = (0, 0, 0)
        WHITE = (255, 255, 255)

        # ── Header bar (inverted: black bg, white text) ───────────────────────
        draw.rectangle([(0, 0), (DISPLAY_WIDTH - 1, 13)], fill=BLACK)

        mode_label = f"[{mode.upper()}]"
        if mode == MODE_ACTIVE and not ACTIVE_MODE_ENABLED:
            mode_label += " LOCKED"
        draw.text((4, 1), "GhostPi", font=font_lg, fill=WHITE)
        draw.text((DISPLAY_WIDTH - 80, 3), mode_label, font=font_sm, fill=WHITE)
        if capture_running:
            draw.text((DISPLAY_WIDTH - 26, 3), "REC", font=font_sm, fill=WHITE)

        # ── Separator ─────────────────────────────────────────────────────────
        draw.line([(0, 14), (DISPLAY_WIDTH - 1, 14)], fill=BLACK)

        # ── Stats block ───────────────────────────────────────────────────────
        for label, value, row in (
            ("Networks",   net_count,   16),
            ("Clients",    cli_count,   30),
            ("Probes",     probe_count, 44),
            ("Handshakes", hs_count,    58),
        ):
            draw.text((4, row), f"{label}:", font=font_sm, fill=BLACK)
            draw.text((90, row), str(value), font=font_med, fill=BLACK)

        # ── Last-seen ESSID ───────────────────────────────────────────────────
        if last_essid:
            draw.line([(0, 72), (DISPLAY_WIDTH - 1, 72)], fill=BLACK)
            draw.text((4, 74), f"Last: {last_essid[:28]}", font=font_sm, fill=BLACK)

        # ── Status message (respects \n, word-wraps each segment) ─────────────
        draw.line([(0, 86), (DISPLAY_WIDTH - 1, 86)], fill=BLACK)
        lines = []
        for segment in status_msg.split("\n"):
            wrapped = textwrap.wrap(segment, width=35)
            lines.extend(wrapped if wrapped else [segment])
        for i, line in enumerate(lines[:3]):
            draw.text((4, 89 + i * 10), line, font=font_sm, fill=BLACK)

        # ── Timestamp (bottom-right) ──────────────────────────────────────────
        draw.text((DISPLAY_WIDTH - 32, 112), time.strftime("%H:%M"),
                  font=font_sm, fill=BLACK)

        return canvas

    def request_refresh(self):
        """Signal the display thread to refresh (non-blocking, safe from GPIO callbacks)."""
        self._refresh_requested.set()

    def refresh(self):
        """Push current state to the e-ink panel. Never raises."""
        try:
            with self._lock:
                snapshot = dict(self._state)

            if not EPD_AVAILABLE:
                log.debug("Display stub: would refresh (mode=%s)", snapshot.get("mode"))
                return

            image = self._render(snapshot)

            if self._epd is None:
                return

            self._epd.image(image)
            self._epd.display()
            self._last_refresh = time.monotonic()
            log.debug("Display refreshed")
        except Exception as exc:
            log.error("Display refresh error: %s", exc)

    # ── Thread lifecycle ──────────────────────────────────────────────────────

    def _run(self):
        """Background loop — hardware init happens here, not in __init__."""
        # Init hardware in this thread so a hung SPI init doesn't block startup.
        if EPD_AVAILABLE:
            self._init_display()

        while not self._stop_event.is_set():
            try:
                self.refresh()
                self._refresh_requested.wait(timeout=DISPLAY_REFRESH_INTERVAL)
                if self._stop_event.is_set():
                    break
                self._refresh_requested.clear()
            except Exception as exc:
                log.error("Display loop unexpected error: %s", exc)
                time.sleep(5)

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
