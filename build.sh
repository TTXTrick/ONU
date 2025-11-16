#!/bin/bash
set -e

# ==============================
#  ONU FULL BUILD SCRIPT
#  With repo fix, dpkg-dev fix,
#  debugging, XFCE, Plymouth,
#  Calamares, OEM, autologin, etc.
# ==============================

ROOT_DIR="$(pwd)"
DISTRO="trixie"
PKG_NAME="onu-desktop"
IN_TREE_REPO="config/onu-local-repo"

step() {
    echo -e "\n[STEP] $1"
    echo "--------------------------------------------------"
}

success() {
    echo "✔ $1"
}

# =========================================
#  INSTALL REQUIRED TOOLS
# =========================================
step "Install dependencies"
apt-get update
apt-get install -y \
  live-build \
  dpkg-dev \
  xorriso \
  squashfs-tools \
  grub-pc-bin \
  grub-efi-amd64-bin \
  grub-efi-ia32-bin
success "Tools installed"

# =========================================
#  CLEAN PREVIOUS BUILD
# =========================================
step "Clean old build"
rm -rf config chroot binary iso || true
success "Clean done"

# =========================================
#  SETUP CONFIG ROOT
# =========================================
step "Prepare config tree"
mkdir -p config/includes.chroot/etc/lightdm
echo "[Seat:*]\nautologin-user=live\nautologin-session=xfce" > config/includes.chroot/etc/lightdm/lightdm.conf

# XFCE default session
echo "xfce4-session" > config/includes.chroot/etc/skel/.xsession

echo "live ALL=(ALL) NOPASSWD: ALL" > config/includes.chroot/etc/sudoers.d/live
success "Base config ready"

# =========================================
#  INSTALL LIVE PACKAGES
# =========================================
step "Create package list"
mkdir -p config/package-lists
echo "\
xfce4
lightdm
plymouth
plymouth-themes
grub2
calamares
squashfs-tools
xserver-xorg
" > config/package-lists/desktop.list.chroot
success "Package list created"

# =========================================
#  LOCAL REPO (FIXED)
# =========================================
step "Build local repo"

REPO_SRC="$IN_TREE_REPO"
REPO_DST="config/includes.chroot/opt/onu-repo"

echo "[DEBUG] REPO_SRC=$REPO_SRC"
echo "[DEBUG] REPO_DST=$REPO_DST"

# ensure dpkg-scanpackages exists
apt-get install -y dpkg-dev

# Ensure .deb exists
if [ ! -f "packages/${PKG_NAME}.deb" ]; then
    echo "ERROR: packages/${PKG_NAME}.deb not found"
    exit 1
fi

rm -rf "$REPO_SRC"
mkdir -p "$REPO_SRC/pool/main"
cp "packages/${PKG_NAME}.deb" "$REPO_SRC/pool/main/"

mkdir -p "$REPO_SRC/dists/$DISTRO/main/binary-amd64"

# Verify repo source exists before pushd
if [ ! -d "$REPO_SRC" ]; then
    echo "ERROR: REPO_SRC does not exist: $REPO_SRC"
    exit 1
fi

pushd "$REPO_SRC" >/dev/null
echo "[DEBUG] Running dpkg-scanpackages..."

# build index
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

# copy into includes tree
mkdir -p config/includes.chroot/opt
rm -rf "$REPO_DST"
cp -a "$REPO_SRC" "$REPO_DST"

echo "deb [trusted=yes] file:/opt/onu-repo $DISTRO main" > config/includes.chroot/etc/apt/sources.list.d/onu-local.list
success "Local repo ready"

# =========================================
#  PLYMOUTH THEME + GRUB THEME
# =========================================
step "Insert Plymouth + Grub themes"
mkdir -p config/includes.chroot/usr/share/plymouth/themes/onu
mkdir -p config/includes.chroot/boot/grub/themes/onu
# (User places their own PNG/logo)

success "Themes placed"

# =========================================
#  CALAMARES + OEM
# =========================================
step "Setup Calamares"
mkdir -p config/includes.chroot/etc/calamares
# (Your autoconfig YAML goes here)
success "Calamares ready"

# =========================================
#  WELCOME APP
# =========================================
step "Add welcome app"
mkdir -p config/includes.chroot/usr/share/onu-welcome
echo "#!/bin/bash
echo 'Welcome to ONU!'" > config/includes.chroot/usr/bin/onu-welcome
chmod +x config/includes.chroot/usr/bin/onu-welcome
success "Welcome app added"

# =========================================
#  BUILD ISO
# =========================================
step "Run live-build"
lb config --distribution $DISTRO --binary-images iso-hybrid
lb build
success "ISO build complete"
