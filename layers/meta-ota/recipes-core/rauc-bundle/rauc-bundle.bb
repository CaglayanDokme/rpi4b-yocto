# RAUC update bundle for Raspberry Pi 4B
#
# Builds a signed .raucb update bundle containing the root filesystem.
#
# Prerequisites:
#   Set RAUC_KEY_FILE  to the full path of your private key (.key.pem)
#   Set RAUC_CERT_FILE to the full path of your CA certificate (.cert.pem)
#
# Example (in local.conf or on the command line):
#   RAUC_KEY_FILE  = "/path/to/rauc-dev.key.pem"
#   RAUC_CERT_FILE = "/path/to/rauc-dev-ca.cert.pem"
#
# Build with:
#   bitbake rauc-bundle

inherit bundle

SUMMARY = "RAUC OTA update bundle for Raspberry Pi 4B"

RAUC_BUNDLE_FORMAT = "plain"
RAUC_BUNDLE_COMPATIBLE = "raspberrypi4-64"

RAUC_BUNDLE_SLOTS = "rootfs"
RAUC_SLOT_rootfs = "core-image-base"
RAUC_SLOT_rootfs[fstype] = "ext4"
