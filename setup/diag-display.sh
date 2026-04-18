#!/usr/bin/env bash
# Quick e-ink display diagnostics — run on the Pi as root.
# Reports SPI state, library imports, and pin accessibility.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
fail() { echo -e "${RED}[FAIL]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }

echo "=== GhostPi display diagnostics ==="
echo ""

# ── 1. SPI device nodes ───────────────────────────────────────────────────────
echo "--- SPI ---"
if ls /dev/spidev0.0 /dev/spidev0.1 &>/dev/null; then
    ok "/dev/spidev0.0 and /dev/spidev0.1 present"
else
    fail "SPI device nodes missing — SPI is not enabled"
    echo "       Fix: add 'dtparam=spi=on' to /boot/firmware/config.txt and reboot"
fi

# ── 2. config.txt SPI flag ────────────────────────────────────────────────────
for cfg in /boot/firmware/config.txt /boot/config.txt; do
    [[ -f "$cfg" ]] || continue
    if grep -q "^dtparam=spi=on" "$cfg"; then
        ok "dtparam=spi=on found in $cfg"
    else
        warn "dtparam=spi=on NOT found in $cfg"
    fi
    break
done

echo ""
echo "--- Python libraries ---"

# ── 3. adafruit-blinka (board module) ─────────────────────────────────────────
BOARD_OUT=$(python3 -c "import board; print('OK')" 2>&1)
if [[ "$BOARD_OUT" == "OK" ]]; then
    ok "import board"
else
    fail "import board: $BOARD_OUT"
fi

# ── 4. busio / digitalio ──────────────────────────────────────────────────────
BUSIO_OUT=$(python3 -c "import busio, digitalio; print('OK')" 2>&1)
if [[ "$BUSIO_OUT" == "OK" ]]; then
    ok "import busio, digitalio"
else
    fail "import busio/digitalio: $BUSIO_OUT"
fi

# ── 5. adafruit_epd ───────────────────────────────────────────────────────────
EPD_OUT=$(python3 -c "from adafruit_epd.ssd1680b import Adafruit_SSD1680B; print('OK')" 2>&1)
if [[ "$EPD_OUT" == "OK" ]]; then
    ok "from adafruit_epd.ssd1680b import Adafruit_SSD1680B"
else
    fail "adafruit_epd.ssd1680b: $EPD_OUT"
fi

# ── 6. PIL ────────────────────────────────────────────────────────────────────
PIL_OUT=$(python3 -c "from PIL import Image, ImageDraw, ImageFont; print('OK')" 2>&1)
if [[ "$PIL_OUT" == "OK" ]]; then
    ok "PIL/Pillow"
else
    fail "PIL: $PIL_OUT"
fi

echo ""
echo "--- Board pin detection ---"

# ── 7. Check pins are accessible ──────────────────────────────────────────────
python3 - <<'PYEOF'
import sys
try:
    import board, digitalio
    pins = {"D8 (CS)": "D8", "D22 (DC)": "D22", "D27 (RST)": "D27", "D17 (BUSY)": "D17"}
    for label, name in pins.items():
        try:
            p = digitalio.DigitalInOut(getattr(board, name))
            p.deinit()
            print(f"\033[0;32m[OK]\033[0m    board.{name} ({label})")
        except Exception as e:
            print(f"\033[0;31m[FAIL]\033[0m  board.{name} ({label}): {e}")
except Exception as e:
    print(f"\033[0;31m[FAIL]\033[0m  Cannot test pins: {e}")
PYEOF

echo ""
echo "--- Full init attempt ---"

# ── 8. Attempt actual display init ────────────────────────────────────────────
python3 - <<'PYEOF'
import sys
try:
    import board, busio, digitalio
    from adafruit_epd.ssd1680b import Adafruit_SSD1680B

    spi  = busio.SPI(board.SCK, MOSI=board.MOSI, MISO=board.MISO)
    cs   = digitalio.DigitalInOut(board.CE0)
    dc   = digitalio.DigitalInOut(board.D22)
    rst  = digitalio.DigitalInOut(board.D27)
    busy = digitalio.DigitalInOut(board.D17)

    print("Attempting Adafruit_SSD1680B init (may take 2-3s)...")
    epd = Adafruit_SSD1680B(122, 250, spi,
                            cs_pin=cs, dc_pin=dc, sramcs_pin=None,
                            rst_pin=rst, busy_pin=busy)
    epd.rotation = 1
    print(f"\033[0;32m[OK]\033[0m    SSD1680B init succeeded! width={epd.width} height={epd.height}")
except Exception as e:
    print(f"\033[0;31m[FAIL]\033[0m  SSD1680B init failed: {e}")
    import traceback; traceback.print_exc()
PYEOF

echo ""
echo "=== Done ==="
