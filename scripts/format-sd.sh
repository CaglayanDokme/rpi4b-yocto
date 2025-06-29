#!/bin/bash

_get_args() {
    echo "device debug help"
}

# Tab completion handler
if [[ "$1" == "--complete" ]]; then
    _get_args
    exit 0
fi

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}/script-helpers.sh" || { >&2 echo "Couldn't source 'script-helpers.sh'!"; exit 1; }

if isSourced; then
    logError "'$(basename "${BASH_SOURCE[0]}")' must be executed, not sourced!"!

    return 1
fi

### Variables ###
CURRENT_DIR="$(pwd)"

showHelp() {
    echo "Usage: ${0#"${CURRENT_DIR}"/} --device <device_name> [options]"
    echo ""
    echo "Format an SD card with 2 partitions: BOOT (FAT), ROOTFS (EXT4)"
    echo ""
    echo "Options:"
    echo "  --device  <device_name> Path to the SD card device (e.g. /dev/mmcblk0, /dev/sda)"
    echo "  --debug                 Enable debug level messages"
    echo "  --help                  Show this help message and exit"
}

### Parse Command-Line Arguments ###
while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            if [ -z "$2" ]; then
                logError "Missing argument for '--device' option"

                exit 1
            elif [ -n "${DEVICE_NAME}" ]; then
                logError "'--device' option was already set to '${DEVICE_NAME}'"

                exit 1
            fi

            DEVICE_NAME="$2"

            shift
            ;;
        --debug)
            if [ ${PRINT_LEVEL} -eq ${LOG_DEBUG} ]; then
                logWarn "'--debug' option was already enabled"
            fi

            PRINT_LEVEL=${LOG_DEBUG}
            ;;
        --help)
            showHelp

            exit 0
            ;;
        *)
            logError "Unknown option: '$1'";
            showHelp

            exit 1
            ;;
    esac

    shift
done

if [[ -z "${DEVICE_NAME}" ]]; then
    logError "Missing required argument '--device'"

    exit 1
fi

### Initialization ###
checkCommand "parted" || { logError "Couldn't find 'parted' command!"; exit 1; }
checkCommand "e2label" || { logError "Couldn't find 'e2label' command!"; exit 1; }
checkCommand "fatlabel" || { logError "Couldn't find 'fatlabel' command!"; exit 1; }
checkCommand "blockdev" || { logError "Couldn't find 'blockdev' command!"; exit 1; }
checkCommand "findmnt" || { logError "Couldn't find 'findmnt' command!"; exit 1; }
checkCommand "mount" || { logError "Couldn't find 'mount' command!"; exit 1; }
checkCommand "umount" || { logError "Couldn't find 'umount' command!"; exit 1; }
checkCommand "mkfs.vfat" || { logError "Couldn't find 'mkfs.vfat' command!"; exit 1; }
checkCommand "mkfs.ext4" || { logError "Couldn't find 'mkfs.ext4' command!"; exit 1; }
checkCommand "e2label" || { logError "Couldn't find 'e2label' command!"; exit 1; }

logDebug "Checking device '${DEVICE_NAME}'.."
if ! lsblk "${DEVICE_NAME}" &>/dev/null; then
    logError "Device '${DEVICE_NAME}' does not exist or is not a block device."

    exit 1
fi

DEVICE_CAPACITY_B=$(lsblk -b -n -o SIZE "${DEVICE_NAME}" 2>/dev/null | head -n 1)
if [[ -z "${DEVICE_CAPACITY_B}" || "${DEVICE_CAPACITY_B}" -eq 0 ]]; then
    logError "Device '${DEVICE_NAME}' couldn't be detected, it might be ejected. Try (re)inserting."

    # Eject and unmount are different operations
    # See https://askubuntu.com/a/5852/970961

    exit 1
fi

DEVICE_CAPACITY_B=$(sudo blockdev --getsize64 "${DEVICE_NAME}")
if [[ $? -ne 0 || -z "${DEVICE_CAPACITY_B}" ]]; then
    logError "Couldn't determine device capacity!"

    exit 1
fi

if [[ ! "${DEVICE_CAPACITY_B}" =~ ^[0-9]+$ ]]; then
    logError "Detected device capacity '${DEVICE_CAPACITY_B}' is not numerical!"

    exit 1
fi

DEVICE_CAPACITY_GB=$(( STORAGE_SIZE_B / 1073741824))
logInfo "Detected device capacity: ${DEVICE_CAPACITY_GB} GB"
if [[ ${DEVICE_CAPACITY_GB} -ge 64 ]]; then
    logError "Device capacity (${DEVICE_CAPACITY_GB} GB) is greater than 64 GB. Are you sure it's an SD card!?"

    exit 1
fi

PARTITION_PREFIX=""
if [[ "${DEVICE_NAME}" == *"mmc"* ]]; then
    PARTITION_PREFIX="p"

    logInfo "SD card recognized as an MMC device, using '${PARTITION_PREFIX}' as partition prefix."
fi

logInfo "Unmounting device '${DEVICE_NAME}'.."
umountDevice "${DEVICE_NAME}"
if [ $? -ne 0 ]; then
    logError "Couldn't unmount all partitions!"

    exit 1
fi

# Overwite existing partiton table with zeros
sudo dd if=/dev/zero of="${DEVICE_NAME}" bs=1M count=1 > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't overwrite partition table with zeros!"

    exit 1
fi

logInfo "Partitioning the SD card.."
sudo parted -s "${DEVICE_NAME}" mklabel msdos > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't create partition table! 'mklabel' failed"

    exit 1
fi

sudo parted --script --align opt "${DEVICE_NAME}" mkpart primary fat32 1MB 128MB > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't create partition table! 'mkpart' failed for BOOT partition"

    exit 1
fi

sudo parted --script --align opt "${DEVICE_NAME}" mkpart primary ext4 128M 100% > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't create partition table! 'mkpart' failed for ROOTFS partition"

    exit 1
fi

sudo parted --script --align opt "${DEVICE_NAME}" set 1 boot on > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't create partition table! Boot flag couldn't be set for BOOT partition"

    exit 1
fi

logInfo "Syncing the partitions.."
sync

logInfo "Unmounting existing devices to make filesystems.."
umountDevice "${DEVICE_NAME}"
if [ $? -ne 0 ]; then
    logError "Couldn't unmount all partitions!"

    exit 1
fi

logInfo "Formatting the partitions with proper filesystems.."
yes | sudo mkfs.vfat -F 32 "${DEVICE_NAME}${PARTITION_PREFIX}1" > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't format BOOT partition!"

    exit 1
fi

yes | sudo mkfs.ext4 "${DEVICE_NAME}${PARTITION_PREFIX}2" > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't format ROOTFS partition!"

    exit 1
fi

logInfo "Renaming the partitions.."
sudo fatlabel "${DEVICE_NAME}${PARTITION_PREFIX}1" "BOOT" > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't rename '${DEVICE_NAME}${PARTITION_PREFIX}1' as 'BOOT'!"

    exit 1
fi

sudo e2label "${DEVICE_NAME}${PARTITION_PREFIX}2" "ROOTFS" > /dev/null
if [ $? -ne 0 ]; then
    logError "Couldn't rename '${DEVICE_NAME}${PARTITION_PREFIX}2' as 'ROOTFS'!"

    exit 1
fi

logInfo "SD card ready for deployment!" && exit 0
