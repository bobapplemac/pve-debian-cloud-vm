#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        create-debian-vm.sh
# Revision:    r11
# Modified:    2026-08-24
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/pve-debian-cloud-vm/blob/main/scripts/create-debian-vm.sh
# Description: Generic host-profile launcher for Debian VM creation. Resolves configured or
#              discovered Proxmox storage, applies host policy, updates the Debian cloud-image
#              cache, then invokes the generic VM build script with explicit parameters.
#
# Requirements:
#              awk
#              bash
#              dirname
#              pvesm
#              readlink
#              update-debian-image.sh
#              build-debian-vm.sh
#
# Notes:
#              This script is intentionally distributed without host-specific infrastructure
#              defaults. Customize the Host Configuration section for the target Proxmox host
#              while keeping update-debian-image.sh and build-debian-vm.sh generic and identical
#              across environments.
#
#              A configured storage ID is validated and used as-is. If a storage variable is
#              intentionally left empty, the launcher discovers active storage supporting the
#              required content type. One match is selected automatically; multiple matches are
#              presented interactively, or cause an error in non-interactive mode.
#
#              Configuration precedence is: Host Configuration < environment < CLI arguments.
#              The script resolves its real path before locating sibling helper scripts, so it may
#              be invoked through a symlink such as /usr/local/sbin/create-debian-vm.
#              Unknown VM-specific arguments are passed through unchanged to build-debian-vm.sh.
# ------------------------------------------------------------------------------------------

set -euo pipefail

# ------------------------------------------------------------------------------------------
# Host Configuration
# ------------------------------------------------------------------------------------------
#
# Customize these values for the target Proxmox host. Blank storage IDs enable automatic
# discovery/selection based on the required Proxmox content type. CPU and network settings are
# intentionally blank in the canonical script and must be configured here, by environment, or
# by CLI before provisioning.
#
# Network mode examples:
#
# 1. tagged-bridge
#    Use when multiple VLANs are carried on one VLAN-aware Proxmox bridge. The VM NIC is
#    configured as bridge=<HOST_NETWORK_BRIDGE>,tag=<VLAN>.
#
#      HOST_IMPORT_STORAGE="local"
#      HOST_SNIPPET_STORAGE="local"
#      HOST_VM_STORAGE="local-lvm"
#      HOST_CPU_TYPE="x86-64-v3"
#      HOST_NETWORK_MODE="tagged-bridge"
#      HOST_NETWORK_BRIDGE="vmbr0"
#      HOST_VLAN_BRIDGE_PREFIX=""
#      HOST_DEFAULT_VLAN="40"
#      HOST_DISK_OPTIONS="discard=on,iothread=1,ssd=1"
#
# 2. per-vlan-bridge
#    Use when each VLAN has its own Proxmox bridge. The VM NIC is configured as
#    bridge=<HOST_VLAN_BRIDGE_PREFIX><VLAN>, for example vlan35.
#
#      HOST_IMPORT_STORAGE="ZFS_HDD_Files"
#      HOST_SNIPPET_STORAGE="ZFS_HDD_Files"
#      HOST_VM_STORAGE="ZFS_NVMe"
#      HOST_CPU_TYPE="Skylake-Server-v5"
#      HOST_NETWORK_MODE="per-vlan-bridge"
#      HOST_NETWORK_BRIDGE=""
#      HOST_VLAN_BRIDGE_PREFIX="vlan"
#      HOST_DEFAULT_VLAN="35"
#      HOST_DISK_OPTIONS="discard=on,iothread=1,ssd=1"
#
# Default root password examples (configure only one):
#
# 1. Plaintext password
#
#      HOST_ROOT_PASSWORD="change-me"
#      HOST_ROOT_PASSWORD_HASH=""
#
# 2. Precomputed SHA-512 crypt hash
#
#      HOST_ROOT_PASSWORD=""
#      HOST_ROOT_PASSWORD_HASH='$6$replace-with-openssl-generated-hash'
#
#    Generate a compatible hash with:
#      openssl passwd -6 'change-me'

HOST_IMPORT_STORAGE=""
HOST_SNIPPET_STORAGE=""
HOST_VM_STORAGE=""

HOST_CPU_TYPE=""

HOST_NETWORK_MODE=""
HOST_NETWORK_BRIDGE=""
HOST_VLAN_BRIDGE_PREFIX=""
HOST_DEFAULT_VLAN=""

HOST_DISK_OPTIONS=""

HOST_ROOT_PASSWORD=""
HOST_ROOT_PASSWORD_HASH=''

# Runtime values. Environment variables override the configured host defaults. The '-' form is
# intentional: explicitly exporting an empty storage variable requests automatic discovery.
IMPORT_STORAGE="${IMPORT_STORAGE-$HOST_IMPORT_STORAGE}"
SNIPPET_STORAGE="${SNIPPET_STORAGE-$HOST_SNIPPET_STORAGE}"
VM_STORAGE="${VM_STORAGE-$HOST_VM_STORAGE}"

CPU_TYPE="${CPU_TYPE-$HOST_CPU_TYPE}"

NETWORK_MODE="${NETWORK_MODE-$HOST_NETWORK_MODE}"
NETWORK_BRIDGE="${NETWORK_BRIDGE-$HOST_NETWORK_BRIDGE}"
VLAN_BRIDGE_PREFIX="${VLAN_BRIDGE_PREFIX-$HOST_VLAN_BRIDGE_PREFIX}"
DEFAULT_VLAN="${DEFAULT_VLAN-$HOST_DEFAULT_VLAN}"

DISK_OPTIONS="${DISK_OPTIONS-$HOST_DISK_OPTIONS}"

ROOT_PASSWORD="${ROOT_PASSWORD-$HOST_ROOT_PASSWORD}"
ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH-$HOST_ROOT_PASSWORD_HASH}"


# ------------------------------------------------------------------------------------------
# Provisioning Configuration
# ------------------------------------------------------------------------------------------

SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
SCRIPT_DIR=$(dirname -- "$SCRIPT_PATH")
UPDATE_SCRIPT="${UPDATE_SCRIPT:-$SCRIPT_DIR/update-debian-image.sh}"
BUILD_SCRIPT="${BUILD_SCRIPT:-$SCRIPT_DIR/build-debian-vm.sh}"
SKIP_UPDATE="${SKIP_UPDATE:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

DEBIAN_VERSION="${DEBIAN_VERSION:-13}"
DEBIAN_CODENAME="${DEBIAN_CODENAME:-trixie}"
IMAGE_ARCH="${IMAGE_ARCH:-amd64}"
IMAGE_VARIANT="${IMAGE_VARIANT:-genericcloud}"
KEEP_IMAGES="${KEEP_IMAGES:-3}"
BASE_URL="${BASE_URL:-}"
CLOUDINIT_SNIPPET="${CLOUDINIT_SNIPPET:-cloudinit-vendor-debian.yml}"


die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: create-debian-vm.sh [launcher options] [build options]

Launcher/image options:
  --skip-update                  Skip the Debian image update step
  --non-interactive              Do not prompt for storage selection or VM values
  --debian-version VERSION       Debian major version
  --debian-codename NAME         Debian codename
  --image-arch ARCH              Debian image architecture
  --image-variant VARIANT        Debian cloud image variant
  --keep-images COUNT            Number of cached images to retain
  --base-url URL                 Override Debian cloud-image base URL

Host configuration options:
  --import-storage STORAGE       Storage supporting import content; empty env enables discovery
  --vm-storage STORAGE           Storage supporting images content; empty env enables discovery
  --snippet-storage STORAGE      Storage supporting snippets content; empty env enables discovery
  --cloudinit-snippet FILE       Vendor cloud-init snippet filename
  --cpu-type TYPE                Proxmox CPU model
  --network-mode MODE            tagged-bridge or per-vlan-bridge
  --network-bridge BRIDGE        Bridge for tagged-bridge mode
  --vlan-bridge-prefix PREFIX    Bridge prefix for per-vlan-bridge mode
  --disk-options OPTIONS         Comma-separated scsi0 options
  --default-vlan VLAN            Default VLAN offered by build-debian-vm.sh
  --root-password PASSWORD       Default VM root password (visible in process arguments)
  --root-password-hash HASH      Default VM root password as SHA-512 crypt hash
  -h, --help                     Show launcher help

Other VM-specific options such as --name, --vlan, --ram-gb, --cores, --disk-gb,
--vmid, and --no-autostart are passed through to build-debian-vm.sh.
USAGE
}

is_true() {
    case "${1,,}" in
        1|y|yes|true|on) return 0 ;;
        *) return 1 ;;
    esac
}

require_value() {
    local option=$1
    local value=${2-}

    [[ -n $value ]] || die "$option requires a value."
}

storage_is_active_with_content() {
    local storage=$1
    local content=$2

    pvesm status --storage "$storage" --content "$content" --enabled 1 2>/dev/null \
        | awk -v storage="$storage" \
            'NR > 1 && $1 == storage && $3 == "active" { found = 1 } END { exit !found }'
}

list_active_storages_for_content() {
    local content=$1

    pvesm status --content "$content" --enabled 1 2>/dev/null \
        | awk 'NR > 1 && $3 == "active" { print $1 }'
}

resolve_storage() {
    local variable_name=$1
    local content=$2
    local label=$3
    local current_value=${!variable_name}
    local -a storages=()
    local selection
    local i

    if [[ -n $current_value ]]; then
        storage_is_active_with_content "$current_value" "$content" ||
            die "Configured $label storage '$current_value' is not active and enabled with content type '$content'."
        return 0
    fi

    mapfile -t storages < <(list_active_storages_for_content "$content")

    case ${#storages[@]} in
        0)
            die "No active, enabled Proxmox storage supports content type '$content'."
            ;;
        1)
            printf -v "$variable_name" '%s' "${storages[0]}"
            echo "Using $label storage: ${storages[0]}"
            ;;
        *)
            is_true "$NONINTERACTIVE" &&
                die "Multiple $label storages support '$content'; configure $variable_name explicitly."

            echo "Available $label storages ($content):"
            for i in "${!storages[@]}"; do
                printf '  %d) %s\n' "$((i + 1))" "${storages[$i]}"
            done

            while true; do
                read -rp "Select $label storage [1-${#storages[@]}]: " selection
                if [[ $selection =~ ^[0-9]+$ ]] &&
                   ((selection >= 1 && selection <= ${#storages[@]})); then
                    printf -v "$variable_name" '%s' "${storages[$((selection - 1))]}"
                    break
                fi
                echo "Invalid selection."
            done
            ;;
    esac
}

validate_host_config() {
    [[ -n $CPU_TYPE ]] || die "CPU_TYPE must be configured in Host Configuration, environment, or CLI."

    case "$NETWORK_MODE" in
        tagged-bridge)
            [[ -n $NETWORK_BRIDGE ]] || die "NETWORK_BRIDGE must be configured for tagged-bridge mode."
            ;;
        per-vlan-bridge)
            [[ -n $VLAN_BRIDGE_PREFIX ]] || die "VLAN_BRIDGE_PREFIX must be configured for per-vlan-bridge mode."
            ;;
        *)
            die "NETWORK_MODE must be configured as 'tagged-bridge' or 'per-vlan-bridge'."
            ;;
    esac

    [[ -z $DEFAULT_VLAN || $DEFAULT_VLAN =~ ^[0-9]+$ ]] ||
        die "DEFAULT_VLAN must be numeric when specified."

    if [[ -n $DEFAULT_VLAN ]]; then
        ((DEFAULT_VLAN >= 1 && DEFAULT_VLAN <= 4094)) ||
            die "DEFAULT_VLAN must be between 1 and 4094."
    fi

    [[ -z $ROOT_PASSWORD || -z $ROOT_PASSWORD_HASH ]] ||
        die "Configure ROOT_PASSWORD or ROOT_PASSWORD_HASH, not both."
}

main() {
    local -a build_passthrough=()
    local -a build_args=()
    local -a update_args=()

    while (($#)); do
        case "$1" in
            --skip-update)
                SKIP_UPDATE=1
                shift
                ;;
            --non-interactive)
                NONINTERACTIVE=1
                shift
                ;;
            --debian-version)
                require_value "$1" "${2-}"
                DEBIAN_VERSION=$2
                shift 2
                ;;
            --debian-codename)
                require_value "$1" "${2-}"
                DEBIAN_CODENAME=$2
                shift 2
                ;;
            --image-arch)
                require_value "$1" "${2-}"
                IMAGE_ARCH=$2
                shift 2
                ;;
            --image-variant)
                require_value "$1" "${2-}"
                IMAGE_VARIANT=$2
                shift 2
                ;;
            --keep-images)
                require_value "$1" "${2-}"
                KEEP_IMAGES=$2
                shift 2
                ;;
            --base-url)
                require_value "$1" "${2-}"
                BASE_URL=$2
                shift 2
                ;;
            --import-storage)
                require_value "$1" "${2-}"
                IMPORT_STORAGE=$2
                shift 2
                ;;
            --vm-storage)
                require_value "$1" "${2-}"
                VM_STORAGE=$2
                shift 2
                ;;
            --snippet-storage)
                require_value "$1" "${2-}"
                SNIPPET_STORAGE=$2
                shift 2
                ;;
            --cloudinit-snippet)
                require_value "$1" "${2-}"
                CLOUDINIT_SNIPPET=$2
                shift 2
                ;;
            --cpu-type)
                require_value "$1" "${2-}"
                CPU_TYPE=$2
                shift 2
                ;;
            --network-mode)
                require_value "$1" "${2-}"
                NETWORK_MODE=$2
                shift 2
                ;;
            --network-bridge)
                require_value "$1" "${2-}"
                NETWORK_BRIDGE=$2
                shift 2
                ;;
            --vlan-bridge-prefix)
                require_value "$1" "${2-}"
                VLAN_BRIDGE_PREFIX=$2
                shift 2
                ;;
            --disk-options)
                require_value "$1" "${2-}"
                DISK_OPTIONS=$2
                shift 2
                ;;
            --default-vlan)
                require_value "$1" "${2-}"
                DEFAULT_VLAN=$2
                shift 2
                ;;
            --root-password)
                require_value "$1" "${2-}"
                ROOT_PASSWORD=$2
                ROOT_PASSWORD_HASH=""
                shift 2
                ;;
            --root-password-hash)
                require_value "$1" "${2-}"
                ROOT_PASSWORD_HASH=$2
                ROOT_PASSWORD=""
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                build_passthrough+=("$@")
                break
                ;;
            *)
                build_passthrough+=("$1")
                shift
                ;;
        esac
    done

    ((EUID == 0)) || die "Run this script as root."

    local cmd
    for cmd in awk pvesm; do
        command -v "$cmd" >/dev/null 2>&1 || die "Required command '$cmd' was not found."
    done

    [[ -x $UPDATE_SCRIPT || -f $UPDATE_SCRIPT ]] || die "Update script not found: $UPDATE_SCRIPT"
    [[ -x $BUILD_SCRIPT || -f $BUILD_SCRIPT ]] || die "Build script not found: $BUILD_SCRIPT"

    validate_host_config

    resolve_storage IMPORT_STORAGE import "import"
    resolve_storage VM_STORAGE images "VM image"
    resolve_storage SNIPPET_STORAGE snippets "snippet"

    echo
    echo "Resolved host configuration:"
    echo "  Import storage:  $IMPORT_STORAGE"
    echo "  VM storage:      $VM_STORAGE"
    echo "  Snippet storage: $SNIPPET_STORAGE"
    echo "  CPU type:        $CPU_TYPE"
    echo "  Network mode:    $NETWORK_MODE"
    [[ -n $DEFAULT_VLAN ]] && echo "  Default VLAN:    $DEFAULT_VLAN"
    echo

    export DEBIAN_VERSION DEBIAN_CODENAME IMAGE_ARCH IMAGE_VARIANT KEEP_IMAGES BASE_URL
    export IMPORT_STORAGE VM_STORAGE SNIPPET_STORAGE CLOUDINIT_SNIPPET
    export CPU_TYPE NETWORK_MODE NETWORK_BRIDGE VLAN_BRIDGE_PREFIX DISK_OPTIONS DEFAULT_VLAN
    export ROOT_PASSWORD ROOT_PASSWORD_HASH
    export NONINTERACTIVE

    if ! is_true "$SKIP_UPDATE"; then
        update_args=(
            --debian-version "$DEBIAN_VERSION"
            --debian-codename "$DEBIAN_CODENAME"
            --import-storage "$IMPORT_STORAGE"
            --image-arch "$IMAGE_ARCH"
            --image-variant "$IMAGE_VARIANT"
            --keep-images "$KEEP_IMAGES"
        )

        [[ -n $BASE_URL ]] && update_args+=(--base-url "$BASE_URL")

        bash "$UPDATE_SCRIPT" "${update_args[@]}"
        echo
    fi

    build_args=(
        --debian-version "$DEBIAN_VERSION"
        --image-arch "$IMAGE_ARCH"
        --image-variant "$IMAGE_VARIANT"
        --import-storage "$IMPORT_STORAGE"
        --vm-storage "$VM_STORAGE"
        --snippet-storage "$SNIPPET_STORAGE"
        --cloudinit-snippet "$CLOUDINIT_SNIPPET"
        --cpu-type "$CPU_TYPE"
        --network-mode "$NETWORK_MODE"
    )

    case "$NETWORK_MODE" in
        tagged-bridge)
            build_args+=(--network-bridge "$NETWORK_BRIDGE")
            ;;
        per-vlan-bridge)
            build_args+=(--vlan-bridge-prefix "$VLAN_BRIDGE_PREFIX")
            ;;
    esac

    [[ -n $DISK_OPTIONS ]] && build_args+=(--disk-options "$DISK_OPTIONS")
    is_true "$NONINTERACTIVE" && build_args+=(--non-interactive)

    build_args+=("${build_passthrough[@]}")

    bash "$BUILD_SCRIPT" "${build_args[@]}"
}

main "$@"
