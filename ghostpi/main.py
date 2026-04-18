"""
GhostPi – main entry point.

Starts three concurrent components as threads:
  1. CaptureDaemon  – passive WiFi recon via airodump-ng
  2. DisplayManager – e-ink display refresh loop
  3. ButtonHandler  – GPIO button interrupts
  4. Flask web UI   – HTTP dashboard on usb0:80

A shared state dict (protected by a single threading.Lock) is the
single source of truth read by display and web UI, and written by capture.

Must be run as root (required for raw socket access and airmon-ng).
"""

import logging
import os
import signal
import sys
import threading

# ── Logging setup (before any imports that might log) ─────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(
            os.path.expanduser("~/ghostpi/logs/ghostpi.log"),
            mode="a"
        ),
    ],
)
log = logging.getLogger("main")

# Silence Flask's request logger to reduce noise
logging.getLogger("werkzeug").setLevel(logging.WARNING)

# ── Imports ───────────────────────────────────────────────────────────────────
from config import (
    MODE_PASSIVE, WEBUI_HOST, WEBUI_PORT, LOG_DIR, ACTIVE_MODE_ENABLED
)
from capture import CaptureDaemon
from display import DisplayManager
from buttons import ButtonHandler
from webui.app import create_app


def check_root():
    if os.geteuid() != 0:
        log.error("GhostPi must be run as root (required for monitor mode)")
        sys.exit(1)


def ensure_dirs():
    os.makedirs(LOG_DIR, exist_ok=True)
    os.makedirs(os.path.expanduser("~/ghostpi/logs/handshakes"), exist_ok=True)


def build_initial_state() -> dict:
    """Return the initial shared state dict."""
    return {
        # Current operating mode
        "mode":             MODE_PASSIVE,

        # Capture on/off (toggled by GPIO 6 in passive mode)
        "capture_running":  False,

        # Counters (updated by capture daemon)
        "network_count":    0,
        "client_count":     0,
        "probe_count":      0,
        "handshake_count":  0,

        # Rich data (updated by capture daemon)
        "networks":         {},
        "clients":          {},
        "probes":           {},

        # Boot prompt shown before web UI starts
        "status_message":   "USB gadget active\nSSH: 192.168.7.1\nPress ACTION → Web UI",
        "last_essid":       "",

        # Active mode state
        "active_mode_enabled": ACTIVE_MODE_ENABLED,
        "selected_bssid":   None,

        # Session metadata
        "session_prefix":   "",
    }


class GhostPi:
    def __init__(self):
        self._state = build_initial_state()
        self._lock  = threading.Lock()

        # Components
        self._capture = CaptureDaemon(self._state, self._lock)
        self._display = DisplayManager(self._state, self._lock)
        self._buttons = ButtonHandler(
            self._state, self._lock, self._display, self._capture
        )
        self._flask_app = create_app(self._state, self._lock, self._capture)

        self._flask_thread: threading.Thread | None = None
        self._running = True
        self._stop_event = threading.Event()

    # ── Flask thread ──────────────────────────────────────────────────────────

    def _start_flask(self):
        """Run Flask in a daemon thread.  Binds to WEBUI_HOST:WEBUI_PORT."""
        def _run():
            log.info("Web UI starting on http://%s:%d", WEBUI_HOST, WEBUI_PORT)
            self._flask_app.run(
                host=WEBUI_HOST,
                port=WEBUI_PORT,
                debug=False,
                use_reloader=False,
                threaded=False,   # single-threaded: no per-request thread spawning
            )

        self._flask_thread = threading.Thread(
            target=_run, name="webui", daemon=True
        )
        self._flask_thread.start()

    # ── Signal handling ───────────────────────────────────────────────────────

    def _handle_signal(self, signum, _frame):
        log.info("Signal %d received – shutting down", signum)
        self._running = False
        self._stop_event.set()

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    def _wait_for_boot_confirm(self):
        """
        Show boot prompt on e-ink and block until GPIO6 is pressed.
        Display and buttons must already be running when this is called.
        """
        confirmed = threading.Event()
        self._buttons.set_boot_mode(confirmed)
        log.info("Boot prompt active — waiting for GPIO6 press to start web UI")
        confirmed.wait()   # blocks indefinitely until button pressed
        log.info("Boot confirmed")

    def start(self):
        """Start all components in the correct order."""
        log.info("=" * 50)
        log.info("GhostPi starting")
        if ACTIVE_MODE_ENABLED:
            log.warning(
                "ACTIVE MODE IS ENABLED – ensure you have written authorization "
                "for all networks in scope before using active features."
            )
        else:
            log.info("Active mode: DISABLED (passive recon only)")
        log.info("=" * 50)

        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT,  self._handle_signal)

        # Stage 1: display + buttons — e-ink shows boot prompt immediately
        self._display.start()
        self._buttons.start()

        # Stage 2: wait for user to press ACTION (GPIO6) before starting web UI.
        # This keeps Flask off the air until the operator is ready.
        self._wait_for_boot_confirm()

        # Stage 3: start web UI and make capture daemon ready
        self._capture.start()   # ready state only — capture starts on GPIO6 press
        self._start_flask()

        with self._lock:
            self._state["status_message"] = "Web UI: 192.168.7.1:80\nPress ACTION to capture"
        self._display.request_refresh()

        log.info("Web UI up at http://%s:%d — press ACTION (GPIO 6) to begin capture",
                 WEBUI_HOST, WEBUI_PORT)

    def run(self):
        """Block until a stop signal is received."""
        self.start()
        try:
            while self._running:
                # Wake every 30 s for watchdog, or immediately on signal
                self._stop_event.wait(timeout=30)
                self._stop_event.clear()
                if self._running:
                    self._watchdog()
        except KeyboardInterrupt:
            pass
        finally:
            self.stop()

    def _watchdog(self):
        """Log warnings, restart display if dead, check capture only when user-started."""
        with self._lock:
            capture_should_run = self._state.get("capture_running", False)

        if capture_should_run and not self._capture.is_running():
            log.error("WATCHDOG: capture thread died unexpectedly")

        # Display thread must always be running — restart if it somehow died
        if self._display._thread and not self._display._thread.is_alive():
            log.error("WATCHDOG: display thread died — restarting")
            self._display._stop_event.clear()
            self._display.start()

        if self._flask_thread and not self._flask_thread.is_alive():
            log.error("WATCHDOG: webui thread has died")

    def stop(self):
        """Gracefully shut down all components."""
        log.info("Shutting down GhostPi...")
        self._capture.stop()
        self._display.stop()
        self._buttons.stop()
        log.info("GhostPi stopped cleanly")


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    check_root()
    ensure_dirs()

    ghost = GhostPi()
    ghost.run()
