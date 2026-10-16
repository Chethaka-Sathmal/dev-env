#!/usr/bin/env bash

set -euo pipefail

# Talk to the system libvirt (the one virt-manager shows), not the per-user session
export LIBVIRT_DEFAULT_URI=qemu:///system

readonly BASE_DIR="/var/lib/libvirt/images/base"
readonly DISK_DIR="/var/lib/libvirt/images/development"
readonly POOL_NAME="development"
readonly CLOUD_INIT_DIR="$HOME/libvirt-vms/cloud-init"
readonly TEMPLATE_FILE="$CLOUD_INIT_DIR/template.yaml"
readonly PLACEHOLDER="{VM_NAME}"
readonly DEFAULT_MEM=2048
readonly DEFAULT_VCPUS=2
readonly SHARE_TAG="host-share"
readonly DEFAULT_GUEST_MOUNT="/workspace"

# Set as the script runs; used by cleanup()
user_data_file=""
disk_path=""
disk_created=false

die() {
    echo "error: $*" >&2
    exit 1
}

# Progress messages go to stderr so they never mix into captured $(...) output
info() {
    echo "==> $*" >&2
}

ok() {
    echo "    done: $*" >&2
}

# Remove the temporary user-data file always, and the disk only if something failed
cleanup() {
    local status=$?
    [[ -n "$user_data_file" ]] && rm -f "$user_data_file"
    if ((status != 0)) && [[ "$disk_created" == true ]]; then
        info "something failed, removing partially created disk: $disk_path"
        sudo rm -f "$disk_path"
    fi
}
trap cleanup EXIT

# prompt <message> <default> -> prints the answer, or the default if empty
prompt() {
    local answer
    read -rp "$1 ($2): " answer
    echo "${answer:-$2}"
}

require_number() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive whole number, got '$2'"
}

read_vm_name() {
    local name
    read -rp "vm name: " name
    [[ -n "$name" ]] || die "vm name is required"
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] ||
        die "vm name may only contain letters, numbers, - and _"
    echo "$name"
}

# Prints the absolute path of the host directory to share with the vm
read_shared_dir() {
    local dir
    read -rp "host directory to share with the vm: " dir
    dir="${dir/#\~/$HOME}"
    [[ -n "$dir" ]] || die "shared directory is required"
    [[ -d "$dir" ]] || die "directory does not exist: $dir"
    # libvirt needs an absolute path for the share source
    realpath "$dir"
}

check_vm_does_not_exist() {
    local name=$1
    [[ ! -e "$DISK_DIR/$name.qcow2" ]] || die "disk already exists: $DISK_DIR/$name.qcow2"
    if virsh dominfo "$name" &>/dev/null; then
        die "a vm named '$name' already exists"
    fi
}

# Lists the base images and prints the full path of the one the user picks
read_backing_file() {
    local images=() choice i

    shopt -s nullglob
    images=("$BASE_DIR"/*.qcow2)
    shopt -u nullglob
    ((${#images[@]} > 0)) || die "no base images found in $BASE_DIR"

    echo "available base images:" >&2
    for i in "${!images[@]}"; do
        printf '  %d) %s\n' "$((i + 1))" "$(basename "${images[i]}")" >&2
    done

    read -rp "backing file [1-${#images[@]}]: " choice
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#images[@]})) ||
        die "invalid choice: '$choice'"

    # Paths from the glob are already absolute, which the overlay needs
    echo "${images[choice - 1]}"
}

# Prints the osinfo name (like fedora44) of the operating system on a disk, or nothing
detect_os_variant() {
    local disk=$1
    virt-inspector --no-applications --no-icon -a "$disk" 2>/dev/null |
        sed -n 's:.*<osinfo>\(.*\)</osinfo>.*:\1:p' | head -n 1 || true
}

# read_os_variant <backing file> -> prints the detected or entered os variant
read_os_variant() {
    local backing=$1 detected os

    info "detecting the operating system in $(basename "$backing") (takes a few seconds)"
    detected=$(detect_os_variant "$backing")

    if [[ -n "$detected" ]]; then
        ok "detected $detected"
        os=$(prompt "os variant" "$detected")
    else
        echo "    could not detect it; list options with: virt-install --osinfo list" >&2
        read -rp "os variant (e.g. fedora44): " os
        [[ -n "$os" ]] || die "os variant isn't specified"
    fi
    echo "$os"
}

create_user_data_file() {
    local name=$1 guest_mount=$2
    info "generating cloud-init user-data from $TEMPLATE_FILE"
    [[ -f "$TEMPLATE_FILE" ]] || die "template not found: $TEMPLATE_FILE"
    user_data_file=$(mktemp --suffix=.yaml)
    sed "s/$PLACEHOLDER/$name/g" "$TEMPLATE_FILE" >"$user_data_file"
    # Mount the virtiofs share on boot; nofail keeps a missing share from blocking boot
    cat >>"$user_data_file" <<EOF

mounts:
  - [ $SHARE_TAG, "$guest_mount", virtiofs, "defaults,nofail", "0", "0" ]
EOF
    ok "user-data written to $user_data_file (temporary)"
}

create_disk() {
    local name=$1 backing=$2
    disk_path="$DISK_DIR/$name.qcow2"
    info "creating overlay disk $disk_path"
    info "backed by $backing"
    # The disk folder is root-owned, so only this step needs root
    sudo qemu-img create -f qcow2 -b "$backing" -F qcow2 "$disk_path" >/dev/null
    disk_created=true
    ok "disk created"
}

create_vm() {
    local name=$1 mem=$2 vcpus=$3 os=$4 shared_dir=$5
    info "defining and starting vm '$name' (${mem} MB memory, $vcpus vcpus, $os)"
    # virtiofs requires shared memory backing
    virt-install \
        --name "$name" \
        --memory "$mem" \
        --vcpus "$vcpus" \
        --memorybacking source.type=memfd,access.mode=shared \
        --disk path="$disk_path" \
        --filesystem source.dir="$shared_dir",target.dir="$SHARE_TAG",driver.type=virtiofs \
        --import \
        --osinfo "$os" \
        --cloud-init user-data="$user_data_file" \
        --noautoconsole
    ok "vm '$name' is running; cloud-init will configure it on first boot"
}

main() {
    local vm_name mem vcpus shared_dir guest_mount backing_file os_variant

    vm_name=$(read_vm_name)

    info "checking that '$vm_name' isn't already taken"
    check_vm_does_not_exist "$vm_name"
    ok "name is free"

    mem=$(prompt "memory in MB" "$DEFAULT_MEM")
    require_number "memory" "$mem"

    vcpus=$(prompt "vcpus" "$DEFAULT_VCPUS")
    require_number "vcpus" "$vcpus"

    shared_dir=$(read_shared_dir)
    guest_mount=$(prompt "mount point inside the vm" "$DEFAULT_GUEST_MOUNT")
    [[ "$guest_mount" == /* ]] || die "mount point must be an absolute path, got '$guest_mount'"

    backing_file=$(read_backing_file)
    os_variant=$(read_os_variant "$backing_file")

    echo >&2
    # Ask for the sudo password now, so it isn't requested halfway through.
    # sudo remembers it for a few minutes, which covers the rest of the run.
    info "creating the disk needs root; you may be asked for your password"
    sudo -v || die "sudo authentication failed"

    create_user_data_file "$vm_name" "$guest_mount"
    create_disk "$vm_name" "$backing_file"
    create_vm "$vm_name" "$mem" "$vcpus" "$os_variant" "$shared_dir"

    info "refreshing storage pool '$POOL_NAME'"
    if virsh pool-refresh "$POOL_NAME" &>/dev/null; then
        ok "pool refreshed"
    else
        echo "    skipped: pool '$POOL_NAME' not found (the vm is fine)" >&2
    fi

    echo
    echo "vm '$vm_name' created."
    echo "it may take a minute for cloud-init to finish and the network to come up."
    echo "get its IP address with: virsh domifaddr $vm_name"
    echo "shared: $shared_dir -> $guest_mount (virtiofs tag '$SHARE_TAG')"
    echo "if it isn't mounted, run in the vm: sudo mount -t virtiofs $SHARE_TAG $guest_mount"
}

main "$@"
