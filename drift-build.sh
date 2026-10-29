#!/bin/sh
set -e

__() { printf "\n\033[1;32m* %s [%s]\033[0m\n" "$1" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; }

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
if [ -d "/mnt/root" ]; then
    PROJECT_DIR="/mnt"
fi

TMPDIR="${TMPDIR:-/storage/dev-projects/tmp}"
mkdir -p "$TMPDIR"
ROOTFS_DEST=$(mktemp -d -p "$TMPDIR")
trap 'rm -rf "$ROOTFS_DEST"' EXIT

__ "Checking host secrets in $PROJECT_DIR"
# Ensure SSH directories exist
mkdir -p "$PROJECT_DIR/root/etc/ssh" "$PROJECT_DIR/root/root/.ssh"

# If host SSH keys or authorized_keys are not present, provide defaults/warnings rather than aborting build
if [ ! -f "$PROJECT_DIR/root/etc/ssh/ssh_host_ed25519_key" ]; then
    printf "Note: No baked-in ssh_host_ed25519_key found. Host keys will be auto-generated or loaded from ESP seed.\n"
fi
if [ ! -f "$PROJECT_DIR/root/root/.ssh/authorized_keys" ]; then
    touch "$PROJECT_DIR/root/root/.ssh/authorized_keys"
    chmod 600 "$PROJECT_DIR/root/root/.ssh/authorized_keys"
    printf "Note: Created empty authorized_keys. Public keys can be supplied via drift.env or ESP seed.\n"
fi

__ "Installing build dependencies & fetching alpine-make-rootfs"
apk add --no-cache wget cpio gzip zstd systemd-efistub ukify
if [ ! -f alpine-make-rootfs ]; then
    wget -q https://raw.githubusercontent.com/alpinelinux/alpine-make-rootfs/v0.7.0/alpine-make-rootfs
    echo '91ceb95b020260832417b01e45ce02c3a250c4527835d1bdf486bf44f80287dc  alpine-make-rootfs' | sha256sum -c
    chmod +x alpine-make-rootfs
fi

__ "Building Alpine rootfs"
mkdir -p "$ROOTFS_DEST/etc/mkinitfs"
echo "disable_trigger=yes" > "$ROOTFS_DEST/etc/mkinitfs/mkinitfs.conf"
TARGET="$(realpath "$1")"
mkdir -p "$(dirname "$TARGET")"
basename "$TARGET" > "$ROOTFS_DEST/etc/drift-release"

export ALPINE_BRANCH=edge
export SCRIPT_CHROOT=yes
export FS_SKEL_DIR="$PROJECT_DIR/root"
export FS_SKEL_CHOWN=root:root
export PACKAGES="$(grep -v '^\s*#' "$PROJECT_DIR/packages" | tr '\n' ' ')"

./alpine-make-rootfs "$ROOTFS_DEST" "$PROJECT_DIR/setup.sh"

__ "Packing initramfs (zstd compressed)"
cd "$ROOTFS_DEST"
find . -path "./boot" -prune -o -print | cpio -o -H newc | zstd -19 -T0 > "$ROOTFS_DEST/boot/initramfs-lts"

__ "Exporting netboot assets (vmlinuz-lts and initramfs-lts)"
NETBOOT_DIR="$(dirname "$TARGET")/netboot"
mkdir -p "$NETBOOT_DIR"
cp "$ROOTFS_DEST/boot/vmlinuz-lts" "$NETBOOT_DIR/vmlinuz-lts"
cp "$ROOTFS_DEST/boot/initramfs-lts" "$NETBOOT_DIR/initramfs-lts"
printf "Netboot assets exported to %s\n" "$NETBOOT_DIR"

__ "Building Unified Kernel Image (UKI)"
CMDLINE="rdinit=/sbin/init console=ttyS0,115200n8 console=tty0 intel_iommu=on amd_iommu=on iommu=pt"

ukify build \
    --output "$TARGET" \
    --cmdline "$CMDLINE" \
    --linux "$ROOTFS_DEST/boot/vmlinuz-lts" \
    --initrd "$ROOTFS_DEST/boot/intel-ucode.img" \
    --initrd "$ROOTFS_DEST/boot/amd-ucode.img" \
    --initrd "$ROOTFS_DEST/boot/initramfs-lts" \
    --os-release "@$ROOTFS_DEST/etc/drift-release"

__ "Build complete: $TARGET ($(ls -lh "$TARGET" | awk '{print $5}'))"
