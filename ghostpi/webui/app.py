"""
GhostPi Flask web UI.

Served on the USB gadget interface (usb0) at 192.168.7.1:80.
No authentication is required because this interface is only reachable
over a direct USB cable connection to the operator's machine.  Do not
bind this to a wireless interface without adding authentication.

Routes:
  GET  /                  – dashboard HTML
  GET  /api/data          – full state JSON (polled by dashboard JS)
  GET  /api/networks      – networks JSON
  GET  /api/clients       – clients JSON
  GET  /api/probes        – probe requests JSON
  GET  /api/pcaps         – list of available PCAP files
  GET  /download/<fname>  – download a PCAP or CSV file from the log dir
  POST /api/select/<bssid>– set the active deauth target (active mode only)
"""

import glob
import json
import logging
import os
import threading

from flask import Flask, abort, jsonify, render_template, send_file, request

log = logging.getLogger(__name__)

# These are injected by create_app()
_state: dict = {}
_lock: threading.Lock = threading.Lock()


def create_app(state: dict, state_lock: threading.Lock) -> Flask:
    """Factory: wire shared state into the Flask app."""
    global _state, _lock
    _state = state
    _lock  = state_lock

    app = Flask(__name__, template_folder="templates")
    app.config["MAX_CONTENT_LENGTH"] = 0   # read-only UI, no uploads

    _register_routes(app)
    return app


def _register_routes(app: Flask):

    # ── Dashboard ─────────────────────────────────────────────────────────────

    @app.get("/")
    def index():
        with _lock:
            snapshot = dict(_state)
        return render_template("index.html", state=snapshot)

    # ── JSON API ──────────────────────────────────────────────────────────────

    @app.get("/api/data")
    def api_data():
        """Full state snapshot – polled every 15 s by the dashboard."""
        with _lock:
            snapshot = _safe_state_copy(_state)
        return jsonify(snapshot)

    @app.get("/api/networks")
    def api_networks():
        with _lock:
            nets = list(_state.get("networks", {}).values())
        # Sort by signal power (descending)
        nets.sort(key=lambda n: _parse_power(n.get("power", "0")), reverse=True)
        return jsonify(nets)

    @app.get("/api/clients")
    def api_clients():
        with _lock:
            clients = list(_state.get("clients", {}).values())
        return jsonify(clients)

    @app.get("/api/probes")
    def api_probes():
        with _lock:
            probes = {k: list(v) for k, v in _state.get("probes", {}).items()}
        # Flatten to list of {mac, essid} for the UI
        flat = [
            {"mac": mac, "essid": essid}
            for mac, essids in probes.items()
            for essid in essids
        ]
        return jsonify(flat)

    @app.get("/api/pcaps")
    def api_pcaps():
        from config import LOG_DIR
        pcaps = sorted(glob.glob(os.path.join(LOG_DIR, "*.cap")))
        return jsonify([os.path.basename(p) for p in pcaps])

    @app.get("/api/status")
    def api_status():
        with _lock:
            return jsonify({
                "mode":           _state.get("mode", "passive"),
                "status_message": _state.get("status_message", ""),
                "network_count":  _state.get("network_count", 0),
                "client_count":   _state.get("client_count", 0),
                "probe_count":    _state.get("probe_count", 0),
                "handshake_count":_state.get("handshake_count", 0),
                "active_enabled": _state.get("active_mode_enabled", False),
            })

    # ── File download ─────────────────────────────────────────────────────────

    @app.get("/download/<path:filename>")
    def download(filename: str):
        """Serve a log file (PCAP or CSV) for download."""
        from config import LOG_DIR

        # Safety: only serve files from LOG_DIR, no path traversal
        safe_path = os.path.realpath(os.path.join(LOG_DIR, filename))
        log_real   = os.path.realpath(LOG_DIR)

        if not safe_path.startswith(log_real + os.sep):
            log.warning("Path traversal attempt blocked: %s", filename)
            abort(403)

        if not os.path.isfile(safe_path):
            abort(404)

        log.info("Serving file download: %s", safe_path)
        return send_file(safe_path, as_attachment=True)

    # ── Target selection (active mode UI) ─────────────────────────────────────

    @app.post("/api/select/<bssid>")
    def select_target(bssid: str):
        """
        Set the deauth target BSSID.  Effective only when active mode is
        enabled.  This endpoint does NOT trigger a deauth itself – the
        GPIO button does.
        """
        from config import ACTIVE_MODE_ENABLED
        if not ACTIVE_MODE_ENABLED:
            return jsonify({"error": "active mode disabled"}), 403

        # Validate BSSID format (basic sanity check)
        parts = bssid.upper().split(":")
        if len(parts) != 6 or not all(len(p) == 2 for p in parts):
            abort(400)

        with _lock:
            _state["selected_bssid"] = bssid.upper()

        log.info("Target selected via web UI: %s", bssid)
        return jsonify({"selected": bssid.upper()})

    # ── Error handlers ────────────────────────────────────────────────────────

    @app.errorhandler(404)
    def not_found(_e):
        return jsonify({"error": "not found"}), 404

    @app.errorhandler(403)
    def forbidden(_e):
        return jsonify({"error": "forbidden"}), 403


# ── Helpers ───────────────────────────────────────────────────────────────────

def _parse_power(pwr: str) -> int:
    try:
        return int(pwr)
    except (ValueError, TypeError):
        return -999


def _safe_state_copy(state: dict) -> dict:
    """Return a JSON-serialisable deep copy of the state dict."""
    try:
        return json.loads(json.dumps(state))
    except (TypeError, ValueError):
        # Fallback: stringify anything that won't serialise
        return {k: v if isinstance(v, (str, int, float, bool, list, dict, type(None)))
                else str(v) for k, v in state.items()}
