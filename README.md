# Yocto-based BSP for Raspberry Pi 4B
This repository provides a Yocto-based Board Support Package (BSP) for the Raspberry Pi 4B. It includes the necessary configurations and recipes to build a minimal Linux image for the Raspberry Pi 4B using the Yocto Project.

## Cloning the repository

```Bash
# Clone with submodules (Use -j X to parallelize the cloning process)
git clone --recurse-submodules git@github.com:CaglayanDokme/rpi4b-yocto.git
```

## Building the BSP
Building the BSP is quite straightforward. The build process will take a while, especially the first time, as it needs to download and compile all the necessary components. The downloaded sources will be cached, so subsequent builds will be faster. See `DL_DIR` and `SSTATE_DIR` in [`conf/local.conf`](conf/local.conf) for the locations of the downloaded sources and shared state cache.

```Bash
# Initialize the build environment
source poky/oe-init-build-env

# Start the build, the first build will take long (~2 hours)
bitbake core-image-base
```

## WiFi Auto-Connection
The BSP includes a pre-configured WiFi auto-connection feature using NetworkManager and systemd. The system will automatically connect to your configured WiFi network at boot time.

### Configuration Required
Before building the image, you **must** customize the WiFi credentials in the connection profile:

**File:** `layers/meta-wifi/recipes-connectivity/networkmanager/files/wifi.nmconnection`

Edit the following fields:
- `ssid=<Your home/work wifi SSID>` - Replace with your actual WiFi network name
- `psk=<Your home/work wifi password>` - Replace with your actual WiFi password

Example:
```ini
[wifi]
ssid=MyNetworkName

[wifi-security]
key-mgmt=wpa-psk
psk=MySecurePassword123
```

After editing the credentials, rebuild the image to apply the changes:
```bash
source poky/oe-init-build-env
bitbake core-image-base
```

### Features
- Automatic WiFi connection at boot
- NetworkManager-based connection management
- WPA/WPA2-PSK security support
- DHCP IP address assignment
- High connection priority (autoconnect-priority=100)

## OTA Updates

The image supports over-the-air (OTA) updates via [RAUC](https://rauc.readthedocs.io/) with an A/B redundant rootfs scheme. If an update fails to boot, the device automatically remains on the previously working slot.

### SD Card Partition Layout

| # | Label    | Filesystem | Purpose                        |
|---|----------|------------|--------------------------------|
| 1 | BOOT     | FAT32      | Kernel, DTBs, bootloader files |
| 2 | ROOTFS-A | ext4       | Active root filesystem (slot A)|
| 3 | ROOTFS-B | ext4       | Passive slot (populated by OTA)|

> **Note:** The SD card must be re-formatted with the new 3-partition layout before deploying a RAUC-enabled image. Run `bash scripts/format-sd.sh --device <device>` then `bash scripts/deploy-to-sd.sh --device <device>`.

### Signing Keys Setup

RAUC uses a **private key + CA certificate** pair to authenticate update bundles:
- **Private key** — used at build time (`bitbake rauc-bundle`) to sign the bundle. Never committed to git. Stored at `~/.rauc/rauc-dev.key.pem`.
- **CA certificate** — baked into the device image at `/etc/rauc/ca.cert.pem`. Used by the device to verify that a bundle was signed by the matching private key.

A pre-generated dev keypair is already set up for this repository:
- The **cert** is committed at `layers/meta-ota/recipes-core/rauc/files/ca.cert.pem`
- The **private key** is at `~/.rauc/rauc-dev.key.pem` on the machine where the image was first built

**To build bundles on a different machine**, obtain `rauc-dev.key.pem` from the original developer (share it securely — not via git) and place it at `~/.rauc/rauc-dev.key.pem`. No cert changes or device reflash required.

**To use your own independent keypair** (e.g. after forking the project):

```bash
mkdir -p ~/.rauc
openssl req -x509 -newkey rsa:4096 \
    -keyout ~/.rauc/rauc-dev.key.pem \
    -out ~/.rauc/rauc-dev-ca.cert.pem \
    -days 3650 -nodes \
    -subj "/CN=rauc-dev-ca/O=rpi4b-yocto/C=TR"

# Replace the cert in the layer with your new one
cp ~/.rauc/rauc-dev-ca.cert.pem layers/meta-ota/recipes-core/rauc/files/ca.cert.pem
```

Then rebuild the image and reflash the SD card once — after that, only bundles signed with your key will be accepted by the device.

### Building an Update Bundle

> **Note:** Bundles use the `plain` format — the default RPi4B kernel does not include the `dm-verity` module required by the `verity` format.

```bash
source poky/oe-init-build-env
bitbake rauc-bundle
```

The bundle is produced at:
```
build/tmp/deploy/images/raspberrypi4-64/rauc-bundle-raspberrypi4-64.raucb
```

### Applying an Update

> **Note:** The inactive rootfs slot must **not** be mounted when running `rauc install`. If you mounted it for inspection, unmount it first: `umount /mnt/rootfs-b`

```bash
# 1. Copy the bundle to the device over Wi-Fi
scp build/tmp/deploy/images/raspberrypi4-64/rauc-bundle-raspberrypi4-64.raucb \
    root@raspberrypi4-64.local:/root/update-bundle.raucb

# 2. On the device: verify the bundle and check current slot status
rauc info /root/update-bundle.raucb
rauc status

# 3. Install the update (writes to the inactive slot)
rauc install /root/update-bundle.raucb

# 4. Reboot into the new slot
reboot
```

After a successful boot, RAUC's `rauc-mark-good.service` automatically marks the new slot as good.


## SSH Connection
The image includes [Dropbear](https://matt.ucc.asn.au/dropbear/dropbear.html), a lightweight SSH server, and [Avahi](https://avahi.org/) for mDNS hostname resolution. Once the device is connected to the network, you can connect to it over SSH without needing to know its IP address.

```bash
ssh root@raspberrypi4-64.local
```

> **Note:** The image is built with `debug-tweaks` enabled (`EXTRA_IMAGE_FEATURES = "debug-tweaks"`), which sets an empty root password. This is intended for development use only and should not be used in production.

If mDNS is not available on your host, you can connect using the device's IP address instead:

```bash
# Find the IP address (e.g. from your router's DHCP table, or via the serial console)
ip addr show wlan0

# Connect via IP
ssh root@<ip-address>
```

## Deploying the image
Using an helper script, you can deploy the images found in `build/tmp/deploy/images/raspberrypi4-64/` to your SD card. This script can also format the SD card if required.

```Bash
bash scripts/deploy-to-sd.sh --device <device-node> --allow-format
```

## Boot

### Command Line Serial Interface
Use GPIO 14-15 for serial connection. The baud rate will be 115200 bps by default.

### Boot Sequence
The Raspberry Pi's boot process is primarily handled by the **VideoCore GPU**, not the ARM CPU directly, at the very beginning. This is a key differentiator from many other embedded Linux systems.

- **Stage 0: On-Chip ROM Bootloader (GPU)**
    - When you power on the Raspberry Pi, the first code that runs is a small, immutable bootloader stored in the GPU's **Read-Only Memory (ROM)**.
    - This ROM bootloader's primary job is to initialize minimal hardware and then look for the `bootcode.bin` file on the SD card. It specifically looks for this file at fixed offsets (sectors) on the card, which is why having that **1MB spare area** before your first partition (the BOOT partition) is crucial. This spare area ensures `bootcode.bin` and potentially other very early boot data can reside there without interfering with the partition table.
- **Stage 1: `bootcode.bin` (First Stage Bootloader)**
    - The ROM bootloader loads `bootcode.bin` from the SD card into the GPU's L2 cache and executes it.
    - `bootcode.bin` is a very small, proprietary binary firmware. Its main purpose is to initialize the SDRAM (main memory) and then load the next stage of the boot process, which is the main VideoCore GPU firmware.
- **Stage 2: `start*.elf` and `fixup*.dat` (VideoCore GPU Firmware)**
    - `bootcode.bin` loads `start*.elf` (e.g., `start4.elf` for RPi4) and its accompanying data files (`fixup*.dat` - e.g., `fixup4.dat`) from the **FAT32 BOOT partition** of your SD card into memory.
    - This `start*.elf` file is the primary GPU firmware. It's a complex piece of proprietary software that handles most of the low-level hardware initialization:
        - It reads the `config.txt` file from the BOOT partition. This is where your recent fix was crucial. See the [documentation](https://www.raspberrypi.com/documentation/computers/config_txt.html).
        - It then loads the Linux kernel image (`Image`) and the Device Tree Blob (`.dtb`) into the ARM CPU's RAM.
        - It processes the `cmdline.txt` file, passing these arguments as the kernel command line to the Linux kernel.
        - Finally, it "hands over" control to the ARM CPU by jumping to the kernel's entry point.
- **Stage 3: Linux Kernel (ARM CPU)**
- **Stage 4: Userspace initialization from RootFS (ARM CPU)**

---

![Raspberry Pi 4B Pinout](docs/Raspberry-Pi-4-Pinout.webp "Raspberry Pi 4B Pinout")