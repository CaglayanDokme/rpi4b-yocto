#!/bin/bash

### Logging ###
[[ -z "${NO_COLOR+x}" ]] && declare -rx NO_COLOR="\033[0m"
[[ -z "${RED+x}"      ]] && declare -rx RED="\033[0;31m"
[[ -z "${GREEN+x}"    ]] && declare -rx GREEN="\033[0;32m"
[[ -z "${YELLOW+x}"   ]] && declare -rx YELLOW="\033[0;33m"
[[ -z "${BLUE+x}"     ]] && declare -rx BLUE="\033[0;34m"
[[ -z "${PURPLE+x}"   ]] && declare -rx PURPLE="\033[0;35m"
[[ -z "${CYAN+x}"     ]] && declare -rx CYAN="\033[0;36m"

# Define log levels
[[ -z "${LOG_DEBUG+x}" ]] && declare -rx LOG_DEBUG=0
[[ -z "${LOG_INFO+x}"  ]] && declare -rx LOG_INFO=1
[[ -z "${LOG_WARN+x}"  ]] && declare -rx LOG_WARN=2
[[ -z "${LOG_ERROR+x}" ]] && declare -rx LOG_ERROR=3
[[ -z "${LOG_NONE+x}"  ]] && declare -rx LOG_NONE=7

# Default print level (change externally if needed)
export PRINT_LEVEL=${PRINT_LEVEL:-${LOG_INFO}}

function timestamp() {
    date +"%Y.%m.%d-%H:%M:%S"
}

function timestampEpoch() {
    date +"%s"
}

### Logging ###
function _getCallerRelativePath() {
    # ${BASH_SOURCE[0]} is the current script as this function is internally used

    # Find the first script in the call stack that isn't the current one
    local i=1
    while [ "${BASH_SOURCE[i]}" = "${BASH_SOURCE[0]}" ] && [ $i -lt ${#BASH_SOURCE[@]} ]; do
        ((i++))
    done

    # If we reached the end with no different script, fall back to the last one
    if [ $i -eq ${#BASH_SOURCE[@]} ]; then
        i=$(( ${#BASH_SOURCE[@]} - 1 ))
    fi

    realpath --relative-to="$(pwd)" "${BASH_SOURCE[i]}" 2> /dev/null
}

function logDebug() {
    if [ -z "$1" ]; then
        return
    fi

    if [ "${PRINT_LEVEL}" -le "${LOG_DEBUG}" ]; then
        echo -e "${NO_COLOR}[$(timestamp)][$(_getCallerRelativePath):${BASH_LINENO[0]}][DEBUG] $* ${NO_COLOR}"
    fi
}

function logInfo() {
    if [ -z "$1" ]; then
        return
    fi

    if [ "${PRINT_LEVEL}" -le "${LOG_INFO}" ]; then
        echo -e "${CYAN}[$(timestamp)][$(_getCallerRelativePath):${BASH_LINENO[0]}][INFO] $* ${NO_COLOR}"
    fi
}

function logWarn() {
    if [ -z "$1" ]; then
        return
    fi

    if [ "${PRINT_LEVEL}" -le "${LOG_WARN}" ]; then
        echo -e "${YELLOW}[$(timestamp)][$(_getCallerRelativePath):${BASH_LINENO[0]}][WARNING] $* ${NO_COLOR}"
    fi
}

function logError() {
    if [ -z "$1" ]; then
        return
    fi

    if [ "${PRINT_LEVEL}" -le "${LOG_ERROR}" ]; then
        >&2 echo -e "${RED}[$(timestamp)][$(_getCallerRelativePath):${BASH_LINENO[0]}][ERROR] $* ${NO_COLOR}"
    fi
}

### Utilities ###
function checkCommand() {
    command -v "$1" &> /dev/null
}

function isSourced() {
    [ "${BASH_SOURCE[1]}" != "${0}" ]
}

function umountDevice() {
    if [ -z "$1" ]; then
        logError "No device specified for unmounting!"

        return 1
    fi

    local device="$1"

    logDebug "Unmounting device '${device}'.."

    if [ ! -e "${device}" ]; then
        logError "Cannot unmount as device '${device}' not found!"

        return 1
    fi

    local mountPoints
    mountPoints=$(mount | grep "${device}" | awk '{print $3}')

    local mountPointAmount
    mountPointAmount=$(echo "${mountPoints}" | wc -w)

    if [ "${mountPointAmount}" -eq 0 ]; then
        logDebug "No mount points found for device '${device}'"

        return 0
    fi

    logDebug "Found ${mountPointAmount} mount point(s) for device '${device}'"

    for mountPoint in ${mountPoints}; do
        logDebug "Unmounting '${mountPoint}'.."

        sudo umount "${mountPoint}" > /dev/null
        if [ $? -ne 0 ]; then
            logError "Failed to unmount '${mountPoint}'!"

            return 1
        fi
    done

    return 0
}

### Numerical Operations ###
function isHex() {
    if [ -z "$1" ]; then
        logError "No input provided!"

        return 1
    elif [ $# -gt 1 ]; then
        logError "Too many arguments($#) provided!"

        return 1
    fi

    [[ "$1" =~ ^0x[0-9A-Fa-f]+$ ]]
}

function isDecimal() {
    if [ -z "$1" ]; then
        logError "No input provided!"

        return 1
    elif [ $# -gt 1 ]; then
        logError "Too many arguments($#) provided!"

        return 1
    fi

    [[ "$1" =~ ^-?[0-9]+$ ]]
}

function isNumerical() {
    if [ -z "$1" ]; then
        logError "No input provided!"

        return 1
    elif [ $# -gt 1 ]; then
        logError "Too many arguments($#) provided!"

        return 1
    fi

    isHex "$1" || isDecimal "$1"
}

function hexToDec() {
    if [ -z "$1" ]; then
        logError "No input provided!"

        return 1
    elif [ $# -gt 1 ]; then
        logError "Too many arguments($#) provided!"

        return 1
    fi

    echo "$(( $1 ))"
}

function convertToNumber() {
    if [ -z "$1" ]; then
        logError "No input provided!"

        return 1
    elif [ $# -gt 1 ]; then
        logError "Too many arguments($#) provided!"

        return 1
    fi

    local input="$1"
    local num unit multiplier

    if isNumerical ${input}; then
        echo ${input}

        return 0
    fi

    num="${input%[EPTGMK]}"
    unit="${input: -1}"

    case "${unit}" in
        E) multiplier=1000000000000000000 ;;
        P) multiplier=1000000000000000 ;;
        T) multiplier=1000000000000 ;;
        G) multiplier=1000000000 ;;
        M) multiplier=1000000 ;;
        K) multiplier=1000 ;;
        *) logError "Unknown unit: '${unit}'" >&2; return 1 ;;
    esac

    awk "BEGIN { printf \"%.0f\n\", ${num} * ${multiplier} }"
}

_script_completions() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local script="${COMP_WORDS[0]}"
    local fullpath
    fullpath=$(command -v "$script") || return

    # Run the script in a subprocess to get raw argument list
    local raw_args
    raw_args=$("$fullpath" --complete 2>/dev/null) || return

    # Prefix each argument with --
    local completions=""
    for arg in $raw_args; do
        completions+="--$arg "
    done

    COMPREPLY=( $(compgen -W "$completions" -- "$cur") )
}

### Main ###
function _main() {
    isSourced || { logError "${0##*/} must be sourced, not executed!"; exit 1; }

    for func in $(declare -F | awk '{print $3}'); do
        if [[ "${func}" != _* ]]; then
            logDebug "Exporting function: '${func?}'"

            export -f "${func?}"
        fi
    done

    local scriptDir
    scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Register completion for each .sh script in the same dir
    for script in "${scriptDir}"/*.sh; do
        [[ -x "${script}" ]] || continue  # skip non-executables
        complete -F _script_completions "$(basename "${script}")"
    done
}

_main "$@"
