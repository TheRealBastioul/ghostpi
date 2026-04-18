#!/usr/bin/env bash
# GhostPi installation script
# Run as root on a fresh Raspberry Pi OS Lite (32-bit) image.
#
# What this script does:
#   1. Install system packages (aircrack-ng, Python deps, flask, dnsmasq)
#   2. Enable SPI (for e-ink bonnet) and USB OTG gadget mode
#   3. Configure usb0 static IP and dnsmasq DHCP for operator connectivity
#   4. Install Python packages (adafruit-circuitpython-epd, RPi.GPIO, flask)
#   5. Install and enable the GhostPi systemd service
#
# Usage: sudo bash setup/install.sh

set -euo pipefail

GHOSTPI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTPI_USER="${SUDO_USER:-admin}"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

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
    python3-venv \
    python3-dev \
    python3-rpi.gpio \
    python3-pillow \
    python3-flask \
    dnsmasq \
    iw \
    wireless-tools \
    net-tools \
    libopenjp2-7 \
    fonts-dejavu-core

# ── 2. Python packages ────────────────────────────────────────────────────────
log "Installing Python packages..."
pip3 install --break-system-packages \
    adafruit-blinka \
    rpi-lgpio \
    adafruit-circuitpython-epd \
    flask

# ── 3. Enable SPI ─────────────────────────────────────────────────────────────
log "Enabling SPI interface..."
if ! grep -q "^dtparam=spi=on" /boot/config.txt; then
    echo "dtparam=spi=on" >> /boot/config.txt
    log "SPI enabled in /boot/config.txt"
else
    log "SPI already enabled"
fi

# Load SPI module immediately (for this session)
modprobe spi_bcm2835 2>/dev/null || true

# ── 4. USB OTG gadget mode (g_ether) ─────────────────────────────────────────
# The Pi Zero OTG port will appear as a USB ethernet adapter on the host PC.
# This is the sole channel for the web UI (no WiFi needed for management).
log "Configuring USB OTG gadget mode..."

# /boot/config.txt: dwc2 overlay enables OTG
if ! grep -q "dtoverlay=dwc2" /boot/config.txt; then
    echo "dtoverlay=dwc2" >> /boot/config.txt
    log "dwc2 overlay added to /boot/config.txt"
fi

# /boot/cmdline.txt: load dwc2 and g_ether at boot
CMDLINE_FILE="/boot/cmdline.txt"
if ! grep -q "modules-load=dwc2" "${CMDLINE_FILE}"; then
    # Insert after 'rootwait' (standard Pi cmdline position)
    sed -i 's/rootwait/rootwait modules-load=dwc2,g_ether/' "${CMDLINE_FILE}"
    log "modules-load=dwc2,g_ether added to ${CMDLINE_FILE}"
else
    log "dwc2 already in cmdline.txt"
fi

# Load g_ether immediately
modprobe g_ether 2>/dev/null || warn "g_ether module not loaded (normal if not in OTG mode)"

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

# ── 7. boot/config.txt additions ─────────────────────────────────────────────
log "Applying boot/config.txt settings from setup/boot_config.txt..."
log "(Skipping auto-append – review setup/boot_config.txt and add manually)"
log "  cat setup/boot_config.txt >> /boot/config.txt"

# ── 8. Directories and permissions ───────────────────────────────────────────
log "Creating log directories..."
mkdir -p "${GHOSTPI_DIR}/logs/handshakes"
chown -R "${GHOSTPI_USER}:${GHOSTPI_USER}" "${GHOSTPI_DIR}/logs" 2>/dev/null || true

# ── 9. systemd service ────────────────────────────────────────────────────────
log "Installing GhostPi systemd service..."
cp "${GHOSTPI_DIR}/systemd/ghostpi.service" /etc/systemd/system/ghostpi.service
systemctl daemon-reload
systemctl enable ghostpi.service
log "Service installed and enabled (will start on next boot)"

# ── 10. Verify aircrack-ng ────────────────────────────────────────────────────
log "Verifying aircrack-ng suite..."
for tool in airmon-ng airodump-ng aireplay-ng aircrack-ng; do
    if command -v "${tool}" &>/dev/null; then
        log "  OK: ${tool}"
    else
        warn "  MISSING: ${tool} – install aircrack-ng manually"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " GhostPi installation complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo " Next steps:"
echo "   1. Append setup/boot_config.txt to /boot/config.txt"
echo "      cat ${GHOSTPI_DIR}/setup/boot_config.txt >> /boot/config.txt"
echo ""
echo "   2. Reboot to apply all changes:"
echo "      sudo reboot"
echo ""
echo "   3. After reboot, connect Pi to laptop via USB (data port)."
echo "      Open http://192.168.7.1 in your browser."
echo ""
echo "   4. GhostPi starts automatically via systemd."
echo "      Check status: journalctl -u ghostpi -f"
echo ""
echo "   LEGAL: only use on networks you own or have written"
echo "   authorization to test.  Active mode is disabled by default."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
