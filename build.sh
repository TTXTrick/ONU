#!/usr/bin/env bash
set -euo pipefail

LOGFILE="onu-build.log"
exec > >(tee "$LOGFILE") 2>&1

echo "========== ONU LINUX BUILD SYSTEM (FIXED FULL) =========="

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
# in-tree repo inside the chroot includes so live environment sees it at build time
IN_TREE_REPO="config/includes.chroot/opt/onu-repo"

# packages dir used for building .deb
PACKAGES_DIR="packages"

# fallback wallpaper local filename used if curl download fails (optional)
FALLBACK_WALLPAPER="fallback-wallpaper.png"

############################################################
# SANITY CHECKS
############################################################
step "Sanity checks"

if [ "$EUID" = 0 ]; then
    fail "Do NOT run this script as root. Run as a normal user with sudo access."
fi

command -v sudo >/dev/null 2>&1 || fail "sudo is required"
sudo true || fail "sudo authentication failed"
command -v dpkg-deb >/dev/null 2>&1 || fail "dpkg-deb not found; please install dpkg-dev"
success "Sanity checks passed"

############################################################
# INSTALL DEPENDENCIES
############################################################
step "Installing dependencies"

sudo apt update || fail "apt update failed"
sudo apt install -y live-build debootstrap xorriso syslinux genisoimage squashfs-tools \
    reprepro dpkg-dev apt-utils curl git xfconf qttools5-dev-tools cmake dpkg-sig mlocate \
    dpkg-scanpackages || fail "Dependency install failed"

success "Dependencies installed"

############################################################
# CLEAN PREVIOUS BUILDS
############################################################
step "Cleaning previous builds"

# keep this safe: only remove build-related directories in current project
sudo rm -rf chroot binary auto tmp build.pid || true
rm -rf config auto build || true
mkdir -p config

success "Clean environment ready"

############################################################
# CREATE PROJECT DIRECTORIES
############################################################
step "Preparing directory structure"

mkdir -p \
    "$PACKAGES_DIR/$PKG_NAME/DEBIAN" \
    config/includes.chroot/etc/skel \
    config/includes.chroot/etc/apt/sources.list.d \
    config/includes.chroot/usr/share/backgrounds/ONU \
    config/includes.chroot/lib/live/config \
    config/includes.binary/isolinux \
    config/includes.binary/boot/grub \
    config/includes.binary/boot/grub/themes \
    branding/calamares \
    config/package-lists \
    config/archives \
    config/includes.chroot/etc/lightdm/lightdm.conf.d \
    config/hooks/live

# ensure in-tree repo structure exists
mkdir -p "$IN_TREE_REPO/dists/$DISTRO/main/binary-amd64"
mkdir -p "$IN_TREE_REPO/pool/main"

success "Directory structure created"

############################################################
# WALLPAPER
############################################################
step "Downloading wallpaper"

# prefer .png because many boots/themes expect raster formats
WP_TARGET=config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png

if curl -fsSL "$WALLPAPER_URL" -o "$WP_TARGET"; then
    success "Wallpaper downloaded to $WP_TARGET"
else
    echo "⚠️ Wallpaper download failed; using fallback if present"
    if [ -f "$FALLBACK_WALLPAPER" ]; then
        cp "$FALLBACK_WALLPAPER" "$WP_TARGET"
        success "Fallback wallpaper copied"
    else
        echo "No fallback wallpaper found; continuing without wallpaper"
    fi
fi

# copy splash for grub (not fatal if fails)
cp "$WP_TARGET" config/includes.binary/boot/grub/onu_splash.png >/dev/null 2>&1 || true

############################################################
# META-PACKAGE
############################################################
step "Creating meta-package"

PACKAGE_DIR="$PACKAGES_DIR/$PKG_NAME"
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

# Build .deb
dpkg-deb --build --root-owner-group "$PACKAGE_DIR" || fail "dpkg-deb failed"

# ensure package is present
if [ ! -f "${PACKAGE_DIR}.deb" ]; then
    # dpkg-deb outputs packages as packages/<pkg>.deb
    # find the .deb we just created
    DEB_CREATED=$(ls -1 "$PACKAGES_DIR"/*.deb 2>/dev/null | tail -n1 || true)
    if [ -z "$DEB_CREATED" ]; then
        fail "Could not find created .deb for $PKG_NAME"
    else
        mv "$DEB_CREATED" "${PACKAGE_DIR}.deb" || true
    fi
fi

# for ease later, copy the resulting deb to top-level packages dir as onu-desktop.deb
cp "${PACKAGE_DIR}.deb" "${PACKAGES_DIR}/${PKG_NAME}.deb" || true

success "Meta-package built: ${PACKAGES_DIR}/${PKG_NAME}.deb"

############################################################
# Prepare in-tree local APT repo (to be included in chroot)
############################################################
step "Preparing in-tree APT repo for inclusion in chroot"

# Remove previous in-tree repo copy
rm -rf "$IN_TREE_REPO"
mkdir -p "$IN_TREE_REPO/pool/main"
mkdir -p "$IN_TREE_REPO/dists/$DISTRO/main/binary-amd64"

# Copy .deb into repository pool
cp "${PACKAGES_DIR}/${PKG_NAME}.deb" "$IN_TREE_REPO/pool/main/" || fail "Cannot copy meta-package into in-tree repo"

pushd "$IN_TREE_REPO" >/dev/null

# Generate Packages file and gz
if command -v dpkg-scanpackages >/dev/null 2>&1; then
    # dpkg-scanpackages expects path relative to where it's run; we run from IN_TREE_REPO, pool exists here
    dpkg-scanpackages pool /dev/null > dists/"$DISTRO"/main/binary-amd64/Packages || fail "dpkg-scanpackages failed"
    gzip -9c dists/"$DISTRO"/main/binary-amd64/Packages > dists/"$DISTRO"/main/binary-amd64/Packages.gz
else
    fail "dpkg-scanpackages is required but not available"
fi

# Create Release file (simple)
cat > dists/"$DISTRO"/Release <<EOREL
Origin: ONU
Label: ONU-Repo
Suite: $DISTRO
Codename: $DISTRO
Architectures: amd64
Components: main
Description: ONU Local Repository
EOREL

popd >/dev/null

# copy the entire repo into config/includes.chroot so it is present in the chroot during package install
rm -rf config/includes.chroot/opt/onu-repo || true
mkdir -p config/includes.chroot/opt
cp -a "$IN_TREE_REPO" config/includes.chroot/opt/onu-repo || fail "Failed to copy local repo into includes.chroot"

success "In-tree APT repo prepared and copied into config/includes.chroot/opt/onu-repo"

############################################################
# ARCHIVES / APT SOURCES TO USE THE LOCAL REPO
############################################################
step "Adding local repo to live-build archives (repositories used in chroot)"

# Live-build will copy files from config/archives/*.list.chroot into the chroot's apt sources
cat > config/archives/onu-local.list.chroot <<EOF
deb [trusted=yes] file:/opt/onu-repo $DISTRO main
EOF

# Also keep an apt source file inside the image by default (this is optional)
cat > config/includes.chroot/etc/apt/sources.list.d/onu-local.list <<EOF
deb [trusted=yes] file:/opt/onu-repo $DISTRO main
EOF

success "Local APT repo registered for live-build"

############################################################
# PACKAGE-LISTS (ensures packages are installed in chroot)
############################################################
step "Creating package-lists for live-build"

mkdir -p config/package-lists
cat > config/package-lists/onu.list.chroot <<EOF
# Ensure our meta package is installed in the live image
$PKG_NAME

# Fallback explicit packages if meta-package doesn't pull everything in time
xfce4
lightdm
network-manager
firefox-esr
thunar
vlc
EOF

success "Package-lists created"

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

# Installer modules (unchanged from your original)
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
# LIVE USER HOOK (create live user at image build time)
############################################################
step "Creating live user hook"

# Using live-build hooks to create the user (runs inside chroot during build)
mkdir -p config/hooks/live
cat > config/hooks/live/001-create-user.hook.chroot <<'EOF'
#!/bin/bash
set -e
LIVE_USER=''"$LIVE_USER"''
LIVE_PASS=''"$LIVE_PASS"''
# Create the user if missing
if ! id "$LIVE_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$LIVE_USER" || true
    echo "$LIVE_USER:$LIVE_PASS" | chpasswd || true
    adduser "$LIVE_USER" sudo || true
fi
EOF
# ensure hook is executable
chmod +x config/hooks/live/001-create-user.hook.chroot

success "Live user hook installed"

############################################################
# LIGHTDM AUTOLOGIN & ENABLE SYSTEMD SERVICE
############################################################
step "Configuring LightDM autologin and enabling service in image"

# LightDM autologin snippet
mkdir -p config/includes.chroot/etc/lightdm/lightdm.conf.d
cat > config/includes.chroot/etc/lightdm/lightdm.conf.d/60-onu.conf <<EOF
[Seat:*]
autologin-user=$LIVE_USER
autologin-user-timeout=0
autologin-session=xfce
EOF

# Ensure LightDM is enabled on boot by creating a graphical.target.wants symlink pre-populated in image
mkdir -p config/includes.chroot/etc/systemd/system/graphical.target.wants
# create symlink that will point to the real unit once lightdm package installs
ln -sf /lib/systemd/system/lightdm.service config/includes.chroot/etc/systemd/system/graphical.target.wants/lightdm.service || true

success "LightDM autologin and systemd enable stub added"

############################################################
# ISOLINUX (BIOS)
############################################################
step "Configuring ISOLINUX bootloader"

mkdir -p config/includes.binary/isolinux
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

mkdir -p config/includes.binary/boot/grub
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
# XFCE DEFAULTS: skel wallpaper + minimal xfce prefs
############################################################
step "Setting default XFCE wallpaper and skel config"

# Default wallpaper for new users
mkdir -p config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/ONU/wallpaper.png"/>
        <property name="image-style" type="int" value="5"/>
      </property>
    </property>
  </property>
</channel>
EOF

success "Default XFCE configuration added"

############################################################
# LIVE-BUILD CONFIG & RUN
############################################################
step "Running live-build config"

# Use explicit lb config to ensure consistent options (keeps parity with original script)
sudo lb config \
   --mode debian \
   --distribution "$DISTRO" \
   --archive-areas "main contrib non-free-firmware" \
   --debian-installer live \
   --bootloaders "syslinux,grub-efi" \
   || fail "lb config failed"

success "lb config created"

step "Starting ISO build (this can take a long time)"

# Start build in background and show spinner
( sudo lb build & echo $! > build.pid )
spinner "$(cat build.pid)"

# Check for final ISO
if [ -f live-image-amd64.hybrid.iso ]; then
    mv live-image-amd64.hybrid.iso "$ISO_NAME"
    success "ISO created: $ISO_NAME"
else
    # capture logs if nothing created
    fail "ISO build failed - check $LOGFILE for lb output and apt errors"
fi

echo ""
echo "============================================"
echo "🎉 ONU Linux ISO Build COMPLETE!"
echo "ISO file: $ISO_NAME"
echo "Log file: $LOGFILE"
echo "============================================"
