#!/usr/bin/env bash
set -euEo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOC="$(dirname "$SCRIPT_DIR")/docs/mergerfs.md"
FSTAB="/etc/fstab"
ARRAY_MOUNT="/array"

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ── error handler ─────────────────────────────────────────────────────────────
_error_handler() {
    local line="$1" cmd="$2"
    echo -e "\n${RED}${BOLD}Error on line ${line}:${NC} ${cmd}"
    echo -e "${DIM}$(basename "$0") failed in $(readlink -f "$0")${NC}"
    exit 1
}
trap '_error_handler $LINENO "$BASH_COMMAND"' ERR

# ── helpers ───────────────────────────────────────────────────────────────────

# Extract a ### section from the doc by heading pattern
doc_section() {
    awk "/^### ${1}/{f=1; next} f && /^### /{f=0} f{print}" "$DOC"
}

step_header() {
    echo ""
    echo -e "${BOLD}${CYAN}━━━ Step ${1}: ${2} ━━━${NC}"
    echo ""
}

# fzf yes/no with a doc section shown in the preview pane
# Usage: confirm "prompt text" "doc heading pattern (awk regex)"
confirm() {
    local prompt="$1" heading="$2"
    local choice
    choice=$(printf 'Yes\nNo' | fzf \
        --prompt="$prompt > " \
        --preview="awk '/^### ${heading}/{f=1; next} f && /^### /{f=0} f{print}' \"$DOC\"" \
        --preview-window=right:55%:wrap \
        --height=50% \
        --border \
        --no-sort) || true
    [[ "$choice" == "Yes" ]]
}

# ── add command ───────────────────────────────────────────────────────────────

cmd_add() {

    # ── Step 1: select drive ──────────────────────────────────────────────────
    step_header 1 "Identify the new drive"

    local raw_drives
    raw_drives=$(
        lsblk -e 7 -p -l -o NAME,SIZE,FSTYPE,MOUNTPOINT --noheadings | \
        awk '$4 == ""' | \
        while read -r name size fstype mp; do
            # skip parent disks that have partitions (let the partitions appear instead)
            if [[ $(lsblk -l --noheadings "$name" 2>/dev/null | wc -l) -gt 1 ]]; then
                continue
            fi
            # skip if any descendant is mounted
            if lsblk -o MOUNTPOINT --noheadings "$name" 2>/dev/null | grep -q '\S'; then
                continue
            fi
            if [[ -z "$fstype" ]]; then
                echo -e "\033[1;32m$name $size <unformatted> ★ recommended\033[0m"
            else
                echo "$name $size $fstype"
            fi
        done
    )

    if [[ -z "$raw_drives" ]]; then
        echo -e "${RED}No available drives found.${NC}"
        echo "Run: lsblk -e 7 -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT"
        exit 1
    fi

    local selected
    selected=$(echo "$raw_drives" | fzf \
        --ansi \
        --prompt="Select new drive > " \
        --preview="lsblk -e 7 -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT {1} 2>/dev/null; echo ''; echo '--- all drives ---'; lsblk -e 7 -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT" \
        --preview-window=right:55%:wrap \
        --height=60% \
        --border \
        --header="Unmounted drives — select the new drive") || {
        echo "Aborted."; exit 0
    }

    local format_device
    format_device=$(echo "$selected" | sed 's/\x1b\[[0-9;]*m//g' | awk '{print $1}')
    local device
    # parent disk is the device without trailing partition number
    device=$(echo "$format_device" | sed 's/p\?[0-9]*$//')
    [[ "$device" == "$format_device" ]] && device="$format_device"
    echo -e "Selected: ${BOLD}$format_device${NC}"

    # ── Step 2: format ────────────────────────────────────────────────────────
    step_header 2 "Format as XFS"

    local existing_fstype
    existing_fstype=$(lsblk -o FSTYPE --noheadings -n "$format_device" 2>/dev/null | head -1)

    if [[ "$existing_fstype" == "xfs" ]]; then
        echo -e "${GREEN}Already formatted as XFS — skipping format.${NC}"
    else
        # Detect whether existing pool drives use partitions
        local existing_drives uses_partitions="no"
        existing_drives=$(grep -E "^/dev/disk/by-uuid" "$FSTAB" | awk '{print $2}' | grep "^/mnt/drive" || true)
        for mp in $existing_drives; do
            if lsblk -o MOUNTPOINT,TYPE --noheadings | grep -q "$mp.*part"; then
                uses_partitions="yes"; break
            fi
        done

        local partition_choice
        partition_choice=$(printf \
            "Whole disk — format $device directly (simpler)\nPartitioned — create GPT partition first (your other drives use partitions)" \
            | fzf \
            --prompt="Partitioning approach > " \
            --preview="awk '/^### 2\. Format/{f=1; next} f && /^### /{f=0} f{print}' \"$DOC\"" \
            --preview-window=right:55%:wrap \
            --height=50% \
            --border \
            --header="Existing pool drives $([ "$uses_partitions" = "yes" ] && echo 'USE partitions' || echo 'do NOT use partitions')") || {
            echo "Aborted."; exit 0
        }

        if [[ "$partition_choice" == Partitioned* ]]; then
            format_device="${device}1"
            echo -e "${YELLOW}Will run:${NC} sudo parted $device --script mklabel gpt mkpart primary 0% 100%"
        fi
        echo -e "${YELLOW}Will run:${NC} sudo mkfs.xfs $format_device"
        echo ""
        echo -e "${RED}${BOLD}WARNING: this permanently destroys all data on $device${NC}"
        echo ""

        if ! confirm "Confirm format $format_device" "2\. Format"; then
            echo "Aborted."; exit 0
        fi

        if [[ "$format_device" == "${device}1" ]]; then
            sudo parted "$device" --script mklabel gpt mkpart primary 0% 100%
            echo -e "${GREEN}Partition created.${NC}"
            sleep 1
        fi
        sudo mkfs.xfs "$format_device"
        echo -e "${GREEN}Formatted as XFS.${NC}"
    fi

    # ── Step 3: get UUID ──────────────────────────────────────────────────────
    step_header 3 "Get UUID"
    local uuid
    uuid=$(sudo blkid -s UUID -o value "$format_device")
    echo -e "UUID: ${BOLD}$uuid${NC}"

    # ── Step 4: mount point ───────────────────────────────────────────────────
    step_header 4 "Create mount point"

    local mount_point mergerfs_sources
    mergerfs_sources=$(grep -v '^#' "$FSTAB" | grep 'mergerfs' | awk '{print $1}' || true)

    if [[ -n "$mergerfs_sources" ]]; then
        local -a pool_mounts
        IFS=':' read -ra pool_mounts <<< "$mergerfs_sources"
        echo -e "Current pool members:"
        printf '  %s\n' "${pool_mounts[@]}"
        echo ""
        local last="${pool_mounts[-1]}"
        local prefix num
        prefix=$(echo "$last" | sed 's/[0-9]*$//')
        num=$(echo "$last" | grep -o '[0-9]*$')
        mount_point="${prefix}$(printf "%0${#num}d" $(( 10#$num + 1 )))"
    else
        local n=0
        while [[ -d "/mnt/drive$(printf '%02d' $n)" ]]; do n=$(( n + 1 )); done
        mount_point="/mnt/drive$(printf '%02d' $n)"
    fi
    local input
    read -e -i "$mount_point" -p "$(echo -e "Mount point ${DIM}(edit or Enter to accept)${NC}: ")" input || { echo "Aborted."; exit 0; }
    [[ -z "$input" ]] && { echo "Aborted."; exit 0; }
    mount_point="$input"

    sudo mkdir "$mount_point"
    echo -e "${GREEN}Created $mount_point${NC}"

    # ── Steps 5 & 6: fstab ───────────────────────────────────────────────────
    step_header "5 & 6" "Update /etc/fstab"

    local drive_line="/dev/disk/by-uuid/$uuid  $mount_point  auto  nosuid,nodev,nofail,x-gvfs-show  0  0"

    local mergerfs_line
    mergerfs_line=$(grep -v '^#' "$FSTAB" | grep 'mergerfs' || true)
    if [[ -z "$mergerfs_line" ]]; then
        echo -e "${RED}No mergerfs line found in $FSTAB — cannot update automatically.${NC}"
        exit 1
    fi
    local old_sources new_sources new_mergerfs_line
    old_sources=$(echo "$mergerfs_line" | awk '{print $1}')
    new_sources="${old_sources}:${mount_point}"
    new_mergerfs_line="${mergerfs_line/$old_sources/$new_sources}"

    echo -e "${YELLOW}Add drive entry:${NC}"
    echo "  $drive_line"
    echo ""
    echo -e "${YELLOW}Update mergerfs line:${NC}"
    echo -e "  ${RED}-${NC} $mergerfs_line"
    echo -e "  ${GREEN}+${NC} $new_mergerfs_line"
    echo ""

    if ! confirm "Apply fstab changes" "5\. Add"; then
        echo "Aborted."; exit 0
    fi

    echo "$drive_line" | sudo tee -a "$FSTAB"
    sudo sed -i "s|${old_sources}|${new_sources}|" "$FSTAB"
    echo -e "${GREEN}fstab updated.${NC}"

    # ── Step 7: mount ─────────────────────────────────────────────────────────
    step_header 7 "Mount and reload MergerFS"

    echo -e "${YELLOW}Will run:${NC}"
    echo "  sudo systemctl daemon-reload"
    echo "  sudo mount $mount_point"
    echo "  sudo attr -s mergerfs.srcmounts -V '+$mount_point' $ARRAY_MOUNT"
    echo ""

    if ! confirm "Mount and reload" "7\. Mount"; then
        echo "Aborted."; exit 0
    fi

    sudo systemctl daemon-reload
    sudo mount "$mount_point"
    sudo attr -s mergerfs.srcmounts -V "+${mount_point}" "$ARRAY_MOUNT"
    echo -e "${GREEN}Mounted.${NC}"

    # ── Step 8: verify ────────────────────────────────────────────────────────
    step_header 8 "Verify"
    echo ""
    df -h "$ARRAY_MOUNT" /mnt/drive*
    echo ""
    echo -e "${GREEN}${BOLD}Done.${NC} $device added to the pool as $mount_point."
}

# ── dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
    add) cmd_add ;;
    *)
        echo "Usage: $(basename "$0") <command>"
        echo ""
        echo "Commands:"
        echo "  add    Add a new drive to the MergerFS pool"
        exit 1
        ;;
esac
