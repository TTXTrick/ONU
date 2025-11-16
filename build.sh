#!/usr/bin/env bash

# ===========================================
#  ONU LINUX BUILD SYSTEM (FULLY INTEGRATED)
#  Includes:
#   ✔ XFCE Desktop
#   ✔ LightDM Autologin
#   ✔ Live User Defaults
#   ✔ Real Plymouth Theme + Animated Logo
#   ✔ Custom Logo (onu-logo.png)
#   ✔ Calamares Installer + OEM Mode + Encryption
#   ✔ Grub Theme
#   ✔ Local Repo Builder
#   ✔ Auto-update System
#   ✔ First-boot Welcome App
# ===========================================

set -euo pipefail
LOGFILE="onu-build.log"
exec > >(tee "$LOGFILE") 2>&1

STEP_NUM=0
step(){ STEP_NUM=$((STEP_NUM+1)); echo "
--------------------------------------------------
[STEP $STEP_NUM] $1
--------------------------------------------------"; }
fail(){ echo "❌ ERROR: $1"; exit 1; }
success(){ echo "✅ $1"; }
spinner(){ pid=$1; spin='-\|/'; i=0; printf "⏳ "; while kill -0 $pid 2>/dev/null; do printf "${spin:i++%${#spin}:1}"; sleep .1; done; printf ""; }

# ===========================================
#  CONFIG
# ===========================================
DISTRO="bookworm"
LIVE_USER="onu"
LIVE_PASS="live"
ISO_NAME="ONU-1.0.iso"
WALLPAPER_URL="https://gitlab.com/TTXTrick/testbg/-/raw/main/onu-background.svg?ref_type=heads"
PKG_NAME="onu-desktop"
EMAIL="builder@onu.local"
NAME="ONU Builder"
ROOT_DIR="$(pwd)"
IN_TREE_REPO="config/includes.chroot/opt/onu-repo"

# ===========================================
#  SANITY
# ===========================================
step "Sanity checks"
[ "$EUID" = 0 ] && fail "Do not run as root."
sudo true || fail "sudo authentication failed"
success "Environment OK"

# ===========================================
#  DEPENDENCIES
# ===========================================
step "Install dependencies"
sudo apt update --allow-releaseinfo-change --allow-insecure-repositories || {
    echo "⚠️ Host apt sources are broken. Temporarily disabling external repos..."
    sudo sed -i 's/^deb/#deb/g' /etc/apt/sources.list.d/*.list 2>/dev/null || true
    sudo apt update --allow-releaseinfo-change || fail "apt update failed again"
}
sudo apt install -y \
  live-build debootstrap xorriso syslinux genisoimage squashfs-tools \
  reprepro dpkg-dev apt-utils curl git xfconf qttools5-dev-tools cmake \
  plymouth plymouth-themes imagemagick zenity unattended-upgrades \
  rsync apt-listchanges || fail "Dependency installation failed"
success "Dependencies installed"

# ===========================================
#  CLEAN
# ===========================================
step "Clean previous builds"
sudo rm -rf chroot binary auto tmp build.pid || true
mkdir -p config
success "Clean"

# ===========================================
#  DIRECTORIES
# ===========================================
step "Setup directory structure"
mkdir -p \
  packages/$PKG_NAME/DEBIAN \
  config/includes.chroot/etc/skel \
  config/includes.chroot/etc/apt/sources.list.d \
  config/includes.chroot/usr/share/backgrounds/ONU \
  config/includes.chroot/lib/live/config \
  config/includes.binary/isolinux \
  config/includes.binary/boot/grub \
  config/includes.chroot/etc/lightdm \
  config/includes.chroot/etc/xdg/lightdm/lightdm.conf.d \
  branding/calamares
mkdir -p "$IN_TREE_REPO/dists/$DISTRO/main/binary-amd64"
mkdir -p "$IN_TREE_REPO/pool/main"
success "Directories ready"

# ===========================================
#  WALLPAPER
# ===========================================
step "Download wallpaper"
curl -Lf "$WALLPAPER_URL" -o config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png || fail "Wallpaper download failed"
cp config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png config/includes.binary/boot/grub/onu_splash.png || true
success "Wallpaper done"

# ===========================================
#  META PACKAGE
# ===========================================
step "Build meta package"
PACKAGE_DIR="packages/$PKG_NAME"
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/DEBIAN" "$PACKAGE_DIR/usr/share/doc/$PKG_NAME"
cat > "$PACKAGE_DIR/DEBIAN/control" <<EOF
Package: $PKG_NAME
Version: 1.0
Architecture: all
Maintainer: $NAME <$EMAIL>
Priority: optional
Depends: xfce4, firefox-esr, thunar, mousepad, vlc, lightdm, network-manager, zenity, plymouth, unattended-upgrades
Section: metapackages
Description: ONU Linux Desktop
EOF
echo "ONU Linux Meta-package" > "$PACKAGE_DIR/usr/share/doc/$PKG_NAME/README"
dpkg-deb --build --root-owner-group "$PACKAGE_DIR" || fail "dpkg-deb failed"
success "Meta package built"

# ===========================================
#  LOCAL REPO
#  (FIX: ensure repo path exists before cp)
# ===========================================
step "Build local repo"
# REPO_SRC should NOT prepend ROOT_DIR — it already contains a full relative path
REPO_SRC="$IN_TREE_REPO"
# Clean + rebuild repo dir
rm -rf "$REPO_SRC"
mkdir -p "$REPO_SRC/pool/main"
