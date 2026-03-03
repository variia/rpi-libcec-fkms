#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== rpi-libcec-fkms installer ==="

# Check we're on a Pi
if [ "$(uname -m)" != "aarch64" ]; then
    echo "Error: This script must be run on an aarch64 Raspberry Pi."
    exit 1
fi

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Run with sudo."
    exit 1
fi

# Check required files exist
LIBCEC_DEB=$(ls "$SCRIPT_DIR"/libcec6_*.deb 2>/dev/null | head -1)
CECUTILS_DEB=$(ls "$SCRIPT_DIR"/cec-utils_*.deb 2>/dev/null | head -1)
COMPAT_DEB=$(ls "$SCRIPT_DIR"/libraspberrypi0-compat_*.deb 2>/dev/null | head -1)

if [ -z "$LIBCEC_DEB" ] || [ -z "$CECUTILS_DEB" ] || [ -z "$COMPAT_DEB" ]; then
    echo "Error: Missing build artifacts. Expected in $SCRIPT_DIR:"
    echo "  libraspberrypi0-compat_*.deb"
    echo "  libcec6_*.deb"
    echo "  cec-utils_*.deb"
    echo ""
    echo "Run the Docker build first. See README.md for instructions."
    exit 1
fi

# Install all three packages together
echo "--- Installing packages ---"
dpkg -i "$COMPAT_DEB" "$LIBCEC_DEB" "$CECUTILS_DEB"

# Fix any missing dependencies (e.g. libncurses6)
echo "--- Resolving dependencies ---"
apt-get install -f -y

# Hold packages to prevent apt from overwriting
echo "--- Holding packages ---"
apt-mark hold libcec6 cec-utils libraspberrypi0-compat

# Verify
echo ""
echo "=== Installation complete ==="
echo ""
echo "Verifying CEC adapter detection:"
if cec-client -l 2>/dev/null | grep -qi "rpi\|raspberry"; then
    echo "OK: Raspberry Pi CEC adapter detected."
else
    echo "WARNING: CEC adapter not detected. Make sure you are using vc4-fkms-v3d in config.txt."
    echo "Run 'cec-client -l' manually to check."
fi

echo ""
echo "Package status:"
dpkg -l | grep -E "^(hi|ii).*(libcec6|libraspberrypi0-compat|cec-utils)"
echo ""
echo "Held packages:"
apt-mark showhold | grep -E "libcec|cec-utils|libraspberrypi0-compat"
