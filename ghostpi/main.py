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
import time

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

        # Counters (updated by capture daemon)
        "network_count":    0,
        "client_count":     0,
        "probe_count":      0,
        "handshake_count":  0,

        # Rich data (updated by capture daemon)
        "networks":         {},
        "clients":          {},
        "probes":           {},

        # Display status line
        "status_message":   "Starting up...",
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
        self._buttons = ButtonHandler(self._state, self._lock, self._display)
        self._flask_app = create_app(self._state, self._lock)

        self._flask_thread: threading.Thread | None = None
        self._running = True

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
                threaded=True,
            )

        self._flask_thread = threading.Thread(
            target=_run, name="webui", daemon=True
        )
        self._flask_thread.start()

    # ── Signal handling ───────────────────────────────────────────────────────

    def _handle_signal(self, signum, _frame):
        log.info("Signal %d received – shutting down", signum)
        self._running = False

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    def start(self):
        """Start all components."""
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

        self._capture.start()
        self._display.start()
        self._buttons.start()
        self._start_flask()

        log.info("All components started")

    def run(self):
        """Block until a stop signal is received."""
        self.start()
        try:
            while self._running:
                time.sleep(1)
                self._watchdog()
        except KeyboardInterrupt:
            pass
        finally:
            self.stop()

    def _watchdog(self):
        """Log periodic heartbeat so we can verify threads are alive."""
        # Could be extended to restart dead threads
        pass

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
