#!/usr/bin/env python3
"""
GhostPi boot splash.

Draws a single "Starting up..." screen to the e-ink display and exits.
Runs as a one-shot systemd service (ghostpi-splash) before the main
ghostpi service starts.

Inlines its own config values so it has no import dependency on the rest
of the GhostPi package.  Any failure exits cleanly — this script must
never block or crash the boot process.
"""

import sys

# ── Inline hardware constants (mirror config.py, do not import it) ─────────
DISPLAY_WIDTH    = 250
DISPLAY_HEIGHT   = 122
DISPLAY_Y_OFFSET = 16
EPD_CS_PIN       = 8
EPD_DC_PIN       = 22
EPD_RST_PIN      = 27   # board label: Reset=27
EPD_BUSY_PIN     = 17   # board label: Busy=17
FONT_PATH        = "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"

# ── Library imports ────────────────────────────────────────────────────────
try:
    import board
    import busio
    import digitalio
    from adafruit_epd.ssd1680b import Adafruit_SSD1680B
    from PIL import Image, ImageDraw, ImageFont
except Exception as exc:
    print(f"ghostpi-splash: display libraries not available ({exc})", file=sys.stderr)
    sys.exit(0)   # exit cleanly — never block boot


def load_font(size):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except Exception:
        return ImageFont.load_default()


def draw_splash() -> Image.Image:
    """Render the boot splash image."""
    canvas = Image.new("1", (DISPLAY_WIDTH, DISPLAY_HEIGHT), 1)
    draw   = ImageDraw.Draw(canvas)
    y = 0

    font_lg = load_font(14)
    font_md = load_font(11)
    font_sm = load_font(9)

    # ── Inverted header bar ───────────────────────────────────────────────
    draw.rectangle([(0, y), (DISPLAY_WIDTH - 1, y + 17)], fill=0)
    draw.text((4, y + 2),               "GhostPi",  font=font_lg, fill=1)
    draw.text((DISPLAY_WIDTH - 58, y + 4), "BOOTING", font=font_sm, fill=1)

    # ── Separator ─────────────────────────────────────────────────────────
    draw.line([(0, y + 18), (DISPLAY_WIDTH - 1, y + 18)], fill=0)

    # ── Body ──────────────────────────────────────────────────────────────
    draw.text((4, y + 25), "Initialising...",          font=font_md, fill=0)
    draw.text((4, y + 44), "Services loading.",        font=font_sm, fill=0)
    draw.text((4, y + 56), "Web UI starts after",      font=font_sm, fill=0)
    draw.text((4, y + 66), "button press (GPIO6).",    font=font_sm, fill=0)

    # ── Bottom rule + hint ────────────────────────────────────────────────
    draw.line([(0, y + 82), (DISPLAY_WIDTH - 1, y + 82)], fill=0)
    draw.text((4, y + 86), "SSH: 192.168.7.1 (usb0)", font=font_sm, fill=0)

    return canvas


def main():
    try:
        spi  = busio.SPI(board.SCK, MOSI=board.MOSI, MISO=board.MISO)
        cs   = digitalio.DigitalInOut(board.CE0)
        dc   = digitalio.DigitalInOut(getattr(board, f"D{EPD_DC_PIN}"))
        rst  = digitalio.DigitalInOut(getattr(board, f"D{EPD_RST_PIN}"))
        busy = digitalio.DigitalInOut(getattr(board, f"D{EPD_BUSY_PIN}"))

        epd = Adafruit_SSD1680B(
            122, 250, spi,
            cs_pin=cs, dc_pin=dc, sramcs_pin=None,
            rst_pin=rst, busy_pin=busy,
        )
        epd.rotation = 1

        epd.image(draw_splash().convert("L"))
        epd.display()
        print("ghostpi-splash: boot screen displayed", file=sys.stderr)

    except Exception as exc:
        # Log the reason but never block boot
        print(f"ghostpi-splash: display error ({exc})", file=sys.stderr)


if __name__ == "__main__":
    main()
