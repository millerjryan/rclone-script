#!/usr/bin/env bash
set -Eeuo pipefail

NFS_SERVER=192.168.1.4
SHARES=(/volume1/media /volume1/downloads)
MOUNTS=(/mnt/media /mnt/downloads)
FSTAB=/etc/fstab
CTID=
MP_KEYS=()
ACCESS_USER=
INSTALL_RCLONE=no
PACKAGE_MANAGER=

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local status=$?
    printf 'Setup failed at line %s (exit %s). Completed changes are retained; fix the error and rerun.\n' \
        "$1" "$status" >&2
    exit "$status"
}

trap 'on_error "$LINENO"' ERR

check_environment() {
    [[ $EUID -eq 0 ]] || die "Run this script as root on the Proxmox host."
    local command
    for command in pct pveversion apt-get systemctl findmnt mountpoint flock; do
        command -v "$command" >/dev/null || die "Required host command not found: $command"
    done
    pveversion >/dev/null
    exec 9>/run/lock/setup-nzbget-storage.lock
    flock -n 9 || die "Another storage setup is already running."
}

select_container() {
    read -r -p 'Container ID: ' CTID
    [[ $CTID =~ ^[1-9][0-9]+$ ]] || die "Enter a numeric container ID."
    pct config "$CTID" >/dev/null
    [[ $(pct status "$CTID") == 'status: running' ]] ||
        die "Start container $CTID before running this script."
    pct exec "$CTID" -- sh -c '
        for tool in sh find id test mktemp rmdir cat; do
            command -v "$tool" >/dev/null || exit 1
        done
        command -v runuser >/dev/null || command -v su >/dev/null
    ' || die "The container needs a POSIX shell and standard Linux utilities."
    [[ -z $(pct config "$CTID" | sed -n '/^\[.*\]$/p') ]] ||
        die "Resolve pending container configuration changes before continuing."
}

select_options() {
    local answer
    read -r -p 'Container user to check for read/write access (e.g. nzbget, sonarr) [root]: ' ACCESS_USER
    ACCESS_USER=${ACCESS_USER:-root}
    [[ $ACCESS_USER =~ ^[a-zA-Z_][a-zA-Z0-9_.-]*[$]?$ ]] ||
        die "Enter a container username, not a UID."
    pct exec "$CTID" -- id "$ACCESS_USER" >/dev/null ||
        die "User $ACCESS_USER does not exist in container $CTID."
    PACKAGE_MANAGER=$(pct exec "$CTID" -- sh -c '
        for manager in apt-get apk dnf yum zypper pacman; do
            if command -v "$manager" >/dev/null; then
                printf "%s\n" "$manager"
                break
            fi
        done
    ')
    if [[ -z $PACKAGE_MANAGER ]]; then
        printf 'No supported package manager found; skipping rclone installation. Mount setup is still supported.\n'
    else
        read -r -p "Install rclone in container $CTID using $PACKAGE_MANAGER? [Y/n] " answer
        case $answer in
            ''|y|Y) INSTALL_RCLONE=yes ;;
            n|N) INSTALL_RCLONE=no ;;
            *) die "Answer y or n for rclone installation." ;;
        esac
    fi
}

plan_bind_mounts() {
    local config line key value index slot existing
    config=$(pct config "$CTID")
    [[ ! $config =~ (^|$'\n')lock: ]] || die "Container $CTID is locked."
    for index in "${!MOUNTS[@]}"; do
        existing=
        while IFS= read -r line; do
            [[ $line =~ ^(mp[0-9]+):[[:space:]](.*)$ ]] || continue
            key=${BASH_REMATCH[1]}
            value=${BASH_REMATCH[2]}
            if [[ ,$value, == *",mp=${MOUNTS[$index]},"* ]]; then
                [[ ${value%%,*} == "${MOUNTS[$index]}" ]] ||
                    die "${MOUNTS[$index]} is already mapped from another source ($key)."
                [[ -z $existing ]] || die "Duplicate bind mounts for ${MOUNTS[$index]}."
                [[ ,$value, != *',ro=1,'* ]] || die "$key is read-only; review it before continuing."
                existing=$key
            fi
        done <<< "$config"
        if [[ -z $existing ]]; then
            pct exec "$CTID" -- sh -eu -c '
                test ! -L "$1"
                if test -e "$1"; then
                    test -d "$1"
                    contents=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)
                    test -z "$contents"
                fi
            ' sh "${MOUNTS[$index]}" ||
                die "Container path ${MOUNTS[$index]} is not an empty directory or is a symlink; move existing data first."
            for ((slot = 0; slot < 256; slot++)); do
                key=mp$slot
                if ! grep -q "^${key}:" <<< "$config"; then
                    existing=$key
                    config+=$'\n'"$key: ${MOUNTS[$index]},mp=${MOUNTS[$index]}"
                    break
                fi
            done
        fi
        [[ -n $existing ]] || die "No free Proxmox mount-point slots."
        MP_KEYS+=("$existing")
    done
}

fstab_source() {
    local entry status
    if entry=$(findmnt --fstab --mountpoint "$1" --noheadings --output SOURCE); then
        printf '%s\n' "$entry"
    else
        status=$?
        # findmnt returns 1 when the target has no fstab entry.
        [[ $status -eq 1 ]] || return "$status"
    fi
}

check_host_mounts() {
    local index target source filesystem entry contents
    for index in "${!MOUNTS[@]}"; do
        target=${MOUNTS[$index]}
        source=$NFS_SERVER:${SHARES[$index]}
        [[ ! -L $target ]] || die "$target must not be a symbolic link."
        [[ ! -e $target || -d $target ]] || die "$target is not a directory."
        entry=$(fstab_source "$target")
        if [[ -n $entry && $entry != "$source" ]]; then
            die "Conflicting fstab entry for $target: $entry"
        fi
        if mountpoint -q "$target"; then
            entry=$(findmnt --mountpoint "$target" --noheadings --output SOURCE)
            filesystem=$(findmnt --mountpoint "$target" --noheadings --output FSTYPE)
            [[ $entry == "$source" && $filesystem == nfs* ]] ||
                die "$target already contains a different mount."
        elif [[ -d $target ]]; then
            contents=$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)
            [[ -z $contents ]] ||
                die "$target is not empty; refusing to hide existing files."
        fi
    done
}

configure_host_mounts() {
    local index target source entry options
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y nfs-common
    cp --preserve=all "$FSTAB" "${FSTAB}.nzbget.$(date +%Y%m%d%H%M%S).bak"
    for index in "${!MOUNTS[@]}"; do
        target=${MOUNTS[$index]}
        source=$NFS_SERVER:${SHARES[$index]}
        mkdir -p "$target"
        entry=$(fstab_source "$target")
        if [[ -z $entry ]]; then
            printf '%s %s nfs rw,hard,_netdev 0 0\n' "$source" "$target" >> "$FSTAB"
        fi
    done
    systemctl daemon-reload
    for target in "${MOUNTS[@]}"; do
        if ! mountpoint -q "$target"; then
            mount "$target"
        fi
        options=$(findmnt --mountpoint "$target" --noheadings --output OPTIONS)
        [[ ,$options, != *,ro,* ]] ||
            die "$target is mounted read-only."
    done
}

install_rclone() {
    [[ $INSTALL_RCLONE == yes ]] || return 0
    case $PACKAGE_MANAGER in
        apt-get)
            pct exec "$CTID" -- apt-get update
            pct exec "$CTID" -- env DEBIAN_FRONTEND=noninteractive apt-get install -y rclone
            ;;
        apk) pct exec "$CTID" -- apk add --no-cache rclone ;;
        dnf|yum) pct exec "$CTID" -- "$PACKAGE_MANAGER" install -y rclone ;;
        zypper) pct exec "$CTID" -- zypper --non-interactive install rclone ;;
        pacman) pct exec "$CTID" -- pacman -Syu --needed --noconfirm rclone ;;
        *) die "Unsupported package manager: $PACKAGE_MANAGER" ;;
    esac
    pct exec "$CTID" -- rclone version
}

configure_container() {
    local directory index config key
    directory=/etc/systemd/system/pve-container@${CTID}.service.d
    mkdir -p "$directory"
    cat > "$directory/nzbget-storage.conf" <<'UNIT'
[Unit]
RequiresMountsFor=/mnt/media /mnt/downloads
After=network-online.target

[Service]
ExecStartPre=/usr/bin/mountpoint -q /mnt/media
ExecStartPre=/usr/bin/mountpoint -q /mnt/downloads
UNIT
    systemctl daemon-reload
    cp --preserve=all "/etc/pve/lxc/${CTID}.conf" \
        "/root/nzbget-${CTID}.$(date +%Y%m%d%H%M%S).conf.bak"
    printf 'Shutting down container %s to apply bind mounts...\n' "$CTID"
    pct shutdown "$CTID" --timeout 60
    [[ $(pct status "$CTID") == 'status: stopped' ]] ||
        die "Container did not stop; no bind mounts were changed."
    config=$(pct config "$CTID")
    for index in "${!MOUNTS[@]}"; do
        key=${MP_KEYS[$index]}
        if ! grep -q "^${key}:" <<< "$config"; then
            pct set "$CTID" "--$key" "${MOUNTS[$index]},mp=${MOUNTS[$index]}"
        fi
    done
    pct start "$CTID"
}

verify_container_access() {
    local script
    script='
        set -eu
        for target in /mnt/media /mnt/downloads; do
            printf "Checking read/write access to %s...\n" "$target"
            test -d "$target"
            test -r "$target"
            test -x "$target"
            probe=$(mktemp -d "$target/.storage-access.XXXXXXXX")
            rmdir "$probe"
        done
    '
    if ! pct exec "$CTID" -- sh -eu -c '
        if command -v runuser >/dev/null; then
            exec runuser -u "$1" -- sh -eu -c "$2"
        fi
        exec su -s /bin/sh -c "$2" "$1"
    ' sh "$ACCESS_USER" "$script"; then
        printf 'NAS access failed for container user %s.\n' "$ACCESS_USER" >&2
        pct exec "$CTID" -- id "$ACCESS_USER"
        printf 'Container UID/GID mappings (container ID -> host ID -> count):\n' >&2
        pct exec "$CTID" -- cat /proc/self/uid_map /proc/self/gid_map
        die "Grant the mapped UID/GID read/write access on the NAS exports, then rerun. Do not recursively chown your library."
    fi
}

main() {
    local answer
    check_environment
    select_container
    select_options
    plan_bind_mounts
    check_host_mounts
    printf '\nWill mount %s:/volume1/{media,downloads} at /mnt/{media,downloads}\n' "$NFS_SERVER"
    printf 'on this host and in container %s. Check access as: %s. Install rclone: %s.\n' \
        "$CTID" "$ACCESS_USER" "$INSTALL_RCLONE"
    if [[ $INSTALL_RCLONE == yes && $PACKAGE_MANAGER == pacman ]]; then
        printf 'Arch Linux requires a full system upgrade with pacman -Syu to safely install rclone.\n'
    fi
    printf 'The container will be shut down and restarted. Application settings will not change.\n'
    read -r -p 'Proceed? [y/N] ' answer
    [[ $answer == y || $answer == Y ]] || die "Cancelled; no configuration changes made."
    configure_host_mounts
    install_rclone
    configure_container
    verify_container_access
    printf '\nDone. Both shares are persistent and writable by container user %s.\n' "$ACCESS_USER"
    printf 'Use /mnt/downloads and /mnt/media in your application settings.\n'
    if [[ $INSTALL_RCLONE == yes ]]; then
        printf 'rclone is installed inside container %s; run "rclone config" there to add remotes.\n' "$CTID"
    fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
