#!/bin/sh
# RAUC custom bootloader backend for Raspberry Pi 4B
#
# This script manages A/B slot selection by maintaining a 'rauc_slot' file
# on the FAT32 BOOT partition and rewriting cmdline.txt accordingly.
#
# RAUC invokes this script with one of the following commands:
#   get-primary            - print the bootname of the currently active slot
#   set-primary <bootname> - make <bootname> the primary boot slot
#   get-state <bootname>   - print 'good' or 'bad' for the slot
#   set-state <bootname> <good|bad> - persist slot state to BOOT partition

BOOT_PART="/dev/mmcblk0p1"
BOOT_MOUNT="/mnt/rauc-boot"
SLOT_A_DEV="/dev/mmcblk0p2"
SLOT_B_DEV="/dev/mmcblk0p3"
SLOT_FILE="${BOOT_MOUNT}/rauc_slot"
STATE_FILE="${BOOT_MOUNT}/rauc_state"

mount_boot() {
    if ! mountpoint -q "${BOOT_MOUNT}"; then
        mkdir -p "${BOOT_MOUNT}"
        mount "${BOOT_PART}" "${BOOT_MOUNT}" || {
            echo "ERROR: Failed to mount BOOT partition" >&2
            exit 1
        }
    fi
}

unmount_boot() {
    if mountpoint -q "${BOOT_MOUNT}"; then
        sync
        umount "${BOOT_MOUNT}"
    fi
}

update_cmdline() {
    local slot="$1"
    local cmdline_file="${BOOT_MOUNT}/cmdline.txt"

    if [ "${slot}" = "A" ]; then
        root_dev="${SLOT_A_DEV}"
    else
        root_dev="${SLOT_B_DEV}"
    fi

    if [ ! -f "${cmdline_file}" ]; then
        echo "ERROR: cmdline.txt not found on BOOT partition" >&2
        exit 1
    fi

    # Replace root= and rauc.slot= parameters for the new slot
    sed -i "s|root=[^ ]*|root=${root_dev}|g" "${cmdline_file}"
    if grep -q "rauc\.slot=" "${cmdline_file}"; then
        sed -i "s|rauc\.slot=[^ ]*|rauc.slot=${slot}|g" "${cmdline_file}"
    else
        sed -i "s|$| rauc.slot=${slot}|" "${cmdline_file}"
    fi
}

case "$1" in
    get-primary)
        mount_boot
        if [ -f "${SLOT_FILE}" ]; then
            slot=$(cat "${SLOT_FILE}")
        else
            slot="A"
        fi
        unmount_boot
        echo "${slot}"
        ;;

    set-primary)
        slot="$2"
        if [ "${slot}" != "A" ] && [ "${slot}" != "B" ]; then
            echo "ERROR: Invalid slot '${slot}', expected A or B" >&2
            exit 1
        fi
        mount_boot
        echo "${slot}" > "${SLOT_FILE}"
        update_cmdline "${slot}"
        unmount_boot
        ;;

    get-state)
        # Returns 'good' or 'bad' for the given bootname (slot A or B).
        # State is persisted in rauc_state on the BOOT partition as "<slot>=<state>" lines.
        mount_boot
        slot="$2"
        state="bad"
        if [ -f "${STATE_FILE}" ]; then
            line=$(grep "^${slot}=" "${STATE_FILE}" 2>/dev/null)
            if [ -n "${line}" ]; then
                state="${line#*=}"
            fi
        fi
        unmount_boot
        echo "${state}"
        ;;

    set-state)
        # Persists 'good' or 'bad' for the given bootname into rauc_state.
        slot="$2"
        state="$3"
        mount_boot
        touch "${STATE_FILE}"
        if grep -q "^${slot}=" "${STATE_FILE}" 2>/dev/null; then
            sed -i "s|^${slot}=.*|${slot}=${state}|" "${STATE_FILE}"
        else
            echo "${slot}=${state}" >> "${STATE_FILE}"
        fi
        unmount_boot
        ;;

    *)
        echo "Usage: $0 {get-primary|set-primary <slot>|get-state <slot>|set-state <slot> <state>}" >&2
        exit 1
        ;;
esac
