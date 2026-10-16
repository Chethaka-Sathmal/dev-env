#!/usr/bin/env bash
#
# rmdev-vm: remove a development vm created by mkdev-vm.
# Stops the vm, undefines it, and deletes its disk(s) in the development folder.
# Base images are never touched.
#
# usage: rmdev-vm [vm-name] [-y]

set -euo pipefail

# Talk to the system libvirt (the one virt-manager shows), not the per-user session
export LIBVIRT_DEFAULT_URI=qemu:///system

readonly BASE_DIR="/var/lib/libvirt/images/base"
readonly DISK_DIR="/var/lib/libvirt/images/development"
readonly POOL_NAME="development"
readonly SHUTDOWN_TIMEOUT=30

die() {
    echo "error: $*" >&2
    exit 1
}

info() {
    echo "==> $*" >&2
}

ok() {
    echo "    done: $*" >&2
}

usage() {
    echo "usage: rmdev-vm [vm-name] [-y]" >&2
    echo "  -y  skip the confirmation prompt" >&2
    exit 1
}

# Pick a vm interactively from everything libvirt knows about
choose_vm() {
    local vms=() choice i
    mapfile -t vms < <(virsh list --all --name | sed '/^$/d')
    ((${#vms[@]} > 0)) || die "there are no vms to remove"

    echo "vms:" >&2
    for i in "${!vms[@]}"; do
        printf '  %d) %s (%s)\n' "$((i + 1))" "${vms[i]}" "$(virsh domstate "${vms[i]}")" >&2
    done

    read -rp "vm to remove [1-${#vms[@]}]: " choice
    [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice <= ${#vms[@]})) ||
        die "invalid choice: '$choice'"
    echo "${vms[choice - 1]}"
}

# Prints the vm's disk file paths (cd-roms and empty drives are skipped)
vm_disks() {
    virsh domblklist "$1" --details |
        awk 'NR > 2 && $2 == "disk" && $4 != "-" { print $4 }'
}

# Ask libvirt for a clean shutdown; force it off if the guest doesn't comply in time
stop_vm() {
    local name=$1 state waited=0
    state=$(virsh domstate "$name")

    if [[ "$state" == "shut off" ]]; then
        ok "vm is already shut off"
        return
    fi

    if [[ "$state" == "running" ]]; then
        info "shutting down '$name' (up to ${SHUTDOWN_TIMEOUT}s)"
        virsh shutdown "$name" >/dev/null || true
        while ((waited < SHUTDOWN_TIMEOUT)); do
            [[ "$(virsh domstate "$name")" == "shut off" ]] && {
                ok "vm shut down cleanly"
                return
            }
            sleep 1
            waited=$((waited + 1))
        done
        echo "    the guest didn't shut down in time" >&2
    fi

    # Paused, crashed, or ignored the shutdown request
    info "forcing '$name' off"
    virsh destroy "$name" >/dev/null
    ok "vm powered off"
}

main() {
    local vm_name="" assume_yes=false arg disks=() disk answer

    for arg in "$@"; do
        case "$arg" in
        -y | --yes) assume_yes=true ;;
        -h | --help) usage ;;
        -*) usage ;;
        *) [[ -z "$vm_name" ]] && vm_name=$arg || usage ;;
        esac
    done

    [[ -n "$vm_name" ]] || vm_name=$(choose_vm)

    info "looking up '$vm_name'"
    virsh dominfo "$vm_name" &>/dev/null || die "no vm named '$vm_name'"
    mapfile -t disks < <(vm_disks "$vm_name")
    ok "found it"

    # Show exactly what will be deleted, and refuse anything outside the development folder
    echo >&2
    echo "this will permanently remove vm '$vm_name' and delete:" >&2
    for disk in "${disks[@]}"; do
        case "$disk" in
        "$BASE_DIR"/*) die "'$vm_name' uses a base image directly as its disk ($disk); refusing to delete it" ;;
        "$DISK_DIR"/*) echo "  $disk" >&2 ;;
        *) die "disk $disk is outside $DISK_DIR; refusing to delete it. remove it by hand if you're sure" ;;
        esac
    done
    ((${#disks[@]} > 0)) || echo "  (no disk files)" >&2
    echo >&2

    if [[ "$assume_yes" != true ]]; then
        read -rp "type the vm name to confirm: " answer
        [[ "$answer" == "$vm_name" ]] || die "confirmation didn't match, nothing was removed"
    fi

    if ((${#disks[@]} > 0)); then
        info "deleting the disk needs root; you may be asked for your password"
        sudo -v || die "sudo authentication failed"
    fi

    stop_vm "$vm_name"

    info "undefining '$vm_name'"
    # Snapshot and checkpoint metadata would block undefine; nvram is the UEFI vars file if any
    virsh undefine "$vm_name" --snapshots-metadata --checkpoints-metadata --nvram >/dev/null
    ok "vm definition removed"

    for disk in "${disks[@]}"; do
        info "deleting $disk"
        sudo rm -f -- "$disk"
        ok "disk deleted"
    done

    info "refreshing storage pool '$POOL_NAME'"
    if virsh pool-refresh "$POOL_NAME" &>/dev/null; then
        ok "pool refreshed"
    else
        echo "    skipped: pool '$POOL_NAME' not found" >&2
    fi

    echo
    echo "vm '$vm_name' removed."
}

main "$@"
