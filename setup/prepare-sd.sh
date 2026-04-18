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
PKG_FAILURES=()
PIP_FAILED=false
QEMU_METHOD=""   # set to "binfmt" or "static" by the host toolchain section

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

# Ensure binfmt_misc is mounted — required by both methods below
if [[ ! -d /proc/sys/fs/binfmt_misc ]]; then
    modprobe binfmt_misc 2>/dev/null || true
    mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
fi

apt-get update -qq 2>/dev/null || apt-get update

# ── Method 1 (preferred): qemu-user-binfmt ───────────────────────────────────
# Modern package (Kali, Debian 2025+). Registers ARM binfmt entries using the
# kernel F (fix-binary) flag, so no binary needs to be copied into the chroot.
# The chroot just calls /bin/bash — the kernel routes ARM ELFs through QEMU.
if apt-get install -y qemu-user-binfmt 2>/dev/null; then
    systemctl restart systemd-binfmt 2>/dev/null || true
    if [[ -e /proc/sys/fs/binfmt_misc/qemu-arm ]]; then
        QEMU_METHOD="binfmt"
        ok "QEMU ARM ready via qemu-user-binfmt (no binary copy needed)."
    fi
fi

# ── Method 2 (fallback): qemu-user-static ────────────────────────────────────
# Older package — copies a static ARM binary into the chroot so the kernel can
# find it.  Used on Ubuntu LTS and older Debian-based systems.
if [[ -z "$QEMU_METHOD" ]]; then
    warn "qemu-user-binfmt not available — falling back to qemu-user-static."
    apt-get install -y qemu-user-static 2>/dev/null \
        || die "Could not install qemu-user-static either. Check your package manager."
    # Register binfmt entry if not already done
    if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-arm ]]; then
        systemctl restart systemd-binfmt 2>/dev/null || \
        update-binfmts --enable qemu-arm 2>/dev/null || true
    fi
    [[ -f /usr/bin/qemu-arm-static ]] \
        || die "qemu-arm-static binary not found after install."
    QEMU_METHOD="static"
    ok "QEMU ARM ready via qemu-user-static (legacy mode)."
fi

[[ -n "$QEMU_METHOD" ]] \
    || die "Could not set up ARM emulation. Ensure binfmt_misc is available: sudo modprobe binfmt_misc"

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

    # Remove QEMU binary if we injected one (static fallback mode only)
    [[ "${QEMU_METHOD:-}" == "static" ]] && \
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

# With qemu-user-binfmt the kernel's F-flag entry points to the host binary —
# no copy needed.  With qemu-user-static we must place the binary inside the
# chroot so it's reachable across the chroot boundary.
if [[ "$QEMU_METHOD" == "static" ]]; then
    cp /usr/bin/qemu-arm-static "$ROOT_DIR/usr/bin/qemu-arm-static"
fi

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

# Build the chroot invocation once so both apt and pip sections use the same command
if [[ "$QEMU_METHOD" == "static" ]]; then
    CHROOT=(chroot "$ROOT_DIR" /usr/bin/qemu-arm-static /bin/bash)
else
    CHROOT=(chroot "$ROOT_DIR" /bin/bash)
fi

# ─── Install system packages ──────────────────────────────────────────────────

banner "System packages (apt)"
info "Downloading ARM packages from Raspbian repos — this may take several minutes."

# Failure log written by the chroot; read back after it exits
PKG_FAIL_LOG="$ROOT_DIR/tmp/ghostpi-pkg-failures.txt"
rm -f "$PKG_FAIL_LOG"

# Run apt inside the ARM chroot.  We deliberately do NOT use 'set -e' here —
# instead each package is installed individually so one missing package cannot
# abort the whole install.  Known renames (e.g. python3-rpi.gpio → python3-rpi-lgpio
# on newer Pi OS releases) are handled with ordered fallback names.
"${CHROOT[@]}" << 'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive
_fail_log=/tmp/ghostpi-pkg-failures.txt

# Try primary name then any fallbacks. Never exits non-zero.
install_pkg() {
    local primary="$1"; shift
    if apt-get install -y --no-install-recommends "$primary" 2>/dev/null; then
        echo "  [+] $primary"
        return 0
    fi
    for fallback in "$@"; do
        echo "  [!] '$primary' not found, trying '$fallback'..."
        if apt-get install -y --no-install-recommends "$fallback" 2>/dev/null; then
            echo "  [+] $fallback (fallback for $primary)"
            return 0
        fi
    done
    echo "  [✗] Could not install '$primary' (tried all fallbacks)"
    echo "$primary" >> "$_fail_log"
}

# Optional: install but don't fail the script if unavailable
install_optional() {
    local pkg="$1"
    apt-get install -y --no-install-recommends "$pkg" 2>/dev/null \
        && echo "  [+] $pkg (optional)" \
        || echo "  [-] $pkg not available — skipping (optional)"
}

apt-get update -qq 2>/dev/null || apt-get update || echo "WARNING: apt-get update failed"

# ── Required ─────────────────────────────────────────────────────────────────
install_pkg aircrack-ng
install_pkg python3
install_pkg python3-pip
# GPIO library — renamed in newer Raspberry Pi OS / Trixie releases
install_pkg python3-rpi.gpio   python3-rpi-lgpio   python3-lgpio
install_pkg python3-pillow
install_pkg python3-flask
install_pkg dnsmasq
install_pkg iw
install_pkg libopenjp2-7
install_pkg fonts-dejavu-core

# ── Optional ─────────────────────────────────────────────────────────────────
# python3-dev: headers for compiling C extensions via pip — not needed if all
#   wheels are pre-built for armhf (likely on Trixie)
install_optional python3-dev
# wireless-tools: provides iwconfig/iwlist — iw covers most cases on modern kernels
install_optional wireless-tools
# net-tools: provides ifconfig — iproute2 (already installed) is the modern replacement
install_optional net-tools

apt-get clean
rm -rf /var/lib/apt/lists/*
CHROOTEOF

# Read failures back into the host array
if [[ -f "$PKG_FAIL_LOG" ]]; then
    while IFS= read -r line; do
        [[ -n "$line" ]] && PKG_FAILURES+=("$line")
    done < "$PKG_FAIL_LOG"
    rm -f "$PKG_FAIL_LOG"
fi

if [[ ${#PKG_FAILURES[@]} -gt 0 ]]; then
    warn "Some packages could not be installed: ${PKG_FAILURES[*]}"
    warn "GhostPi may be missing functionality — see the summary at the end."
else
    ok "All system packages installed."
fi

# ─── Install Python packages ──────────────────────────────────────────────────

banner "Python packages (pip)"

# Temporarily suspend errexit so a pip failure doesn't kill the script —
# we report it in the final summary instead.
set +e
"${CHROOT[@]}" << 'CHROOTEOF'
pip3 install --break-system-packages --no-cache-dir \
    adafruit-blinka \
    rpi-lgpio \
    adafruit-circuitpython-epd
CHROOTEOF
PIP_EXIT=$?
set -e

if [[ $PIP_EXIT -ne 0 ]]; then
    PIP_FAILED=true
    warn "pip install failed (exit $PIP_EXIT) — e-ink display libraries are missing."
    warn "The rest of the install will continue. You can retry on the Pi:"
    warn "  pip3 install --break-system-packages adafruit-blinka rpi-lgpio adafruit-circuitpython-epd"
else
    ok "Python packages installed."
fi

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

# GhostPi main service
cp "$REPO_DIR/systemd/ghostpi.service" "$SYSTEMD_DIR/ghostpi.service"
ln -sf /etc/systemd/system/ghostpi.service \
       "$WANTS_DIR/ghostpi.service"
ok "ghostpi.service installed and enabled."

# GhostPi boot splash service (draws to e-ink before main service starts)
cp "$REPO_DIR/systemd/ghostpi-splash.service" "$SYSTEMD_DIR/ghostpi-splash.service"
ln -sf /etc/systemd/system/ghostpi-splash.service \
       "$WANTS_DIR/ghostpi-splash.service"
ok "ghostpi-splash.service installed and enabled."

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

# SSH + user credentials for Pi OS Trixie
#
# Pi OS Trixie uses two first-boot mechanisms (both must be set):
#
#  1. /boot/ssh  — Pi OS sshswitch.service sees this file and runs
#                  "systemctl enable --now ssh", then deletes the flag.
#                  No manual systemd symlink is needed or correct here.
#
#  2. /boot/custom.toml — Pi OS init_config reads this on first boot to
#                  create the user account and configure SSH password auth.
#                  This is the official Trixie replacement for the older
#                  userconf.txt mechanism.

# SSH boot flag
touch "$BOOT_DIR/ssh"
ok "SSH boot flag set (sshswitch.service will enable ssh on first boot)."

# custom.toml — user + SSH config (Pi OS Trixie first-boot mechanism)
cat > "$BOOT_DIR/custom.toml" << EOF
[system]
hostname = "ghostpi"

[user]
name = "${PI_USER}"
password = "ghostpi"
password_encrypted = false

[ssh]
enabled = true
password_authentication = true
EOF
ok "custom.toml written: user=${PI_USER} password=ghostpi hostname=ghostpi."
warn "Change the default password after first login: passwd"

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
echo "  Services enabled   : ghostpi + dnsmasq + ssh"
echo "  Boot config        : config.txt + cmdline.txt updated"
echo "  App location on Pi : /home/$PI_USER/ghostpi"
echo ""

# ── Warn about anything that failed ──────────────────────────────────────────
if [[ ${#PKG_FAILURES[@]} -gt 0 || "$PIP_FAILED" == "true" ]]; then
    echo -e "${YELLOW}━━━  Installation warnings  ━━━${NC}"
    if [[ ${#PKG_FAILURES[@]} -gt 0 ]]; then
        echo -e "${YELLOW}  The following apt packages could not be installed:${NC}"
        for pkg in "${PKG_FAILURES[@]}"; do
            echo -e "${YELLOW}    • $pkg${NC}"
        done
        echo -e "${YELLOW}  Fix on the Pi after boot:${NC}"
        echo -e "${YELLOW}    sudo apt-get install ${PKG_FAILURES[*]}${NC}"
    fi
    if [[ "$PIP_FAILED" == "true" ]]; then
        echo -e "${YELLOW}  pip install failed (e-ink display libraries missing).${NC}"
        echo -e "${YELLOW}  Fix on the Pi after boot:${NC}"
        echo -e "${YELLOW}    pip3 install --break-system-packages adafruit-blinka rpi-lgpio adafruit-circuitpython-epd${NC}"
    fi
    echo ""
fi

echo -e "${BOLD}Next steps:${NC}"
echo "  1. Safely eject the SD card:    sudo eject $DEVICE"
echo "  2. Insert it into the Pi Zero WH and power on."
echo "  3. GhostPi starts automatically on boot — no SSH needed."
echo "  4. Plug the Pi's DATA USB port into your laptop."
echo "  5. Open http://192.168.7.1 in your browser."
echo ""
echo -e "${BOLD}SSH access:${NC}"
echo "  SSH is enabled automatically.  Default credentials:"
echo "  ssh ${PI_USER}@192.168.7.1   password: ghostpi"
echo "  Change password immediately after first login: passwd"
echo ""
echo -e "${YELLOW}  LEGAL: use only on networks you own or have written authorization to test.${NC}"
echo -e "${YELLOW}  Active mode (deauth) is disabled by default in ghostpi/config.py.${NC}"
echo ""
