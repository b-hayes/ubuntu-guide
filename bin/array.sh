#!/usr/bin/env bash
set -euEo pipefail

FSTAB="/etc/fstab"
ARRAY_MOUNT="/array"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

# ── error handler ─────────────────────────────────────────────────────────────
_error_handler() {
    local line="$1" cmd="$2"
    echo -e "\n${RED}${BOLD}Error on line ${line}:${NC} ${cmd}"
    exit 1
}
trap '_error_handler $LINENO "$BASH_COMMAND"' ERR

# ── shared per-drive logic ────────────────────────────────────────────────────
# Usage: _prepare_drive <device> <label> <mount_point> <owner>
# Formats (if needed), creates mount point, adds individual fstab entry.
# Sets global _PREPARED_UUID to the drive's UUID after completion.
_PREPARED_UUID=""
_prepare_drive() {
    local device="$1" label="$2" mount_point="$3" drive_owner="$4"

    echo -e "${BOLD}Device:${NC}      $device"
    echo -e "${BOLD}Label:${NC}       $label"
    echo -e "${BOLD}Mount point:${NC} $mount_point"
    echo -e "${BOLD}Owner:${NC}       $drive_owner"
    echo ""

    # Format or relabel
    if lsblk -o FSTYPE --noheadings -n "$device" 2>/dev/null | grep -q '\S'; then
        echo -e "${GREEN}Already formatted — skipping mkfs.${NC}"
        echo -e "${YELLOW}Running:${NC} sudo xfs_admin -L \"$label\" $device"
        sudo xfs_admin -L "$label" "$device"
    else
        local parent_disk
        parent_disk=$(echo "$device" | sed 's/p\?[0-9]*$//')
        if [[ "$parent_disk" != "$device" ]]; then
            echo -e "${YELLOW}Running:${NC} sudo parted $parent_disk --script mklabel gpt mkpart primary 0% 100%"
            sudo parted "$parent_disk" --script mklabel gpt mkpart primary 0% 100%
            sleep 1
        fi
        echo -e "${YELLOW}Running:${NC} sudo mkfs.xfs -L \"$label\" $device"
        sudo mkfs.xfs -L "$label" "$device"
    fi
    echo -e "${GREEN}Formatted.${NC}"

    # Get UUID
    _PREPARED_UUID=$(sudo blkid -s UUID -o value "$device")
    echo -e "UUID: ${BOLD}$_PREPARED_UUID${NC}"

    # Create mount point
    echo -e "${YELLOW}Running:${NC} sudo install -d -o $drive_owner -g $drive_owner $mount_point"
    sudo install -d -o "$drive_owner" -g "$drive_owner" "$mount_point"

    # Add individual drive fstab entry
    local drive_line="/dev/disk/by-uuid/$_PREPARED_UUID  $mount_point  auto  nosuid,nodev,nofail,x-gvfs-show  0  0"
    echo -e "${YELLOW}Adding to fstab:${NC} $drive_line"
    echo "$drive_line" | sudo tee -a "$FSTAB"
}

# ── add command ───────────────────────────────────────────────────────────────

cmd_add() {
    local device="${1:?Usage: array add <device> <label> <mountpoint>}"
    local label="${2:?Usage: array add <device> <label> <mountpoint>}"
    local mount_point="${3:?Usage: array add <device> <label> <mountpoint>}"

    echo -e "${YELLOW}Detected drives:${NC}"
    lsblk -e 7 -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT
    echo ""

    local default_owner="${SUDO_USER:-$(whoami)}"
    read -r -p "Drive owner [$default_owner]: " drive_owner
    drive_owner="${drive_owner:-$default_owner}"
    echo ""

    _prepare_drive "$device" "$label" "$mount_point" "$drive_owner"

    # Update mergerfs fstab line
    local mergerfs_line old_sources
    mergerfs_line=$(grep -v '^#' "$FSTAB" | grep 'mergerfs' || true)
    if [[ -z "$mergerfs_line" ]]; then
        echo -e "${RED}No mergerfs line found in $FSTAB.${NC}"; exit 1
    fi
    old_sources=$(echo "$mergerfs_line" | awk '{print $1}')
    echo -e "${YELLOW}Updating mergerfs line in fstab${NC}"
    sudo sed -i "s|${old_sources}|${old_sources}:${mount_point}|" "$FSTAB"

    # Mount and live-add to pool
    echo -e "${YELLOW}Running:${NC} sudo systemctl daemon-reload"
    sudo systemctl daemon-reload
    echo -e "${YELLOW}Running:${NC} sudo mount $mount_point"
    sudo mount "$mount_point"
    echo -e "${YELLOW}Running:${NC} sudo setfattr -n user.mergerfs.branches -v '+>$mount_point' $ARRAY_MOUNT/.mergerfs"
    sudo setfattr -n user.mergerfs.branches -v "+>${mount_point}" "$ARRAY_MOUNT/.mergerfs"

    # Verify
    echo ""
    df -h "$ARRAY_MOUNT" /mnt/drive*
    echo ""
    echo -e "${GREEN}${BOLD}Done.${NC} $device added to the pool as $mount_point."
}

# ── setup command ─────────────────────────────────────────────────────────────
# NOTE: This command is untested. Review carefully before running on a real system.

cmd_setup() {
    # Install mergerfs
    echo -e "${BOLD}Installing mergerfs...${NC}"
    sudo apt install -y mergerfs
    echo -e "${GREEN}mergerfs installed.${NC}"
    echo ""

    # Ask for array mount point
    read -r -p "Array mount point [/array]: " array_mount
    array_mount="${array_mount:-/array}"
    ARRAY_MOUNT="$array_mount"

    # Ask for shared options upfront
    local default_owner="${SUDO_USER:-$(whoami)}"
    read -r -p "Drive owner [$default_owner]: " drive_owner
    drive_owner="${drive_owner:-$default_owner}"

    read -r -p "Label prefix [Array_]: " label_prefix
    label_prefix="${label_prefix:-Array_}"

    read -r -p "Mount point prefix [/mnt/drive]: " mp_prefix
    mp_prefix="${mp_prefix:-/mnt/drive}"
    echo ""

    # Show available drives
    echo -e "${YELLOW}Available drives:${NC}"
    lsblk -e 7 -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT
    echo ""

    # Let user select drives one by one
    local selected_devices=()
    while true; do
        read -r -p "Enter device to add (e.g. /dev/sdb1), or press Enter when done: " dev
        [[ -z "$dev" ]] && break
        if [[ ! -b "$dev" ]]; then
            echo -e "${RED}$dev is not a block device, try again.${NC}"
            continue
        fi
        selected_devices+=("$dev")
        echo -e "${GREEN}Added $dev${NC}"
    done

    if [[ ${#selected_devices[@]} -eq 0 ]]; then
        echo -e "${RED}No drives selected. Aborting.${NC}"; exit 1
    fi

    # Create array mount point owned by the user
    echo ""
    echo -e "${YELLOW}Creating array mount point:${NC} $ARRAY_MOUNT"
    sudo install -d -o "$drive_owner" -g "$drive_owner" "$ARRAY_MOUNT"

    # Process each selected drive
    local mergerfs_sources=""
    local mount_points=()
    local idx=0
    for device in "${selected_devices[@]}"; do
        local label mount_point
        label=$(printf "%s%02d" "$label_prefix" "$idx")
        mount_point=$(printf "%s%02d" "$mp_prefix" "$idx")
        mount_points+=("$mount_point")

        echo ""
        echo -e "${BOLD}── Drive $((idx + 1)) of ${#selected_devices[@]} ──────────────────────────────${NC}"
        _prepare_drive "$device" "$label" "$mount_point" "$drive_owner"

        mergerfs_sources="${mergerfs_sources:+${mergerfs_sources}:}${mount_point}"
        idx=$((idx + 1))
    done

    # Write mergerfs fstab line
    local mergerfs_line="$mergerfs_sources  $ARRAY_MOUNT  mergerfs  cache.files=off,category.create=pfrd,func.getattr=newest,dropcacheonclose=false,allow_other  0  0"
    echo ""
    echo -e "${YELLOW}Adding mergerfs line to fstab:${NC} $mergerfs_line"
    echo "$mergerfs_line" | sudo tee -a "$FSTAB"

    # Mount individual drives then the array
    echo -e "${YELLOW}Running:${NC} sudo systemctl daemon-reload"
    sudo systemctl daemon-reload
    for mp in "${mount_points[@]}"; do
        echo -e "${YELLOW}Running:${NC} sudo mount $mp"
        sudo mount "$mp"
    done
    echo -e "${YELLOW}Running:${NC} sudo mount $ARRAY_MOUNT"
    sudo mount "$ARRAY_MOUNT"

    # Verify
    echo ""
    df -h "$ARRAY_MOUNT" "${mount_points[@]}"
    echo ""
    echo -e "${GREEN}${BOLD}Setup complete.${NC} Array mounted at $ARRAY_MOUNT with ${#selected_devices[@]} drive(s)."
}

# ── list command ──────────────────────────────────────────────────────────────

cmd_list() {
    local mergerfs_sources
    mergerfs_sources=$(grep -v '^#' "$FSTAB" | grep 'mergerfs' | awk '{print $1}' || true)

    echo -e "${BOLD}In the array:${NC}"
    if [[ -n "$mergerfs_sources" ]]; then
        IFS=':' read -ra pool_mounts <<< "$mergerfs_sources"
        for mp in "${pool_mounts[@]}"; do
            local device label size used avail usepct
            device=$(lsblk -o MOUNTPOINT,NAME -p --noheadings -l | awk -v mp="$mp" '$1 == mp {print $2}')
            label=$(lsblk -o MOUNTPOINT,LABEL --noheadings -l | awk -v mp="$mp" '$1 == mp {print $2}')
            read -r size used avail usepct _ < <(df -h --output=size,used,avail,pcent "$mp" | tail -1)
            printf "  %-14s  %-10s  %-10s  size:%-6s used:%-6s avail:%-6s (%s)\n" \
                "$mp" "${device:-?}" "${label:--}" "$size" "$used" "$avail" "$usepct"
        done
    else
        echo "  No mergerfs line found in $FSTAB"
    fi

    echo ""
    echo -e "${BOLD}Not in the array:${NC}"
    local found=0
    while read -r name size fstype label; do
        # skip if any descendant is mounted
        if lsblk -o MOUNTPOINT --noheadings "$name" 2>/dev/null | grep -q '\S'; then
            continue
        fi
        # skip if it has children (show partitions, not parent disks)
        if [[ $(lsblk -l --noheadings "$name" 2>/dev/null | wc -l) -gt 1 ]]; then
            continue
        fi
        local uuid
        uuid=$(sudo blkid -s UUID -o value "$name" 2>/dev/null || true)
        printf "  %-14s  %-10s  fstype:%-6s label:%-10s uuid:%s\n" \
            "$name" "$size" "${fstype:--}" "${label:--}" "${uuid:--}"
        echo -e "  ${YELLOW}→ array add $name ${label:+$label }<mountpoint>${NC}"
        echo ""
        found=1
    done < <(lsblk -e 7 -p -l -o NAME,SIZE,FSTYPE,LABEL --noheadings | awk '$4 == ""')
    [[ $found -eq 0 ]] && echo "  None found."
}

# ── remove command ─────────────────────────────────────────────────────────────

cmd_remove() {
    local mount_point="${1:?Usage: array remove <mountpoint>}"

    # Check it's actually in the pool
    local mergerfs_sources
    mergerfs_sources=$(grep -v '^#' "$FSTAB" | grep 'mergerfs' | awk '{print $1}' || true)
    if [[ -z "$mergerfs_sources" ]] || ! echo "$mergerfs_sources" | grep -q "$mount_point"; then
        echo -e "${RED}$mount_point is not in the mergerfs pool.${NC}"; exit 1
    fi

    local device label file_count
    device=$(lsblk -o MOUNTPOINT,NAME -p --noheadings -l | awk -v mp="$mount_point" '$1 == mp {print $2}')
    label=$(lsblk -o MOUNTPOINT,LABEL --noheadings -l | awk -v mp="$mount_point" '$1 == mp {print $2}')
    file_count=$(find "$mount_point" -mindepth 1 -maxdepth 1 | wc -l)

    echo -e "${BOLD}Removing:${NC} $mount_point  (${device:-?} / ${label:--})"
    echo ""
    echo -e "${RED}${BOLD}WARNING:${NC}"
    echo "  - Any app or user accessing files via $ARRAY_MOUNT that are physically"
    echo "    stored on $mount_point will get errors — the files will appear missing."
    echo "  - Files are NOT deleted, but they won't be accessible until the drive"
    echo "    is re-added or files are moved off first."
    echo ""
    echo -e "  Files at $mount_point root: ${BOLD}$file_count item(s)${NC}"
    echo ""
    read -r -p "Type YES to confirm removal: " confirm
    [[ "$confirm" != "YES" ]] && { echo "Aborted."; exit 0; }

    # Remove from live pool
    echo -e "${YELLOW}Running:${NC} sudo setfattr -n user.mergerfs.branches -v '-$mount_point' $ARRAY_MOUNT/.mergerfs"
    sudo setfattr -n user.mergerfs.branches -v "-${mount_point}" "$ARRAY_MOUNT/.mergerfs"

    # Unmount
    echo -e "${YELLOW}Running:${NC} sudo umount $mount_point"
    sudo umount "$mount_point"

    # Remove drive's fstab entry
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$device" 2>/dev/null || true)
    if [[ -n "$uuid" ]]; then
        echo -e "${YELLOW}Removing fstab entry for UUID $uuid${NC}"
        sudo sed -i "/by-uuid\/${uuid}/d" "$FSTAB"
    fi

    # Remove mount point from mergerfs sources in fstab
    local old_sources new_sources
    old_sources=$(grep -v '^#' "$FSTAB" | grep 'mergerfs' | awk '{print $1}' || true)
    new_sources=$(echo "$old_sources" | sed "s|:${mount_point}||;s|${mount_point}:||;s|${mount_point}||")
    sudo sed -i "s|${old_sources}|${new_sources}|" "$FSTAB"
    echo -e "${YELLOW}Updated mergerfs fstab sources:${NC} $new_sources"

    sudo systemctl daemon-reload
    echo -e "${GREEN}${BOLD}Done.${NC} $mount_point removed from the pool."
    echo "The drive is still physically connected. To re-add it: array add $device ${label:+$label }<mountpoint>"
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
    setup)  cmd_setup ;;
    add)    shift; cmd_add "$@" ;;
    remove) shift; cmd_remove "$@" ;;
    list)   cmd_list ;;
    *)
        echo "Usage: $(basename "$0") <command>"
        echo ""
        echo "Commands:"
        echo "  setup                             Install mergerfs and configure a new array from scratch"
        echo "  list                              Show array members and available drives"
        echo "  add <device> <label> <mountpoint> Add a drive to the array"
        echo "  remove <mountpoint>               Remove a drive from the array"
        echo ""
        echo "Examples:"
        echo "  $(basename "$0") setup"
        echo "  $(basename "$0") list"
        echo "  $(basename "$0") add /dev/sdc1 Array_02 /mnt/drive02"
        echo "  $(basename "$0") remove /mnt/drive02"
        exit 1
        ;;
esac
