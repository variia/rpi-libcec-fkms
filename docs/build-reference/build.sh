#!/bin/bash
set -e

OUTPUT_DIR="/output"
BUILD_DIR="/tmp/libcec-build"

echo "=== rpi-libcec-fkms build ==="

# Ensure output directory exists
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: Mount /output volume to retrieve build artifacts."
    echo "Usage: docker run --platform linux/arm64 -v \$(pwd)/output:/output rpi-libcec-build"
    exit 1
fi

# --- Step 1: Build libraspberrypi0-compat ---
echo "--- Building libraspberrypi0-compat ---"
cd /tmp
apt-get update -qq
apt-get download libraspberrypi0
mkdir -p compat-deb
dpkg-deb -R libraspberrypi0*.deb compat-deb/

# Replace control file
cat > compat-deb/DEBIAN/control << 'EOF'
Package: libraspberrypi0-compat
Source: raspberrypi-userland
Version: 1:2+git20231018~131943+3c97f76-1
Architecture: arm64
Maintainer: <YOUR_GITHUB_HANDLE>
Installed-Size: 416
Depends: libc6 (>= 2.34)
Section: libs
Priority: optional
Multi-Arch: same
Homepage: https://github.com/variia/rpi-libcec-fkms
Description: Raspberry Pi VideoCore IV libraries (FKMS compatibility repackage)
 Repackage of libraspberrypi0 that coexists with libdtovl0.
 Contains VCHI runtime libraries (libbcm_host, libvcos, libvchiq_arm)
 needed by libcec's Raspberry Pi CEC adapter when using the FKMS
 display driver.
 .
 Original package: libraspberrypi0 from raspberrypi-userland.
EOF

# Fix shlibs: rename package, remove libdtovl entry
sed -i 's/libraspberrypi0/libraspberrypi0-compat/g' compat-deb/DEBIAN/shlibs
sed -i '/libdtovl/d' compat-deb/DEBIAN/shlibs

# Rename doc directory
mv compat-deb/usr/share/doc/libraspberrypi0 compat-deb/usr/share/doc/libraspberrypi0-compat

# Remove libdtovl.so.0 — already provided by libdtovl0
rm -f compat-deb/usr/lib/aarch64-linux-gnu/libdtovl.so.0

# Build and install compat deb
dpkg-deb --build --root-owner-group compat-deb/ libraspberrypi0-compat_2+git20231018_arm64.deb
dpkg -i libraspberrypi0-compat_2+git20231018_arm64.deb

echo "--- libraspberrypi0-compat installed in build container ---"

# --- Step 2: Build libcec ---
echo "--- Pulling libcec source from RPi archive ---"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
apt source libcec
cd libcec-*/

# Apply patch — add RPI API flags to cmake configuration
echo "--- Applying RPi CEC patch ---"
RULES_FILE="debian/rules"

if grep -q "HAVE_RPI_API" "$RULES_FILE"; then
    echo "Patch already applied, skipping."
else
    sed -i 's/-DHAVE_LINUX_API=1$/\-DHAVE_LINUX_API=1 \\\n\t\t-DHAVE_RPI_API=1 \\\n\t\t-DRPI_INCLUDE_DIR=\/usr\/include \\\n\t\t-DRPI_LIB_DIR=\/usr\/lib\/aarch64-linux-gnu/' "$RULES_FILE"
fi

echo "--- Patched debian/rules ---"
cat "$RULES_FILE"
echo "---"

# Build
echo "--- Building libcec ---"
dpkg-buildpackage -us -uc -b

# --- Step 3: Collect artifacts ---
echo "--- Collecting build artifacts ---"
cp "$BUILD_DIR"/*.deb "$OUTPUT_DIR/"
cp /tmp/libraspberrypi0-compat_*.deb "$OUTPUT_DIR/"

# --- Step 4: Generate apt repo structure ---
echo "--- Generating apt repository ---"
REPO_DIR="$OUTPUT_DIR/repo"
DIST_DIR="$REPO_DIR/dists/bookworm"
POOL_DIR="$REPO_DIR/pool/main"
BIN_DIR="$DIST_DIR/main/binary-arm64"

mkdir -p "$BIN_DIR" "$POOL_DIR"
cp "$OUTPUT_DIR"/*.deb "$POOL_DIR/"

cd "$REPO_DIR"
dpkg-scanpackages --multiversion pool/main /dev/null > "$BIN_DIR/Packages"
gzip -9fk "$BIN_DIR/Packages"

# Generate Release file
PKG="main/binary-arm64/Packages"
PKG_GZ="main/binary-arm64/Packages.gz"
cd "$DIST_DIR"
cat > Release << EOF
Origin: rpi-libcec-fkms
Label: rpi-libcec-fkms
Suite: bookworm
Codename: bookworm
Architectures: arm64
Components: main
Description: Patched libcec with RPi firmware CEC adapter for FKMS
Date: $(date -Ru)
MD5Sum:
 $(md5sum "$PKG" | cut -d' ' -f1) $(wc -c < "$PKG" | tr -d ' ') $PKG
 $(md5sum "$PKG_GZ" | cut -d' ' -f1) $(wc -c < "$PKG_GZ" | tr -d ' ') $PKG_GZ
SHA256:
 $(sha256sum "$PKG" | cut -d' ' -f1) $(wc -c < "$PKG" | tr -d ' ') $PKG
 $(sha256sum "$PKG_GZ" | cut -d' ' -f1) $(wc -c < "$PKG_GZ" | tr -d ' ') $PKG_GZ
EOF

# Summary
echo ""
echo "=== Build complete ==="
echo ""
echo "Packages in repository:"
grep "^Package:" "$BIN_DIR/Packages"
echo ""
echo "Repository structure in $REPO_DIR:"
find "$REPO_DIR" -type f | sort
echo ""
echo "Copy repo/ to your GitHub Pages root."
