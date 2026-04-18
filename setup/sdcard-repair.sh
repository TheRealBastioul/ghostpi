#!/usr/bin/env bash
# sdcard-repair.sh — Fix GhostPi SD card from a Linux host (no Pi needed).
#
# Run this when:
#  - SSH won't connect over USB after boot
#  - The USB gadget (usb0) interface doesn't appear
#  - You need to re-enable SSH or fix boot config
#  - You want to push updated GhostPi files to the card
#
# Usage:
#   sudo bash setup/sdcard-repair.sh                    # auto-detect mounts
#   sudo bash setup/sdcard-repair.sh --device /dev/sdb  # auto-mount from device
#   sudo bash setup/sdcard-repair.sh --boot /media/user/bootfs --root /media/user/rootfs
#   sudo bash setup/sdcard-repair.sh --status            # read-only diagnostics only
#
# What it fixes (all idempotent — safe to run multiple times):
#   1. User  — creates user in rootfs passwd/shadow with password ghostpi
#   2. SSH   — enables ssh.service via systemd symlink; writes sshd_config.d/ghostpi.conf
#   3. USB OTG — adds modules-load=dwc2,g_ether to cmdline.txt
#   4. SPI   — adds dtparam=spi=on + dtoverlay=dwc2 to config.txt
#   5. usb0 IP — writes static IP (192.168.7.1) block to dhcpcd.conf
#   6. dnsmasq — writes DHCP config for usb0 subnet
#   7. GhostPi files — copies app files from this repo if missing

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
info()  { echo -e "        $*"; }
banner(){ echo -e "\n${BOLD}── $* ──${NC}"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEVICE=""
BOOT_DIR=""
ROOT_DIR=""
STATUS_ONLY=false
MOUNTED_BOOT=false
MOUNTED_ROOT=false
PI_USER="admin"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device|-d)  DEVICE="$2"; shift 2 ;;
        --boot)       BOOT_DIR="$2"; shift 2 ;;
        --root)       ROOT_DIR="$2"; shift 2 ;;
        --user)       PI_USER="$2"; shift 2 ;;
        --status)     STATUS_ONLY=true; shift ;;
        --help|-h)
            sed -n '2,25p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo bash $0"

# ── Find/mount partitions ─────────────────────────────────────────────────────
if [[ -n "$DEVICE" ]]; then
    BOOT_DIR="$(mktemp -d /tmp/ghostpi-boot-XXXX)"
    ROOT_DIR="$(mktemp -d /tmp/ghostpi-root-XXXX)"
    mount "${DEVICE}1" "$BOOT_DIR" && MOUNTED_BOOT=true \
        || die "Cannot mount ${DEVICE}1 (boot)"
    mount "${DEVICE}2" "$ROOT_DIR" && MOUNTED_ROOT=true \
        || die "Cannot mount ${DEVICE}2 (root)"
elif [[ -z "$BOOT_DIR" || -z "$ROOT_DIR" ]]; then
    # Auto-detect: look for mounted Pi partitions
    for mp in /media/*/* /mnt/*; do
        [[ -f "$mp/config.txt" ]] && BOOT_DIR="$mp" && break
    done
    for mp in /media/*/* /mnt/*; do
        [[ -d "$mp/etc" && -d "$mp/usr" && -f "$mp/etc/hostname" ]] \
            && ROOT_DIR="$mp" && break
    done
    [[ -n "$BOOT_DIR" ]] || die "Cannot find boot partition. Use --boot /path or --device /dev/sdX"
    [[ -n "$ROOT_DIR" ]] || die "Cannot find root partition. Use --root /path or --device /dev/sdX"
fi

cleanup() {
    $MOUNTED_BOOT && { umount -l "$BOOT_DIR" 2>/dev/null; rmdir "$BOOT_DIR" 2>/dev/null; }
    $MOUNTED_ROOT && { umount -l "$ROOT_DIR" 2>/dev/null; rmdir "$ROOT_DIR" 2>/dev/null; }
}
trap cleanup EXIT

# Verify these look like the right partitions
[[ -f "$BOOT_DIR/config.txt" ]] \
    || die "No config.txt at $BOOT_DIR — wrong partition?"
[[ -d "$ROOT_DIR/etc" && -d "$ROOT_DIR/usr" ]] \
    || die "$ROOT_DIR doesn't look like a root filesystem"

echo ""
echo -e "${BOLD}GhostPi SD card repair${NC}"
echo "  Boot: $BOOT_DIR"
echo "  Root: $ROOT_DIR"
echo "  Mode: $(${STATUS_ONLY} && echo 'status only' || echo 'repair')"
echo ""

# ─── Status checks ────────────────────────────────────────────────────────────
banner "Status"

# User account in rootfs
if grep -q "^${PI_USER}:" "$ROOT_DIR/etc/passwd" 2>/dev/null; then
    ok  "User '${PI_USER}' present in rootfs"
else
    fail "User '${PI_USER}' missing from rootfs passwd — repair will add it"
fi

# SSH service enabled
if [[ -L "$ROOT_DIR/etc/systemd/system/multi-user.target.wants/ssh.service" ]] || \
   [[ -L "$ROOT_DIR/etc/systemd/system/multi-user.target.wants/sshd.service" ]]; then
    ok  "SSH service enabled (systemd symlink present)"
elif [[ -f "$BOOT_DIR/ssh" ]]; then
    ok  "SSH boot flag present (sshswitch.service will enable SSH on first boot)"
else
    fail "SSH not enabled — neither systemd symlink nor boot flag found"
fi

# USB OTG
if grep -q "modules-load=dwc2" "$BOOT_DIR/cmdline.txt" 2>/dev/null; then
    ok  "cmdline.txt: USB OTG (dwc2,g_ether) present"
else
    fail "cmdline.txt: USB OTG modules missing — usb0 won't appear"
fi

# SPI
if grep -q "dtparam=spi=on" "$BOOT_DIR/config.txt" 2>/dev/null; then
    ok  "config.txt: SPI enabled"
else
    fail "config.txt: SPI not enabled — e-ink display won't work"
fi

# dwc2 overlay
if grep -q "dtoverlay=dwc2" "$BOOT_DIR/config.txt" 2>/dev/null; then
    ok  "config.txt: dtoverlay=dwc2 present"
else
    fail "config.txt: dtoverlay=dwc2 missing — USB gadget won't work"
fi

# usb0 static IP
if grep -q "interface usb0" "$ROOT_DIR/etc/dhcpcd.conf" 2>/dev/null; then
    ok  "dhcpcd.conf: usb0 static IP configured"
else
    fail "dhcpcd.conf: usb0 static IP missing — SSH over USB won't get IP"
fi

# dnsmasq
if [[ -f "$ROOT_DIR/etc/dnsmasq.d/ghostpi-usb.conf" ]]; then
    ok  "dnsmasq: ghostpi-usb.conf present"
else
    fail "dnsmasq: ghostpi-usb.conf missing — DHCP for USB won't work"
fi

# GhostPi app
if [[ -f "$ROOT_DIR/home/$PI_USER/ghostpi/ghostpi/main.py" ]]; then
    ok  "GhostPi app files present (/home/$PI_USER/ghostpi/)"
else
    fail "GhostPi app files missing"
fi


$STATUS_ONLY && { echo ""; echo "Status check complete (read-only)."; exit 0; }

# ─── Repairs ──────────────────────────────────────────────────────────────────
banner "Applying fixes"

# ── 1. User account — write directly into rootfs passwd/shadow ───────────────
# This is reliable across all Pi OS versions and survives re-runs.
# custom.toml only works on first boot — not suitable for repair.

PASSWD_FILE="$ROOT_DIR/etc/passwd"
SHADOW_FILE="$ROOT_DIR/etc/shadow"

if grep -q "^${PI_USER}:" "$PASSWD_FILE" 2>/dev/null; then
    ok "User '${PI_USER}' already exists in rootfs"
else
    # Find a free UID ≥ 1000
    NEXT_UID=1000
    while grep -q ":${NEXT_UID}:" "$PASSWD_FILE" 2>/dev/null; do
        (( NEXT_UID++ ))
    done
    # Create home directory
    mkdir -p "$ROOT_DIR/home/${PI_USER}"
    # Add passwd entry (uid=gid=NEXT_UID, home=/home/PI_USER, shell=/bin/bash)
    echo "${PI_USER}:x:${NEXT_UID}:${NEXT_UID}::/home/${PI_USER}:/bin/bash" >> "$PASSWD_FILE"
    # Add group entry
    [[ -f "$ROOT_DIR/etc/group" ]] && \
        echo "${PI_USER}:x:${NEXT_UID}:" >> "$ROOT_DIR/etc/group"
    # Add sudo group membership
    sed -i "s/^sudo:.*/&,${PI_USER}/" "$ROOT_DIR/etc/group" 2>/dev/null || true
    ok "User '${PI_USER}' added to rootfs (UID ${NEXT_UID})"
fi

# Set/reset password in shadow (works whether user existed or was just created)
if command -v openssl &>/dev/null; then
    HASHED_PW="$(openssl passwd -6 'ghostpi')"
    if grep -q "^${PI_USER}:" "$SHADOW_FILE" 2>/dev/null; then
        # Update existing shadow entry
        sed -i "s|^${PI_USER}:[^:]*:|${PI_USER}:${HASHED_PW}:|" "$SHADOW_FILE"
    else
        echo "${PI_USER}:${HASHED_PW}:19900:0:99999:7:::" >> "$SHADOW_FILE"
    fi
    ok "Password set for '${PI_USER}' (ghostpi)"
else
    warn "openssl not found — cannot set password. Set it manually via: passwd ${PI_USER}"
fi

# Allow SSH password auth
mkdir -p "$ROOT_DIR/etc/ssh/sshd_config.d"
cat > "$ROOT_DIR/etc/ssh/sshd_config.d/ghostpi.conf" << 'SSHCONF'
PasswordAuthentication yes
PermitRootLogin no
SSHCONF
ok "sshd: password authentication enabled"

# ── 2. Enable SSH via systemd symlink (works before first boot) ───────────────
SYSTEMD_WANTS="$ROOT_DIR/etc/systemd/system/multi-user.target.wants"
mkdir -p "$SYSTEMD_WANTS"
SSH_ENABLED=false
for candidate in \
    "$ROOT_DIR/lib/systemd/system/ssh.service" \
    "$ROOT_DIR/usr/lib/systemd/system/ssh.service" \
    "$ROOT_DIR/lib/systemd/system/sshd.service" \
    "$ROOT_DIR/usr/lib/systemd/system/sshd.service"
do
    if [[ -f "$candidate" ]]; then
        SSH_UNIT_ABS="${candidate#$ROOT_DIR}"
        ln -sf "$SSH_UNIT_ABS" "$SYSTEMD_WANTS/$(basename "$candidate")"
        ok "SSH service enabled via systemd symlink"
        SSH_ENABLED=true
        break
    fi
done
$SSH_ENABLED || { touch "$BOOT_DIR/ssh"; warn "SSH unit not found — boot flag set as fallback"; }

# ── 3. cmdline.txt: USB OTG modules ──────────────────────────────────────────
if [[ -f "$BOOT_DIR/cmdline.txt" ]] && ! grep -q "modules-load=dwc2" "$BOOT_DIR/cmdline.txt"; then
    sed -i 's/$/ modules-load=dwc2,g_ether/' "$BOOT_DIR/cmdline.txt"
    ok "cmdline.txt: modules-load=dwc2,g_ether added"
else
    ok "cmdline.txt: USB OTG already configured"
fi

# ── 4. config.txt: SPI + dwc2 overlay ────────────────────────────────────────
CONFIG_TXT="$BOOT_DIR/config.txt"
ADDED_CONFIG=false

if ! grep -q "dtparam=spi=on" "$CONFIG_TXT"; then
    echo "dtparam=spi=on" >> "$CONFIG_TXT"
    ADDED_CONFIG=true
fi
if ! grep -q "dtoverlay=dwc2" "$CONFIG_TXT"; then
    echo "dtoverlay=dwc2" >> "$CONFIG_TXT"
    ADDED_CONFIG=true
fi
$ADDED_CONFIG && ok "config.txt: SPI/dwc2 settings added" \
              || ok "config.txt: already configured"

# ── 5. dhcpcd.conf: usb0 static IP ──────────────────────────────────────────
DHCPCD="$ROOT_DIR/etc/dhcpcd.conf"
if ! grep -q "interface usb0" "$DHCPCD" 2>/dev/null; then
    cat >> "$DHCPCD" << 'EOF'

# GhostPi USB gadget static IP
interface usb0
static ip_address=192.168.7.1/24
static routers=
static domain_name_servers=
EOF
    ok "dhcpcd.conf: usb0 static IP added (192.168.7.1)"
else
    ok "dhcpcd.conf: usb0 already configured"
fi

# ── 6. dnsmasq config ────────────────────────────────────────────────────────
DNSMASQ_CONF="$ROOT_DIR/etc/dnsmasq.d/ghostpi-usb.conf"
mkdir -p "$ROOT_DIR/etc/dnsmasq.d"
if [[ ! -f "$DNSMASQ_CONF" ]]; then
    cat > "$DNSMASQ_CONF" << 'EOF'
# GhostPi: DHCP for USB gadget clients (laptop connecting over USB)
interface=usb0
dhcp-range=192.168.7.2,192.168.7.10,255.255.255.0,24h
dhcp-option=3            # no default route
dhcp-option=6            # no DNS server
EOF
    ok "dnsmasq: ghostpi-usb.conf written"
else
    ok "dnsmasq: config already present"
fi

# ── 7. GhostPi app files ─────────────────────────────────────────────────────
APP_DEST="$ROOT_DIR/home/$PI_USER/ghostpi"
if [[ ! -f "$APP_DEST/ghostpi/main.py" ]]; then
    mkdir -p "$APP_DEST"
    tar -C "$REPO_DIR" \
        --exclude='.git' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        --exclude='logs' \
        -cf - . | tar -C "$APP_DEST" -xf -
    # Fix ownership: get UID/GID of the user in the rootfs
    PI_UID="$(grep "^${PI_USER}:" "$ROOT_DIR/etc/passwd" | cut -d: -f3)" || PI_UID="1000"
    PI_GID="$(grep "^${PI_USER}:" "$ROOT_DIR/etc/passwd" | cut -d: -f4)" || PI_GID="1000"
    chown -R "${PI_UID}:${PI_GID}" "$APP_DEST"
    ok "GhostPi app files copied to $APP_DEST"
else
    ok "GhostPi app files already present"
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  SD card repair complete${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  SSH credentials  : user=${PI_USER}  password=ghostpi"
echo "  !! Change the password after first login: passwd"
echo ""
echo "  After inserting card and booting Pi:"
echo "  1. Plug Pi DATA USB port (not power) into laptop"
echo "  2. Wait ~30s for usb0 to appear on laptop"
echo "  3. ssh ${PI_USER}@192.168.7.1"
echo ""
echo -e "${YELLOW}  Troubleshooting SSH:${NC}"
echo "  - 'Connection refused': SSH service not running — check sshd_config"
echo "  - 'No route to host':   usb0 not up — check cmdline.txt dwc2 entry"
echo "  - 'Permission denied':  wrong password — re-run this script to reset"
echo "  - Pi OS may ask to change password on first login (expected)"
echo ""
