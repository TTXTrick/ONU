#!/usr/bin/env bash
set -euo pipefail

LOGFILE="onu-build.log"
exec > >(tee "$LOGFILE") 2>&1

echo "========== ONU LINUX BUILD SYSTEM =========="

############################################################
# UTILITIES
############################################################
step() {
    STEP_NUM=$((STEP_NUM+1))
    echo ""
    echo "--------------------------------------------------"
    echo "[STEP $STEP_NUM] $1"
    echo "--------------------------------------------------"
}

fail() {
    echo "❌ ERROR: $1"
    echo "See: $LOGFILE"
    exit 1
}

success() {
    echo "✅ $1"
}

spinner() {
    local pid=$1
    local delay=0.15
    local spin='-\|/'

    printf "⏳ Working... "
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\b${spin:i++%${#spin}:1}"
        sleep $delay
    done
    printf "\b"
    echo ""
}

STEP_NUM=0

############################################################
# CONFIG
############################################################
DISTRO="bookworm"
LIVE_USER="onu"
LIVE_PASS="live"
ISO_NAME="ONU-1.0.iso"
WALLPAPER_URL="https://upload.wikimedia.org/wikipedia/commons/3/38/Onu-background.svg"
PKG_NAME="onu-desktop"
EMAIL="builder@onu.local"
NAME="ONU Builder"

ROOT_DIR="$(pwd)"

# Where we will create an *in-tree* repository that will be included into the chroot
# so apt inside the chroot can read the repo with a file: URL that exists inside the chroot.
IN_TREE_REPO="config/includes.chroot/opt/onu-repo"

############################################################
# SANITY CHECKS
############################################################
step "Sanity checks"

if [ "$EUID" = 0 ]; then
    fail "Do NOT run this script as root."
fi

sudo true || fail "sudo authentication failed"
success "Sanity checks passed"

############################################################
# INSTALL DEPENDENCIES
############################################################
step "Installing dependencies"

sudo apt update || fail "apt update failed"
sudo apt install -y live-build debootstrap xorriso syslinux genisoimage squashfs-tools \
    reprepro dpkg-dev apt-utils curl git xfconf qttools5-dev-tools cmake apt-ftparchive || fail "Dependency install failed"

success "Dependencies installed"

############################################################
# CLEAN PREVIOUS BUILDS
############################################################
step "Cleaning previous builds"

# remove previous outputs but keep the script/config templates (we will recreate)
sudo rm -rf chroot binary auto tmp build.pid || fail "Cleanup failed"
# do not remove 'config' entirely here if you want to preserve custom edits — we recreate needed subdirs below
mkdir -p config

success "Clean environment ready"

############################################################
# CREATE PROJECT DIRECTORIES
############################################################
step "Preparing directory structure"

mkdir -p \
    packages/$PKG_NAME/DEBIAN \
    config/includes.chroot/etc/skel \
    config/includes.chroot/etc/apt/sources.list.d \
    config/includes.chroot/usr/share/backgrounds/ONU \
    config/includes.chroot/lib/live/config \
    config/includes.binary/isolinux \
    config/includes.binary/boot/grub \
    config/includes.binary/boot/grub/themes \
    branding/calamares \
    repo

# ensure the in-tree repo directories exist (we will generate repo metadata here)
mkdir -p "$IN_TREE_REPO/pool/main" "$IN_TREE_REPO/dists/$DISTRO/main/binary-amd64"

success "Directory structure created"

############################################################
# WALLPAPER
############################################################
step "Downloading wallpaper"

# Save to both chroot includes and binary grub area (so UEFI sees it)
curl -Lf "$WALLPAPER_URL" \
  -o config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png \
  || fail "Wallpaper download failed"
# copy a copy for GRUB splash (UEFI)
cp config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png config/includes.binary/boot/grub/onu_splash.png || true

success "Wallpaper downloaded"

############################################################
# META-PACKAGE
############################################################
step "Creating meta-package"

PACKAGE_DIR="packages/$PKG_NAME"
rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR/DEBIAN" "$PACKAGE_DIR/usr/share/doc/$PKG_NAME"

cat <<EOF > "$PACKAGE_DIR/DEBIAN/control"
Package: $PKG_NAME
Version: 1.0
Architecture: all
Maintainer: $NAME <$EMAIL>
Priority: optional
Depends: xfce4, firefox-esr, thunar, mousepad, vlc, lightdm, network-manager
Section: metapackages
Description: ONU Linux Desktop Meta-package
 Installs the ONU Linux core desktop environment.
EOF

echo "ONU Linux Meta-package" > "$PACKAGE_DIR/usr/share/doc/$PKG_NAME/README"

# Build deb (will create packages/onu-desktop.deb)
dpkg-deb --build --root-owner-group "$PACKAGE_DIR" || fail "dpkg-deb failed"

# Ensure the .deb exists
if [ ! -f "packages/$PKG_NAME.deb" ]; then
    fail "Expected packages/$PKG_NAME.deb missing"
fi

success "Meta-package built"

############################################################
# LOCAL APT REPOSITORY (IN-TREE / will be included in chroot)
############################################################
step "Building local APT repository (inside tree so chroot can access it)"

REPO_ROOT="$ROOT_DIR/$IN_TREE_REPO"
DISTRO_DIR="$REPO_ROOT/dists/$DISTRO/main/binary-amd64"
POOL_DIR="$REPO_ROOT/pool/main"

# Clean and re-create the in-tree repo
rm -rf "$REPO_ROOT"
mkdir -p "$DISTRO_DIR" "$POOL_DIR"

# Copy our generated package into the repo pool
cp "packages/$PKG_NAME.deb" "$POOL_DIR/" || fail "Failed to copy package to pool"

# Move into the repo root (dpkg-scanpackages expects to be run with paths relative)
pushd "$REPO_ROOT" >/dev/null

# Generate Packages (uncompressed) and compressed Packages.gz
# dpkg-scanpackages scans the pool directory and writes Packages file for apt
dpkg-scanpackages pool /dev/null > "dists/$DISTRO/main/binary-amd64/Packages" || { popd >/dev/null; fail "dpkg-scanpackages failed"; }
gzip -9c "dists/$DISTRO/main/binary-amd64/Packages" > "dists/$DISTRO/main/binary-amd64/Packages.gz" || { popd >/dev/null; fail "gzip Packages failed"; }

# Create a minimal Release file so apt is happier. Prefer apt-ftparchive if installed.
if command -v apt-ftparchive >/dev/null 2>&1; then
    apt-ftparchive release dists/"$DISTRO" > dists/"$DISTRO"/Release 2>/dev/null || true
else
    # Minimal Release fallback
    cat > dists/"$DISTRO"/Release <<EOREL
Origin: ONU
Label: ONU repo
Suite: $DISTRO
Codename: $DISTRO
Date: $(date -Ru)
Architectures: amd64
Components: main
Description: ONU in-tree repository
EOREL
fi

popd >/dev/null

# Add repo entry for the live system, BUT point at the repo inside the chroot (in-tree path).
# When the ISO/chroot is built the path /opt/onu-repo will exist as we've included it under
# config/includes.chroot/opt/onu-repo
echo "deb [trusted=yes] file:/opt/onu-repo $DISTRO main" \
  | tee config/includes.chroot/etc/apt/sources.list.d/onu-local.list >/dev/null

success "Local APT repo ready (created under $IN_TREE_REPO and referenced inside chroot)"

############################################################
# CALAMARES INSTALLER — FULL CONFIG
############################################################
step "Configuring full Calamares installer (Calamares 3.3+ style)"

CAL_DIR="config/includes.chroot/etc/calamares"
mkdir -p "$CAL_DIR/modules"

cat <<'EOF' > "$CAL_DIR/settings.conf"
---
modules-search: [ local ]
instances:
  - show:
      sidebar: true
      steps:
        - welcome
        - locale
        - keyboard
        - partition
        - users
        - packages
        - displaymanager
        - finished

sequence:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - packages
  - displaymanager
  - finished
EOF

cat <<EOF > "$CAL_DIR/modules/users.conf"
---
createUser:
  fullName: "ONU Linux User"
  userName: "$LIVE_USER"
  autoLogin: true
  password: "$LIVE_PASS"
EOF

cat <<'EOF' > "$CAL_DIR/modules/locale.conf"
---
localeGen: [ "en_US.UTF-8 UTF-8" ]
defaultLocale: "en_US.UTF-8"
timeZone: "UTC"
EOF

cat <<'EOF' > "$CAL_DIR/modules/keyboard.conf"
---
defaultLayout: "us"
EOF

cat <<'EOF' > "$CAL_DIR/modules/partition.conf"
---
dontInstallOnSsd: false
defaultFilesystemType: "ext4"
efiSystemPartition: "/boot/efi"
userSwapChoices: [ none ]
automatic:
  partitionLayout: "erase"
EOF

cat <<'EOF' > "$CAL_DIR/modules/displaymanager.conf"
---
displaymanagers:
  - lightdm
EOF

cat <<'EOF' > "$CAL_DIR/modules/finished.conf"
---
restartNowEnabled: true
runLiveCleanup: true
EOF

cat <<'EOF' > "$CAL_DIR/modules/packages.conf"
---
packages:
  remove:
    - live-boot
    - live-config
EOF

success "Calamares installer configured (full auto mode)"

############################################################
# LIVE USER
############################################################
step "Creating live user hook (live-config)"

cat <<EOF > config/includes.chroot/lib/live/config/0031-onu-user
#!/bin/sh
set -e
useradd -m -s /bin/bash $LIVE_USER
echo "$LIVE_USER:$LIVE_PASS" | chpasswd
adduser $LIVE_USER sudo || true
EOF
chmod +x config/includes.chroot/lib/live/config/0031-onu-user

success "Live user hook created"

############################################################
# BOOTLOADER — ISOLINUX (BIOS)
############################################################
step "Creating BIOS (ISOLINUX) bootloader"

cat <<'EOF' > config/includes.binary/isolinux/isolinux.cfg
UI menu.c32
PROMPT 0
MENU TITLE ONU Linux Boot Menu
TIMEOUT 50

LABEL live
  MENU LABEL Start ONU Linux Live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

success "ISOLINUX ready"

############################################################
# BOOTLOADER — EFI GRUB THEME
############################################################
step "Configuring EFI GRUB theme"

EFI_DIR="config/includes.binary/boot/grub"
mkdir -p "$EFI_DIR"

# we already copied the splash earlier; ensure the file exists
if [ ! -f "$EFI_DIR/onu_splash.png" ]; then
    cp config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png "$EFI_DIR/onu_splash.png" || true
fi

cat <<'EOF' > "$EFI_DIR/grub.cfg"
set timeout=5
set default=0

insmod all_video
insmod gfxterm
terminal_output gfxterm

background_image /boot/grub/onu_splash.png

menuentry "Start ONU Linux Live (EFI)" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd.img
}
EOF

success "EFI GRUB theme installed"

############################################################
# BUILD ISO
############################################################
step "Configuring live-build"

# choose bootloaders; syslinux for BIOS and grub-efi for UEFI.
sudo lb config \
   --mode debian \
   --distribution "$DISTRO" \
   --archive-areas "main contrib non-free-firmware" \
   --debian-installer live \
   --bootloaders syslinux,grub-efi \
   || fail "lb config failed"

step "Building ISO (this will take time)"

# Run lb build in background and save its PID so spinner can monitor it.
( sudo lb build & echo $! > build.pid )
# read PID and start spinner
PID="$(cat build.pid)"
spinner "$PID"

if [ ! -f live-image-amd64.hybrid.iso ]; then
    fail "ISO build failed"
fi

mv live-image-amd64.hybrid.iso "$ISO_NAME"
success "ISO created: $ISO_NAME"

echo ""
echo "============================================"
echo "🎉 ONU Linux ISO Build COMPLETE!"
echo "ISO file: $ISO_NAME"
echo "Log file: $LOGFILE"
echo "============================================"
