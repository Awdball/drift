#!/bin/sh
set -e

__() { printf "\n\033[1;32m* [build:%s] %s [%s]\033[0m\n" "$1" "$2" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; }

PROJECT_DIR="${PROJECT_DIR:-$(cd "$(dirname "$0")" && pwd)}"
if [ -d "/mnt/root" ]; then
    PROJECT_DIR="/mnt"
fi

TMPDIR="${TMPDIR:-/storage/dev-projects/tmp}"
mkdir -p "$TMPDIR"
ROOTFS_DEST=$(mktemp -d -p "$TMPDIR")
trap 'rm -rf "$ROOTFS_DEST"' EXIT

__ "preflight" "Checking host secrets and scripts in $PROJECT_DIR"
mkdir -p "$PROJECT_DIR/root/etc/ssh" "$PROJECT_DIR/root/root/.ssh" "$PROJECT_DIR/root/usr/local/bin"

if [ ! -f "$PROJECT_DIR/root/etc/ssh/ssh_host_ed25519_key" ]; then
    printf "Note: No baked-in ssh_host_ed25519_key found. Host keys will be auto-generated or loaded from ESP seed.\n"
fi
if [ ! -f "$PROJECT_DIR/root/root/.ssh/authorized_keys" ]; then
    touch "$PROJECT_DIR/root/root/.ssh/authorized_keys"
    chmod 600 "$PROJECT_DIR/root/root/.ssh/authorized_keys"
    printf "Note: Created empty authorized_keys. Public keys can be supplied via drift.env or ESP seed.\n"
fi

__ "fetching_tools" "Installing build dependencies & verifying alpine-make-rootfs"
apk add --no-cache wget cpio gzip zstd systemd-efistub ukify
if [ ! -f alpine-make-rootfs ]; then
    wget -q https://raw.githubusercontent.com/alpinelinux/alpine-make-rootfs/v0.7.0/alpine-make-rootfs
    echo '91ceb95b020260832417b01e45ce02c3a250c4527835d1bdf486bf44f80287dc  alpine-make-rootfs' | sha256sum -c
    chmod +x alpine-make-rootfs
fi

__ "building_rootfs" "Building Alpine rootfs"
mkdir -p "$ROOTFS_DEST/etc/mkinitfs"
echo "disable_trigger=yes" > "$ROOTFS_DEST/etc/mkinitfs/mkinitfs.conf"
TARGET="$(realpath "$1")"
mkdir -p "$(dirname "$TARGET")"
basename "$TARGET" > "$ROOTFS_DEST/etc/drift-release"
if [ -f "$PROJECT_DIR/VERSION" ]; then
    tr -d '[:space:]' < "$PROJECT_DIR/VERSION" > "$ROOTFS_DEST/etc/drift-version"
    echo "" >> "$ROOTFS_DEST/etc/drift-version"
else
    echo "1.1.0" > "$ROOTFS_DEST/etc/drift-version"
fi

export ALPINE_BRANCH=edge
export SCRIPT_CHROOT=yes
export FS_SKEL_DIR="$PROJECT_DIR/root"
export FS_SKEL_CHOWN=root:root
export PACKAGES="$(grep -v '^\s*#' "$PROJECT_DIR/packages" | tr '\n' ' ')"

./alpine-make-rootfs "$ROOTFS_DEST" "$PROJECT_DIR/setup.sh"

__ "packing_initramfs" "Packing initramfs (zstd -19 -T0 compressed)"
cd "$ROOTFS_DEST"
find . -path "./boot" -prune -o -print | cpio -o -H newc | zstd -19 -T0 > "$ROOTFS_DEST/boot/initramfs-lts"

__ "assembling_uki" "Building Unified Kernel Image (UKI)"
CMDLINE="rdinit=/sbin/init console=ttyS0,115200n8 console=tty0 intel_iommu=on amd_iommu=on iommu=pt"

ukify build \
    --output "${TARGET}.tmp" \
    --cmdline "$CMDLINE" \
    --linux "$ROOTFS_DEST/boot/vmlinuz-lts" \
    --initrd "$ROOTFS_DEST/boot/intel-ucode.img" \
    --initrd "$ROOTFS_DEST/boot/amd-ucode.img" \
    --initrd "$ROOTFS_DEST/boot/initramfs-lts" \
    --os-release "@$ROOTFS_DEST/etc/drift-release"

mv "${TARGET}.tmp" "$TARGET"

__ "exporting_netboot" "Exporting netboot assets (vmlinuz-lts and initramfs-lts)"
NETBOOT_DIR="$(dirname "$TARGET")/netboot"
mkdir -p "$NETBOOT_DIR"
cp "$ROOTFS_DEST/boot/vmlinuz-lts" "$NETBOOT_DIR/vmlinuz-lts.tmp"
cp "$ROOTFS_DEST/boot/initramfs-lts" "$NETBOOT_DIR/initramfs-lts.tmp"
mv "$NETBOOT_DIR/vmlinuz-lts.tmp" "$NETBOOT_DIR/vmlinuz-lts"
mv "$NETBOOT_DIR/initramfs-lts.tmp" "$NETBOOT_DIR/initramfs-lts"
printf "Netboot assets exported to %s\n" "$NETBOOT_DIR"

__ "verified" "Build complete: $TARGET ($(ls -lh "$TARGET" | awk '{print $5}'))"
