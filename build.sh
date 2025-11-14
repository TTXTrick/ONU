#!/usr/bin/env bash
set -e

echo "========== ONU LINUX BUILD SYSTEM =========="

# -----------------------------
#  CONFIG
# -----------------------------
DISTRO="bookworm"
LIVE_USER="onu"
LIVE_PASS="live"
ISO_NAME="ONU-1.0.iso"
WALLPAPER_URL="https://upload.wikimedia.org/wikipedia/commons/8/89/Xfce_wallpaper_blue.png"
REPO_NAME="onu-repo"
PKG_NAME="onu-desktop"
EMAIL="builder@onu.local"
NAME="ONU Builder"

ROOT_DIR="$(pwd)"

# -----------------------------
#  SANITY CHECKS
# -----------------------------
if [ "$EUID" = 0 ]; then
    echo "❌ Do NOT run this script as root."
    exit 1
fi

sudo true

# -----------------------------
#  INSTALL DEPENDENCIES
# -----------------------------
echo "[1/10] Installing dependencies..."
sudo apt update
sudo apt install -y live-build debootstrap xorriso syslinux genisoimage squashfs-tools \
     reprepro dpkg-dev curl git vim xfconf qttools5-dev-tools cmake

# -----------------------------
#  CLEAN PREVIOUS BUILDS
# -----------------------------
echo "[2/10] Cleaning previous build directories..."
sudo rm -rf chroot binary auto config local tmp
mkdir -p config

# -----------------------------
#  CREATE DIRECTORY STRUCTURE
# -----------------------------
echo "[3/10] Creating project directories..."
mkdir -p \
 packages/$PKG_NAME/DEBIAN \
 repo/conf \
 branding/calamares \
 branding/livecd \
 config/includes.chroot/etc/skel \
 config/includes.chroot/usr/share/backgrounds/ONU \
 config/includes.binary/isolinux \
 config/package-lists

# -----------------------------
#  DOWNLOAD WALLPAPER
# -----------------------------
echo "[4/10] Downloading wallpaper..."
curl -L "$WALLPAPER_URL" -o config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png

# -----------------------------
#  CREATE METAPACKAGE
# -----------------------------
echo "[5/10] Creating meta-package..."
cat <<EOF > packages/$PKG_NAME/DEBIAN/control
Package: $PKG_NAME
Version: 1.0
Architecture: all
Maintainer: $NAME <$EMAIL>
Depends: xfce4, firefox-esr, thunar, mousepad, vlc, lightdm, network-manager
Description: ONU Linux Desktop Meta-package
 Installs the ONU Linux core desktop environment.
EOF

mkdir -p packages/$PKG_NAME/usr/share/doc/$PKG_NAME
echo "ONU Linux Meta-package" > packages/$PKG_NAME/usr/share/doc/$PKG_NAME/README

dpkg-deb --build --root-owner-group packages/$PKG_NAME

# -----------------------------
#  CREATE LOCAL APT REPO
# -----------------------------
echo "[6/10] Building local repo..."
cat <<EOF > repo/conf/distributions
Codename: $DISTRO
Components: main
Architectures: amd64
SignWith: yes
EOF

# Generate GPG key automatically if missing
if ! gpg --list-keys "$NAME" >/dev/null 2>&1; then
    echo "Generating GPG key..."
    gpg --batch --passphrase '' --quick-gen-key "$NAME <$EMAIL>" default default never
fi

reprepro -b repo includedeb $DISTRO packages/$PKG_NAME.deb

# -----------------------------
#  ADD REPO TO LIVE IMAGE
# -----------------------------
echo "deb [trusted=yes] file:$ROOT_DIR/repo $DISTRO main" \
  | tee config/includes.chroot/etc/apt/sources.list.d/onu-local.list

# -----------------------------
#  CREATE CALAMARES BRANDING
# -----------------------------
echo "[7/10] Creating Calamares branding..."
cat <<EOF > branding/calamares/branding.desc
---
branding:
  componentName: "ONU Linux Installer"
  welcomeText: "Welcome to ONU Linux"
EOF

mkdir -p config/includes.chroot/etc/calamares/branding/onu
cp -r branding/calamares/* config/includes.chroot/etc/calamares/branding/onu/

# -----------------------------
#  LIVE USER CREATION
# -----------------------------
echo "[8/10] Adding live user..."
mkdir -p config/includes.chroot/lib/live/config
cat <<EOF > config/includes.chroot/lib/live/config/0031-onu-user
#!/bin/sh
useradd -m -s /bin/bash $LIVE_USER
echo "$LIVE_USER:$LIVE_PASS" | chpasswd
adduser $LIVE_USER sudo
EOF
chmod +x config/includes.chroot/lib/live/config/0031-onu-user

# -----------------------------
#  LIVE-BOOT CONFIG
# -----------------------------
echo "[9/10] Creating bootloader theme..."
cat <<EOF > config/includes.binary/isolinux/isolinux.cfg
UI menu.c32
PROMPT 0
MENU TITLE ONU Linux Boot Menu
TIMEOUT 50

LABEL live
  MENU LABEL Start ONU Linux Live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

# -----------------------------
#  LIVE-BUILD CONFIG
# -----------------------------
echo "[10/10] Starting ISO build..."
sudo lb config \
   --mode debian \
   --distribution "$DISTRO" \
   --archive-areas "main contrib non-free-firmware" \
   --debian-installer live

sudo lb build

mv live-image-amd64.hybrid.iso "$ISO_NAME"

echo "=========================================="
echo "ONU Linux ISO built successfully!"
echo "ISO: $ISO_NAME"
echo "=========================================="
