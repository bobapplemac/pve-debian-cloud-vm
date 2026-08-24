#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        build-debian-vm.sh
# Revision:    r7
# Modified:    2026-08-24
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/pve-debian-cloud-vm/blob/main/scripts/build-debian-vm.sh
# Description: Builds a Proxmox VM from the newest cached Debian generic cloud image stored as
#              Proxmox import content. Interactive prompts are used for VM values not supplied
#              by environment or CLI.
#
# Requirements:
#              awk
#              bash
#              openssl
#              pvesh
#              pvesm
#              qm
#              sed
#              sort
#
# Environment:
#              DEBIAN_VERSION, IMAGE_ARCH, IMAGE_VARIANT
#              IMPORT_STORAGE, VM_STORAGE, SNIPPET_STORAGE, CLOUDINIT_SNIPPET
#              CPU_TYPE, NETWORK_MODE, NETWORK_BRIDGE, VLAN_BRIDGE_PREFIX
#              DISK_OPTIONS, DEFAULT_VM_NAME, DEFAULT_VLAN, DEFAULT_RAM_GB
#              DEFAULT_CPU_CORES, DEFAULT_DISK_GB, DEFAULT_AUTOSTART
#              VM_NAME, VLAN, RAM_GB, CPU_CORES, DISK_GB, AUTOSTART, VMID
#              ROOT_PASSWORD, ROOT_PASSWORD_HASH, NONINTERACTIVE
#
# Notes:
#              Configuration precedence is: built-in defaults < environment < CLI arguments.
#              Host-specific infrastructure values have no built-in defaults. IMPORT_STORAGE,
#              VM_STORAGE, SNIPPET_STORAGE, CPU_TYPE, and network configuration must be supplied
#              by the caller. This script validates supplied storage IDs but does not discover or
#              select storage; that policy belongs in create-debian-vm.sh or another launcher.
#              Physical import/snippet paths are resolved by Proxmox rather than hardcoded.
#              The selected VMID is applied as the cluster next-id lower bound so future
#              automatically allocated IDs do not reuse lower gaps.
# ------------------------------------------------------------------------------------------

set -euo pipefail

# ------------------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------------------

DEBIAN_VERSION="${DEBIAN_VERSION:-13}"
IMAGE_ARCH="${IMAGE_ARCH:-amd64}"
IMAGE_VARIANT="${IMAGE_VARIANT:-genericcloud}"

IMPORT_STORAGE="${IMPORT_STORAGE:-}"
VM_STORAGE="${VM_STORAGE:-}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-}"
CLOUDINIT_SNIPPET="${CLOUDINIT_SNIPPET:-cloudinit-vendor-debian.yml}"

CPU_TYPE="${CPU_TYPE:-}"
NETWORK_MODE="${NETWORK_MODE:-}"
NETWORK_BRIDGE="${NETWORK_BRIDGE:-}"
VLAN_BRIDGE_PREFIX="${VLAN_BRIDGE_PREFIX:-}"
DISK_OPTIONS="${DISK_OPTIONS:-}"

DEFAULT_VM_NAME="${DEFAULT_VM_NAME:-debian}"
DEFAULT_VLAN="${DEFAULT_VLAN:-}"
DEFAULT_RAM_GB="${DEFAULT_RAM_GB:-4}"
DEFAULT_CPU_CORES="${DEFAULT_CPU_CORES:-2}"
DEFAULT_DISK_GB="${DEFAULT_DISK_GB:-8}"
DEFAULT_AUTOSTART="${DEFAULT_AUTOSTART:-yes}"

# Standard metadata applied to every VM created by this script.
VM_TAGS="debian13;linux;new"

VM_NAME="${VM_NAME:-}"
VLAN="${VLAN:-}"
RAM_GB="${RAM_GB:-}"
CPU_CORES="${CPU_CORES:-}"
DISK_GB="${DISK_GB:-}"
AUTOSTART="${AUTOSTART:-}"
VMID="${VMID:-}"
ROOT_PASSWORD="${ROOT_PASSWORD:-}"
ROOT_PASSWORD_HASH="${ROOT_PASSWORD_HASH:-}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"


die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: build-debian-vm.sh [options]

VM options:
  --name NAME                    VM name
  --vlan VLAN                    VLAN ID
  --ram-gb GB                    Memory in GiB
  --cores COUNT                  CPU core count
  --disk-gb GB                   Disk size in GiB
  --autostart                    Start VM after creation
  --no-autostart                 Do not start VM after creation
  --vmid ID                      Use a specific VMID instead of the next available ID
  --root-password PASSWORD       Root password (visible in process arguments)
  --root-password-hash HASH      Precomputed SHA-512 crypt password hash
  --non-interactive              Do not prompt; use defaults for unset VM values

Required host/image options:
  --debian-version VERSION       Debian major version
  --image-arch ARCH              Debian image architecture
  --image-variant VARIANT        Debian image variant
  --import-storage STORAGE       Proxmox storage containing cached import images
  --vm-storage STORAGE           Proxmox storage receiving VM disks/cloud-init drive
  --snippet-storage STORAGE      Proxmox storage containing cloud-init snippets
  --cloudinit-snippet FILE       Vendor snippet filename within snippets content
  --cpu-type TYPE                Proxmox CPU model
  --network-mode MODE            tagged-bridge or per-vlan-bridge
  --network-bridge BRIDGE        Bridge used by tagged-bridge mode
  --vlan-bridge-prefix PREFIX    Bridge prefix used by per-vlan-bridge mode
  --disk-options OPTIONS         Comma-separated scsi0 disk options
  -h, --help                     Show this help

Environment variables with matching names may be used instead of CLI arguments.
CLI arguments take precedence over environment variables.
USAGE
}

require_value() {
    local option=$1
    local value=${2-}

    [[ -n $value ]] || die "$option requires a value."
}

parse_args() {
    while (($#)); do
        case "$1" in
            --name)
                require_value "$1" "${2-}"
                VM_NAME=$2
                shift 2
                ;;
            --vlan)
                require_value "$1" "${2-}"
                VLAN=$2
                shift 2
                ;;
            --ram-gb)
                require_value "$1" "${2-}"
                RAM_GB=$2
                shift 2
                ;;
            --cores)
                require_value "$1" "${2-}"
                CPU_CORES=$2
                shift 2
                ;;
            --disk-gb)
                require_value "$1" "${2-}"
                DISK_GB=$2
                shift 2
                ;;
            --autostart)
                AUTOSTART=yes
                shift
                ;;
            --no-autostart)
                AUTOSTART=no
                shift
                ;;
            --vmid)
                require_value "$1" "${2-}"
                VMID=$2
                shift 2
                ;;
            --root-password)
                require_value "$1" "${2-}"
                ROOT_PASSWORD=$2
                shift 2
                ;;
            --root-password-hash)
                require_value "$1" "${2-}"
                ROOT_PASSWORD_HASH=$2
                shift 2
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
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    (($# == 0)) || die "Unexpected positional argument: $1"
}


# ------------------------------------------------------------------------------------------
# Proxmox storage helpers
# ------------------------------------------------------------------------------------------

storage_is_active_with_content() {
    local storage=$1
    local content=$2

    pvesm status --storage "$storage" --content "$content" --enabled 1 2>/dev/null \
        | awk -v storage="$storage" \
            'NR > 1 && $1 == storage && $3 == "active" { found = 1 } END { exit !found }'
}

list_matching_import_volids() {
    local prefix="debian-${DEBIAN_VERSION}-${IMAGE_VARIANT}-${IMAGE_ARCH}-"
    local volid
    local filename

    while IFS= read -r volid; do
        [[ -n $volid ]] || continue
        filename=${volid#"${IMPORT_STORAGE}:import/"}

        if [[ $volid == "${IMPORT_STORAGE}:import/"* && \
              $filename == "${prefix}"*.qcow2 ]]; then
            printf '%s\n' "$volid"
        fi
    done < <(pvesm list "$IMPORT_STORAGE" --content import 2>/dev/null | awk 'NR > 1 { print $1 }')
}

find_latest_image_volid() {
    local -a volids=()

    mapfile -t volids < <(list_matching_import_volids | sort -r)
    ((${#volids[@]} > 0)) ||
        die "No Debian ${DEBIAN_VERSION} ${IMAGE_VARIANT} ${IMAGE_ARCH} image found in '${IMPORT_STORAGE}:import/'."

    printf '%s\n' "${volids[0]}"
}

resolve_volume_path() {
    local volid=$1
    local path

    path=$(pvesm path "$volid" 2>/dev/null) ||
        die "Could not resolve Proxmox volume path: $volid"

    [[ -n $path ]] || die "Proxmox returned an empty path for volume: $volid"
    printf '%s\n' "$path"
}


# ------------------------------------------------------------------------------------------
# Preflight and input
# ------------------------------------------------------------------------------------------

is_true() {
    case "${1,,}" in
        1|y|yes|true|on) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_value() {
    local variable_name=$1
    local prompt=$2
    local default_value=$3
    local current_value=${!variable_name}
    local input

    if [[ -n $current_value ]]; then
        return 0
    fi

    if is_true "$NONINTERACTIVE"; then
        [[ -n $default_value ]] ||
            die "$variable_name must be specified in non-interactive mode."
        printf -v "$variable_name" '%s' "$default_value"
        return 0
    fi

    if [[ -n $default_value ]]; then
        read -rp "$prompt [$default_value]: " input
        printf -v "$variable_name" '%s' "${input:-$default_value}"
    else
        read -rp "$prompt: " input
        [[ -n $input ]] || die "$variable_name cannot be empty."
        printf -v "$variable_name" '%s' "$input"
    fi
}

collect_input() {
    prompt_value VM_NAME "Enter VM name" "$DEFAULT_VM_NAME"
    prompt_value VLAN "Enter VLAN tag" "$DEFAULT_VLAN"
    prompt_value RAM_GB "Enter RAM in GB" "$DEFAULT_RAM_GB"
    prompt_value CPU_CORES "Enter CPU core count" "$DEFAULT_CPU_CORES"
    prompt_value DISK_GB "Enter disk size in GB" "$DEFAULT_DISK_GB"
    prompt_value AUTOSTART "Autostart VM after creation? (yes/no)" "$DEFAULT_AUTOSTART"

    if [[ -z $ROOT_PASSWORD_HASH && -z $ROOT_PASSWORD ]]; then
        is_true "$NONINTERACTIVE" &&
            die "ROOT_PASSWORD or ROOT_PASSWORD_HASH is required in non-interactive mode."

        read -srp "Enter root password: " ROOT_PASSWORD
        echo
        [[ -n $ROOT_PASSWORD ]] || die "Root password cannot be empty."
    fi
}

preflight_host() {
    local cmd

    ((EUID == 0)) || die "Run this script as root."

    for cmd in awk openssl pvesh pvesm qm sed sort; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    [[ -n $IMPORT_STORAGE ]] || die "IMPORT_STORAGE must be specified."
    [[ -n $VM_STORAGE ]] || die "VM_STORAGE must be specified."
    [[ -n $SNIPPET_STORAGE ]] || die "SNIPPET_STORAGE must be specified."
    [[ -n $CPU_TYPE ]] || die "CPU_TYPE must be specified."
    [[ -n $NETWORK_MODE ]] || die "NETWORK_MODE must be specified."

    storage_is_active_with_content "$IMPORT_STORAGE" import ||
        die "Storage '$IMPORT_STORAGE' is not active and enabled with content type 'import'."

    storage_is_active_with_content "$VM_STORAGE" images ||
        die "Storage '$VM_STORAGE' is not active and enabled with content type 'images'."

    storage_is_active_with_content "$SNIPPET_STORAGE" snippets ||
        die "Storage '$SNIPPET_STORAGE' is not active and enabled with content type 'snippets'."
}

preflight_config() {
    local snippet_volid
    local snippet_path

    [[ $DEBIAN_VERSION =~ ^[0-9]+$ ]] || die "DEBIAN_VERSION must be numeric."
    [[ $VLAN =~ ^[0-9]+$ ]] || die "VLAN must be numeric."
    ((VLAN >= 1 && VLAN <= 4094)) || die "VLAN must be between 1 and 4094."
    [[ $RAM_GB =~ ^[0-9]+$ ]] && ((RAM_GB > 0)) || die "RAM_GB must be a positive integer."
    [[ $CPU_CORES =~ ^[0-9]+$ ]] && ((CPU_CORES > 0)) || die "CPU_CORES must be a positive integer."
    [[ $DISK_GB =~ ^[0-9]+$ ]] && ((DISK_GB > 0)) || die "DISK_GB must be a positive integer."
    [[ -z $VMID || $VMID =~ ^[0-9]+$ ]] || die "VMID must be numeric."
    [[ $CLOUDINIT_SNIPPET != */* ]] ||
        die "CLOUDINIT_SNIPPET must be a filename within the snippets content directory, not a path."

    case "$NETWORK_MODE" in
        tagged-bridge)
            [[ -n $NETWORK_BRIDGE ]] || die "NETWORK_BRIDGE must be specified for tagged-bridge mode."
            ;;
        per-vlan-bridge)
            [[ -n $VLAN_BRIDGE_PREFIX ]] || die "VLAN_BRIDGE_PREFIX must be specified for per-vlan-bridge mode."
            ;;
        *)
            die "NETWORK_MODE must be 'tagged-bridge' or 'per-vlan-bridge'."
            ;;
    esac

    case "${AUTOSTART,,}" in
        1|y|yes|true|on|0|n|no|false|off) ;;
        *) die "AUTOSTART must be yes/no, true/false, on/off, or 1/0." ;;
    esac

    [[ -z $ROOT_PASSWORD_HASH || -z $ROOT_PASSWORD ]] ||
        die "Specify ROOT_PASSWORD or ROOT_PASSWORD_HASH, not both."

    snippet_volid="${SNIPPET_STORAGE}:snippets/${CLOUDINIT_SNIPPET}"
    snippet_path=$(resolve_volume_path "$snippet_volid")
    [[ -f $snippet_path ]] || die "Cloud-init vendor snippet does not exist: $snippet_volid"
}


# ------------------------------------------------------------------------------------------
# VM creation
# ------------------------------------------------------------------------------------------

build_net0() {
    case "$NETWORK_MODE" in
        tagged-bridge)
            printf 'virtio,bridge=%s,tag=%s\n' "$NETWORK_BRIDGE" "$VLAN"
            ;;
        per-vlan-bridge)
            printf 'virtio,bridge=%s%s\n' "$VLAN_BRIDGE_PREFIX" "$VLAN"
            ;;
    esac
}

build_vm() {
    local image_volid
    local image_path
    local ram_mb
    local root_hash
    local net0
    local imported_volume
    local snippet_volid
    local created_date
    local description
    local mac

    image_volid=$(find_latest_image_volid)
    image_path=$(resolve_volume_path "$image_volid")
    [[ -f $image_path ]] || die "Cached import image does not exist: $image_volid"

    ram_mb=$((RAM_GB * 1024))
    net0=$(build_net0)
    snippet_volid="${SNIPPET_STORAGE}:snippets/${CLOUDINIT_SNIPPET}"

    printf -v created_date '%(%F)T' -1
    printf -v description '%s\n\n%s\n\n%s\n\n%s\n\n%s\n\n%s\n\n%s\n\n%s\n' \
        "**Hostname:** $VM_NAME" \
        "**Description:** TBD" \
        "**Native Services:** TBD" \
        "**Docker Services:** TBD" \
        "**OS:** Debian Linux 13 (Trixie)" \
        "**Date Created:** $created_date" \
        "**CNAME Aliases:** N/A" \
        "**Notes:**"

    if [[ -n $ROOT_PASSWORD_HASH ]]; then
        root_hash=$ROOT_PASSWORD_HASH
    else
        root_hash=$(openssl passwd -6 "$ROOT_PASSWORD")
    fi

    if [[ -z $VMID ]]; then
        VMID=$(pvesh get /cluster/nextid)
    fi

    # Keep future automatically allocated VMIDs at or above the selected VMID.
    pvesh set /cluster/options --next-id "lower=$VMID"

    qm status "$VMID" >/dev/null 2>&1 && die "VMID $VMID already exists."

    echo "Building VM $VM_NAME (VMID: $VMID) using image: $image_volid"

    qm create "$VMID"
    qm set "$VMID" --name "$VM_NAME"
    qm set "$VMID" --tags "$VM_TAGS"
    qm set "$VMID" --description "$description"
    qm set "$VMID" --ostype l26
    qm set "$VMID" --bios ovmf
    qm set "$VMID" --machine q35
    qm set "$VMID" --cpu "$CPU_TYPE"
    qm set "$VMID" --sockets 1
    qm set "$VMID" --cores "$CPU_CORES"
    qm set "$VMID" --numa 1

    qm set "$VMID" --memory "$ram_mb"
    qm set "$VMID" --balloon 0
    qm set "$VMID" --hotplug disk,network,usb

    qm set "$VMID" --vga qxl
    qm set "$VMID" --agent enabled=1
    qm set "$VMID" --serial0 socket
    qm set "$VMID" --net0 "$net0"
    qm set "$VMID" --scsihw virtio-scsi-single

    qm importdisk "$VMID" "$image_path" "$VM_STORAGE"
    imported_volume=$(qm config "$VMID" | sed -n 's/^unused0: //p; /^unused0:/q')
    [[ -n $imported_volume ]] || die "Could not determine the imported disk volume."

    if [[ -n $DISK_OPTIONS ]]; then
        qm set "$VMID" --scsi0 "${imported_volume},${DISK_OPTIONS}"
    else
        qm set "$VMID" --scsi0 "$imported_volume"
    fi

    qm resize "$VMID" scsi0 "${DISK_GB}G"
    qm set "$VMID" --boot order=scsi0

    qm set "$VMID" --ciuser root
    qm set "$VMID" --cipassword "$root_hash"
    qm set "$VMID" --ipconfig0 ip=dhcp
    qm set "$VMID" --cicustom "vendor=${snippet_volid}"
    qm set "$VMID" --scsi15 "${VM_STORAGE}:cloudinit,media=cdrom"

    if is_true "$AUTOSTART"; then
        qm start "$VMID"
    fi

    mac=$(qm config "$VMID" | sed -nE 's/^net0: virtio=([^,]+).*/\1/p')

    echo "======================================="
    echo "VM Created: $VM_NAME"
    echo "VMID: $VMID"
    echo "Tags: $VM_TAGS"
    echo "Date created: $created_date"
    echo "Primary MAC Address: $mac"
    echo "Cloud image: $image_volid"
    echo "Import storage: $IMPORT_STORAGE"
    echo "VM storage: $VM_STORAGE"
    echo "Snippet storage: $SNIPPET_STORAGE"
    echo "Vendor snippet: $snippet_volid"
    echo "Max RAM: $ram_mb MB"
    echo "CPU: 1 socket, $CPU_CORES cores ($CPU_TYPE)"
    echo "Disk size: $DISK_GB GB"
    echo "VLAN: $VLAN"
    echo "Network: $net0"
    echo "Cloud-Init drive: scsi15 on $VM_STORAGE (CD-ROM)"
    echo "======================================="
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    parse_args "$@"
    preflight_host
    collect_input
    preflight_config
    build_vm
}

main "$@"
