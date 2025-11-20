#!/bin/bash
set -e

# ==============================
#  ONU FULL BUILD SCRIPT
#  With repo fix, dpkg-dev fix,
#  debugging, XFCE, Plymouth,
#  Calamares, OEM, autologin, etc.
# ==============================

ROOT_DIR="$(pwd)"
DISTRO="bookworm"
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
step "APT cleanup (remove broken repo files + stale locks)"

echo "[INFO] Cleaning stale APT lock files"
sudo rm -f /var/lib/apt/lists/lock || true
sudo rm -f /var/cache/apt/archives/lock || true
sudo rm -f /var/lib/dpkg/lock || true
sudo rm -f /var/lib/dpkg/lock-frontend || true

echo "[INFO] Fixing dpkg status if needed"
sudo dpkg --configure -a || true

echo "[INFO] Removing invalid .list files"
sudo find /etc/apt/sources.list.d -type f ! -name "*.list" -exec rm -f {} \; || true

echo "[INFO] Removing disabled or outdated MariaDB repos"
sudo rm -f /etc/apt/sources.list.d/mariadb*.list || true

echo "[INFO] Cleaning pkgcache + srcpkgcache"
sudo rm -f /var/cache/apt/pkgcache.bin || true
sudo rm -f /var/cache/apt/srcpkgcache.bin || true

echo "[INFO] Running apt-get clean"
sudo apt-get clean || true

success "APT cleanup completed"

step "Install dependencies"
echo "[INFO] Updating APT (bookworm)…"
sudo apt-get update || { echo "❌ ERROR: APT update failed"; exit 1; }

echo "[INFO] Installing build dependencies…"
sudo apt-get install -y \

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

# Ensure required directories exist
mkdir -p config/includes.chroot/etc/lightdm
mkdir -p config/includes.chroot/etc/skel
mkdir -p config/includes.chroot/etc/sudoers.d

# LightDM autologin
echo "[Seat:*]
autologin-user=live
autologin-session=xfce" > config/includes.chroot/etc/lightdm/lightdm.conf

# XFCE session
echo "xfce4-session" > config/includes.chroot/etc/skel/.xsession

# Live user sudo permissions
echo "live ALL=(ALL) NOPASSWD: ALL" > config/includes.chroot/etc/sudoers.d/live

success "Base config ready"

# =========================================
#  CREATE LIVE USER (CRITICAL FIX)
# =========================================
step "Create live user inside chroot"

mkdir -p config/includes.chroot/etc/skel

# Create chroot hook to ensure user exists
mkdir -p config/hooks/live
cat > config/hooks/live/010-liveuser.chroot << 'EOF'
#!/bin/bash
useradd -m -s /bin/bash live || true
echo "live:live" | chpasswd
adduser live sudo || true
EOF
chmod +x config/hooks/live/010-liveuser.chroot

# LightDM autologin
mkdir -p config/includes.chroot/etc/lightdm
cat > config/includes.chroot/etc/lightdm/lightdm.conf <<EOF
[Seat:*]
autologin-user=live
autologin-session=xfce
EOF

success "Live user creation ready"

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
sudo apt-get install -y dpkg-dev || { echo "❌ ERROR: dpkg-dev install failed"; exit 1; }

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
mkdir -p config/includes.chroot/etc/apt/sources.list.d || true
mkdir -p config/includes.chroot/opt
rm -rf "$REPO_DST"
cp -a "$REPO_SRC" "$REPO_DST" || fail "Failed to copy repo into chroot"
# Debug: list repo dst
if [ -d "$REPO_DST" ]; then
  echo "[DEBUG] Repo deployed at $REPO_DST"
  ls -l "$REPO_DST" || true
else
  echo "❌ ERROR: Repo destination missing after copy: $REPO_DST"
  fail "Repo copy failed"
fi

mkdir -p config/includes.chroot/etc/apt/sources.list.d
mkdir -p config/includes.chroot/etc/apt/sources.list.d
echo "deb [trusted=yes] file:/opt/onu-repo $DISTRO main" > config/includes.chroot/etc/apt/sources.list.d/onu-local.list
success "Local APT repo configured"

# =========================================
#  COPY WALLPAPER + SPLASH FROM REPO
# =========================================
step "Copy wallpaper + splash"

# Ensure dirs
mkdir -p config/includes.chroot/usr/share/backgrounds/xfce
mkdir -p config/includes.chroot/usr/share/plymouth/themes/onu

# Copy repo images
cp "$ROOT_DIR/background.png" config/includes.chroot/usr/share/backgrounds/xfce/background.png || true
cp "$ROOT_DIR/splash.png" config/includes.chroot/usr/share/plymouth/themes/onu/logo.png || true

success "Wallpaper + Plymouth splash copied from repo"

# =========================================
#  XFCE DEFAULT WALLPAPER (AUTO‑SET)
# =========================================
step "Set XFCE default wallpaper"

# Copy wallpaper from repo into XFCE backgrounds
mkdir -p config/includes.chroot/usr/share/backgrounds
cp "$ROOT_DIR/background.png" config/includes.chroot/usr/share/backgrounds/onu.png

# Set XFCE default wallpaper via xfconf
mkdir -p config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="workspace0" type="empty">
          <property name="last-image" type="string" value="/usr/share/backgrounds/onu.png"/>
        </property>
      </property>
    </property>
  </property>
</channel>
EOF

success "XFCE default wallpaper applied"

# =========================================
#  PLYMOUTH THEME (REMOVE DEBIAN 12 SPLASH)
# =========================================
step "Insert Plymouth + Grub themes"

# Remove Debian default theme
mkdir -p config/includes.chroot/usr/share/plymouth/themes
rm -rf config/includes.chroot/usr/share/plymouth/themes/debian || true

# Install custom ONU theme
mkdir -p config/includes.chroot/usr/share/plymouth/themes/onu
cat > config/includes.chroot/usr/share/plymouth/themes/onu/onu.plymouth <<EOF
[Plymouth Theme]
Name=ONU
Description=ONU Boot Splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/onu
ScriptFile=/usr/share/plymouth/themes/onu/onu.script
EOF

# Minimal script that shows a PNG logo (user replaces logo.png)
cat > config/includes.chroot/usr/share/plymouth/themes/onu/onu.script <<EOF
# Show logo centered
logo = Image("logo.png");

fun draw() {
    logo.Draw(Screen.Width/2 - logo.Width/2, Screen.Height/2 - logo.Height/2);
}

Plymouth.SetUpdateFunction(draw);
EOF

# Placeholder logo
echo "" > config/includes.chroot/usr/share/plymouth/themes/onu/logo.png

# Select ONU theme
mkdir -p config/includes.chroot/etc/plymouth
cat > config/includes.chroot/etc/plymouth/plymouthd.conf <<EOF
[Daemon]
Theme=onu
EOF

# Fix initramfs regeneration inside live-build
mkdir -p config/hooks/live
cat > config/hooks/live/020-plymouth.chroot <<'EOF'
#!/bin/bash
update-alternatives --set default.plymouth /usr/share/plymouth/themes/onu/onu.plymouth || true
update-initramfs -u || true
EOF
chmod +x config/hooks/live/020-plymouth.chroot

# After plymouth theme, install XFCE wallpaper and set default desktop
# Ensure we have a usable logo and wallpaper (create placeholder if missing)
if [ ! -f ./onu-logo.png ]; then
  echo "[INFO] Creating placeholder logo: onu-logo.png"
  if command -v convert >/dev/null 2>&1; then
    convert -size 512x512 xc:none -gravity center -pointsize 72 -fill white -annotate 0 'ONU' ./onu-logo.png || true
  else
    # fallback: create an empty file to avoid build errors
    echo "" > ./onu-logo.png
  fi
fi

# Copy logo into plymouth theme as logo.png (resize)
if command -v convert >/dev/null 2>&1; then
  convert ./onu-logo.png -resize 512x512 config/includes.chroot/usr/share/plymouth/themes/onu/logo.png || cp ./onu-logo.png config/includes.chroot/usr/share/plymouth/themes/onu/logo.png
else
  cp ./onu-logo.png config/includes.chroot/usr/share/plymouth/themes/onu/logo.png || true
fi

# Also ensure XFCE wallpaper exists (use earlier wallpaper if present)
mkdir -p config/includes.chroot/usr/share/xfce4/backdrops
if [ -f config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png ]; then
  cp config/includes.chroot/usr/share/backgrounds/ONU/wallpaper.png config/includes.chroot/usr/share/xfce4/backdrops/onu.png || true
else
  # create a placeholder wallpaper
  if command -v convert >/dev/null 2>&1; then
    convert -size 1920x1080 xc:#0a0a0a -gravity center -pointsize 48 -fill white -annotate 0 'ONU Linux' config/includes.chroot/usr/share/xfce4/backdrops/onu.png || true
  else
    echo "" > config/includes.chroot/usr/share/xfce4/backdrops/onu.png
  fi
fi

# Create XFCE desktop config to set the wallpaper
mkdir -p config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml
cat > config/includes.chroot/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-desktop" version="1.0">
    <property name="backdrop" type="empty">
        <property name="screen0" type="empty">
            <property name="monitor0" type="empty">
                <property name="image-path" type="string" value="/usr/share/xfce4/backdrops/onu.png"/>
                <property name="last-image" type="string" value="/usr/share/xfce4/backdrops/onu.png"/>
                <property name="image-style" type="int" value="5"/>
            </property>
        </property>
    </property>
</channel>
XML

success "Plymouth and XFCE wallpaper configured"
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
# (FIXED: ensure usr/bin exists before writing)
# =========================================
step "Add welcome app"
mkdir -p config/includes.chroot/usr/share/onu-welcome
mkdir -p config/includes.chroot/usr/bin
echo "#!/bin/bash
echo 'Welcome to ONU!'" > config/includes.chroot/usr/bin/onu-welcome
chmod +x config/includes.chroot/usr/bin/onu-welcome
success "Welcome app added"

# =========================================
#  BUILD ISO
# =========================================
step "Run live-build"

# Disable manpage pager that appears during lb config
export MANPAGER=cat
export PAGER=cat
sudo lb config --distribution $DISTRO --binary-images iso-hybrid
sudo lb build
success "ISO build complete"
