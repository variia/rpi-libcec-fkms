# Manual Build Guide

Step-by-step instructions to reproduce the libcec build with RPi CEC support. This is the manual equivalent of what the Dockerfile and build.sh automate.

## Prerequisites

- Docker Desktop (macOS Apple Silicon runs ARM64 natively — no emulation needed)
- Or any Linux ARM64 machine / VM

## 1. Start the Build Environment

```bash
docker run --platform linux/arm64 -it -v $(pwd)/output:/output debian:bookworm bash
```

## 2. Add Package Sources

```bash
# Debian source repos (for apt source / build-dep)
echo "deb-src https://deb.debian.org/debian bookworm main" \
    > /etc/apt/sources.list.d/debian-src.list

# Install essentials
apt-get update
apt-get install -y curl gpg

# Import RPi archive GPG key into a dedicated keyring
curl -fsSL https://archive.raspberrypi.com/debian/raspberrypi.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/raspberrypi-archive-keyring.gpg

# Add RPi repos (binary + source) with signed-by
echo "deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] https://archive.raspberrypi.com/debian/ bookworm main" \
    > /etc/apt/sources.list.d/raspi.list
echo "deb-src [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] https://archive.raspberrypi.com/debian/ bookworm main" \
    >> /etc/apt/sources.list.d/raspi.list

apt-get update
```

> **Note**: If apt complains about an additional key, try: `apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 82B129927FA3303E`
>
> Optionally run `apt-get upgrade` after update — advised in a fresh container.

## 3. Install Build Dependencies

```bash
# libcec build deps (cmake, build-essential, libp8-platform-dev, etc.)
apt-get build-dep -y libcec

# RPi firmware headers (provides bcm_host.h, vc_cecservice.h, etc.)
# dpkg-dev provides dpkg-scanpackages for generating the apt repo index
apt-get install -y libraspberrypi-dev dpkg-dev
```

Verify the key components are in place:

```bash
# Headers
ls /usr/include/interface/vmcs_host/vc_cecservice.h

# Libraries
ls /usr/lib/aarch64-linux-gnu/libbcm_host.so

# Link test — this must succeed or the build will fail
echo 'extern void bcm_host_init(void); int main() { bcm_host_init(); return 0; }' > /tmp/test.c
gcc /tmp/test.c -L/usr/lib/aarch64-linux-gnu -lbcm_host -o /tmp/test
echo $?   # Should print 0
```

## 4. Build libraspberrypi0-compat

Before building libcec, create and install the `libraspberrypi0-compat` package. This repackages the VCHI runtime libraries from `libraspberrypi0` without the `Breaks: libdtovl0` conflict, and without `libdtovl.so.0` (already provided by `libdtovl0`).

```bash
cd /tmp
apt-get download libraspberrypi0
mkdir -p compat-deb
dpkg-deb -R libraspberrypi0*.deb compat-deb/
```

Replace the control file:

```bash
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
```

Fix up the shlibs and remove the conflicting library:

```bash
# Update shlibs to reference the new package name, remove libdtovl entry
sed -i 's/libraspberrypi0/libraspberrypi0-compat/g' compat-deb/DEBIAN/shlibs
sed -i '/libdtovl/d' compat-deb/DEBIAN/shlibs

# Rename doc directory
mv compat-deb/usr/share/doc/libraspberrypi0 compat-deb/usr/share/doc/libraspberrypi0-compat

# Remove libdtovl.so.0 — already provided by libdtovl0
rm compat-deb/usr/lib/aarch64-linux-gnu/libdtovl.so.0
```

Build and install the compat package:

```bash
dpkg-deb --build --root-owner-group compat-deb/ libraspberrypi0-compat_2+git20231018_arm64.deb
dpkg -i libraspberrypi0-compat_2+git20231018_arm64.deb
```

Installing the compat package in the build container updates the shlibs database. When libcec is built next, `dh_shlibdeps` will automatically detect the VCHI libraries and generate `Depends: libraspberrypi0-compat` — no manual dependency overrides needed.

## 5. Pull libcec Source

```bash
cd /tmp
apt source libcec
cd libcec-*/
```

This downloads the RPi OS version of libcec (6.0.2-5+rpt2 at time of writing) with their patches already applied.

## 6. Patch debian/rules

Edit `debian/rules` with your preferred editor. The `override_dh_auto_configure` section needs three additions.

**Before** (stock):

```makefile
override_dh_auto_configure:
	dh_auto_configure -- -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=1 -DCMAKE_INSTALL_LIBDIR=/usr/lib/$(DEB_HOST_MULTIARCH) \
		-DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
		-DHAVE_EXYNOS_API=1 \
		-DHAVE_AOCEC_API=1 \
		-DHAVE_LINUX_API=1

execute_after_dh_auto_install:
```

**After** (patched):

```makefile
override_dh_auto_configure:
	dh_auto_configure -- -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=1 -DCMAKE_INSTALL_LIBDIR=/usr/lib/$(DEB_HOST_MULTIARCH) \
		-DCMAKE_BUILD_RPATH_USE_ORIGIN=ON \
		-DHAVE_EXYNOS_API=1 \
		-DHAVE_AOCEC_API=1 \
		-DHAVE_LINUX_API=1 \
		-DHAVE_RPI_API=1 \
		-DRPI_INCLUDE_DIR=/usr/include \
		-DRPI_LIB_DIR=/usr/lib/aarch64-linux-gnu

execute_after_dh_auto_install:
```

**What each change does:**

| Flag | Purpose |
|---|---|
| `-DHAVE_RPI_API=1` | Enables the firmware VCHI CEC adapter in libcec |
| `-DRPI_INCLUDE_DIR=/usr/include` | Tells cmake where to find `vc_cecservice.h` and friends |
| `-DRPI_LIB_DIR=/usr/lib/aarch64-linux-gnu` | Tells cmake where to find `libbcm_host.so` and friends |

No `override_dh_shlibdeps` is needed because `libraspberrypi0-compat` was installed in step 4. The shlibs database maps the VCHI libraries to the compat package, so `dh_shlibdeps` generates the correct dependency automatically.

> **Important**: `debian/rules` is a Makefile — indentation must use **tabs**, not spaces.

## 7. Build

```bash
dpkg-buildpackage -us -uc -b
```

- `-us` — don't sign the source package
- `-uc` — don't sign the changes file
- `-b` — binary-only build (skip source package rebuild)

The build produces `.deb` files in the parent directory (`/tmp/`).

**If the build fails**, clean and retry:

```bash
dpkg-buildpackage -T clean
rm -f include/platform
rm -rf obj-aarch64-linux-gnu
dpkg-buildpackage -us -uc -b
```

## 8. Collect Artifacts and Generate Repo

```bash
# Set up repo structure
mkdir -p /output/repo/pool/main
mkdir -p /output/repo/dists/bookworm/main/binary-arm64

cp /tmp/libcec6_*.deb /output/repo/pool/main/
cp /tmp/cec-utils_*.deb /output/repo/pool/main/
cp /tmp/libcec-dev_*.deb /output/repo/pool/main/
cp /tmp/python3-cec_*.deb /output/repo/pool/main/
cp /tmp/libraspberrypi0-compat_*.deb /output/repo/pool/main/

# Generate Packages index
cd /output/repo
dpkg-scanpackages --multiversion pool/main /dev/null \
    > dists/bookworm/main/binary-arm64/Packages
gzip -9fk dists/bookworm/main/binary-arm64/Packages

# Generate Release file
cd /output/repo/dists/bookworm
PKG="main/binary-arm64/Packages"
PKG_GZ="main/binary-arm64/Packages.gz"
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
```

If you want to host your own apt repository, the resulting `repo/` directory can be served as-is via GitHub Pages or any static web server. For manual installation, skip this and go straight to step 9 — the `.deb` files are in `repo/pool/main/`.

> **GitHub Pages with custom domains**: If you have a custom domain configured for GitHub Pages (e.g. via Cloudflare), `*.github.io` URLs will redirect to your domain. apt refuses HTTPS-to-HTTP redirects, so use your custom domain directly in the apt source line. See the [Install via APT](../README.md#install-via-apt) section in the README for the full setup.

## 9. Install on the Raspberry Pi

Copy the `.deb` files to the Pi (via scp, USB, etc.), then:

```bash
# Install all three packages together
sudo dpkg -i libraspberrypi0-compat_*.deb libcec6_*.deb cec-utils_*.deb

# Pull in any missing dependencies (e.g. libncurses6)
sudo apt-get install -f -y

# Hold packages so apt doesn't overwrite with the stock version
sudo apt-mark hold libcec6 cec-utils libraspberrypi0-compat
```

## 10. Configure FKMS (if not already done)

Edit `/boot/firmware/config.txt`:

```ini
dtoverlay=vc4-fkms-v3d
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=16
gpu_mem=320
```

Remove or comment out any `dtoverlay=vc4-kms-v3d` lines.

Reboot.

## 11. Verify

```bash
# Check CEC adapter is detected
cec-client -l

# Check package state is clean
dpkg --audit

# Check held packages
apt-mark showhold

# Test that apt works normally
sudo apt-get install -s some-package
```

The `cec-client -l` output should show a Raspberry Pi CEC adapter. If it only shows "Linux CEC Framework" adapters, the FKMS driver is not active or the VCHI libs are not in the library path.

## Troubleshooting

**Build fails with "Raspberry Pi library not found"**

cmake's `check_library_exists` cannot link against `libbcm_host`. Verify:

```bash
ls -la /usr/lib/aarch64-linux-gnu/libbcm_host.so
gcc -L/usr/lib/aarch64-linux-gnu -lbcm_host -o /dev/null -xc - <<< 'extern void bcm_host_init(void); int main() { bcm_host_init(); }'
```

If the symlink is missing, create it: `ln -s libbcm_host.so.0 /usr/lib/aarch64-linux-gnu/libbcm_host.so`

**apt complains about dependency errors after install**

Make sure you install `libraspberrypi0-compat` together with (or before) `libcec6`. The `dpkg -i` command in step 9 installs all three at once, which is the cleanest approach. Then `sudo apt-get install -f` to resolve any remaining dependencies.

**CEC adapter not detected**

- Confirm FKMS is active: `dmesg | grep -i fkms` should show the firmware KMS driver loading
- Confirm VCHI libs are loadable: `ldd /usr/lib/aarch64-linux-gnu/libcec.so.6 | grep -E "bcm_host|vcos|vchiq"` — all three should resolve
- Check if `/dev/vchiq` exists — this is the firmware communication channel used by the RPi CEC adapter
