# Copilot Instructions

## Project Overview

Yocto-based Board Support Package (BSP) for the **Raspberry Pi 4B (64-bit)**. Builds a minimal Linux image using the Yocto Project's Scarthgap (5.0.x) release. The primary build target is `core-image-base` for `MACHINE = raspberrypi4-64`. Supports **RAUC A/B OTA updates** over Wi-Fi.

## Build Commands

```bash
# Initialize the build environment (must be done in every new shell)
source poky/oe-init-build-env build

# Build the image (~2 hours first time; subsequent builds use sstate cache)
bitbake core-image-base

# Build a RAUC OTA update bundle (requires RAUC_KEY_FILE + RAUC_CERT_FILE to be set)
bitbake rauc-bundle

# Build a single recipe
bitbake <recipe-name>

# Clean a single recipe
bitbake -c cleansstate <recipe-name>

# Show what would be built / check recipe variables
bitbake -e <recipe-name> | grep ^VARIABLE_NAME
```

Build output lands in `build/tmp/deploy/images/raspberrypi4-64/`.  
Downloads cache: `~/.yocto_downloads/scarthgap/downloads/`  
Shared state cache: `~/.yocto_downloads/scarthgap/sstate/`

## SD Card Deployment

```bash
# Format the SD card (creates BOOT FAT32 + ROOTFS-A + ROOTFS-B EXT4 partitions)
bash scripts/format-sd.sh --device /dev/sdX

# Deploy all components (auto-formats if needed)
bash scripts/deploy-to-sd.sh --device /dev/sdX --allow-format

# Deploy only rootfs or only boot
bash scripts/deploy-to-sd.sh --device /dev/sdX --rootfs
bash scripts/deploy-to-sd.sh --device /dev/sdX --boot
```

SD card layout: `1MB` spare → **BOOT** (FAT32, 1MB–128MB) → **ROOTFS-A** (ext4, 128MB–50%) → **ROOTFS-B** (ext4, 50%–100%).  
The deploy script renames the kernel image to `kernel8.img`, generates `config.txt` and `cmdline.txt` on the BOOT partition, and writes `rauc_slot=A` for initial RAUC slot selection.

## Architecture

### Layer Stack

| Layer | Source | Purpose |
|---|---|---|
| `poky/meta`, `meta-poky`, `meta-yocto-bsp` | `poky/` submodule | Yocto core |
| `layers/meta-raspberrypi` | submodule | RPi machine config, GPU firmware |
| `layers/meta-openembedded/meta-oe` | submodule | Extended package set |
| `layers/meta-openembedded/meta-python` | submodule | Python packages |
| `layers/meta-openembedded/meta-networking` | submodule | Networking packages (NM, wpa-supplicant) |
| `layers/meta-rauc` | submodule (scarthgap) | RAUC OTA update framework |
| `layers/meta-wifi` | in-tree custom layer | Wi-Fi auto-connection, kernel module and firmware fixes |
| `layers/meta-ota` | in-tree custom layer | RAUC system config, A/B boot hooks, bundle recipe |

Custom layer priorities: `meta-wifi = 8`, `meta-ota = 9`.

### Key Configuration

All image customization lives in `build/conf/local.conf`:
- **Init system**: systemd (with SysV compat units)
- **Package format**: deb
- **Parallelism**: `BB_NUMBER_THREADS=10`, `PARALLEL_MAKE=-j 10`
- `IMAGE_INSTALL:append` is where packages are added to the image

### meta-wifi Layer

The custom layer solves two upstream issues and adds Wi-Fi auto-connection:

- **`linux-firmware-rpidistro_%.bbappend`** — fixes a broken symlink: creates the missing `cyfmac43455-sdio.bin` target that upstream package symlinks reference but doesn't ship.
- **`init-ifupdown_%.bbappend`** — removes `wlan0` from `/etc/network/interfaces` so NetworkManager can manage it (without this, NM detects the interface but won't take ownership).
- **`networkmanager-wifi-config_1.0.bb`** — installs a pre-configured NM connection profile (`wifi.nmconnection`) at `/etc/NetworkManager/system-connections/`.

### meta-ota Layer

The custom layer provides RAUC OTA update support:

- **`rauc_%.bbappend`** — installs `system.conf` (slot layout), `ca.cert.pem` (keyring), custom boot select script, and `rauc-mark-good.service`.
- **`rauc-bundle.bb`** — builds a `.raucb` update bundle from `core-image-base`. Requires `RAUC_KEY_FILE` and `RAUC_CERT_FILE` to be set at build time.
- **Boot integration**: Uses RAUC's `custom` bootloader backend. Hook scripts at `/usr/lib/rauc/boot-select.sh` mount the BOOT FAT32 partition and rewrite `cmdline.txt` (updating `root=`) plus a `rauc_slot` marker file to switch between slot A (`/dev/mmcblk0p2`) and slot B (`/dev/mmcblk0p3`).
- **`rauc-mark-good.service`** — marks the currently booted slot as good after a successful boot.

## Key Conventions

### Wi-Fi Credentials

Before building, update credentials in:
```
layers/meta-wifi/recipes-connectivity/networkmanager/files/wifi.nmconnection
```
The `ssid=` and `psk=` fields must be set to real values. The file is installed with `0600` permissions.

### bblayers.conf Path References

Layer paths in `bblayers.conf` use the `${BSPDIR}` variable (resolved relative to the conf file location) — **not** absolute paths.

### Hostname

The device hostname is derived from `MACHINE` via Yocto's `base-files` recipe:
```
hostname = "${MACHINE}"  →  raspberrypi4-64
```
Override without changing `MACHINE` by adding to `local.conf`:
```bitbake
hostname:pn-base-files = "my-custom-name"
```
With `avahi-daemon` installed, the device is reachable as `raspberrypi4-64.local` on the LAN.

### SSH Access

The image runs **Dropbear** SSH. Root login with an empty password is enabled via `EXTRA_IMAGE_FEATURES = "debug-tweaks"`.
```bash
ssh root@raspberrypi4-64.local
```

### Scripts Conventions

All shell scripts in `scripts/` source `script-helpers.sh` for shared logging (`logInfo`, `logWarn`, `logError`, `logDebug`) and utilities. Scripts must be **executed**, not sourced. They support `--complete` for tab completion registration.

### Adding Packages to the Image

Append to `IMAGE_INSTALL` in `build/conf/local.conf`:
```bitbake
IMAGE_INSTALL:append = " <package-name>"
```
For new features requiring `DISTRO_FEATURES` support (e.g., `zeroconf` for avahi, `wifi` for wireless), also append to:
```bitbake
DISTRO_FEATURES:append = " <feature>"
```

### Serial Console

GPIO 14 (TX) / GPIO 15 (RX), 115200 bps. Enabled via `enable_uart=1` and `uart_2ndstage=1` in `config.txt` (written by the deploy script).
