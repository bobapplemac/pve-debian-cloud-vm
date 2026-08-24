#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        update-debian-image.sh
# Revision:    r7
# Modified:    2026-08-24
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/pve-debian-cloud-vm/blob/main/scripts/update-debian-image.sh
# Description: Downloads the latest dated Debian generic cloud image to a Proxmox storage
#              configured for import content and removes older images per the retention setting.
#
# Requirements:
#              awk
#              bash
#              curl
#              grep
#              pvesm
#              sed
#              sort
#              wget
#
# Environment:
#              DEBIAN_VERSION       Debian major version. Default: 13
#              DEBIAN_CODENAME      Debian codename. Default: trixie
#              IMPORT_STORAGE       Proxmox storage ID for import content. Required.
#              IMAGE_ARCH           Debian image architecture. Default: amd64
#              IMAGE_VARIANT        Debian cloud image variant. Default: genericcloud
#              KEEP_IMAGES          Number of cached images to retain. Default: 3
#              BASE_URL             Override Debian cloud-image base URL.
#              FORCE_CHECK          Force a remote refresh even if one succeeded today. Default: 0
#
# Notes:
#              Configuration precedence is: built-in defaults < environment < CLI arguments.
#              IMPORT_STORAGE has no built-in default and must be supplied by environment or
#              CLI. It must be enabled, active, and support the Proxmox 'import' content type.
#              Physical paths are resolved by Proxmox with pvesm rather than hardcoded.
#              Downloads are written to a temporary .part file and renamed only after wget
#              completes successfully. Existing current images are not downloaded again.
#
#              Remote lookup or download failures are non-fatal when a usable matching image is
#              already cached locally. In that case the updater prints a warning and returns
#              success so VM creation can continue with the newest cached image. Local storage,
#              configuration, and cache-availability errors remain fatal.
#
#              Successful remote refreshes are recorded as timestamp files under:
#                /var/lib/pve-debian-cloud-vm/update-debian-image/images/
#              Each extensionless filename identifies an image family. If a usable cached image
#              exists and its state file was refreshed today, the remote lookup is skipped.
#              --force-check (or FORCE_CHECK=1) bypasses this once-per-day optimization.
# ------------------------------------------------------------------------------------------

set -euo pipefail

# ------------------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------------------

DEBIAN_VERSION="${DEBIAN_VERSION:-13}"
DEBIAN_CODENAME="${DEBIAN_CODENAME:-trixie}"
IMPORT_STORAGE="${IMPORT_STORAGE:-}"
IMAGE_ARCH="${IMAGE_ARCH:-amd64}"
IMAGE_VARIANT="${IMAGE_VARIANT:-genericcloud}"
KEEP_IMAGES="${KEEP_IMAGES:-3}"
BASE_URL="${BASE_URL:-}"
FORCE_CHECK="${FORCE_CHECK:-0}"

STATE_DIR="/var/lib/pve-debian-cloud-vm/update-debian-image"
IMAGE_STATE_DIR="$STATE_DIR/images"
IMAGE_KEY=""
IMAGE_STATE_FILE=""


die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: update-debian-image.sh [options]

Options:
  --debian-version VERSION    Debian major version
  --debian-codename NAME     Debian codename
  --import-storage STORAGE    Proxmox storage ID containing import content
  --image-arch ARCH           Image architecture
  --image-variant VARIANT     Image variant, e.g. genericcloud
  --keep-images COUNT         Number of images to retain
  --base-url URL              Override Debian cloud-image base URL
  --force-check               Check Debian even if a successful refresh already occurred today
  -h, --help                  Show this help

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
            --import-storage)
                require_value "$1" "${2-}"
                IMPORT_STORAGE=$2
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
            --force-check)
                FORCE_CHECK=1
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


is_true() {
    case "${1,,}" in
        1|y|yes|true|on) return 0 ;;
        *) return 1 ;;
    esac
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

resolve_import_path() {
    local volid=$1
    local path

    path=$(pvesm path "$volid" 2>/dev/null) ||
        die "Could not resolve Proxmox volume path: $volid"

    [[ -n $path ]] || die "Proxmox returned an empty path for volume: $volid"
    printf '%s\n' "$path"
}


find_latest_cached_volid() {
    local -a volids=()
    local volid
    local path

    mapfile -t volids < <(list_matching_import_volids | sort -r)

    for volid in "${volids[@]}"; do
        path=$(pvesm path "$volid" 2>/dev/null || true)
        [[ -n $path && -f $path ]] || continue

        printf '%s\n' "$volid"
        return 0
    done

    return 1
}


continue_with_cached_image() {
    local reason=$1
    local cached_volid

    cached_volid=$(find_latest_cached_volid) || return 1

    echo "WARNING: $reason" >&2
    echo "WARNING: Continuing with newest cached image: $cached_volid" >&2
    return 0
}


image_was_refreshed_today() {
    [[ -f $IMAGE_STATE_FILE ]] || return 1
    [[ $(date -r "$IMAGE_STATE_FILE" +%F) == "$(date +%F)" ]]
}


record_successful_refresh() {
    mkdir -p -- "$IMAGE_STATE_DIR"
    touch -- "$IMAGE_STATE_FILE"
}


# ------------------------------------------------------------------------------------------
# Preflight
# ------------------------------------------------------------------------------------------

preflight() {
    local cmd

    ((EUID == 0)) || die "Run this script as root."

    for cmd in awk curl date grep pvesm sed sort wget; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    [[ $DEBIAN_VERSION =~ ^[0-9]+$ ]] || die "DEBIAN_VERSION must be numeric."
    [[ $KEEP_IMAGES =~ ^[0-9]+$ ]] || die "KEEP_IMAGES must be a non-negative integer."
    [[ -n $IMPORT_STORAGE ]] || die "IMPORT_STORAGE must be specified."

    storage_is_active_with_content "$IMPORT_STORAGE" import ||
        die "Storage '$IMPORT_STORAGE' is not active and enabled with content type 'import'."

    if [[ -z $BASE_URL ]]; then
        BASE_URL="https://cloud.debian.org/images/cloud/${DEBIAN_CODENAME}"
    fi

    BASE_URL=${BASE_URL%/}

    # Build the state key only after environment and CLI configuration has been resolved.
    IMAGE_KEY="debian-${DEBIAN_VERSION}-${DEBIAN_CODENAME}-${IMAGE_VARIANT}-${IMAGE_ARCH}"
    IMAGE_STATE_FILE="$IMAGE_STATE_DIR/$IMAGE_KEY"
}


# ------------------------------------------------------------------------------------------
# Image update
# ------------------------------------------------------------------------------------------

find_latest_build() {
    curl -fsSL "$BASE_URL/" \
        | grep -oE 'href="[0-9]{8}-[0-9]{4}/"' \
        | sed -E 's/^href="//; s#/"$##' \
        | sort \
        | tail -n 1
}

prune_old_images() {
    local -a volids=()
    local volid
    local path
    local i

    ((KEEP_IMAGES > 0)) || return 0

    mapfile -t volids < <(list_matching_import_volids | sort -r)
    ((${#volids[@]} > KEEP_IMAGES)) || return 0

    for ((i = KEEP_IMAGES; i < ${#volids[@]}; i++)); do
        volid=${volids[$i]}
        path=$(resolve_import_path "$volid")
        echo "Removing old image: $volid"
        rm -f -- "$path"
    done
}

update_image() {
    local cached_volid=""
    local latest_tag
    local qcow_file
    local file_url
    local target_volid
    local target_file
    local target_dir
    local temp_file

    # A usable cached image plus a successful refresh already completed today makes the normal
    # invocation intentionally cheap. The state timestamp is only written after a successful
    # remote lookup that either confirms the current image or completes a new download.
    #
    # --force-check bypasses this fast path, and the absence of a usable cached image always forces
    # a remote lookup regardless of the state-file timestamp.
    cached_volid=$(find_latest_cached_volid || true)

    if [[ -n $cached_volid ]] &&
       ! is_true "$FORCE_CHECK" &&
       image_was_refreshed_today; then
        echo "Debian image already refreshed today; using cached image: $cached_volid"
        return 0
    fi

    # Determine the newest build published by Debian. Network, DNS, TLS, HTTP, or parsing failures
    # are allowed to fall back to an existing local image, but do not update the state timestamp:
    # a later invocation today should try the remote refresh again.
    if ! latest_tag=$(find_latest_build) || [[ -z $latest_tag ]]; then
        if continue_with_cached_image \
            "Could not determine the latest Debian build at $BASE_URL/."; then
            return 0
        fi

        die "Could not determine the latest Debian build at $BASE_URL/, and no usable cached Debian ${DEBIAN_VERSION} ${IMAGE_VARIANT} ${IMAGE_ARCH} image is available."
    fi

    qcow_file="debian-${DEBIAN_VERSION}-${IMAGE_VARIANT}-${IMAGE_ARCH}-${latest_tag}.qcow2"
    file_url="${BASE_URL}/${latest_tag}/${qcow_file}"
    target_volid="${IMPORT_STORAGE}:import/${qcow_file}"
    target_file=$(resolve_import_path "$target_volid")
    target_dir=$(dirname -- "$target_file")
    temp_file="${target_file}.part"

    mkdir -p -- "$target_dir"
    [[ -w $target_dir ]] || die "Import directory is not writable: $target_dir"

    # The remote lookup succeeded and confirmed that the newest published build is already cached.
    # Record the successful refresh so later VM creations today can skip the online lookup.
    if [[ -f $target_file ]]; then
        echo "Already up-to-date: $target_volid"
        prune_old_images
        record_successful_refresh
        return 0
    fi

    echo "Downloading new Debian cloud image: $qcow_file"
    echo "Destination: $target_volid"
    rm -f -- "$temp_file"

    # A failed download may fall back to a previous cached image, but intentionally does not record
    # a successful refresh. This lets a subsequent invocation retry the download later the same day.
    # The .part file is always removed so an interrupted download cannot be mistaken for an image.
    if ! wget -O "$temp_file" "$file_url"; then
        rm -f -- "$temp_file"

        if continue_with_cached_image "Download failed: $file_url"; then
            return 0
        fi

        die "Download failed: $file_url, and no usable cached Debian ${DEBIAN_VERSION} ${IMAGE_VARIANT} ${IMAGE_ARCH} image is available."
    fi

    mv -- "$temp_file" "$target_file"
    prune_old_images
    record_successful_refresh

    echo "Updated Debian image saved as: $target_volid"
}


# ------------------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------------------

main() {
    parse_args "$@"
    preflight
    update_image
}

main "$@"
