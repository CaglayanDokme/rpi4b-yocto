#!/bin/bash

_get_args() {
    echo "device boot rootfs allow-format force-format debug help"
}

# Tab completion handler
if [[ "$1" == "--complete" ]]; then
    _get_args
    exit 0
fi


SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
SCRIPT_NAME="${BASH_SOURCE[0]##*/}"
CURRENT_DIR="$(pwd)"
source "${SCRIPT_DIR}/script-helpers.sh" || { >&2 echo "Couldn't source 'script-helpers.sh'!"; exit 1; }

if isSourced; then
    logError "${SCRIPT_NAME} must be executed, not sourced!"!

    return 1
fi

### Variables ###
TOPDIR="$(realpath ${SCRIPT_DIR}/..)"
CURRENT_DIR="$(pwd)"
IMAGES_DIR="${TOPDIR}/build/tmp/deploy/images/raspberrypi4-64/"
DATE="$(date '+%Y%m%d-%H%M%S')"
DEVICE_MOUNT_POINT="/tmp/${DATE}-SD"
COMPLETED_DEPLOYMENTS=0
DEPLOY_FLAG_NAMES=("DEPLOY_BOOT" "DEPLOY_ROOTFS")

# Helper Scripts
SD_FORMAT_SCRIPT="${SCRIPT_DIR}/format-sd.sh"

# Mount-points
BOOT_MOUNT_POINT="${DEVICE_MOUNT_POINT}/BOOT/"
ROOTFS_MOUNT_POINT="${DEVICE_MOUNT_POINT}/ROOTFS/"

### Functions ###
showHelp() {
    echo "Usage: ${0#"${CURRENT_DIR}"/} --device <device> [OPTIONS]"
    echo ""
    echo "Deploy different parts of an embedded system image to the specified device."
    echo ""
    echo "Options:"
    echo "  --device <device>  Device name (e.g. /dev/sda, /dev/mmcblk0)"
    echo "  --boot             Deploy boot images"
    echo "  --rootfs           Deploy the root filesystem"
    echo "  --allow-format     If required, allow formatting the device prior to deployment"
    echo "                     See ${SD_FORMAT_SCRIPT#${CURRENT_DIR}/} for more information"
    echo "  --force-format     Always format the device prior to deployment"
    echo "                     See ${SD_FORMAT_SCRIPT#${CURRENT_DIR}/} for more information"
    echo "  --debug            Enable debug level messages"
    echo "  --help             Show this help message and exit"
    echo ""
    echo "If no options are specified, all components will be deployed."
}

create_directory() {
    local dir="$1"

    if [[ -z "${dir}" ]]; then
        logError "Directory path is empty!"

        exit 1
    fi

    mkdir --parents "${dir}" > /dev/null || {
        logWarn "Couldn't create directory '${dir}', trying with sudo.."

        sudo mkdir --parents "${dir}" > /dev/null
        if [ $? -ne 0 ]; then
            logError "Couldn't create directory '${dir}' even with sudo!"
            exit 1
        fi
    }
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
        --boot)
            if [[ ${DEPLOY_BOOT} == true ]]; then
                logWarn "'--boot' option was already enabled"
            fi

            DEPLOY_BOOT=true
            ;;
        --rootfs)
            if [[ ${DEPLOY_ROOTFS} == true ]]; then
                logWarn "'--rootfs' option was already enabled"
            fi

            DEPLOY_ROOTFS=true
            ;;
        --allow-format)
            if [[ ${ALLOW_FORMAT} = true ]]; then
                logWarn "'--allow-format' option was already enabled"
            elif [[ ${FORCE_FORMAT} = true ]]; then
                logWarn "'--allow-format' option was already enabled by '--force-format'"
            fi

            ALLOW_FORMAT=true
            ;;
        --force-format)
            if [[ ${FORCE_FORMAT} = true ]]; then
                logWarn "'--force-format' option was already enabled"
            elif [[ ${ALLOW_FORMAT} = true ]]; then
                logWarn "No need to use '--allow-format' if '--force-format' is used"
            fi

            FORCE_FORMAT=true
            ALLOW_FORMAT=true
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
            logError "Unknown option: $1"
            logInfo "Run '${SCRIPT_NAME} --help' for usage information."

            exit 1
            ;;
    esac

    shift
done

if [[ -z "${DEVICE_NAME}" ]]; then
    logError "Missing required argument '--device'"

    exit 1
fi

### Default Values ###
NO_DEPLOY_FLAG_ENABLED=true
for deployFlagName in "${DEPLOY_FLAG_NAMES[@]}"; do
    declare -n DEPLOY_FLAG="${deployFlagName}"

    if [[ -z "${DEPLOY_FLAG}" ]]; then
        DEPLOY_FLAG=false
    fi

    if [[ ${DEPLOY_FLAG} == true ]]; then
        NO_DEPLOY_FLAG_ENABLED=false
    fi
done

if [[ ${NO_DEPLOY_FLAG_ENABLED} = true ]]; then
    logDebug "Enabling all deployment options as none of them were explicitly enabled."

    for deployFlagName in "${DEPLOY_FLAG_NAMES[@]}"; do
        declare -n DEPLOY_FLAG="${deployFlagName}"

        DEPLOY_FLAG=true
    done
fi

for deployFlagName in "${DEPLOY_FLAG_NAMES[@]}"; do
    declare -n DEPLOY_FLAG="${deployFlagName}"

    logDebug "Deploy flag '${deployFlagName}' is set to '${DEPLOY_FLAG}'"
done

### Initialization ###
checkCommand "lsblk"   || { logError "Command 'lsblk' not found!" && exit 1; }
checkCommand "findmnt" || { logError "Command 'findmnt' not found!" && exit 1; }
checkCommand "umount"  || { logError "Command 'umount' not found!" && exit 1; }
checkCommand "mkdir"   || { logError "Command 'mkdir' not found!" && exit 1; }
checkCommand "mount"   || { logError "Command 'mount' not found!" && exit 1; }
checkCommand "cp"      || { logError "Command 'cp' not found!" && exit 1; }
checkCommand "tar"     || { logError "Command 'tar' not found!" && exit 1; }
checkCommand "sync"    || { logError "Command 'sync' not found!" && exit 1; }

if ! lsblk "${DEVICE_NAME}" &>/dev/null; then
    logError "Device '${DEVICE_NAME}' does not exist or is not a block device."

    exit 1
fi

DEVICE_CAPACITY=$(lsblk -b -n -o SIZE "${DEVICE_NAME}" 2>/dev/null | head -n 1)
if [[ -z "${DEVICE_CAPACITY}" || "${DEVICE_CAPACITY}" -eq 0 ]]; then
    logError "Device '${DEVICE_NAME}' couldn't be detected, it might be ejected. Try (re)inserting."

    # Eject and unmount are different operations
    # See https://askubuntu.com/a/5852/970961

    exit 1
fi

PARTITION_PREFIX=""
if [[ "${DEVICE_NAME}" == *"mmc"* ]]; then
    PARTITION_PREFIX="p"
    logDebug "MMC device detected, using '${PARTITION_PREFIX}' as partition prefix."

    # Depending on which port the device is connected to, it appears as /dev/sda or /dev/mmcblk0
    # When it has /dev/sda prefix, the partitions are numbered as /dev/sda1, /dev/sda2, etc.
    # When it has /dev/mmcblk0 prefix, the partitions are numbered as /dev/mmcblk0p1, /dev/mmcblk0p2, etc.
    # So, we need to add 'p' to the partition number sometimes
fi

BOOT_DEV="${DEVICE_NAME}${PARTITION_PREFIX}1"
ROOTFS_DEV="${DEVICE_NAME}${PARTITION_PREFIX}2"

if [ ! -d "${IMAGES_DIR}" ]; then
    logError "Images directory '${IMAGES_DIR}' does not exist!"

    exit 1
fi

if [[ ${FORCE_FORMAT} = true ]]; then
    logInfo "Formatting the device '${DEVICE_NAME}'.."
    bash "${SCRIPT_DIR}/format-sd.sh" --device "${DEVICE_NAME}" > /dev/null
    if [ $? -ne 0 ]; then
        logError "Couldn't format the device '${DEVICE_NAME}'!"

        exit 1
    fi

    logInfo "Device '${DEVICE_NAME}' formatted successfully!"
else
    PARTITION_COUNT=$(sudo sfdisk --dump "${DEVICE_NAME}" | grep --count "^${DEVICE_NAME}")
    if [ "${PARTITION_COUNT}" -ne 2 ]; then
        # We could've enhanced this by checking the partitioning layout
        # I didn't want to make it too complex

        if [ ${PARTITION_COUNT} -eq 0 ]; then
            logWarn "Device '${DEVICE_NAME}' does not have any partitions!"
        else
            logWarn "Device '${DEVICE_NAME}' does not have 2 partitions, it has ${PARTITION_COUNT}"

            if [ ${PRINT_LEVEL} -le ${LOG_DEBUG} ]; then
                logDebug "Partitions: "
                sudo sfdisk --dump "${DEVICE_NAME}" | grep "^${DEVICE_NAME}"
            fi
        fi

        if [[ ${ALLOW_FORMAT} != true ]]; then
            logError "Cannot proceed with deployment, please format the device first or use '--allow-format' option to allow automatic formatting."

            exit 1
        fi

        logInfo "Formatting the device '${DEVICE_NAME}'.."
        bash "${SCRIPT_DIR}/format-sd.sh" --device "${DEVICE_NAME}" > /dev/null
        if [ $? -ne 0 ]; then
            logError "Couldn't format the device '${DEVICE_NAME}'!"

            exit 1
        fi

        logInfo "Device '${DEVICE_NAME}' formatted successfully!"
    fi
fi

### Unmount Partitions ###
logDebug "Un-mounting selected partitions..."

if [[ "${DEPLOY_BOOT}" == true ]]; then
    device="${BOOT_DEV}"
    logDebug "Unmounting partition '${device}' as boot image deployment is selected.."

    umountDevice "${device}"
    if [ $? -ne 0 ]; then
        logError "Couldn't unmount partition '${device}'!"

        exit 1
    fi
fi

if [[ "${DEPLOY_ROOTFS}" == true ]]; then
    device="${ROOTFS_DEV}"
    logDebug "Unmounting partition '${device}' as rootfs deployment is selected.."

    umountDevice "${device}"
    if [ $? -ne 0 ]; then
        logError "Couldn't unmount partition '${device}'!"

        exit 1
    fi
fi

### Deploy Boot Image ###
if [[ "${DEPLOY_BOOT}" == true ]]; then
    logDebug "Boot image deployment selected.."

    FSBL_IMAGE="${IMAGES_DIR}/bootfiles/bootcode.bin"
    if [ ! -f "${FSBL_IMAGE}" ]; then
        logError "FSBL image '${FSBL_IMAGE#}' does not exist!"

        exit 1
    fi

    SSBL_IMAGES=( "${IMAGES_DIR}/bootfiles/start"*.elf )
    if (( ${#SSBL_IMAGES[@]} == 0 )); then
        logError "No SSBL images found in '${IMAGES_DIR}/bootfiles/'!"

        exit 1
    fi

    FIXUP_IMAGES=( "${IMAGES_DIR}/bootfiles/fixup"*.dat )
    if (( ${#FIXUP_IMAGES[@]} == 0 )); then
        logError "No fixup images found in '${IMAGES_DIR}/bootfiles/'!"

        exit 1
    fi

    DTB_IMAGES=( "${IMAGES_DIR}/bcm2711-rpi-4-b.dtb")
    for dtbFile in "${IMAGES_DIR}/"*.dtb; do
        if [ ! -f "${dtbFile}" ]; then
            logError "Device tree file '${dtbFile}' does not exist!"

            exit 1
        fi
    done

    BOOT_FILES=( "${SSBL_IMAGES[@]}" "${FSBL_IMAGE}" "${FIXUP_IMAGES[@]}" "${DTB_IMAGES[@]}" )

    logDebug "Checking BOOT target directory '${BOOT_MOUNT_POINT}'.."
    if [ -d "${BOOT_MOUNT_POINT}" ] && [ "$(ls -A "${BOOT_MOUNT_POINT}")" ]; then
        logError "Deployment directory ${BOOT_MOUNT_POINT} is not empty!"

        exit 1
    fi

    create_directory "${BOOT_MOUNT_POINT}"

    sudo mount "${BOOT_DEV}" "${BOOT_MOUNT_POINT}"
    if [ $? -ne 0 ]; then
        logError "Couldn't mount partition '${BOOT_DEV}' to '${BOOT_MOUNT_POINT}'!"

        exit 1
    fi

    logInfo "Clearing BOOT target directory '${BOOT_MOUNT_POINT}'.."
    sudo rm -rf "${BOOT_MOUNT_POINT:?}"/* || { logError "Couldn't clear BOOT target directory!"; exit 1; }

    logInfo "Copying images into '${BOOT_MOUNT_POINT}'.."
    sudo cp "${BOOT_FILES[@]}" "${BOOT_MOUNT_POINT}/" || { logError "Couldn't copy images!"; exit 1; }

    for dtbFile in "${DTB_IMAGES[@]}"; do
        sudo dtc "${dtbFile}" --in-format dtb --out-format dts --out "${BOOT_MOUNT_POINT}/$(basename "${dtbFile%.dtb}.dts")" --quiet > "/dev/null"
        if [ $? -ne 0 ]; then
            logWarn "Device tree de-compilation failed for '${dtbFile}'!"
        fi
    done

    ((COMPLETED_DEPLOYMENTS++))
else
    logWarn "Skipping BOOT image deployment.."
fi

### Deploy Root Filesystem ###
if [[ "${DEPLOY_ROOTFS}" == true ]]; then
    logDebug "RootFS deployment selected.."

    POTENTIAL_ROOTFS_IMAGES=( "${IMAGES_DIR}/"*.tar.bz2 )

    if (( ${#POTENTIAL_ROOTFS_IMAGES[@]} == 0 )); then
        logError "No RootFS images found in '${IMAGES_DIR}'!"

        exit 1
    fi

    MULTIPLE_ROOTFS_IMAGES=false
    for image in "${POTENTIAL_ROOTFS_IMAGES[@]}"; do
        if [ -L "${image}" ]; then
            logDebug "Skipping symbolic link '${image##*/}'"

            continue
        fi

        if [ -z "${ROOTFS_IMAGE}" ]; then
            ROOTFS_IMAGE="${image}"
            logDebug "Using RootFS image '${ROOTFS_IMAGE##*/}'"
        else
            logWarn "-> '${image##*/}'"

            MULTIPLE_ROOTFS_IMAGES=true
        fi
    done

    if [[ "${MULTIPLE_ROOTFS_IMAGES}" == true ]]; then
        logError "Multiple RootFS images found in '${IMAGES_DIR}'! Please specify one explicitly."

        exit 1
    fi

    if [ -z "${ROOTFS_IMAGE}" ]; then
        logError "No RootFS image found in '${IMAGES_DIR}'!"

        exit 1
    fi

    logDebug "Checking ROOTFS target directory '${ROOTFS_MOUNT_POINT}'.."
    if [ -d "${ROOTFS_MOUNT_POINT}" ] && [ "$(ls -A "${ROOTFS_MOUNT_POINT}")" ]; then
        logError "Deployment directory '${ROOTFS_MOUNT_POINT}' is not empty!"

        exit 1
    fi

    create_directory "${ROOTFS_MOUNT_POINT}"

    sudo mount "${ROOTFS_DEV}" "${ROOTFS_MOUNT_POINT}" > /dev/null
    if [ $? -ne 0 ]; then
        logError "Couldn't mount partition '${ROOTFS_DEV}' to '${ROOTFS_MOUNT_POINT}'!"

        exit 1
    fi

    logInfo "Clearing ROOTFS target directory '${ROOTFS_MOUNT_POINT}'.."
    sudo rm -rf "${ROOTFS_MOUNT_POINT:?}/"* || { logError "Couldn't clear ROOTFS target directory!"; exit 1; }

    logInfo "Extracting rootfs '${ROOTFS_IMAGE##*/}' into '${ROOTFS_MOUNT_POINT}'.."
    sudo tar -xjf "${ROOTFS_IMAGE}" -C "${ROOTFS_MOUNT_POINT}" || { logError "Couldn't extract RootFS!"; exit 1; }

    if [ "${DEPLOY_SSH_KEYS}" == true ]; then
        logInfo "Deploying SSH keys.."

        for pub_key in "${HOME}/.ssh/"*.pub; do
            create_directory "${ROOTFS_MOUNT_POINT}/home/root/.ssh/"

            if [ ! -f "${ROOTFS_MOUNT_POINT}/home/root/.ssh/authorized_keys" ]; then
                sudo touch "${ROOTFS_MOUNT_POINT}/home/root/.ssh/authorized_keys"
            fi

            logDebug "Deploying public SSH key '${pub_key##*/}'.."
            if [ -f "${pub_key}" ]; then
                cat "${pub_key}" | sudo tee --append "${ROOTFS_MOUNT_POINT}/home/root/.ssh/authorized_keys" > /dev/null
                if [ $? -ne 0 ]; then
                    logError "Couldn't deploy public SSH key '${pub_key##*/}'!"

                    # Let's not abort as SSH key deployment isn't critical
                fi
            fi
        done
    fi

    ((COMPLETED_DEPLOYMENTS++))
else
    logWarn "Skipping ROOTFS deployment.."
fi

### Finalization ###
if [ "${COMPLETED_DEPLOYMENTS}" -eq 0 ]; then
    logError "No successful deployment!"

    exit 1
fi

logInfo "Synchronizing file cache, will take some time.."

( sync & pid=$!; while kill -0 ${pid} 2>/dev/null; do echo -n "."; sleep 1; done; echo "" )

if [ $? -eq 0 ]; then
    logInfo "Deployment done!"
else
    logError "Couldn't sync the file cache!"

    exit 1
fi

logInfo "Unmounting partitions..."
umountDevice "${DEVICE_NAME}"
if [ $? -ne 0 ]; then
    logWarn "Couldn't unmount partitions! Unmount them manually.."
fi

logInfo "Deployment complete and selected partitions unmounted!"
exit 0
