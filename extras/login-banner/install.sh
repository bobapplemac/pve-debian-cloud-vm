#!/bin/bash

# Quick start:
# curl -fsSL https://raw.githubusercontent.com/bobapplemac/pve-debian-cloud-vm/main/extras/login-banner/install.sh | bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        install.sh
# Revision:    r2
# Modified:    2026-08-24
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/pve-debian-cloud-vm/blob/main/extras/login-banner/install.sh
# Description: Installs required Debian packages, downloads the dynamic console login-banner
#              script and systemd service, then enables and starts the service.
#
# Requirements:
#              apt-get
#              dpkg-query
#
# Packages:
#              bash
#              ca-certificates
#              coreutils
#              curl
#              diffutils
#              hostname
#              inotify-tools
#              iproute2
#              mawk
#              sed
#              systemd
#
# Installs:
#              /usr/local/libexec/update-login-banner.sh
#              /etc/systemd/system/update-login-banner.service
#
# Notes:
#              Required packages are installed only when missing. Existing component files are
#              replaced by the current repository versions. The service is restarted after
#              installation so updates take effect immediately.
# ------------------------------------------------------------------------------------------

set -euo pipefail

REPO_RAW_BASE="https://raw.githubusercontent.com/bobapplemac/pve-debian-cloud-vm/main/extras/login-banner"

SCRIPT_URL="${REPO_RAW_BASE}/update-login-banner.sh"
SERVICE_URL="${REPO_RAW_BASE}/update-login-banner.service"

SCRIPT_DEST="/usr/local/libexec/update-login-banner.sh"
SERVICE_DEST="/etc/systemd/system/update-login-banner.service"

REQUIRED_PACKAGES=(
    bash
    ca-certificates
    coreutils
    curl
    diffutils
    hostname
    inotify-tools
    iproute2
    mawk
    sed
    systemd
)

TEMP_DIR=""


die() {
    echo "ERROR: $*" >&2
    exit 1
}


ensure_packages() {
    local package
    local status
    local -a missing_packages=()

    for package in "${REQUIRED_PACKAGES[@]}"; do
        status=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)
        [[ $status == "install ok installed" ]] || missing_packages+=("$package")
    done

    if ((${#missing_packages[@]} == 0)); then
        echo "Required packages are already installed."
        return 0
    fi

    echo "Installing required packages: ${missing_packages[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "${missing_packages[@]}"
}


download_file() {
    local url=$1
    local destination=$2

    echo "Downloading: $url"
    curl -fsSL --retry 3 --retry-delay 1 "$url" -o "$destination" ||
        die "Download failed: $url"
}


main() {
    local cmd
    local script_source
    local service_source

    ((EUID == 0)) || die "Run this installer as root."

    for cmd in apt-get dpkg-query; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found."
    done

    ensure_packages

    for cmd in bash cmp curl hostname inotifywait install ip mktemp rm systemctl who; do
        command -v "$cmd" >/dev/null 2>&1 ||
            die "Required command '$cmd' was not found after package installation."
    done

    TEMP_DIR=$(mktemp -d)
    trap '[[ -n ${TEMP_DIR:-} ]] && rm -rf -- "$TEMP_DIR"' EXIT

    script_source="${TEMP_DIR}/update-login-banner.sh"
    service_source="${TEMP_DIR}/update-login-banner.service"

    download_file "$SCRIPT_URL" "$script_source"
    download_file "$SERVICE_URL" "$service_source"

    bash -n "$script_source" ||
        die "Downloaded update-login-banner.sh failed Bash syntax validation."

    grep -q '^\[Unit\]$' "$service_source" ||
        die "Downloaded update-login-banner.service does not appear to be a systemd unit."

    install -D -o root -g root -m 0755 "$script_source" "$SCRIPT_DEST"
    install -D -o root -g root -m 0644 "$service_source" "$SERVICE_DEST"

    systemctl daemon-reload
    systemctl enable update-login-banner.service
    systemctl restart update-login-banner.service

    echo
    echo "Login banner installed."
    echo
    echo "  Script:  $SCRIPT_DEST"
    echo "  Service: $SERVICE_DEST"
    echo
    systemctl --no-pager --full status update-login-banner.service || true
}


main "$@"
