"""
GhostPi passive recon daemon.

Runs airodump-ng in monitor mode and continuously parses its CSV output.
All captures are PASSIVE – no frames are transmitted.  The parsed state
is written to a shared dict (protected by a threading.Lock) for display
and web-UI consumption.

CSV columns written by airodump-ng:
  Networks section:
    BSSID, First time seen, Last time seen, channel, Speed, Privacy,
    Cipher, Authentication, Power, # beacons, # IV, LAN IP, ID-length, ESSID, Key
  Clients section:
    Station MAC, First time seen, Last time seen, Power, # packets,
    BSSID, Probed ESSIDs

Output files (rotated on startup):
  logs/capture-<timestamp>-01.csv
  logs/capture-<timestamp>-01.cap    (full PCAP including WPA handshakes)
"""

import csv
import glob
import logging
import os
import subprocess
import threading
import time
from collections import defaultdict, deque
from datetime import datetime

from config import (
    WIFI_INTERFACE, MON_INTERFACE,
    LOG_DIR, CAPTURE_PREFIX, HANDSHAKE_DIR,
    MAX_PROBES_PER_STA,
    DISPLAY_REFRESH_INTERVAL,
)

log = logging.getLogger(__name__)


class CaptureDaemon:
    """Manages monitor mode, airodump-ng subprocess, and CSV parsing."""

    def __init__(self, state: dict, state_lock: threading.Lock):
        self._state = state
        self._lock  = state_lock

        self._stop_event = threading.Event()
        self._proc: subprocess.Popen | None = None

        # Per-session capture file prefix (timestamped to avoid collisions)
        ts = datetime.now().strftime("%Y%m%d-%H%M%S")
        self._session_prefix = f"{CAPTURE_PREFIX}-{ts}"

        # In-memory parsed state
        self._networks: dict[str, dict] = {}   # keyed by BSSID
        self._clients: dict[str, dict]  = {}   # keyed by station MAC
        # probe_requests: station_mac → bounded deque of ESSIDs
        self._probes: dict[str, deque] = defaultdict(
            lambda: deque(maxlen=MAX_PROBES_PER_STA)
        )

        # Handshake count cached from background thread (avoids blocking parse loop)
        self._hs_count: int = 0
        self._last_hs_check: float = 0.0

        # airodump-ng restart backoff counter
        self._restart_count: int = 0

        # Ensure log directories exist
        os.makedirs(LOG_DIR, exist_ok=True)
        os.makedirs(HANDSHAKE_DIR, exist_ok=True)

    # ── Monitor mode management ───────────────────────────────────────────────

    def _start_monitor_mode(self) -> bool:
        """Put the wireless card into monitor mode using airmon-ng."""
        log.info("Starting monitor mode on %s", WIFI_INTERFACE)
        try:
            # Kill processes that may interfere with monitor mode
            subprocess.run(
                ["airmon-ng", "check", "kill"],
                capture_output=True, timeout=10
            )
            result = subprocess.run(
                ["airmon-ng", "start", WIFI_INTERFACE],
                capture_output=True, text=True, timeout=15
            )
            if result.returncode == 0:
                log.info("Monitor mode started: %s", MON_INTERFACE)
                return True
            log.error("airmon-ng start failed: %s", result.stderr)
            return False
        except Exception as exc:
            log.error("Could not start monitor mode: %s", exc)
            return False

    def _stop_monitor_mode(self):
        """Return the wireless card to managed mode."""
        log.info("Stopping monitor mode")
        try:
            subprocess.run(
                ["airmon-ng", "stop", MON_INTERFACE],
                capture_output=True, timeout=10
            )
        except Exception as exc:
            log.warning("Could not stop monitor mode cleanly: %s", exc)

    # ── airodump-ng subprocess ────────────────────────────────────────────────

    def _start_airodump(self):
        """Launch airodump-ng writing CSV + PCAP to the session prefix."""
        cmd = [
            "airodump-ng",
            "--write",         self._session_prefix,
            "--output-format", "csv,pcap",
            "--write-interval", "5",   # flush CSV every 5 s
            MON_INTERFACE,
        ]
        log.info("Launching: %s", " ".join(cmd))
        self._proc = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

    def _stop_airodump(self):
        """Terminate the airodump-ng subprocess."""
        if self._proc and self._proc.poll() is None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self._proc.kill()
        self._proc = None

    # ── CSV parsing ───────────────────────────────────────────────────────────

    def _find_csv(self) -> str | None:
        """Return the path to the most recent airodump-ng CSV for this session."""
        pattern = f"{self._session_prefix}-*.csv"
        files = sorted(glob.glob(pattern))
        return files[-1] if files else None

    def _parse_csv(self, csv_path: str):
        """
        Parse an airodump-ng CSV file and update internal dicts.

        The file has two sections separated by a blank line:
          1. AP / network records
          2. Client / station records
        """
        try:
            with open(csv_path, "r", errors="replace") as fh:
                content = fh.read()
        except OSError as exc:
            log.debug("CSV read error: %s", exc)
            return

        sections = content.split("\n\n")
        if len(sections) < 1:
            return

        # ── Section 1: Access Points ──────────────────────────────────────────
        ap_lines = sections[0].strip().splitlines()
        if len(ap_lines) > 1:   # first line is header
            reader = csv.reader(ap_lines[1:])
            for row in reader:
                row = [c.strip() for c in row]
                if len(row) < 14:
                    continue
                bssid = row[0]
                if not bssid or bssid.lower() == "bssid":
                    continue
                self._networks[bssid] = {
                    "bssid":        bssid,
                    "first_seen":   row[1],
                    "last_seen":    row[2],
                    "channel":      row[3],
                    "speed":        row[4],
                    "privacy":      row[5],
                    "cipher":       row[6],
                    "auth":         row[7],
                    "power":        row[8],
                    "beacons":      row[9],
                    "iv":           row[10],
                    "essid":        row[13] if len(row) > 13 else "",
                }

        # ── Section 2: Client Stations ────────────────────────────────────────
        if len(sections) < 2:
            return

        cli_lines = sections[1].strip().splitlines()
        if len(cli_lines) > 1:
            reader = csv.reader(cli_lines[1:])
            for row in reader:
                row = [c.strip() for c in row]
                if len(row) < 6:
                    continue
                mac = row[0]
                if not mac or mac.lower() in ("station mac", ""):
                    continue
                probed_raw = row[6] if len(row) > 6 else ""
                probed = [p.strip() for p in probed_raw.split(",") if p.strip()]

                self._clients[mac] = {
                    "mac":        mac,
                    "first_seen": row[1],
                    "last_seen":  row[2],
                    "power":      row[3],
                    "packets":    row[4],
                    "bssid":      row[5],
                    "probes":     probed,
                }

                # Accumulate probe requests (deduplicated; deque enforces maxlen)
                for essid in probed:
                    if essid not in self._probes[mac]:
                        self._probes[mac].append(essid)

    # ── Handshake detection ───────────────────────────────────────────────────

    # Minimum seconds between handshake recounts — avoids blocking the capture
    # loop with O(n) subprocess calls as the session and PCAP count grows.
    _HS_CHECK_INTERVAL = 120.0

    def _count_handshakes_sync(self) -> int:
        """
        Count PCAPs containing a WPA handshake.  Blocking — call only from
        the dedicated background thread spawned by _update_handshakes_async().
        """
        pcap_pattern = f"{self._session_prefix}-*.cap"
        pcaps = glob.glob(pcap_pattern)
        count = 0
        for pcap in pcaps:
            try:
                result = subprocess.run(
                    ["aircrack-ng", "-a", "2", pcap],
                    capture_output=True, text=True, timeout=10
                )
                if "handshake" in result.stdout.lower():
                    count += 1
            except Exception:
                pass
        return count

    def _update_handshakes_async(self):
        """
        Kick off a background handshake recount if the cache has expired.
        Returns immediately; self._hs_count is updated when the thread finishes.
        """
        now = time.monotonic()
        if now - self._last_hs_check < self._HS_CHECK_INTERVAL:
            return
        self._last_hs_check = now  # stamp before launch to prevent double-spawn

        def _worker():
            count = self._count_handshakes_sync()
            self._hs_count = count  # int assignment is atomic under the GIL

        threading.Thread(
            target=_worker, name="hs-count", daemon=True
        ).start()

    # ── State publishing ──────────────────────────────────────────────────────

    def _publish_state(self):
        """Write parsed data into the shared state dict."""
        all_probes = sum(len(v) for v in self._probes.values())
        last_essid = ""
        if self._networks:
            newest = max(
                self._networks.values(),
                key=lambda n: n.get("last_seen", ""),
                default={}
            )
            last_essid = newest.get("essid", "")

        # Trigger async recount (returns immediately; updates self._hs_count in bg)
        self._update_handshakes_async()

        with self._lock:
            self._state["network_count"]   = len(self._networks)
            self._state["client_count"]    = len(self._clients)
            self._state["probe_count"]     = all_probes
            self._state["handshake_count"] = self._hs_count
            self._state["last_essid"]      = last_essid
            self._state["networks"]        = dict(self._networks)
            self._state["clients"]         = dict(self._clients)
            # Convert deques to plain lists for JSON serialisation
            self._state["probes"]          = {k: list(v) for k, v in self._probes.items()}
            self._state["session_prefix"]  = self._session_prefix
            self._state["status_message"]  = (
                f"Monitoring {MON_INTERFACE} | "
                f"{len(self._networks)} nets, {len(self._clients)} clients"
            )

        log.debug(
            "State published: %d nets, %d clients, %d probe entries",
            len(self._networks), len(self._clients), all_probes
        )

    # ── Main loop ─────────────────────────────────────────────────────────────

    def _run(self):
        if not self._start_monitor_mode():
            with self._lock:
                self._state["status_message"] = "ERROR: monitor mode failed"
                self._state["capture_running"] = False
            return

        self._start_airodump()

        try:
            while not self._stop_event.is_set():
                time.sleep(DISPLAY_REFRESH_INTERVAL)

                csv_path = self._find_csv()
                if csv_path:
                    self._parse_csv(csv_path)
                    self._publish_state()
                else:
                    log.debug("No CSV yet, waiting...")

                # Do NOT auto-restart on unexpected exit — let the user re-trigger
                if self._proc and self._proc.poll() is not None:
                    log.warning("airodump-ng exited unexpectedly — stopping capture")
                    break

        finally:
            self._stop_airodump()
            self._stop_monitor_mode()
            with self._lock:
                self._state["capture_running"] = False
                if not self._stop_event.is_set():
                    # Exited due to airodump crash, not user request
                    self._state["status_message"] = "Capture stopped (press ACTION to restart)"

    def start(self):
        """Prepare the daemon — capture does NOT start until start_capture() is called."""
        log.info("Capture daemon ready (session prefix: %s)", self._session_prefix)

    def start_capture(self):
        """Start monitor mode and airodump-ng. Called when user presses ACTION in passive mode."""
        if self.is_running():
            log.info("Capture already running")
            return
        self._stop_event.clear()
        self._restart_count = 0
        with self._lock:
            self._state["capture_running"] = True
            self._state["status_message"] = "Starting capture..."
        self._thread = threading.Thread(target=self._run, name="capture", daemon=True)
        self._thread.start()
        log.info("Capture started by user (session: %s)", self._session_prefix)

    def stop_capture(self):
        """Stop airodump-ng and return to managed mode. Called when user presses ACTION again."""
        if not self.is_running():
            return
        self._stop_event.set()
        if hasattr(self, "_thread") and self._thread.is_alive():
            self._thread.join(timeout=20)
        with self._lock:
            self._state["capture_running"] = False
            self._state["status_message"] = "Capture stopped"
        log.info("Capture stopped by user")

    def is_running(self) -> bool:
        """Return True if the capture thread is alive."""
        return getattr(self, "_thread", None) is not None and self._thread.is_alive()

    def stop(self):
        """Graceful shutdown (called by GhostPi.stop())."""
        self.stop_capture()
        log.info("Capture daemon stopped")

    # ── Public accessors (for web UI) ─────────────────────────────────────────

    def get_pcap_files(self) -> list[str]:
        """Return all PCAP file paths for the current session."""
        return sorted(glob.glob(f"{self._session_prefix}-*.cap"))
