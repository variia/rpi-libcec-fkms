# rpi-libcec-fkms

APT repository hosting a patched `libcec` for Raspberry Pi OS Bookworm (arm64) with the firmware CEC adapter enabled, restoring HDMI-CEC support when using the FKMS display driver.

## The Problem

Raspberry Pi OS moved from the **FKMS** (`vc4-fkms-v3d`) display driver to **KMS** (`vc4-kms-v3d`). For media center use (Kodi), KMS introduces real problems:

- **Higher CPU load** — the kernel mediates all display operations, causing D-state waits that inflate load averages even at idle
- **Washed-out colors** — quantization range mismatches between the KMS driver and TVs
- **Less mature** — KMS was built to standardize Linux display drivers, not to improve video playback on embedded devices

Switching back to FKMS solves all of this, but **breaks CEC** (the ability to control Kodi with your TV remote over HDMI).

## Why CEC Breaks on FKMS

CEC commands travel over HDMI pin 13. The Pi's hardware can send and receive them, but the software path differs between drivers:

```
KMS path (works):
  TV Remote -> TV -> HDMI CEC pin -> kernel vc4_hdmi driver -> /dev/cec0 -> libcec -> Kodi

FKMS path (broken):
  TV Remote -> TV -> HDMI CEC pin -> VideoCore firmware has CEC, but...
  libcec only looks for /dev/cec0 (kernel CEC framework)
  FKMS doesn't create /dev/cec0 -> no CEC
```

The old firmware CEC path via VCHI (VideoCore Host Interface) still works under FKMS. The VideoCore firmware manages HDMI when FKMS is active, and it can handle CEC directly. But RPi OS builds `libcec` with only `HAVE_LINUX_API=1` (kernel CEC framework). The old `HAVE_RPI_API` flag that enables the firmware VCHI CEC adapter is not compiled in.

```
FKMS path (fixed):
  TV Remote -> TV -> HDMI CEC pin -> VideoCore firmware -> VCHI -> libcec (RPi adapter) -> Kodi
```

## The Solution

This repository provides pre-built packages for RPi OS Bookworm (arm64):

| Package | Description |
|---|---|
| `libcec6` | Rebuilt with `-DHAVE_RPI_API=1` to enable the firmware VCHI CEC adapter |
| `cec-utils` | `cec-client` tool for testing CEC |
| `libraspberrypi0-compat` | VCHI runtime libraries repackaged to coexist with `libdtovl0` |
| `libcec-dev` | Development headers (optional) |
| `python3-cec` | Python 3 bindings (optional) |

The `libraspberrypi0-compat` package contains the same VCHI runtime libraries as `libraspberrypi0` but without the `Breaks: libdtovl0` conflict that prevents the original from being installed on Bookworm. It is pulled in automatically as a dependency of `libcec6`.

## Install via APT

Add this repository to your Raspberry Pi:

```bash
# Add the repo
echo "deb [trusted=yes] https://ivanvari.com/rpi-libcec-fkms/repo bookworm main" \
    | sudo tee /etc/apt/sources.list.d/rpi-libcec-fkms.list

# Pin our packages above the stock RPi/Debian versions
cat << 'EOF' | sudo tee /etc/apt/preferences.d/rpi-libcec-fkms
Package: libcec6 cec-utils libraspberrypi0-compat
Pin: origin ivanvari.com
Pin-Priority: 900
EOF

sudo apt-get update
```

If you already have the stock `libcec6` installed, remove it first — our packages share the same version number:

```bash
sudo apt-get remove libcec6 cec-utils
```

Install:

```bash
sudo apt-get install libcec6 cec-utils
```

This automatically pulls in `libraspberrypi0-compat`. Hold the packages to prevent apt from overwriting them with the stock versions:

```bash
sudo apt-mark hold libcec6 cec-utils libraspberrypi0-compat
```

Verify:

```bash
cec-client -l
```

> **Note**: `[trusted=yes]` is used because the packages are not GPG-signed. This is a personal repository. Review the [build documentation](docs/manual-build.md) if you prefer to build from source.
>
> If `apt-get update` warns about skipping `armhf` packages, the repo only ships `arm64` — add `arch=arm64` to the source line to suppress it: `deb [trusted=yes arch=arm64] https://...`

## Install Manually

Download the packages from the [`repo/pool/main/`](repo/pool/main/) directory and install directly:

```bash
sudo dpkg -i libraspberrypi0-compat_*.deb libcec6_*.deb cec-utils_*.deb
sudo apt-get install -f -y
sudo apt-mark hold libcec6 cec-utils libraspberrypi0-compat
```

## FKMS Configuration

In `/boot/firmware/config.txt`, use `vc4-fkms-v3d` instead of `vc4-kms-v3d`:

```ini
dtoverlay=vc4-fkms-v3d
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=16
gpu_mem=320
```

`hdmi_group=1` + `hdmi_mode=16` = 1080p@60Hz (CEA). Adjust to your display. Unlike KMS, FKMS respects these firmware-level HDMI settings.

## Why Bookworm, Not Trixie

We tried Trixie first and hit multiple blockers that made the build impractical:

- **No firmware headers**: `libraspberrypi-dev` has been **removed** from the Trixie RPi archive entirely. The VCHI headers (`bcm_host.h`, `vc_cecservice.h`, etc.) needed to compile the RPi CEC adapter don't exist as a package.
- **Cross-release headers don't work**: Pulling `libraspberrypi-dev` from the Bookworm archive into Trixie gets the headers installed, but cmake's `check_library_exists(bcm_host bcm_host_init ...)` link test fails. `libbcm_host.so` depends on `libvcos` and `libvchiq_arm`, and the Trixie linker doesn't resolve these transitive dependencies during the cmake test. A manual `gcc -lbcm_host` link test that succeeds on Bookworm fails on Trixie for the same reason.
- **GPG breakage**: Trixie's signature verifier (`sqv`) rejects SHA1 signatures as of February 2026. The RPi archive key uses SHA1 binding signatures, so `apt-get update` fails unless you bypass verification with `[trusted=yes]`.
- **Worse package conflicts**: The `libdtovl0` vs `libraspberrypi0` conflict is harder to work around on Trixie.

On Bookworm, `libraspberrypi-dev` is a first-class package, the link test passes cleanly, and `dpkg-buildpackage` completes without issues.

## What's in the Packages

### libcec6

Rebuilt from the RPi OS source package with the following changes to `debian/rules`:

1. `-DHAVE_RPI_API=1` — enables the firmware VCHI CEC adapter
2. `-DRPI_INCLUDE_DIR=/usr/include` and `-DRPI_LIB_DIR=/usr/lib/aarch64-linux-gnu` — cmake paths for VCHI headers and libraries

The `libraspberrypi0-compat` package is installed in the build container before building libcec. This way, `dh_shlibdeps` automatically detects the VCHI libraries and generates the correct `Depends: libraspberrypi0-compat` — no manual dependency overrides needed.

### libraspberrypi0-compat

Repackage of `libraspberrypi0` from the Bookworm RPi archive containing:

| Library | Purpose |
|---|---|
| `libbcm_host.so.0` | Broadcom VideoCore host interface |
| `libvcos.so.0` | VideoCore OS abstraction layer |
| `libvchiq_arm.so.0` | VCHI message passing to VideoCore firmware |
| `libdebug_sym.so.0` | Debug symbol support |

Key differences from the original `libraspberrypi0`:
- **Excludes `libdtovl.so.0`** — this library is already provided by `libdtovl0` on Bookworm; including it would cause a file collision
- Does **not** declare `Provides: libraspberrypi0` — doing so triggers `libdtovl0`'s `Breaks: libraspberrypi0` conflict, making it uninstallable
- Drops the `raspberrypi-bootloader` dependency (not needed for VCHI libs)
- Does **not** conflict with or replace `libraspberrypi0` — the two packages can coexist since they ship different files

## Compatibility

- **Tested on**: Raspberry Pi 4B (2GB), RPi OS Bookworm Lite (arm64)
- **libcec version**: 6.0.2-5+rpt2
- **Display driver**: `vc4-fkms-v3d`
- **Kodi**: 20.5 from RPi archive
- **Build host**: macOS (Apple Silicon) with Docker Desktop — ARM64 containers run natively, no emulation

## Known Limitations

### Load average is higher than Buster

Even with FKMS, Bookworm's Kodi 20 reports a load average of ~1.0 while streaming, compared to ~0.3-0.5 on Buster with Kodi 18. This is **not real CPU pressure** — actual CPU utilisation is 94-98% idle. The inflated load comes from D-state (uninterruptible sleep) waits in Mesa's V3D OpenGLES driver, which Kodi 20 uses for GUI rendering.

On Buster, Kodi 18 used the proprietary Broadcom GLES driver and MMAL for video. These waits happened inside the VideoCore firmware, invisible to the Linux scheduler. On Bookworm, the open source Mesa stack makes these GPU waits visible as D-state processes, which Linux counts toward load average.

| Setup | Load (streaming) | Actual CPU idle | Why |
|---|---|---|---|
| Buster + FKMS + Kodi 18 | 0.3 - 0.5 | ~97% | MMAL/proprietary GL — waits hidden in firmware |
| Bookworm + FKMS + Kodi 20 | ~1.0 | ~95% | Mesa V3D GL — waits visible as D-state |
| Trixie + KMS + Kodi 20 | ~1.8 | ~90% | Full KMS + Mesa — display pipeline and GL both in kernel |

Playback and system responsiveness are not affected. The load number is cosmetic.

### Minor GUI rendering glitch

Kodi 20's navigation bar may occasionally show tearing or partial redraw artefacts when browsing media. This is likely related to the Mesa V3D rendering path and was not present on Buster's proprietary GL driver. Playback is unaffected.

## Building from Source

If you prefer to build the packages yourself rather than using the pre-built ones from this repository, see:

- [Manual Build Guide](docs/manual-build.md) — tested step-by-step instructions
- [Build Reference](docs/build-reference/) — Dockerfile, build script, and patches (untested, provided as reference only)

## Links

- [libcec upstream](https://github.com/Pulse-Eight/libcec)
- [RPi kernel vc4_hdmi CEC code](https://github.com/raspberrypi/linux/blob/rpi-6.6.y/drivers/gpu/drm/vc4/vc4_hdmi.c) — where `/dev/cec0` is created under KMS
- [RPi firmware VCHI CEC service](https://github.com/raspberrypi/userland/blob/master/interface/vmcs_host/vc_vchi_cecservice.c) — the firmware CEC path used by this build
- [RPi config.txt documentation](https://www.raspberrypi.com/documentation/computers/config_txt.html)

## License

The build scripts and documentation in this repository are provided under the MIT License. The `libcec` source code and `libraspberrypi0` libraries are subject to their respective upstream licenses.
