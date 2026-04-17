#!/usr/bin/env bash
# prepare-sd.sh — Pre-install GhostPi onto a microSD card from a Linux host.
#
# Everything that can be done offline is done here: packages are downloaded and
# installed into the SD card's ARM rootfs via QEMU chroot, all configs are
# written, and systemd services are enabled by symlink.  The Pi just boots and
# runs — no SSH install step required.
#
# Target OS: Raspberry Pi OS Lite 32-bit, Trixie (2026-04-13 release)
# Target hardware: Raspberry Pi Zero WH
#
# Usage (run as root on your Linux machine with the SD card inserted):
#
#   # Auto-mount from device node:
#   sudo bash setup/prepare-sd.sh --device /dev/sdX
#
#   # If you already have both partitions mounted:
#   sudo bash setup/prepare-sd.sh --boot /mnt/sdboot --root /mnt/sdroot
#
#   # Custom Pi username (default: admin):
#   sudo bash setup/prepare-sd.sh --device /dev/sdX --user pi
#
# Host requirements: Debian/Ubuntu Linux.  The script will install
# qemu-user-static and binfmt-support automatically if missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

# ─── Defaults ────────────────────────────────────────────────────────────────

PI_USER="admin"
PI_UID="1000"
DEVICE=""
BOOT_DIR=""
ROOT_DIR=""
MOUNTED_BOOT=false
MOUNTED_ROOT=false
RESOLV_WAS_SYMLINK=false
RESOLV_SYMLINK_TARGET=""

# ─── Colour helpers ──────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
die()   { echo -e "${RED}[✗] $*${NC}" >&2; exit 1; }
banner(){ echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${NC}\n"; }

# ─── Argument parsing ─────────────────────────────────────────────────────────

usage() {
    echo "Usage: sudo bash $0 --device /dev/sdX [--user <username>]"
    echo "       sudo bash $0 --boot /mnt/sdboot --root /mnt/sdroot [--user <username>]"
    echo ""
    echo "  --device   Block device of the SD card (e.g. /dev/sdb)"
    echo "  --boot     Path where the FAT boot partition is already mounted"
    echo "  --root     Path where the ext4 root partition is already mounted"
    echo "  --user     Username you set in Raspberry Pi Imager (default: admin)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2";   shift 2 ;;
        --boot)   BOOT_DIR="$2"; shift 2 ;;
        --root)   ROOT_DIR="$2"; shift 2 ;;
        --user)   PI_USER="$2";  shift 2 ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

# ─── Preflight checks ─────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "This script must be run as root.  Use: sudo bash $0 ..."

if [[ -n "$DEVICE" && ( -n "$BOOT_DIR" || -n "$ROOT_DIR" ) ]]; then
    die "Specify --device OR --boot/--root, not both."
fi

if [[ -z "$DEVICE" && ( -z "$BOOT_DIR" || -z "$ROOT_DIR" ) ]]; then
    usage
fi

if [[ -n "$DEVICE" && ! -b "$DEVICE" ]]; then
    die "Device $DEVICE not found or is not a block device."
fi

# ─── Install host tools ───────────────────────────────────────────────────────

banner "Host toolchain"

MISSING=()
command -v qemu-arm-static &>/dev/null || MISSING+=(qemu-user-static)
dpkg -l binfmt-support &>/dev/null 2>&1   || MISSING+=(binfmt-support)

if [[ ${#MISSING[@]} -gt 0 ]]; then
    info "Installing host packages: ${MISSING[*]}"
    apt-get install -y "${MISSING[@]}"
    update-binfmts --enable qemu-arm 2>/dev/null || true
fi

[[ -f /usr/bin/qemu-arm-static ]] || die "qemu-arm-static not found. Install qemu-user-static."
ok "QEMU ARM emulation available."

# ─── Mount SD card partitions ─────────────────────────────────────────────────

banner "SD card"

if [[ -n "$DEVICE" ]]; then
    # Desktop Linux auto-mounts SD partitions (bootfs/rootfs) when inserted.
    # Detect existing mounts and reuse them instead of failing with "already mounted".
    EXISTING_BOOT="$(findmnt -n -o TARGET "${DEVICE}1" 2>/dev/null || true)"
    EXISTING_ROOT="$(findmnt -n -o TARGET "${DEVICE}2" 2>/dev/null || true)"

    if [[ -n "$EXISTING_BOOT" ]]; then
        info "${DEVICE}1 already mounted at $EXISTING_BOOT — reusing."
        BOOT_DIR="$EXISTING_BOOT"
    else
        BOOT_DIR="$(mktemp -d /tmp/ghostpi-boot-XXXX)"
        info "Mounting ${DEVICE}1 (bootfs) → $BOOT_DIR"
        mount "${DEVICE}1" "$BOOT_DIR" || die "Failed to mount ${DEVICE}1"
        MOUNTED_BOOT=true
    fi

    if [[ -n "$EXISTING_ROOT" ]]; then
        info "${DEVICE}2 already mounted at $EXISTING_ROOT — reusing."
        ROOT_DIR="$EXISTING_ROOT"
    else
        ROOT_DIR="$(mktemp -d /tmp/ghostpi-root-XXXX)"
        info "Mounting ${DEVICE}2 (rootfs) → $ROOT_DIR"
        mount "${DEVICE}2" "$ROOT_DIR" || die "Failed to mount ${DEVICE}2"
        MOUNTED_ROOT=true
    fi
fi

# Sanity-check the mounted partitions
[[ -f "$BOOT_DIR/config.txt" ]] \
    || die "No config.txt found at $BOOT_DIR — is this the right boot partition?"
[[ -d "$ROOT_DIR/etc" && -d "$ROOT_DIR/usr" && -d "$ROOT_DIR/bin" ]] \
    || die "$ROOT_DIR doesn't look like a Linux root filesystem."

ok "SD card verified: boot=$BOOT_DIR  root=$ROOT_DIR"

# ─── Cleanup trap ─────────────────────────────────────────────────────────────

cleanup() {
    local exit_code=$?
    [[ $exit_code -ne 0 ]] && warn "Script exited with error — cleaning up."

    # Remove policy-rc.d if we left it behind
    rm -f "$ROOT_DIR/usr/sbin/policy-rc.d" 2>/dev/null || true

    # Restore resolv.conf
    if [[ "$RESOLV_WAS_SYMLINK" == "true" && -n "$RESOLV_SYMLINK_TARGET" ]]; then
        rm -f "$ROOT_DIR/etc/resolv.conf" 2>/dev/null || true
        ln -sf "$RESOLV_SYMLINK_TARGET" "$ROOT_DIR/etc/resolv.conf" 2>/dev/null || true
    elif [[ -f "$ROOT_DIR/etc/resolv.conf.ghostpi-bak" ]]; then
        mv "$ROOT_DIR/etc/resolv.conf.ghostpi-bak" "$ROOT_DIR/etc/resolv.conf" 2>/dev/null || true
    fi

    # Remove QEMU binary we injected
    rm -f "$ROOT_DIR/usr/bin/qemu-arm-static" 2>/dev/null || true

    # Unmount bind mounts in reverse order
    for mp in dev/pts dev sys proc; do
        umount -l "$ROOT_DIR/$mp" 2>/dev/null || true
    done

    # Unmount SD partitions (only if we mounted them)
    if $MOUNTED_ROOT; then
        umount -l "$ROOT_DIR" 2>/dev/null || true
        rmdir "$ROOT_DIR"   2>/dev/null || true
    fi
    if $MOUNTED_BOOT; then
        umount -l "$BOOT_DIR" 2>/dev/null || true
        rmdir "$BOOT_DIR"   2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Setup chroot ─────────────────────────────────────────────────────────────

banner "ARM chroot setup"

# Inject QEMU binary so the kernel knows how to run ARM ELF binaries
cp /usr/bin/qemu-arm-static "$ROOT_DIR/usr/bin/qemu-arm-static"

# Bind-mount kernel pseudo-filesystems
mount --bind /proc    "$ROOT_DIR/proc"
mount --bind /sys     "$ROOT_DIR/sys"
mount --bind /dev     "$ROOT_DIR/dev"
mount --bind /dev/pts "$ROOT_DIR/dev/pts"

# Give the chroot DNS access.  On Trixie/Bookworm, /etc/resolv.conf is a symlink to
# a runtime path that doesn't exist in the offline rootfs — replace it.
if [[ -L "$ROOT_DIR/etc/resolv.conf" ]]; then
    RESOLV_SYMLINK_TARGET="$(readlink "$ROOT_DIR/etc/resolv.conf")"
    RESOLV_WAS_SYMLINK=true
    rm "$ROOT_DIR/etc/resolv.conf"
else
    cp "$ROOT_DIR/etc/resolv.conf" "$ROOT_DIR/etc/resolv.conf.ghostpi-bak" 2>/dev/null || true
fi
cp /etc/resolv.conf "$ROOT_DIR/etc/resolv.conf"

# Block service start attempts inside the chroot (apt postinst scripts may try)
cat > "$ROOT_DIR/usr/sbin/policy-rc.d" << 'EOF'
#!/bin/sh
exit 101
EOF
chmod +x "$ROOT_DIR/usr/sbin/policy-rc.d"

ok "Chroot ready (QEMU ARM + bind mounts + DNS)."

# ─── Install system packages ──────────────────────────────────────────────────

banner "System packages (apt)"
info "This downloads ARM packages from Raspbian repos — may take several minutes."

chroot "$ROOT_DIR" /usr/bin/qemu-arm-static /bin/bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    aircrack-ng \
    python3 \
    python3-pip \
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
apt-get clean
rm -rf /var/lib/apt/lists/*
"

ok "System packages installed."

# ─── Install Python packages ──────────────────────────────────────────────────

banner "Python packages (pip)"

chroot "$ROOT_DIR" /usr/bin/qemu-arm-static /bin/bash -c "
set -e
pip3 install --break-system-packages --no-cache-dir \
    adafruit-circuitpython-epd \
    adafruit-circuitpython-ssd1680
"

ok "Python packages installed."

# Remove the service-blocking policy file before we configure services
rm -f "$ROOT_DIR/usr/sbin/policy-rc.d"

# ─── Copy GhostPi application ─────────────────────────────────────────────────

banner "Application files"

APP_DEST="$ROOT_DIR/home/$PI_USER/ghostpi"
mkdir -p "$APP_DEST"

# Use tar to copy while excluding noise directories
tar -C "$REPO_DIR" \
    --exclude='./.git' \
    --exclude='./logs' \
    --exclude='./__pycache__' \
    --exclude='./ghostpi/__pycache__' \
    --exclude='./ghostpi/webui/__pycache__' \
    -cf - . \
  | tar -C "$APP_DEST" -xf -

# Pre-create log directories (the service expects these on first run)
mkdir -p "$APP_DEST/logs/handshakes"

# Set ownership to UID 1000 — the first user created by RPi OS Imager / firstboot
# will always receive UID 1000, matching whatever username you chose.
chown -R "${PI_UID}:${PI_UID}" "$ROOT_DIR/home/$PI_USER"

ok "GhostPi files copied to $APP_DEST"

# ─── Network configuration ────────────────────────────────────────────────────

banner "Network configuration"

# Static IP for usb0 (USB OTG ethernet gadget interface)
DHCPCD="$ROOT_DIR/etc/dhcpcd.conf"
if [[ -f "$DHCPCD" ]] && ! grep -q 'interface usb0' "$DHCPCD"; then
    cat >> "$DHCPCD" << 'EOF'

# GhostPi USB gadget networking
interface usb0
static ip_address=192.168.7.1/24
static routers=
static domain_name_servers=
nohook wpa_supplicant
EOF
    ok "dhcpcd.conf: static usb0 IP configured."
else
    warn "dhcpcd.conf: usb0 entry already present or file missing — skipping."
fi

# dnsmasq DHCP server for the USB interface
mkdir -p "$ROOT_DIR/etc/dnsmasq.d"
cat > "$ROOT_DIR/etc/dnsmasq.d/ghostpi-usb.conf" << 'EOF'
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
ok "dnsmasq: ghostpi-usb.conf written."

# ─── Systemd services ─────────────────────────────────────────────────────────

banner "Systemd services"

SYSTEMD_DIR="$ROOT_DIR/etc/systemd/system"
WANTS_DIR="$SYSTEMD_DIR/multi-user.target.wants"
mkdir -p "$WANTS_DIR"

# GhostPi service
cp "$REPO_DIR/systemd/ghostpi.service" "$SYSTEMD_DIR/ghostpi.service"
ln -sf /etc/systemd/system/ghostpi.service \
       "$WANTS_DIR/ghostpi.service"
ok "ghostpi.service installed and enabled."

# dnsmasq — find the unit file in the rootfs and create the wants symlink
DNSMASQ_UNIT=""
for candidate in \
    "$ROOT_DIR/lib/systemd/system/dnsmasq.service" \
    "$ROOT_DIR/usr/lib/systemd/system/dnsmasq.service"
do
    if [[ -f "$candidate" ]]; then
        # Build the absolute path as the Pi would see it (strip $ROOT_DIR prefix)
        DNSMASQ_UNIT="${candidate#$ROOT_DIR}"
        break
    fi
done

if [[ -n "$DNSMASQ_UNIT" ]]; then
    ln -sf "$DNSMASQ_UNIT" "$WANTS_DIR/dnsmasq.service"
    ok "dnsmasq.service enabled."
else
    warn "dnsmasq.service unit not found in rootfs — it will need to be enabled manually."
    warn "  On the Pi: sudo systemctl enable dnsmasq"
fi

# ─── Boot partition configuration ─────────────────────────────────────────────

banner "Boot partition"

CONFIG_TXT="$BOOT_DIR/config.txt"
CMDLINE_TXT="$BOOT_DIR/cmdline.txt"

# Append GhostPi boot settings (guards against double-append)
if ! grep -q 'dtoverlay=dwc2' "$CONFIG_TXT"; then
    # Strip the header comment from boot_config.txt and append
    grep -v '^#.*GhostPi' "$SCRIPT_DIR/boot_config.txt" >> "$CONFIG_TXT"
    ok "config.txt: GhostPi settings appended."
else
    warn "config.txt: dtoverlay=dwc2 already present — skipping append."
fi

# cmdline.txt must remain a single line; add USB OTG module loading
if [[ -f "$CMDLINE_TXT" ]] && ! grep -q 'modules-load=dwc2' "$CMDLINE_TXT"; then
    # Append to the end of the single line (no trailing newline needed)
    sed -i 's/$/ modules-load=dwc2,g_ether/' "$CMDLINE_TXT"
    ok "cmdline.txt: modules-load=dwc2,g_ether added."
else
    warn "cmdline.txt: USB OTG modules already configured or file missing."
fi

# ─── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}${GREEN}  GhostPi SD card preparation complete!${NC}"
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Packages installed : yes (ARM chroot via QEMU)"
echo "  Services enabled   : ghostpi + dnsmasq"
echo "  Boot config        : config.txt + cmdline.txt updated"
echo "  App location on Pi : /home/$PI_USER/ghostpi"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo "  1. Safely eject the SD card:    sudo eject $DEVICE"
echo "  2. Insert it into the Pi Zero WH and power on."
echo "  3. GhostPi starts automatically on boot — no SSH needed."
echo "  4. Plug the Pi's DATA USB port into your laptop."
echo "  5. Open http://192.168.7.1 in your browser."
echo ""
echo -e "${BOLD}If you need SSH access:${NC}"
echo "  - Enable SSH via Raspberry Pi Imager (advanced options) before flashing."
echo "  - Or: create an empty file named 'ssh' in the boot partition now."
echo "    touch $BOOT_DIR/ssh"
echo ""
echo -e "${YELLOW}  LEGAL: use only on networks you own or have written authorization to test.${NC}"
echo -e "${YELLOW}  Active mode (deauth) is disabled by default in ghostpi/config.py.${NC}"
echo ""
