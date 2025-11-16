#!/usr/bin/env bash
set -euo pipefail

LOGFILE="onu-build.log"
exec > >(tee "$LOGFILE") 2>&1

echo "========== ONU LINUX BUILD SYSTEM (FIXED) =========="

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
WALLPAPER_URL="https://gitlab.com/TTXTrick/testbg/-/raw/main/onu-background.svg?ref_type=heads"
PKG_NAME="onu-desktop"
EMAIL="builder@onu.local"
NAME="ONU Builder"

ROOT_DIR="$(pwd)"
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
    reprepro dpkg-dev apt-utils curl git xfconf qttools5-dev-tools cmake || fail "Dependency install failed"

success "Dependencies installed"

############################################################
# CLEAN PREVIOUS BUILDS
############################################################
step "Cleaning previous builds"

sudo rm -rf chroot binary auto tmp build.pid || fail "Cleanup failed"
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
    config/package-lists

mkdir -p "$IN_TREE_REPO/dists/$DISTRO/main/binary-amd64"
mkdir -p "$IN_TREE_REPO/pool/main"

success "Directory structure created"

############################################################
# WALLPAPER
############################################################
step "Downloading wallpaper"

curl -Lf "$WALLPAPER_URL" \
  -o config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png \
  || fail "Wallpaper download failed"

cp config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png \
   config/includes.binary/boot/grub/onu_splash.png || true

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
 Installs the core ONU Linux desktop environment.
EOF

echo "ONU Linux Meta-package" > "$PACKAGE_DIR/usr/share/doc/$PKG_NAME/README"

dpkg-deb --build --root-owner-group "$PACKAGE_DIR" || fail "dpkg-deb failed"

success "Meta-package built"

############################################################
# PACKAGE-LISTS (ensures packages are installed in chroot)
############################################################
step "Creating package-lists for live-build"

# Ensure live-build installs our meta-package (and fallback packages) during chroot build
cat > config/package-lists/onu.list.chroot <<EOF
# Ensure our meta package is installed in the live image
$PKG_NAME
# Fallback explicit packages (helpful if meta-package fails to pull everything)
xfce4
lightdm
network-manager
firefox-esr
thunar
vlc
EOF

success "Package-lists created"

############################################################
# LOCAL APT REPOSITORY  (INSIDE CHROOT)
############################################################
step "Building internal APT repository"

REPO="$ROOT_DIR/$IN_TREE_REPO"

rm -rf "$REPO"
mkdir -p "$REPO/dists/$DISTRO/main/binary-amd64"
mkdir -p "$REPO/pool/main"

# copy our built .deb into the in-tree repo (so apt in chroot can use it)
cp "packages/$PKG_NAME.deb" "$REPO/pool/main/" || fail "Cannot copy meta-package"

pushd "$REPO" >/dev/null

# create Packages index
dpkg-scanpackages pool > dists/$DISTRO/main/binary-amd64/Packages || fail "dpkg-scanpackages failed"
gzip -9c dists/$DISTRO/main/binary-amd64/Packages > dists/$DISTRO/main/binary-amd64/Packages.gz

# Try to create a Release file for nicer apt output
if command -v apt-ftparchive >/dev/null; then
    apt-ftparchive release dists/"$DISTRO" > dists/"$DISTRO"/Release
else
    cat > dists/"$DISTRO"/Release <<EOREL
Origin: ONU
Label: ONU-Repo
Suite: $DISTRO
Codename: $DISTRO
Architectures: amd64
Components: main
EOREL
fi

popd >/dev/null

# Add local repo to chroot apt sources so live-build chroot can install onu-desktop
cat > config/includes.chroot/etc/apt/sources.list.d/onu-local.list <<EOF
deb [trusted=yes] file:/opt/onu-repo $DISTRO main
EOF

success "Local APT repo ready"

############################################################
# CALAMARES INSTALLER (3.3+)
############################################################
step "Configuring Calamares installer"

CAL_DIR="config/includes.chroot/etc/calamares"
mkdir -p "$CAL_DIR/modules"

cat <<'EOF' > "$CAL_DIR/settings.conf"
---
modules-search: [ local ]
sequence:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - packages
  - displaymanager
  - finished

branding: "onu"
EOF

# Installer modules

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
defaultFilesystemType: "ext4"
automatic:
  partitionLayout: "erase"
efiSystemPartition: "/boot/efi"
EOF

cat <<'EOF' > "$CAL_DIR/modules/displaymanager.conf"
---
displaymanagers:
  - lightdm
EOF

# NOTE: we no longer remove live-boot/live-config here (they are useful for live sessions)
cat <<'EOF' > "$CAL_DIR/modules/packages.conf"
---
packages:
  remove: []
EOF

cat <<'EOF' > "$CAL_DIR/modules/finished.conf"
---
restartNowEnabled: true
runLiveCleanup: true
EOF

success "Calamares configured"

############################################################
# LIVE USER HOOK
############################################################
step "Creating live user hook"

cat <<EOF > config/includes.chroot/lib/live/config/0031-onu-user
#!/bin/sh
set -e
useradd -m -s /bin/bash $LIVE_USER
echo "$LIVE_USER:$LIVE_PASS" | chpasswd
adduser $LIVE_USER sudo || true
EOF
chmod +x config/includes.chroot/lib/live/config/0031-onu-user

success "Live user hook installed"

############################################################
# LIGHTDM AUTOLOGIN (so the live session boots directly to desktop)
############################################################
step "Creating LightDM autologin config and enable symlink"

# Create LightDM conf snippet for autologin (will be present in the built image)
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/60-onu.conf <<EOF
[Seat:*]
autologin-user=$LIVE_USER
autologin-user-timeout=0
autologin-session=xfce
EOF

# Ensure LightDM is enabled on boot by creating the appropriate systemd wants directory
# Live-build will copy this into the image exactly, causing systemd to enable the service.
mkdir -p config/includes.chroot/etc/systemd/system/graphical.target.wants
# Symlink will point to the unit file installed by the package at /lib/systemd/system/lightdm.service
ln -sf /lib/systemd/system/lightdm.service config/includes.chroot/etc/systemd/system/graphical.target.wants/lightdm.service || true

success "LightDM autologin and enable configuration added"

############################################################
# ISOLINUX (BIOS)
############################################################
step "Configuring ISOLINUX bootloader"

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

success "ISOLINUX configured"

############################################################
# GRUB (UEFI)
############################################################
step "Configuring EFI GRUB"

cat <<'EOF' > config/includes.binary/boot/grub/grub.cfg
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

success "EFI GRUB configured"

############################################################
# Optional: Ensure our wallpaper is set as default for skel (new users)
############################################################
step "Set wallpaper for default skel"

mkdir -p config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
# Minimal xfce wallpaper config - XFCE will respect user settings if present.
cat > config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/ONU/wallpaper.png"/>
      </property>
    </property>
  </property>
</channel>
EOF

success "Default wallpaper configured"

############################################################
# BUILD ISO
############################################################
step "Running live-build config"

sudo lb config \
   --mode debian \
   --distribution "$DISTRO" \
   --archive-areas "main contrib non-free-firmware" \
   --debian-installer live \
   --bootloaders "syslinux,grub-efi" \
   || fail "lb config failed"

step "Building the ISO (this will take time)"

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
