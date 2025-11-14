#!/usr/bin/env bash
set -e

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
    while kill -0 "$pid" 2>/dev/null; do
        printf "\b${spin:i++%${#spin}:1}"
        sleep $delay
    done
    printf "\b"
}

STEP_NUM=0

############################################################
# CONFIG
############################################################
DISTRO="bookworm"
LIVE_USER="onu"
LIVE_PASS="live"
ISO_NAME="ONU-1.0.iso"
WALLPAPER_URL="https://upload.wikimedia.org/wikipedia/commons/8/89/Xfce_wallpaper_blue.png"
PKG_NAME="onu-desktop"
EMAIL="builder@onu.local"
NAME="ONU Builder"

ROOT_DIR="$(pwd)"

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
    reprepro dpkg-dev curl git xfconf qttools5-dev-tools cmake || fail "Dependency install failed"

success "Dependencies installed"

############################################################
# CLEAN PREVIOUS BUILDS
############################################################
step "Cleaning previous builds"

sudo rm -rf chroot binary auto config packages repo branding tmp || fail "Cleanup failed"
mkdir -p config

success "Clean environment ready"

############################################################
# CREATE PROJECT DIRECTORIES
############################################################
step "Preparing directory structure"

mkdir -p \
    packages/$PKG_NAME/DEBIAN \
    config/includes.chroot/etc/skel \
    config/includes.chroot/usr/share/backgrounds/ONU \
    config/includes.chroot/lib/live/config \
    config/includes.binary/isolinux \
    config/includes.binary/boot/grub \
    branding/calamares \
    repo/conf

success "Directory structure created"

############################################################
# WALLPAPER
############################################################
step "Downloading wallpaper"

curl -Lf "$WALLPAPER_URL" \
  -o config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png \
  || fail "Wallpaper download failed"

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
Depends: xfce4, firefox-esr, thunar, mousepad, vlc, lightdm, network-manager
Section: metapackages
Description: ONU Linux Desktop Meta-package
 Installs the ONU Linux core desktop environment.
EOF

echo "ONU Linux Meta-package" > "$PACKAGE_DIR/usr/share/doc/$PKG_NAME/README"

dpkg-deb --build --root-owner-group "$PACKAGE_DIR" || fail "dpkg-deb failed"

success "Meta-package built"

############################################################
# LOCAL APT REPOSITORY
############################################################
step "Building local APT repository"

mkdir -p repo/conf repo/db repo/dists repo/pool

cat <<EOF > repo/conf/distributions
Codename: $DISTRO
Components: main
Architectures: amd64
SignWith: yes
EOF

# GPG key generation
if ! gpg --list-keys "$NAME" >/dev/null 2>&1; then
    echo "🔑 Generating GPG key..."
    gpg --batch --passphrase '' --quick-gen-key "$NAME <$EMAIL>" default default never \
        || fail "GPG key creation failed"
fi

if ! reprepro -b repo includedeb $DISTRO packages/$PKG_NAME.deb; then
    echo "⚠️ Signing failed — retrying unsigned"
    sed -i 's/SignWith: yes/SignWith: no/' repo/conf/distributions
    reprepro -b repo includedeb $DISTRO packages/$PKG_NAME.deb || fail "reprepro failed"
fi

echo "deb [trusted=yes] file:$ROOT_DIR/repo $DISTRO main" \
  | tee config/includes.chroot/etc/apt/sources.list.d/onu-local.list >/dev/null

success "Local APT repo ready"

############################################################
# CALAMARES INSTALLER — FULL CONFIG
############################################################
step "Configuring full Calamares installer"

CAL_DIR="config/includes.chroot/etc/calamares"
mkdir -p "$CAL_DIR/modules"

# Main settings
cat <<EOF > "$CAL_DIR/settings.conf"
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

# Users
cat <<EOF > "$CAL_DIR/modules/users.conf"
---
createUser:
  fullName: "ONU Linux User"
  userName: "onu"
  autoLogin: true
  password: "live"
EOF

# Locale
cat <<EOF > "$CAL_DIR/modules/locale.conf"
---
localeGen: [ "en_US.UTF-8 UTF-8" ]
defaultLocale: "en_US.UTF-8"
timeZone: "UTC"
EOF

# Keyboard
cat <<EOF > "$CAL_DIR/modules/keyboard.conf"
---
defaultLayout: "us"
EOF

# Partitioning
cat <<EOF > "$CAL_DIR/modules/partition.conf"
---
dontInstallOnSsd: false
defaultFilesystemType: "ext4"
efiSystemPartition: "/boot/efi"
userSwapChoices: [ none ]
automatic:
  partitionLayout: "erase"
EOF

# Display manager
cat <<EOF > "$CAL_DIR/modules/displaymanager.conf"
---
displaymanagers:
  - lightdm
EOF

# Finished
cat <<EOF > "$CAL_DIR/modules/finished.conf"
---
restartNowEnabled: true
runLiveCleanup: true
EOF

# Packages
cat <<EOF > "$CAL_DIR/modules/packages.conf"
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
step "Creating live user"

cat <<EOF > config/includes.chroot/lib/live/config/0031-onu-user
#!/bin/sh
useradd -m -s /bin/bash $LIVE_USER
echo "$LIVE_USER:$LIVE_PASS" | chpasswd
adduser $LIVE_USER sudo
EOF
chmod +x config/includes.chroot/lib/live/config/0031-onu-user

success "Live user created"

############################################################
# BOOTLOADER — ISOLINUX (BIOS)
############################################################
step "Creating BIOS (ISOLINUX) bootloader"

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

success "ISOLINUX ready"

############################################################
# BOOTLOADER — EFI GRUB THEME
############################################################
step "Configuring EFI GRUB theme"

EFI_DIR="config/includes.binary/boot/grub"

curl -Lf "https://upload.wikimedia.org/wikipedia/commons/3/3f/Light_blue_gradient_background.png" \
     -o "$EFI_DIR/onu_splash.png"

cat <<EOF > "$EFI_DIR/grub.cfg"
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

sudo lb config \
   --mode debian \
   --distribution "$DISTRO" \
   --archive-areas "main contrib non-free-firmware" \
   --debian-installer live || fail "lb config failed"

step "Building ISO (this will take time)"

( sudo lb build & echo $! > build.pid )
spinner "$(cat build.pid)"

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
