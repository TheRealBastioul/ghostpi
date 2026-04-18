#!/usr/bin/env python3
"""
Preview the GhostPi e-ink display output as a PNG — no Pi hardware needed.
Renders what the display would show given a state, using only Pillow.

Usage:
  python3 tools/preview-display.py                      # default idle state
  python3 tools/preview-display.py --capture            # show capture running
  python3 tools/preview-display.py --mode active        # show active mode
  python3 tools/preview-display.py --status "booting"   # custom status text
  python3 tools/preview-display.py --out /tmp/disp.png  # custom output path
  python3 tools/preview-display.py --scale 3            # 3x zoom (default 4)

Output: /tmp/ghostpi-preview.png  (or --out path)

Dependencies: Pillow only (pip install pillow)
The font path defaults to a DejaVu monospace TTF.  On macOS / Windows,
if the system font is missing, falls back to PIL's built-in bitmap font.
"""

import argparse
import os
import sys
import textwrap
import time

try:
    from PIL import Image, ImageDraw, ImageFont, ImageFilter
except ImportError:
    print("ERROR: Pillow not installed.  Run:  pip install pillow")
    sys.exit(1)

# ── Constants (mirror config.py) ──────────────────────────────────────────────
DISPLAY_WIDTH  = 250
DISPLAY_HEIGHT = 122

FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",   # Linux
    "/System/Library/Fonts/Supplemental/Courier New.ttf",    # macOS
    "C:/Windows/Fonts/cour.ttf",                             # Windows
]


def load_font(size: int):
    for path in FONT_PATHS:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except Exception:
                pass
    return ImageFont.load_default()


def render(state: dict) -> Image.Image:
    """
    Render a 250×122 RGB PIL image exactly as DisplayManager._render() does.
    Returns the RGB canvas.
    """
    BLACK = (0, 0, 0)
    WHITE = (255, 255, 255)

    canvas = Image.new("RGB", (DISPLAY_WIDTH, DISPLAY_HEIGHT), WHITE)
    draw   = ImageDraw.Draw(canvas)

    font_sm  = load_font(9)
    font_med = load_font(11)
    font_lg  = load_font(14)

    mode            = state.get("mode", "passive")
    capture_running = state.get("capture_running", False)
    net_count       = state.get("network_count", 0)
    cli_count       = state.get("client_count", 0)
    probe_count     = state.get("probe_count", 0)
    hs_count        = state.get("handshake_count", 0)
    status_msg      = state.get("status_message", "Ready")
    last_essid      = state.get("last_essid", "")

    # ── Header bar ────────────────────────────────────────────────────────────
    draw.rectangle([(0, 0), (DISPLAY_WIDTH - 1, 13)], fill=BLACK)
    mode_label = f"[{mode.upper()}]"
    draw.text((4, 1),                    "GhostPi",  font=font_lg, fill=WHITE)
    draw.text((DISPLAY_WIDTH - 80, 3),   mode_label, font=font_sm, fill=WHITE)
    if capture_running:
        draw.text((DISPLAY_WIDTH - 26, 3), "REC",   font=font_sm, fill=WHITE)

    # ── Separator ─────────────────────────────────────────────────────────────
    draw.line([(0, 14), (DISPLAY_WIDTH - 1, 14)], fill=BLACK)

    # ── Stats block ───────────────────────────────────────────────────────────
    for label, value, row in (
        ("Networks",   net_count,   16),
        ("Clients",    cli_count,   30),
        ("Probes",     probe_count, 44),
        ("Handshakes", hs_count,    58),
    ):
        draw.text((4,  row), f"{label}:", font=font_sm, fill=BLACK)
        draw.text((90, row), str(value),  font=font_med, fill=BLACK)

    # ── Last-seen ESSID ───────────────────────────────────────────────────────
    if last_essid:
        draw.line([(0, 72), (DISPLAY_WIDTH - 1, 72)], fill=BLACK)
        draw.text((4, 74), f"Last: {last_essid[:28]}", font=font_sm, fill=BLACK)

    # ── Status message ────────────────────────────────────────────────────────
    draw.line([(0, 86), (DISPLAY_WIDTH - 1, 86)], fill=BLACK)
    lines = []
    for segment in status_msg.split("\n"):
        wrapped = textwrap.wrap(segment, width=35)
        lines.extend(wrapped if wrapped else [segment])
    for i, line in enumerate(lines[:3]):
        draw.text((4, 89 + i * 10), line, font=font_sm, fill=BLACK)

    # ── Timestamp ─────────────────────────────────────────────────────────────
    draw.text((DISPLAY_WIDTH - 32, 112), time.strftime("%H:%M"), font=font_sm, fill=BLACK)

    return canvas


def save_preview(image: Image.Image, out_path: str, scale: int = 4):
    """
    Scale up and add a border so it's easy to view on a normal monitor.
    E-ink is ~212 dpi so 4x gives a viewable 1000×488 px image.
    """
    scaled = image.convert("L").resize(
        (DISPLAY_WIDTH * scale, DISPLAY_HEIGHT * scale),
        Image.NEAREST,
    )
    # Add a thin grey border
    bordered_w = scaled.width  + 4
    bordered_h = scaled.height + 4
    out = Image.new("L", (bordered_w, bordered_h), 180)
    out.paste(scaled, (2, 2))
    out.save(out_path)
    print(f"Preview saved → {out_path}  ({out.width}×{out.height}px, {scale}x scale)")


def main():
    parser = argparse.ArgumentParser(
        description="Render GhostPi e-ink display to PNG (no hardware needed)"
    )
    parser.add_argument("--mode",    default="passive",
                        choices=["passive", "active", "review"],
                        help="Operating mode shown in header")
    parser.add_argument("--capture", action="store_true",
                        help="Show capture running (REC badge)")
    parser.add_argument("--networks",  type=int, default=0)
    parser.add_argument("--clients",   type=int, default=0)
    parser.add_argument("--probes",    type=int, default=0)
    parser.add_argument("--handshakes",type=int, default=0)
    parser.add_argument("--status",  default="USB gadget active\nSSH: 192.168.7.1\nPress ACTION → Web UI",
                        help="Status message (\\n for newline)")
    parser.add_argument("--essid",   default="",
                        help="Last seen ESSID")
    parser.add_argument("--out",     default="/tmp/ghostpi-preview.png",
                        help="Output PNG path")
    parser.add_argument("--scale",   type=int, default=4,
                        help="Scale factor (default 4 = 1000×488px)")
    parser.add_argument("--demo",    action="store_true",
                        help="Render a demo with fake data")
    args = parser.parse_args()

    if args.demo:
        state = {
            "mode":            "passive",
            "capture_running": True,
            "network_count":   12,
            "client_count":    7,
            "probe_count":     34,
            "handshake_count": 2,
            "status_message":  "Scanning...",
            "last_essid":      "CoffeeShop_Free",
        }
    else:
        state = {
            "mode":            args.mode,
            "capture_running": args.capture,
            "network_count":   args.networks,
            "client_count":    args.clients,
            "probe_count":     args.probes,
            "handshake_count": args.handshakes,
            "status_message":  args.status.replace("\\n", "\n"),
            "last_essid":      args.essid,
        }

    image = render(state)
    save_preview(image, args.out, scale=args.scale)

    # Also print what state was used
    print(f"State: mode={state['mode']}  capture={state['capture_running']}  "
          f"nets={state['network_count']}  clients={state['client_count']}")


if __name__ == "__main__":
    main()
