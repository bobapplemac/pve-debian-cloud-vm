#!/bin/bash

# SPDX-License-Identifier: 0BSD
# Copyright (c) 2026 Andrew J. Moore
#
# ------------------------------------------------------------------------------------------
# File:        update-login-banner.sh
# Revision:    r5
# Modified:    2026-08-24
# Author:      Andrew J. Moore
# License:     Zero-Clause BSD (0BSD)
# Source:      https://github.com/bobapplemac/pve-debian-cloud-vm/blob/main/extras/login-banner/update-login-banner.sh
# Description: Maintains a dynamic console login banner containing the system short hostname,
#              FQDN, and current global IPv4 addresses. The banner is refreshed when IPv4
#              addressing or local hostname-resolution configuration changes, and unused virtual
#              consoles are restarted so the new banner is displayed.
#
# Requirements:
#              awk
#              cmp
#              cut
#              hostname
#              inotifywait
#              ip
#              paste
#              sed
#              systemctl
#              who
#
# Output:
#              /run/issue.d/50-network.issue
#
# Notes:
#              The banner is generated immediately at startup and then refreshed when the kernel
#              reports an IPv4 address change or when /etc/hostname or /etc/hosts changes. The two
#              independent event sources write into one shared stdout stream. The main loop reads
#              that stream and waits until it has been quiet for one second before rebuilding the
#              banner, which coalesces bursts of DHCP/network/hostname activity into one refresh.
#
#              /etc is watched rather than /etc/hostname and /etc/hosts directly because tools may
#              update those files by atomically replacing them. The inotify include filter limits
#              emitted events to only the two filenames that can affect the displayed hostname/FQDN.
#
#              If either long-running watcher exits unexpectedly, watch_changes() terminates the
#              other watcher and closes the event stream. The systemd service is configured to
#              restart the script, restoring both watches without requiring recovery logic here.
#
#              Active login sessions are never restarted. Only active getty services without a
#              logged-in user are restarted when the displayed banner content changes.
# ------------------------------------------------------------------------------------------

set -euo pipefail

BANNER_DIR="/run/issue.d"
BANNER_FILE="${BANNER_DIR}/50-network.issue"


update_banner() {
    local hostname_value
    local fqdn
    local ipv4
    local temp_file
    local tty

    hostname_value=$(hostname -s 2>/dev/null || true)
    fqdn=$(hostname -f 2>/dev/null || true)

    ipv4=$(
        ip -4 -o addr show scope global 2>/dev/null \
            | awk '{print $4}' \
            | cut -d/ -f1 \
            | paste -sd ',' - \
            | sed 's/,/, /g'
    )

    [[ -n $hostname_value ]] || hostname_value="<unknown>"
    [[ -n $fqdn ]] || fqdn="<unknown>"
    [[ -n $ipv4 ]] || ipv4="<unknown>"

    mkdir -p "$BANNER_DIR"
    temp_file=$(mktemp "${BANNER_DIR}/.50-network.issue.XXXXXX")

    printf '%s\n' \
        '------------------------------------------------------------' \
        " Hostname:  ${hostname_value}" \
        " FQDN:      ${fqdn}" \
        " IPv4:      ${ipv4}" \
        '------------------------------------------------------------' \
        '' \
        > "$temp_file"

    # Do nothing if the displayed information has not actually changed.
    if [[ -f $BANNER_FILE ]] && cmp -s "$temp_file" "$BANNER_FILE"; then
        rm -f -- "$temp_file"
        return
    fi

    mv -- "$temp_file" "$BANNER_FILE"

    # Refresh unused virtual consoles without disrupting logged-in users.
    for tty in tty{1..6}; do
        if systemctl is-active --quiet "getty@${tty}.service"; then
            if ! who | awk -v tty="$tty" '$2 == tty { found=1 } END { exit !found }'; then
                systemctl restart "getty@${tty}.service"
            fi
        fi
    done
}


watch_changes() {
    local ip_pid
    local files_pid

    # This function is intentionally an event producer rather than an event consumer.
    #
    # Both long-running commands below inherit this function's standard output. Because
    # watch_changes() itself is later piped into a single `while read` loop, output from either
    # command becomes an event on the same stream:
    #
    #   ip -4 monitor address ----\
    #                              +--> watch_changes stdout --> while read ...
    #   inotifywait /etc ---------/
    #
    # The actual event contents are not important. A complete line from either command simply
    # means "something relevant changed; consider rebuilding the banner."
    {
        # Watch the kernel's IPv4 address notifications using rtnetlink. This remains blocked until
        # an address is added, removed, or otherwise changed, so there is no network polling loop.
        #
        # Each event is written directly to this function's stdout, where the caller reads it.
        ip -4 monitor address &
        ip_pid=$!

        # Watch the /etc directory for changes that can affect hostname -s or hostname -f.
        #
        # We watch the directory instead of the two files directly because editors, hostname tools,
        # and configuration-management systems may update a file by writing a temporary file and
        # renaming it over the original. A watch attached directly to the old inode could then be
        # lost. Watching the parent directory reliably sees both in-place writes and replacements.
        #
        # --include restricts emitted events to /etc/hostname and /etc/hosts only, so unrelated
        # activity elsewhere in /etc never reaches the banner update loop.
        inotifywait -mq \
            -e close_write,moved_to,create \
            --include '(^|/)(hostname|hosts)$' \
            --format '%f' \
            /etc 2>/dev/null &
        files_pid=$!

        # Both watchers are expected to run indefinitely. If either one exits, wait -n returns.
        # At that point the combined event source is no longer trustworthy, so stop the remaining
        # watcher as well. Closing this function closes the pipe feeding the main read loop.
        #
        # The systemd unit uses Restart=always, so systemd will start a fresh copy of the script and
        # both watches will be re-established automatically.
        wait -n "$ip_pid" "$files_pid" || true
        kill "$ip_pid" "$files_pid" 2>/dev/null || true
        wait "$ip_pid" "$files_pid" 2>/dev/null || true
    }
}


# Generate the banner immediately when the service starts so the console has useful information
# even before any network or hostname change event occurs.
update_banner

# watch_changes() writes one line to stdout whenever either:
#
#   - the kernel reports an IPv4 address change, or
#   - /etc/hostname or /etc/hosts changes.
#
# The outer read blocks until the first relevant event arrives.
watch_changes | while read -r event; do

    # Once an event arrives, keep consuming additional events until the combined stream has been
    # quiet for one full second. Every successfully read line resets the one-second timeout.
    #
    # This is a debounce/settling window. During boot or DHCP configuration several closely spaced
    # events may occur as addresses are added, removed, routes settle, or hostname files are updated.
    # Without this loop, each event could cause update_banner() to restart idle gettys independently.
    #
    # Example:
    #
    #   0.0s  IPv4 event
    #   0.2s  IPv4 event
    #   0.7s  /etc/hosts event
    #   1.1s  IPv4 event
    #   2.1s  no event for one second -> continue
    #
    # All four events therefore result in one banner rebuild at approximately 2.1 seconds.
    while read -r -t 1 event; do :; done

    # update_banner() performs a second layer of protection: it renders the proposed banner to a
    # temporary file and compares it with the current banner. If hostname, FQDN, and IPv4 display
    # values are unchanged, it returns without replacing the file or restarting any getty service.
    update_banner
done
