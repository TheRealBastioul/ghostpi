#!/usr/bin/env bash
# repair.sh — GhostPi repair and reinstall tool.
# Runs on the Pi itself via SSH.  No internet required — packages stay as-is.
#
# Usage:
#   sudo bash ~/ghostpi/setup/repair.sh           # full repair
#   sudo bash ~/ghostpi/setup/repair.sh --status  # diagnostics only, no changes

set -euo pipefail

GHOSTPI_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GHOSTPI_USER="${SUDO_USER:-admin}"
STATUS_ONLY=false

# ─── Colour helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; }
banner(){ echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}"; }

# ─── Args ────────────────────────────────────────────────────────────────────

for arg in "$@"; do
    case "$arg" in
        --status|-s) STATUS_ONLY=true ;;
        --help|-h)
            echo "Usage: sudo bash $0 [--status]"
            echo "  (no flags)  Full repair: service + network + boot config"
            echo "  --status    Diagnostics only — no changes made"
            exit 0 ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }

# ─── Status / diagnostics ────────────────────────────────────────────────────

print_status() {
    banner "GhostPi status"
    echo ""

    # Service state
    local svc_state
    svc_state="$(systemctl is-active ghostpi 2>/dev/null || echo 'inactive')"
    local svc_enabled
    svc_enabled="$(systemctl is-enabled ghostpi 2>/dev/null || echo 'disabled')"
    if [[ "$svc_state" == "active" ]]; then
        ok "ghostpi.service   : $svc_state / $svc_enabled"
    else
        fail "ghostpi.service   : $svc_state / $svc_enabled"
    fi

    local splash_enabled
    splash_enabled="$(systemctl is-enabled ghostpi-splash 2>/dev/null || echo 'disabled')"
    ok "ghostpi-splash    : $splash_enabled (one-shot, runs at boot)"

    local dns_state
    dns_state="$(systemctl is-active dnsmasq 2>/dev/null || echo 'inactive')"
    if [[ "$dns_state" == "active" ]]; then
        ok "dnsmasq.service   : $dns_state"
    else
        warn "dnsmasq.service   : $dns_state"
    fi

    # USB interface
    if ip link show usb0 &>/dev/null; then
        local usb_ip
        usb_ip="$(ip -4 addr show usb0 2>/dev/null | grep -oP '(?<=inet )\S+' || echo 'no IP')"
        ok "usb0 interface    : up  ($usb_ip)"
    else
        warn "usb0 interface    : not present (USB cable not connected?)"
    fi

    # WiFi / monitor mode
    if ip link show wlan0 &>/dev/null; then
        ok "wlan0             : present"
    else
        warn "wlan0             : not found"
    fi

    # aircrack-ng suite
    local all_tools=true
    for tool in airmon-ng airodump-ng aireplay-ng aircrack-ng; do
        if ! command -v "$tool" &>/dev/null; then
            fail "aircrack-ng tool  : $tool missing"
            all_tools=false
        fi
    done
    $all_tools && ok "aircrack-ng suite : all tools present"

    # Python packages (use the actual import names, not the pip package names)
    local py_ok=true
    for pkg in adafruit_epd flask RPi PIL; do
        if ! python3 -c "import $pkg" &>/dev/null; then
            fail "Python package    : $pkg not importable"
            py_ok=false
        fi
    done
    $py_ok && ok "Python packages   : all importable (adafruit_epd, flask, RPi, PIL)"

    # Config files
    [[ -f /etc/dnsmasq.d/ghostpi-usb.conf ]] \
        && ok "dnsmasq config    : present" \
        || fail "dnsmasq config    : /etc/dnsmasq.d/ghostpi-usb.conf missing"

    grep -q 'interface usb0' /etc/dhcpcd.conf 2>/dev/null \
        && ok "dhcpcd config     : usb0 entry present" \
        || warn "dhcpcd config     : usb0 static IP entry missing"

    # Boot config — handle both old (/boot) and Bookworm (/boot/firmware) paths
    local config_txt=""
    for p in /boot/firmware/config.txt /boot/config.txt; do
        [[ -f "$p" ]] && { config_txt="$p"; break; }
    done
    if [[ -n "$config_txt" ]]; then
        grep -q 'dtoverlay=dwc2' "$config_txt" \
            && ok "boot config       : dwc2 overlay present ($config_txt)" \
            || warn "boot config       : dtoverlay=dwc2 missing in $config_txt"
        grep -q 'dtparam=spi=on' "$config_txt" \
            && ok "boot config       : SPI enabled" \
            || warn "boot config       : dtparam=spi=on missing"
    else
        warn "boot config       : config.txt not found"
    fi

    # App files
    [[ -f "$GHOSTPI_DIR/ghostpi/main.py" ]] \
        && ok "app files         : main.py present ($GHOSTPI_DIR)" \
        || fail "app files         : main.py missing — run full repair"

    # Recent log
    echo ""
    info "Last 10 log lines:"
    journalctl -u ghostpi -n 10 --no-pager 2>/dev/null || echo "  (no journal entries yet)"
    echo ""
}

print_status

$STATUS_ONLY && exit 0

# ─── Full repair ─────────────────────────────────────────────────────────────

banner "Starting repair"

# ── 1. Stop running service ───────────────────────────────────────────────────

info "Stopping ghostpi service..."
systemctl stop ghostpi 2>/dev/null || true
# Kill any stray airmon-ng / airodump-ng processes left over from a crash
pkill -f airodump-ng 2>/dev/null || true
pkill -f airmon-ng   2>/dev/null || true
ok "Service stopped."

# ── 2. Restore monitor interface if stuck ─────────────────────────────────────

if iw dev wlan0mon info &>/dev/null 2>&1; then
    info "Removing stuck wlan0mon interface..."
    airmon-ng stop wlan0mon 2>/dev/null || ip link delete wlan0mon 2>/dev/null || true
    ok "wlan0mon removed."
fi

# ── 3. Log directory ──────────────────────────────────────────────────────────

info "Ensuring log directories exist..."
mkdir -p "${GHOSTPI_DIR}/logs/handshakes"
chown -R "${GHOSTPI_USER}:${GHOSTPI_USER}" "${GHOSTPI_DIR}/logs" 2>/dev/null || true
ok "Log directories OK."

# ── 4. Systemd services ───────────────────────────────────────────────────────

info "Reinstalling systemd services..."
cp "${GHOSTPI_DIR}/systemd/ghostpi.service"        /etc/systemd/system/ghostpi.service
cp "${GHOSTPI_DIR}/systemd/ghostpi-splash.service" /etc/systemd/system/ghostpi-splash.service
systemctl daemon-reload
systemctl enable ghostpi.service
systemctl enable ghostpi-splash.service
ok "ghostpi.service and ghostpi-splash.service reinstalled and enabled."

# ── 5. Network configs ────────────────────────────────────────────────────────

info "Restoring dnsmasq config..."
mkdir -p /etc/dnsmasq.d
cat > /etc/dnsmasq.d/ghostpi-usb.conf << 'EOF'
# GhostPi – USB gadget (usb0) DHCP
interface=usb0
dhcp-range=192.168.7.2,192.168.7.10,255.255.255.0,12h
dhcp-option=option:router
dhcp-option=option:dns-server
except-interface=wlan0
domain-needed
bogus-priv
no-resolv
EOF
ok "dnsmasq config written."

info "Checking dhcpcd usb0 static IP..."
if ! grep -q 'interface usb0' /etc/dhcpcd.conf; then
    cat >> /etc/dhcpcd.conf << 'EOF'

# GhostPi USB gadget networking
interface usb0
static ip_address=192.168.7.1/24
static routers=
static domain_name_servers=
nohook wpa_supplicant
EOF
    ok "dhcpcd.conf: usb0 static IP added."
else
    ok "dhcpcd.conf: usb0 entry already present."
fi

# ── 6. Boot config (best-effort — partition may not be mounted) ───────────────

CONFIG_TXT=""
for p in /boot/firmware/config.txt /boot/config.txt; do
    [[ -f "$p" ]] && { CONFIG_TXT="$p"; break; }
done

if [[ -n "$CONFIG_TXT" ]]; then
    REPAIR_ADDED=0
    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        KEY="${line%%=*}"
        if ! grep -q "^${KEY}" "$CONFIG_TXT" 2>/dev/null; then
            echo "$line" >> "$CONFIG_TXT"
            (( REPAIR_ADDED++ )) || true
        fi
    done < "${GHOSTPI_DIR}/setup/boot_config.txt"
    if [[ $REPAIR_ADDED -gt 0 ]]; then
        ok "Boot config: $REPAIR_ADDED setting(s) added to $CONFIG_TXT — reboot required."
    else
        ok "Boot config: all settings already present in $CONFIG_TXT."
    fi

    local_cmdline=""
    for p in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
        [[ -f "$p" ]] && { local_cmdline="$p"; break; }
    done
    if [[ -n "$local_cmdline" ]] && ! grep -q 'modules-load=dwc2' "$local_cmdline"; then
        sed -i 's/$/ modules-load=dwc2,g_ether/' "$local_cmdline"
        ok "cmdline.txt: USB OTG modules added."
    fi
else
    warn "Boot partition not accessible — skipping config.txt check."
    warn "If USB OTG (usb0) is missing after reboot, re-run prepare-sd.sh from your Linux machine."
fi

# ── 7. Restart services ───────────────────────────────────────────────────────

info "Restarting dnsmasq..."
systemctl enable dnsmasq 2>/dev/null || true
systemctl restart dnsmasq && ok "dnsmasq restarted." || warn "dnsmasq restart failed — check: journalctl -u dnsmasq"

info "Starting ghostpi..."
systemctl start ghostpi && ok "ghostpi started." || warn "ghostpi failed to start — check: journalctl -u ghostpi -f"

# ── 8. Final status ───────────────────────────────────────────────────────────

banner "Post-repair status"
print_status

echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  Repair complete.${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Web UI   : http://192.168.7.1  (connect USB data cable first)"
echo "  Logs     : journalctl -u ghostpi -f"
echo ""
echo "  If issues persist and packages are broken, re-prep the SD card"
echo "  from your Linux machine:  sudo bash setup/prepare-sd.sh --device /dev/sdX"
echo ""
