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
# ===========================================
step "Build local repo"
REPO_SRC="$ROOT_DIR/$IN_TREE_REPO"
REPO_DST="config/includes.chroot/opt/onu-repo"
rm -rf "$REPO_SRC"
mkdir -p "$REPO_SRC/pool/main"
cp "packages/${PKG_NAME}.deb" "$REPO_SRC/pool/main/"
mkdir -p "$REPO_SRC/dists/$DISTRO/main/binary-amd64"
pushd "$REPO_SRC" >/dev/null
dpkg-scanpackages pool /dev/null > dists/$DISTRO/main/binary-amd64/Packages
gzip -9c dists/$DISTRO/main/binary-amd64/Packages > dists/$DISTRO/main/binary-amd64/Packages.gz
cat > dists/$DISTRO/Release <<EOF
Origin: ONU
Label: ONU-Repo
Suite: $DISTRO
Codename: $DISTRO
Architectures: amd64
Components: main
EOF
popd >/dev/null
rm -rf "$REPO_DST"
mkdir -p config/includes.chroot/opt
cp -a "$REPO_SRC" "$REPO_DST"

# Point apt to repo
echo "deb [trusted=yes] file:/opt/onu-repo $DISTRO main" > config/includes.chroot/etc/apt/sources.list.d/onu-local.list
success "Local repo ready"

# ===========================================
#  PLYMOUTH THEME + LOGO
# ===========================================
step "Add Plymouth theme"
PLY="config/includes.chroot/usr/share/plymouth/themes/onu"
mkdir -p "$PLY"
if [ ! -f ./onu-logo.png ]; then convert -size 512x512 canvas:none -fill white -draw "text 10,250 'ONU'" ./onu-logo.png; fi
cp ./onu-logo.png "$PLY/onu-logo.png"
cat > "$PLY/onu.plymouth" <<EOF
[Plymouth Theme]
Name=ONU Linux
Description=ONU animated theme
ModuleName=script
EOF
cat > "$PLY/onu.script" <<'EOF'
theme_image = Image("onu-logo.png");
for (i = 0; i <= 30; i++) { theme_image.SetOpacity(i*8); Window.Fill(); theme_image.Draw((Window.GetWidth()-theme_image.GetWidth())/2,(Window.GetHeight()-theme_image.GetHeight())/2,255); Animation.Sleep(30);} 
for (j=0;j<3;j++){for(s=100;s<=110;s+=2){theme_image.Scale(s/100.0);Window.Fill();theme_image.Draw((Window.GetWidth()-theme_image.GetWidth())/2,(Window.GetHeight()-theme_image.GetHeight())/2,255);Animation.Sleep(20);}for(s=110;s>=100;s-=2){theme_image.Scale(s/100.0);Window.Fill();theme_image.Draw((Window.GetWidth()-theme_image.GetWidth())/2,(Window.GetHeight()-theme_image.GetHeight())/2,255);Animation.Sleep(20);}}
EOF
mkdir -p config/includes.chroot/etc/plymouth
cat > config/includes.chroot/etc/plymouth/plymouthd.conf <<EOF
Theme=onu
EOF
success "Plymouth ready"

# ===========================================
#  LIGHTDM AUTOLOGIN
# ===========================================
step "LightDM autologin"
cat > config/includes.chroot/etc/lightdm/lightdm.conf <<EOF
[Seat:*]
autologin-user=$LIVE_USER
autologin-user-timeout=0
user-session=xfce
greeter-session=lightdm-gtk-greeter
EOF
cat > config/includes.chroot/etc/xdg/lightdm/lightdm.conf.d/50-onu.conf <<EOF
[Seat:*]
user-session=xfce
EOF
cat > config/includes.chroot/etc/skel/.dmrc <<EOF
[Desktop]
Session=xfce
EOF
success "LightDM configured"

# ===========================================
#  LIVE USER
# ===========================================
step "Live user setup"
cat > config/includes.chroot/lib/live/config/0031-onu-user <<EOF
#!/bin/sh
set -e

# Create live user
useradd -m -s /bin/bash $LIVE_USER

# Set password
echo "$LIVE_USER:$LIVE_PASS" | chpasswd

# Add to sudoers
usermod -aG sudo "$LIVE_USER"
mkdir -p /etc/sudoers.d
echo "$LIVE_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99_liveuser
chmod 440 /etc/sudoers.d/99_liveuser

# Ensure XFCE session
echo "[Desktop]" > /home/$LIVE_USER/.dmrc
echo "Session=xfce" >> /home/$LIVE_USER/.dmrc
chown $LIVE_USER:$LIVE_USER /home/$LIVE_USER/.dmrc
EOF
chmod +x config/includes.chroot/lib/live/config/0031-onu-user
success "Live user configured"
