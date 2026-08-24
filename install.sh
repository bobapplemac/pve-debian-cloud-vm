#!/bin/bash

# Quick start:
# curl -fsSL https://raw.githubusercontent.com/bobapplemac/pve-debian-cloud-vm/main/install.sh | bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        install.sh
# Revision:    r4
# Modified:    2026-08-24
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/pve-debian-cloud-vm/blob/main/install.sh
# Description: Installs the pve-debian-cloud-vm scripts and cloud-init vendor snippet on a
#              Proxmox VE host, then creates convenient local symlinks for normal use.
#
# Requirements:
#              awk
#              bash
#              cmp
#              cp
#              curl
#              dirname
#              grep
#              install
#              ln
#              mktemp
#              mv
#              pvesm
#              rm
#
# Environment:
#              IMPORT_STORAGE       Proxmox storage ID for import content. Optional.
#              SNIPPET_STORAGE      Proxmox storage ID for snippets content. Required unless a
#                                   valid value already exists in installed create-debian-vm.sh.
#              VM_STORAGE           Proxmox storage ID for VM image content. Optional.
#              INSTALL_DIR          Script installation directory.
#                                   Default: /opt/scripts/pve-debian-cloud-vm
#              COMMAND_LINK         Convenience command symlink.
#                                   Default: /usr/local/sbin/create-debian-vm
#              FORCE                Overwrite locally editable files when true. Default: 0
#              NONINTERACTIVE       Disable interactive storage selection when true. Default: 0
#
# Notes:
#              The canonical GitHub filenames do not contain revision suffixes; revisions are
#              retained only in each file's comment header.
#
#              Storage selection precedence is: explicit environment/CLI value <existing installed
#              create-debian-vm.sh host default> <interactive selection>. Existing HOST_*_STORAGE
#              values are reused without prompting when they remain active, enabled, and support
#              the required content type. Invalid or blank existing values fall back to normal
#              selection. Import and VM storage may remain unconfigured; snippets storage is
#              required and installation aborts before writing files if none is available.
#
#              build-debian-vm.sh and update-debian-image.sh are generic helper scripts and are
#              refreshed on every run. create-debian-vm.sh and cloudinit-vendor-debian.yml are
#              locally editable and are preserved when they differ from the current repository
#              versions. Updated repository copies are written beside them with a .dist suffix.
#              Pass --force to back up and replace locally edited copies. Existing non-storage
#              HOST_* settings are carried into the replacement create-debian-vm.sh; storage
#              defaults come from the selections made during the current installer run.
#
#              Prompts read from /dev/tty so the documented curl-to-bash quick start remains
#              interactive. In non-interactive mode, snippet storage must be supplied explicitly
#              or already be valid in the installed create-debian-vm.sh; import and VM storage may
#              remain blank.
# ------------------------------------------------------------------------------------------

set -euo pipefail

# ------------------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------------------

REPO_RAW_BASE="https://raw.githubusercontent.com/bobapplemac/pve-debian-cloud-vm/main"

INSTALL_DIR="${INSTALL_DIR:-/opt/scripts/pve-debian-cloud-vm}"
COMMAND_LINK="${COMMAND_LINK:-/usr/local/sbin/create-debian-vm}"
IMPORT_STORAGE="${IMPORT_STORAGE:-}"
SNIPPET_STORAGE="${SNIPPET_STORAGE:-}"
VM_STORAGE="${VM_STORAGE:-}"
FORCE="${FORCE:-0}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

CREATE_FILE="create-debian-vm.sh"
BUILD_FILE="build-debian-vm.sh"
UPDATE_FILE="update-debian-image.sh"
SNIPPET_FILE="cloudinit-vendor-debian.yml"

CREATE_PRESERVED=0
SNIPPET_PRESERVED=0
TEMP_DIR=""


die() {
    echo "ERROR: $*" >&2
    exit 1
}


usage() {
    cat <<'USAGE'
Usage: install.sh [options]

Options:
  --import-storage STORAGE    Proxmox storage ID supporting import content
  --snippet-storage STORAGE   Proxmox storage ID supporting snippets content
  --vm-storage STORAGE        Proxmox storage ID supporting VM images content
  --install-dir PATH          Script installation directory
  --command-link PATH         Convenience command symlink path
  --force                     Back up and overwrite locally editable files
  --non-interactive           Do not prompt for storage selection
  -h, --help                  Show this help

Existing valid HOST_*_STORAGE values in the installed create-debian-vm.sh are reused without
prompting. Otherwise, interactive mode presents compatible storage as a numbered list for each
role. Import and VM storage may be left unconfigured. Snippet storage is required.

Environment variables with matching names may also be used.
CLI arguments take precedence over environment variables and existing installed defaults.
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


parse_args() {
    while (($#)); do
        case "$1" in
            --import-storage)
                require_value "$1" "${2-}"
                IMPORT_STORAGE=$2
                shift 2
                ;;
            --snippet-storage)
                require_value "$1" "${2-}"
                SNIPPET_STORAGE=$2
                shift 2
                ;;
            --vm-storage)
                require_value "$1" "${2-}"
                VM_STORAGE=$2
                shift 2
                ;;
            --install-dir)
                require_value "$1" "${2-}"
                INSTALL_DIR=$2
                shift 2
                ;;
            --command-link)
                require_value "$1" "${2-}"
                COMMAND_LINK=$2
                shift 2
                ;;
            --force)
                FORCE=1
                shift
                ;;
            --non-interactive)
                NONINTERACTIVE=1
                shift
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


list_active_storages_for_content() {
    local content=$1

    pvesm status --content "$content" --enabled 1 2>/dev/null \
        | awk 'NR > 1 && $3 == "active" { print $1 }'
}


read_existing_host_storage_default() {
    local file=$1
    local key=$2
    local line
    local value

    [[ -f $file ]] || return 1

    line=$(grep -m1 "^${key}=" "$file" || true)
    [[ -n $line ]] || return 1

    value=${line#*=}

    if [[ $value =~ ^\"([^\"]*)\"$ ]]; then
        value=${BASH_REMATCH[1]}
    elif [[ $value =~ ^\'([^\']*)\'$ ]]; then
        value=${BASH_REMATCH[1]}
    elif [[ $value =~ ^[A-Za-z0-9_.-]+$ ]]; then
        :
    else
        return 1
    fi

    [[ -n $value ]] || return 1
    printf '%s\n' "$value"
}


reuse_existing_storage_default() {
    local variable_name=$1
    local key=$2
    local content=$3
    local label=$4
    local create_file=$5
    local current_value=${!variable_name}
    local existing_value

    # An explicit environment or CLI value always takes precedence.
    [[ -z $current_value ]] || return 0

    existing_value=$(read_existing_host_storage_default "$create_file" "$key" || true)
    [[ -n $existing_value ]] || return 0

    if storage_is_active_with_content "$existing_value" "$content"; then
        printf -v "$variable_name" '%s' "$existing_value"
        echo "Using $label storage: $existing_value (existing create-debian-vm.sh)"
    else
        echo "Existing $key='$existing_value' is not currently valid for content type '$content'; selecting again."
    fi
}


read_from_tty() {
    local variable_name=$1
    local prompt=$2
    local value

    if ! IFS= read -r -p "$prompt" value </dev/tty; then
        die "Interactive input is unavailable. Use --non-interactive with explicit storage options."
    fi

    printf -v "$variable_name" '%s' "$value"
}


resolve_storage_selection() {
    local variable_name=$1
    local content=$2
    local label=$3
    local required=$4
    local current_value=${!variable_name}
    local -a storages=()
    local selection
    local i

    # Explicit environment/CLI values are treated as an intentional selection.
    if [[ -n $current_value ]]; then
        storage_is_active_with_content "$current_value" "$content" ||
            die "Storage '$current_value' is not active and enabled with content type '$content'."
        echo "Using $label storage: $current_value (specified)"
        return 0
    fi

    mapfile -t storages < <(list_active_storages_for_content "$content")

    if ((${#storages[@]} == 0)); then
        if is_true "$required"; then
            die "No active, enabled Proxmox storage supports content type '$content'. Configure a storage for '$content' before installing."
        fi

        printf -v "$variable_name" '%s' ""
        echo "No active storage supports $label content type '$content'; leaving $variable_name unconfigured."
        return 0
    fi

    if is_true "$NONINTERACTIVE"; then
        if is_true "$required"; then
            die "$variable_name must be specified in non-interactive mode."
        fi

        printf -v "$variable_name" '%s' ""
        echo "Leaving $variable_name unconfigured in non-interactive mode."
        return 0
    fi

    echo
    echo "Available $label storage:"
    if ! is_true "$required"; then
        echo "  0) Leave unconfigured"
    fi

    for i in "${!storages[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "${storages[$i]}"
    done

    while true; do
        if is_true "$required"; then
            read_from_tty selection "Select $label storage [1-${#storages[@]}]: "
        else
            read_from_tty selection "Select $label storage [0-${#storages[@]}]: "
        fi

        if ! is_true "$required" && [[ $selection == 0 ]]; then
            printf -v "$variable_name" '%s' ""
            echo "Leaving $variable_name unconfigured."
            return 0
        fi

        if [[ $selection =~ ^[0-9]+$ ]] &&
           ((selection >= 1 && selection <= ${#storages[@]})); then
            printf -v "$variable_name" '%s' "${storages[$((selection - 1))]}"
            echo "Selected $label storage: ${storages[$((selection - 1))]}"
            return 0
        fi

        echo "Invalid selection."
    done
}


resolve_snippet_path() {
    local volid=$1
    local path

    path=$(pvesm path "$volid" 2>/dev/null) ||
        die "Could not resolve Proxmox snippet path: $volid"

    [[ -n $path ]] || die "Proxmox returned an empty path for snippet volume: $volid"
    printf '%s\n' "$path"
}


# ------------------------------------------------------------------------------------------
# Download and installation helpers
# ------------------------------------------------------------------------------------------

download_file() {
    local url=$1
    local destination=$2

    echo "Downloading: $url"
    curl -fsSL --retry 3 --retry-delay 1 "$url" -o "$destination" ||
        die "Download failed: $url"
}


preserve_existing_host_defaults() {
    local existing=$1
    local source=$2
    local temp="${source}.host-defaults"

    [[ -f $existing ]] || return 0

    # Preserve host-specific settings from an existing create-debian-vm.sh while allowing the
    # installer-selected storage defaults to be applied separately below. This is especially useful
    # with --force, which can then refresh launcher logic without discarding local host policy.
    awk '
        NR == FNR {
            if ($0 ~ /^HOST_[A-Z0-9_]+=/) {
                split($0, parts, "=")
                key = parts[1]
                if (key != "HOST_IMPORT_STORAGE" &&
                    key != "HOST_SNIPPET_STORAGE" &&
                    key != "HOST_VM_STORAGE") {
                    saved[key] = $0
                }
            }
            next
        }
        $0 ~ /^HOST_[A-Z0-9_]+=/ {
            split($0, parts, "=")
            key = parts[1]
            if (key in saved) {
                print saved[key]
                next
            }
        }
        { print }
    ' "$existing" "$source" > "$temp"

    mv -- "$temp" "$source"
}


patch_create_storage_defaults() {
    local file=$1
    local temp="${file}.patched"

    grep -q '^HOST_IMPORT_STORAGE=""$' "$file" ||
        die "Could not find the expected HOST_IMPORT_STORAGE configuration line in ${CREATE_FILE}."
    grep -q '^HOST_SNIPPET_STORAGE=""$' "$file" ||
        die "Could not find the expected HOST_SNIPPET_STORAGE configuration line in ${CREATE_FILE}."
    grep -q '^HOST_VM_STORAGE=""$' "$file" ||
        die "Could not find the expected HOST_VM_STORAGE configuration line in ${CREATE_FILE}."

    awk \
        -v import_storage="$IMPORT_STORAGE" \
        -v snippet_storage="$SNIPPET_STORAGE" \
        -v vm_storage="$VM_STORAGE" '
        /^HOST_IMPORT_STORAGE=""$/ {
            print "HOST_IMPORT_STORAGE=\"" import_storage "\""
            next
        }
        /^HOST_SNIPPET_STORAGE=""$/ {
            print "HOST_SNIPPET_STORAGE=\"" snippet_storage "\""
            next
        }
        /^HOST_VM_STORAGE=""$/ {
            print "HOST_VM_STORAGE=\"" vm_storage "\""
            next
        }
        { print }
    ' "$file" > "$temp"

    mv -- "$temp" "$file"
}


backup_file() {
    local file=$1
    local timestamp
    local backup

    printf -v timestamp '%(%Y%m%d-%H%M%S)T' -1
    backup="${file}.bak.${timestamp}"

    cp -a -- "$file" "$backup"
    echo "Backed up: $file -> $backup"
}


install_generic_script() {
    local source=$1
    local destination=$2

    install -o root -g root -m 0755 "$source" "$destination"
    echo "Installed: $destination"
}


install_editable_file() {
    local source=$1
    local destination=$2
    local mode=$3
    local preserved_variable=$4

    if [[ ! -e $destination ]]; then
        install -o root -g root -m "$mode" "$source" "$destination"
        rm -f -- "${destination}.dist"
        echo "Installed: $destination"
        return 0
    fi

    if cmp -s -- "$source" "$destination"; then
        rm -f -- "${destination}.dist"
        echo "Unchanged: $destination"
        return 0
    fi

    if is_true "$FORCE"; then
        backup_file "$destination"
        install -o root -g root -m "$mode" "$source" "$destination"
        rm -f -- "${destination}.dist"
        echo "Updated: $destination"
        return 0
    fi

    install -o root -g root -m "$mode" "$source" "${destination}.dist"
    printf -v "$preserved_variable" '%s' 1
    echo "Preserved local file: $destination"
    echo "Repository version:   ${destination}.dist"
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    local cmd
    local temp_dir
    local create_source
    local build_source
    local update_source
    local snippet_source
    local create_dest
    local build_dest
    local update_dest
    local snippet_volid
    local snippet_path
    local command_dir
    local first_line

    parse_args "$@"

    ((EUID == 0)) || die "Run this script as root."

    for cmd in awk cmp cp curl dirname grep install ln mktemp mv pvesm rm; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    pvesm status >/dev/null 2>&1 || die "Could not query Proxmox storage. Run this on a Proxmox VE host."

    create_dest="${INSTALL_DIR}/${CREATE_FILE}"

    # Reuse valid storage defaults from an existing installed host profile unless explicitly
    # overridden by environment or CLI. This avoids prompting again on normal installer reruns.
    reuse_existing_storage_default IMPORT_STORAGE HOST_IMPORT_STORAGE import "Debian cloud-image import" "$create_dest"
    reuse_existing_storage_default SNIPPET_STORAGE HOST_SNIPPET_STORAGE snippets "cloud-init snippet" "$create_dest"
    reuse_existing_storage_default VM_STORAGE HOST_VM_STORAGE images "VM image" "$create_dest"

    # Resolve any remaining storage choices before downloading or installing anything. Snippet
    # storage is required; import and VM storage are optional host defaults and may remain blank.
    resolve_storage_selection IMPORT_STORAGE import "Debian cloud-image import" 0
    resolve_storage_selection SNIPPET_STORAGE snippets "cloud-init snippet" 1
    resolve_storage_selection VM_STORAGE images "VM image" 0

    snippet_volid="${SNIPPET_STORAGE}:snippets/${SNIPPET_FILE}"
    snippet_path=$(resolve_snippet_path "$snippet_volid")

    echo
    echo "Selected host storage defaults:"
    echo "  Import storage:  ${IMPORT_STORAGE:-<unconfigured>}"
    echo "  Snippet storage: $SNIPPET_STORAGE"
    echo "  VM storage:      ${VM_STORAGE:-<unconfigured>}"
    echo

    temp_dir=$(mktemp -d)
    TEMP_DIR=$temp_dir
    trap '[[ -n ${TEMP_DIR:-} ]] && rm -rf -- "$TEMP_DIR"' EXIT

    create_source="${temp_dir}/${CREATE_FILE}"
    build_source="${temp_dir}/${BUILD_FILE}"
    update_source="${temp_dir}/${UPDATE_FILE}"
    snippet_source="${temp_dir}/${SNIPPET_FILE}"

    build_dest="${INSTALL_DIR}/${BUILD_FILE}"
    update_dest="${INSTALL_DIR}/${UPDATE_FILE}"

    download_file "${REPO_RAW_BASE}/scripts/${CREATE_FILE}" "$create_source"
    download_file "${REPO_RAW_BASE}/scripts/${BUILD_FILE}" "$build_source"
    download_file "${REPO_RAW_BASE}/scripts/${UPDATE_FILE}" "$update_source"
    download_file "${REPO_RAW_BASE}/snippets/${SNIPPET_FILE}" "$snippet_source"

    preserve_existing_host_defaults "$create_dest" "$create_source"
    patch_create_storage_defaults "$create_source"

    bash -n "$create_source" || die "Downloaded ${CREATE_FILE} failed bash syntax validation."
    bash -n "$build_source" || die "Downloaded ${BUILD_FILE} failed bash syntax validation."
    bash -n "$update_source" || die "Downloaded ${UPDATE_FILE} failed bash syntax validation."

    IFS= read -r first_line < "$snippet_source" || true
    [[ $first_line == '#cloud-config' ]] ||
        die "Downloaded ${SNIPPET_FILE} does not begin with #cloud-config."

    install -d -o root -g root -m 0755 "$INSTALL_DIR"
    install -d -o root -g root -m 0755 "$(dirname -- "$snippet_path")"

    install_generic_script "$build_source" "$build_dest"
    install_generic_script "$update_source" "$update_dest"
    install_editable_file "$create_source" "$create_dest" 0755 CREATE_PRESERVED
    install_editable_file "$snippet_source" "$snippet_path" 0644 SNIPPET_PRESERVED

    ln -sfn "$snippet_path" "${INSTALL_DIR}/${SNIPPET_FILE}"

    command_dir=$(dirname -- "$COMMAND_LINK")
    install -d -o root -g root -m 0755 "$command_dir"
    ln -sfn "$create_dest" "$COMMAND_LINK"

    echo
    echo "Installation complete."
    echo
    echo "  Scripts:         $INSTALL_DIR"
    echo "  Command:         $COMMAND_LINK"
    echo "  Import storage:  ${IMPORT_STORAGE:-<unconfigured>}"
    echo "  Snippet storage: $SNIPPET_STORAGE"
    echo "  VM storage:      ${VM_STORAGE:-<unconfigured>}"
    echo "  Snippet volume:  $snippet_volid"
    echo "  Snippet path:    $snippet_path"
    echo

    if ((CREATE_PRESERVED)); then
        echo "Local ${CREATE_FILE} was preserved. Review the new repository version at:"
        echo "  ${create_dest}.dist"
        echo
    else
        echo "Configure any remaining host defaults in:"
        echo "  $create_dest"
        echo
    fi

    if ((SNIPPET_PRESERVED)); then
        echo "Local ${SNIPPET_FILE} was preserved. Review the new repository version at:"
        echo "  ${snippet_path}.dist"
        echo
    fi

    echo "Convenient snippet edit path:"
    echo "  ${INSTALL_DIR}/${SNIPPET_FILE}"
    echo
    echo "Create a VM with:"
    echo "  $COMMAND_LINK"
}

main "$@"
