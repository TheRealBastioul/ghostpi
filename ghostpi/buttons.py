"""
GhostPi GPIO button handler.

Button layout (Adafruit 2.13" e-ink bonnet):
  GPIO 5 (BUTTON_MODE_PIN)   – cycle operating mode
  GPIO 6 (BUTTON_ACTION_PIN) – context-sensitive action

Mode cycling (GPIO 5): passive → active → review → passive …

GPIO 6 actions:
  passive mode : force an immediate e-ink display refresh
  active mode  : trigger a deauthentication burst against the selected target
                 REQUIRES ACTIVE_MODE_ENABLED=True in config.py
  review mode  : page through captured network list on the display

LEGAL NOTICE: The deauthentication feature in active mode transmits 802.11
management frames.  Sending deauth frames to devices without the owner's
explicit written consent is illegal in most jurisdictions.  This feature is
disabled by default (ACTIVE_MODE_ENABLED=False) and must only be enabled
during authorized penetration tests or on networks you own.
"""

import logging
import subprocess
import threading
import time

log = logging.getLogger(__name__)

try:
    import RPi.GPIO as GPIO
    GPIO_AVAILABLE = True
except Exception:
    log.warning("RPi.GPIO not available – button handler running in stub mode")
    GPIO_AVAILABLE = False

from config import (
    BUTTON_MODE_PIN, BUTTON_ACTION_PIN, BUTTON_DEBOUNCE_MS,
    MODES, MODE_PASSIVE, MODE_ACTIVE, MODE_REVIEW,
    ACTIVE_MODE_ENABLED,
    MON_INTERFACE, DEAUTH_COUNT,
)


class ButtonHandler:
    """Handles GPIO button presses and updates shared state."""

    def __init__(
        self,
        state: dict,
        state_lock: threading.Lock,
        display_manager=None,
        capture_daemon=None,
    ):
        """
        Args:
            state:           Shared application state dict.
            state_lock:      Lock protecting state.
            display_manager: DisplayManager instance for forced refreshes.
            capture_daemon:  CaptureDaemon instance for start/stop capture.
        """
        self._state   = state
        self._lock    = state_lock
        self._display = display_manager
        self._capture = capture_daemon

        # Review mode: index into the network list for paging
        self._review_index = 0

        # Boot confirmation: set by main before web UI starts; cleared on first ACTION press
        self._boot_confirm_event: threading.Event | None = None

        self._stop_event = threading.Event()

        if GPIO_AVAILABLE:
            self._setup_gpio()

    # ── GPIO initialisation ───────────────────────────────────────────────────

    def _setup_gpio(self):
        """Configure GPIO pins with pull-up resistors (buttons pull to GND)."""
        GPIO.setmode(GPIO.BCM)
        GPIO.setup(BUTTON_MODE_PIN,   GPIO.IN, pull_up_down=GPIO.PUD_UP)
        GPIO.setup(BUTTON_ACTION_PIN, GPIO.IN, pull_up_down=GPIO.PUD_UP)

        GPIO.add_event_detect(
            BUTTON_MODE_PIN,
            GPIO.FALLING,
            callback=self._on_mode_press,
            bouncetime=BUTTON_DEBOUNCE_MS,
        )
        GPIO.add_event_detect(
            BUTTON_ACTION_PIN,
            GPIO.FALLING,
            callback=self._on_action_press,
            bouncetime=BUTTON_DEBOUNCE_MS,
        )
        log.info("GPIO buttons configured (mode=GPIO%d, action=GPIO%d)",
                 BUTTON_MODE_PIN, BUTTON_ACTION_PIN)

    # ── Button callbacks ──────────────────────────────────────────────────────

    def _on_mode_press(self, channel: int):
        """GPIO 5 pressed: advance to the next operating mode."""
        with self._lock:
            current = self._state.get("mode", MODE_PASSIVE)
            idx     = MODES.index(current) if current in MODES else 0
            next_mode = MODES[(idx + 1) % len(MODES)]

            # Skip active mode if not enabled
            if next_mode == MODE_ACTIVE and not ACTIVE_MODE_ENABLED:
                log.info("Active mode is disabled – skipping to review")
                next_mode = MODE_REVIEW

            self._state["mode"] = next_mode
            self._state["status_message"] = f"Mode → {next_mode.upper()}"
            log.info("Mode changed: %s → %s", current, next_mode)

        # Reset review index when entering review mode
        if next_mode == MODE_REVIEW:
            self._review_index = 0

        if self._display:
            self._display.request_refresh()

    def set_boot_mode(self, confirm_event: threading.Event):
        """
        Enter boot-confirmation mode.  The next ACTION press fires confirm_event
        instead of its normal action.  main.py calls this before waiting for
        the user to start the web UI.
        """
        self._boot_confirm_event = confirm_event
        log.info("Button handler: boot confirmation mode active (press GPIO6 to start)")

    def _on_action_press(self, channel: int):
        """GPIO 6 pressed: context-sensitive action."""
        # Boot-confirmation takes priority over everything else
        if self._boot_confirm_event is not None:
            log.info("Boot confirmation received via GPIO6")
            evt = self._boot_confirm_event
            self._boot_confirm_event = None
            with self._lock:
                self._state["status_message"] = "Starting web UI..."
            if self._display:
                self._display.request_refresh()
            evt.set()
            return

        with self._lock:
            current_mode = self._state.get("mode", MODE_PASSIVE)

        if current_mode == MODE_PASSIVE:
            self._action_toggle_capture()
        elif current_mode == MODE_ACTIVE:
            self._action_active_deauth()
        elif current_mode == MODE_REVIEW:
            self._action_review_page()

    # ── Mode-specific actions ─────────────────────────────────────────────────

    def _action_toggle_capture(self):
        """Toggle passive capture on/off (GPIO 6 in passive mode)."""
        if self._capture is None:
            log.warning("No capture daemon available")
            return
        if self._capture.is_running():
            log.info("User stopped capture")
            self._capture.stop_capture()
        else:
            log.info("User started capture")
            self._capture.start_capture()
        if self._display:
            self._display.request_refresh()

    def _action_active_deauth(self):
        """
        Send a deauthentication burst at the currently selected target.

        AUTHORIZATION REQUIRED: This transmits 802.11 deauth frames.
        Only execute against networks you own or have explicit written
        permission to test.  Disabled unless ACTIVE_MODE_ENABLED=True.
        """
        # Hard gate – never transmit if the flag is False
        if not ACTIVE_MODE_ENABLED:
            log.warning(
                "Deauth blocked: ACTIVE_MODE_ENABLED=False. "
                "Set this flag only during authorized engagements."
            )
            with self._lock:
                self._state["status_message"] = "ACTIVE MODE DISABLED"
            if self._display:
                self._display.request_refresh()
            return

        with self._lock:
            target_bssid = self._state.get("selected_bssid")

        if not target_bssid:
            log.info("No target selected for deauth")
            with self._lock:
                self._state["status_message"] = "No target selected"
            if self._display:
                self._display.request_refresh()
            return

        log.info(
            "ACTIVE MODE: sending %d deauth frames to BSSID %s on %s "
            "(ACTIVE_MODE_ENABLED=True, ensure authorization is in scope)",
            DEAUTH_COUNT, target_bssid, MON_INTERFACE
        )

        with self._lock:
            self._state["status_message"] = f"Deauth → {target_bssid[:17]}"
        if self._display:
            self._display.request_refresh()

        # Run deauth in a background thread so we don't block the GPIO callback
        threading.Thread(
            target=self._run_deauth,
            args=(target_bssid,),
            daemon=True,
        ).start()

    def _run_deauth(self, bssid: str):
        """Execute the aireplay-ng deauth command (active mode only)."""
        # AUTHORIZATION GATE – checked again inside the thread
        if not ACTIVE_MODE_ENABLED:
            return

        try:
            cmd = [
                "aireplay-ng",
                "--deauth", str(DEAUTH_COUNT),
                "-a", bssid,
                MON_INTERFACE,
            ]
            log.info("Executing: %s", " ".join(cmd))
            result = subprocess.run(
                cmd,
                capture_output=True, text=True, timeout=15
            )
            status = "Deauth sent" if result.returncode == 0 else "Deauth failed"
            log.info("Deauth result: %s (rc=%d)", status, result.returncode)
        except subprocess.TimeoutExpired:
            status = "Deauth timeout"
            log.warning("Deauth timed out")
        except Exception as exc:
            status = f"Deauth error: {exc}"
            log.error("Deauth error: %s", exc)

        with self._lock:
            self._state["status_message"] = status
        if self._display:
            self._display.request_refresh()

    def _action_review_page(self):
        """Page through captured networks on the e-ink display (review mode)."""
        with self._lock:
            networks = list(self._state.get("networks", {}).values())

        if not networks:
            with self._lock:
                self._state["status_message"] = "No networks captured yet"
            if self._display:
                self._display.request_refresh()
            return

        self._review_index = (self._review_index + 1) % len(networks)
        net = networks[self._review_index]

        essid   = net.get("essid", "<hidden>") or "<hidden>"
        bssid   = net.get("bssid", "??:??:??:??:??:??")
        channel = net.get("channel", "?")
        privacy = net.get("privacy", "?")
        power   = net.get("power", "?")

        with self._lock:
            self._state["status_message"] = (
                f"{self._review_index+1}/{len(networks)} "
                f"{essid[:16]} ch{channel} {privacy} {power}dBm"
            )
            # Set selected_bssid so active mode knows the current target
            self._state["selected_bssid"] = bssid

        log.info("Review page: %s (%s)", essid, bssid)
        if self._display:
            self._display.request_refresh()

    # ── Lifecycle ─────────────────────────────────────────────────────────────

    def start(self):
        """Start the button handler (GPIO callbacks are interrupt-driven)."""
        log.info("Button handler started")
        # Nothing to do – GPIO event detection is set up in __init__

    def stop(self):
        """Clean up GPIO resources."""
        if GPIO_AVAILABLE:
            GPIO.cleanup()
        log.info("Button handler stopped")
