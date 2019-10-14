#!/bin/bash

set -eu

# Mode name, will be set during build procedure
readonly MODE_NAME="Force NVDIMM reset"
# Version information, will be set during build procedure
readonly VERSION="v1.0-5-gcde4820-dirty"
# pflash utility
readonly PFLASH="/usr/sbin/pflash"
# PNOR partition name and size for store attribute overrides
readonly PART_NAME="ATTR_TMP"
readonly PART_SIZE=32768
# PNOR lock file
readonly PNOR_LOCK="/var/lock/attroverride.lock"

# Color escape sequences
if [[ -t 1 ]]; then
  readonly CLR_ERR="\e[1;31m"
  readonly CLR_INFO="\e[1m"
  readonly CLR_RSET="\e[0m"
else
  readonly CLR_ERR=
  readonly CLR_INFO=
  readonly CLR_RSET=
fi


# Exit trap
function exit_trap {
  local rc=$?
  [[ -z "${PNOR_LOCK}" ]] || rm -f "${PNOR_LOCK}"
  exit ${rc}
}


# Print error message.
# Param 1: message to print.
function print_error {
  local msg="$1"
  echo -e "${CLR_ERR}${msg}${CLR_RSET}" >&2
}


# Set lock to prevent simultaneous access to PNOR flash.
# Return: 0 if PNOR lock was acquired.
function pnor_lock {
  # Create lock file
  if (set -o noclobber; echo "lock" > "${PNOR_LOCK}") 2> /dev/null; then
    trap exit_trap INT TERM EXIT
  else
    print_error "PNOR flash is locked: another process acquired the lock"
    return 1
  fi
  # Check for running pflash
  local pflash_pid="$(pidof pflash)"
  if [[ -n "${pflash_pid}" ]]; then
    print_error "PNOR flash is locked: pflash in progress (${pflash_pid})"
    return 1
  fi
  # Check for host running
  local host_state="$(busctl --no-pager \
                      call xyz.openbmc_project.State.Host \
                      /xyz/openbmc_project/state/host0 \
                      org.freedesktop.DBus.Properties \
                      Get ss xyz.openbmc_project.State.Host \
                      CurrentHostState | sed 's/.*\.\([[:alpha:]]*\)"$/\1/')"
  if [[ "${host_state}" != "Off" ]]; then
    print_error "PNOR flash is locked: Host system is running"
    return 1
  fi
}


# Read the temporary attributes partition to the file.
# Param 1: path to the file used to save the partition dump.
# Return: 0 if partition data was read successfully.
function pnor_read {
  local dump_file="$1"
  rm -f "${dump_file}"
  ${PFLASH} -r "${dump_file}" -P ${PART_NAME} > /dev/null
  if [[ ! -f ${dump_file} ]]; then
    print_error "Error reading ${PART_NAME} partition"
    return 1
  fi
}


# Write the temporary attributes partition to PNOR flash.
# Param 1: path to the file with binary partition content
function pnor_write {
  local attr_file="$1"
  ${PFLASH} -e -f -p "${attr_file}" -P ${PART_NAME} > /dev/null
  # pflash utility doesn't return error codes, check the partition content
  # to ensure that we have correctly written data
  local dump_file="${attr_file}.dump"
  pnor_read "${dump_file}"
  cmp -s "${attr_file}" "${dump_file}" && local rc=0 || local rc=1
  rm -f "${dump_file}"
  if [[ ${rc} -ne 0 ]]; then
    print_error "Error writing ${PART_NAME} partition: data check failed"
  fi
  return ${rc}
}


# Extract attribute override data from script file.
# Param 1: path to the file used to save binary decoded data.
function extract_payload {
  local payload_file="$1"
  # Unpack the payload that contains attribute override partition dump
  local payload_start="$(grep -n '^PAYLOAD:$' "$0" | cut -d ':' -f 1)"
  tail -n +$((payload_start + 1)) "$0" | gunzip -c > "${payload_file}"
  # Enlarge original data file up to partition size
  local file_size=$(stat -c%s "${payload_file}")
  if [[ ${PART_SIZE} -gt ${file_size} ]]; then
    dd if=/dev/zero count=1 bs=$((PART_SIZE - file_size)) 2> /dev/null | tr "\000" "\377" >> "${payload_file}"
  fi
}


# Write the attribute partition from script payload.
function attributes_write {
  local payload_file="/tmp/attroverride.bin"
  extract_payload "${payload_file}" && local rc=0 || local rc=1
  if [[ ${rc} -ne 0 ]]; then
    print_error "Error extracting payload"
    return ${rc}
  fi
  pnor_write "${payload_file}" && rc=0 || rc=1
  rm -f "${payload_file}"
  return ${rc}
}


# Erase the temporary attributes partition in PNOR flash.
# Actually, we fill the partition with 0xff instead of real erasing,
# because it prevent setting partition size to zero.
function attributes_erase {
  local empty_file="/tmp/attroverride.erase"
  dd if=/dev/zero count=1 bs=${PART_SIZE} 2> /dev/null | tr "\000" "\377" >> "${empty_file}"
  pnor_write "${empty_file}" && local rc=0 || local rc=1
  rm -f "${empty_file}"
  return ${rc}
}


# Attribute partition states
readonly ATTR_STATE_UNKNOWN=1
readonly ATTR_STATE_EQUAL=2
readonly ATTR_STATE_DIFF=3
readonly ATTR_STATE_EMPTY=4

# Get attribute partition state.
# Return ATTR_STATE_UNKNOWN: error occurred during the check operation
#        ATTR_STATE_EQUAL: partition contains data from this script's payload
#        ATTR_STATE_DIFF: partition's data differs from this script's payload
#        ATTR_STATE_EMPTY: partition is empty
function attributes_state {
  local dump_file="/tmp/attroverride.dump"
  pnor_read "${dump_file}" || return ${ATTR_STATE_UNKNOWN}

  local rc=${ATTR_STATE_UNKNOWN}

  # Check for empty partition
  local first_byte="$(hexdump -e '1/1 "%02x"' -n1 "${dump_file}")"
  if [[ "${first_byte}" == "ff" ]]; then
    rc=${ATTR_STATE_EMPTY}
  else
    # Compare with payload
    local payload_file="/tmp/attroverride.bin"
    if ! extract_payload "${payload_file}"; then
      print_error "Error extracting payload"
    else
      cmp -s "${payload_file}" "${dump_file}" && local rc=${ATTR_STATE_EQUAL} || local rc=${ATTR_STATE_DIFF}
    fi
    rm -f "${payload_file}"
  fi
  rm -f "${dump_file}"
  return ${rc}
}


################################################################################
# Script entry point
################################################################################
[[ $# -eq 0 ]] && OPERATION="help" || OPERATION="$1"
case "${OPERATION}" in
  enable)
    echo "Enable ${MODE_NAME}..."
    #pnor_lock
    attributes_write
    echo -e "${MODE_NAME} ${CLR_INFO}enabled${CLR_RSET} successfully"
    exit 0;;
  disable)
    echo "Disable ${MODE_NAME}..."
    #pnor_lock
    attributes_erase
    echo -e "${MODE_NAME} ${CLR_INFO}disabled${CLR_RSET} successfully"
    exit 0;;
  status)
    echo "Check for ${MODE_NAME}..."
    #pnor_lock
    RC=${ATTR_STATE_UNKNOWN}
    attributes_state || RC=$?
    echo -n "${MODE_NAME}: "
    case ${RC} in
      ${ATTR_STATE_EQUAL})
        echo -e "${CLR_INFO}ENABLED${CLR_RSET}"
        exit 0;;
      ${ATTR_STATE_EMPTY})
        echo -e "${CLR_INFO}DISABLED${CLR_RSET} (attribute partition is empty)"
        exit 1;;
      ${ATTR_STATE_DIFF})
        echo -e "${CLR_ERR}UNKNOWN${CLR_RSET} (attribute partition contains unknown data)"
        exit 2;;
      ${ATTR_STATE_UNKNOWN})
        echo -e "${CLR_ERR}UNKNOWN${CLR_RSET} (error occurred during check)"
        exit 3;;
      *)
        echo -e "${CLR_ERR}UNKNOWN${CLR_RSET} (unhandled status ${RC})"
        exit 4;;
    esac;;
  version | --version | -v)
    echo "${MODE_NAME} switcher for OpenPOWER firmware environment."
    echo "Version: ${VERSION}"
    exit 0;;
  help | --help | -h )
    echo "${MODE_NAME} switcher for OpenPOWER firmware environment."
    echo "Usage: $0 command"
    echo "Commands:"
    echo "  enable    Enable ${MODE_NAME}"
    echo "  disable   Disable ${MODE_NAME}"
    echo "  status    Print current status of ${MODE_NAME}"
    echo "  version   Print version information and exit"
    echo "  help      Print this help and exit"
    exit 0;;
  *)
    echo "Invalid command: ${OPERATION}" >&2
    echo "Use '$0 help' to read usage info." >&2
    exit 1;;
esac


PAYLOAD:
�      ��1 ! � 
PC����Th`f����Wos|�%3��3   ���v   
