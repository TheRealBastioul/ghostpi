#!/usr/bin/env bash
# GhostPi installation script — runs directly on the Pi via SSH.
#
# What this script does:
#   1. Install system packages (aircrack-ng, Python deps, flask, dnsmasq)
#   2. Install Python packages (adafruit-blinka, rpi-lgpio, adafruit-circuitpython-epd)
#   3. Apply all boot_config.txt settings to config.txt (SPI, USB OTG, GPU, etc.)
#   4. Configure usb0 static IP and dnsmasq DHCP for operator connectivity
#   5. Install and enable ghostpi.service and ghostpi-splash.service
#
# Usage: sudo bash setup/install.sh

set -euo pipefail

GHOSTPI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTPI_USER="${SUDO_USER:-admin}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

# Find the boot partition config files (Pi OS Trixie uses /boot/firmware/)
find_boot_file() {
    local name="$1"
    for p in "/boot/firmware/$name" "/boot/$name"; do
        [[ -f "$p" ]] && { echo "$p"; return 0; }
    done
    echo ""
}

[[ $EUID -eq 0 ]] || die "Run with sudo or as root"

log "GhostPi installation starting"
log "Project dir: ${GHOSTPI_DIR}"
log "User: ${GHOSTPI_USER}"

# ── 1. System packages ────────────────────────────────────────────────────────
log "Updating package list..."
apt-get update -qq

log "Installing system packages..."
apt-get install -y --no-install-recommends \
    aircrack-ng \
    python3 \
    python3-pip \
    python3-pillow \
    python3-flask \
    dnsmasq \
    iw \
    libopenjp2-7 \
    fonts-dejavu-core

# GPIO library — python3-rpi.gpio was renamed in Pi OS Trixie
if apt-get install -y --no-install-recommends python3-rpi-lgpio 2>/dev/null; then
    log "GPIO: python3-rpi-lgpio installed"
elif apt-get install -y --no-install-recommends python3-rpi.gpio 2>/dev/null; then
    log "GPIO: python3-rpi.gpio installed"
else
    warn "GPIO library not found via apt — will use pip rpi-lgpio"
fi

# ── 2. Python packages ────────────────────────────────────────────────────────
log "Installing Python packages (adafruit-blinka, rpi-lgpio, adafruit-circuitpython-epd)..."
pip3 install --break-system-packages --no-cache-dir \
    adafruit-blinka \
    rpi-lgpio \
    adafruit-circuitpython-epd

# ── 3. Boot partition config (config.txt + cmdline.txt) ──────────────────────
log "Applying boot_config.txt settings..."

CONFIG_TXT="$(find_boot_file config.txt)"
CMDLINE_TXT="$(find_boot_file cmdline.txt)"

if [[ -z "$CONFIG_TXT" ]]; then
    warn "config.txt not found — boot partition may not be mounted."
    warn "Manually add settings from setup/boot_config.txt to your boot config."
else
    log "Applying settings to $CONFIG_TXT ..."
    ADDED=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        KEY="${line%%=*}"
        if ! grep -q "^${KEY}" "$CONFIG_TXT" 2>/dev/null; then
            echo "$line" >> "$CONFIG_TXT"
            (( ADDED++ )) || true
        fi
    done < "${GHOSTPI_DIR}/setup/boot_config.txt"
    log "config.txt: $ADDED setting(s) added (SPI, USB OTG, GPU, LED, etc.)"
    # Load SPI module immediately for this session
    modprobe spi_bcm2835 2>/dev/null || true
fi

if [[ -z "$CMDLINE_TXT" ]]; then
    warn "cmdline.txt not found — USB OTG modules not added."
elif ! grep -q "modules-load=dwc2" "$CMDLINE_TXT"; then
    sed -i 's/$/ modules-load=dwc2,g_ether/' "$CMDLINE_TXT"
    log "cmdline.txt: modules-load=dwc2,g_ether added"
    modprobe g_ether 2>/dev/null || true
else
    log "cmdline.txt: USB OTG already configured"
fi

# ── 5. Static IP for usb0 (dhcpcd) ───────────────────────────────────────────
log "Configuring static IP for usb0 interface..."
DHCPCD_CONF="/etc/dhcpcd.conf"

if ! grep -q "interface usb0" "${DHCPCD_CONF}"; then
    cat >> "${DHCPCD_CONF}" << 'EOF'

# GhostPi USB gadget networking
interface usb0
static ip_address=192.168.7.1/24
static routers=
static domain_name_servers=
nohook wpa_supplicant
EOF
    log "usb0 static IP added to ${DHCPCD_CONF}"
else
    log "usb0 already configured in ${DHCPCD_CONF}"
fi

# ── 6. dnsmasq for DHCP on usb0 ──────────────────────────────────────────────
# Provides the host PC with an IP in 192.168.7.0/24 automatically.
# Note: hostapd is NOT needed for USB ethernet gadget networking.
log "Configuring dnsmasq for USB DHCP..."

cat > /etc/dnsmasq.d/ghostpi-usb.conf << 'EOF'
# GhostPi – USB gadget (usb0) DHCP
# Serves a single IP to the connected operator laptop.
interface=usb0
dhcp-range=192.168.7.2,192.168.7.10,255.255.255.0,12h
dhcp-option=option:router
dhcp-option=option:dns-server
# Do not forward local DNS queries to upstream
domain-needed
bogus-priv
no-resolv
EOF

# Prevent dnsmasq from touching wlan0
if ! grep -q "except-interface=wlan0" /etc/dnsmasq.d/ghostpi-usb.conf; then
    echo "except-interface=wlan0" >> /etc/dnsmasq.d/ghostpi-usb.conf
fi

# Enable dnsmasq
systemctl enable dnsmasq
systemctl restart dnsmasq || warn "dnsmasq restart failed (will start on next boot)"

# ── 7. Directories and permissions ───────────────────────────────────────────
log "Creating log directories..."
mkdir -p "${GHOSTPI_DIR}/logs/handshakes"
chown -R "${GHOSTPI_USER}:${GHOSTPI_USER}" "${GHOSTPI_DIR}/logs" 2>/dev/null || true

# ── 8. systemd services ───────────────────────────────────────────────────────
log "Installing GhostPi systemd services..."
cp "${GHOSTPI_DIR}/systemd/ghostpi.service"        /etc/systemd/system/ghostpi.service
cp "${GHOSTPI_DIR}/systemd/ghostpi-splash.service" /etc/systemd/system/ghostpi-splash.service
systemctl daemon-reload
systemctl enable ghostpi.service
systemctl enable ghostpi-splash.service
log "ghostpi.service and ghostpi-splash.service enabled."

# ── 9. Verify aircrack-ng ─────────────────────────────────────────────────────
log "Verifying aircrack-ng suite..."
for tool in airmon-ng airodump-ng aireplay-ng aircrack-ng; do
    if command -v "${tool}" &>/dev/null; then
        log "  OK: ${tool}"
    else
        warn "  MISSING: ${tool}"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " GhostPi installation complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Reboot to apply config.txt changes:"
echo "   sudo reboot"
echo ""
echo " After reboot:"
echo "   1. Plug Pi DATA USB port into your laptop"
echo "   2. SSH: ssh ${GHOSTPI_USER}@192.168.7.1  (password: ghostpi)"
echo "   3. Press ACTION (GPIO 6) on the bonnet to start the Web UI"
echo "   4. Open http://192.168.7.1"
echo ""
echo " Logs: journalctl -u ghostpi -f"
echo ""
echo " LEGAL: only use on networks you own or have written"
echo " authorization to test.  Active mode disabled by default."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
