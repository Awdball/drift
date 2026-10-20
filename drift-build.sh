#!/bin/sh
set -e

__() { printf "\n\033[1;32m* %s [%s]\033[0m\n" "$1" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; }

ROOTFS_DEST=$(mktemp -d)

__ "Checking required host secrets"
missing=""
for req in /root/etc/ssh/ssh_host_ed25519_key /root/root/.ssh/authorized_keys; do
    if [ ! -e "/mnt$req" ]; then
        missing="${missing}  ${req}\n"
    fi
done
if [ -n "$missing" ]; then
    printf "Missing required files (run './drift sync-host-secrets' first):\n%b" "$missing" >&2
    exit 1
fi

__ "Installing build dependencies & fetching alpine-make-rootfs"
apk add --no-cache wget cpio gzip zstd systemd-efistub ukify
wget -q https://raw.githubusercontent.com/alpinelinux/alpine-make-rootfs/v0.7.0/alpine-make-rootfs
echo '91ceb95b020260832417b01e45ce02c3a250c4527835d1bdf486bf44f80287dc  alpine-make-rootfs' | sha256sum -c
chmod +x alpine-make-rootfs

__ "Building Alpine rootfs"
mkdir -p "$ROOTFS_DEST/etc/mkinitfs"
echo "disable_trigger=yes" > "$ROOTFS_DEST/etc/mkinitfs/mkinitfs.conf"
basename "$1" > "$ROOTFS_DEST/etc/drift-release"

export ALPINE_BRANCH=edge
export SCRIPT_CHROOT=yes
export FS_SKEL_DIR=/mnt/root
export FS_SKEL_CHOWN=root:root
export PACKAGES="$(grep -v '^\s*#' /mnt/packages | tr '\n' ' ')"

./alpine-make-rootfs "$ROOTFS_DEST" /mnt/setup.sh

__ "Packing initramfs (zstd compressed)"
cd "$ROOTFS_DEST"
find . -path "./boot" -prune -o -print | cpio -o -H newc | zstd -19 -T0 > "$ROOTFS_DEST/boot/initramfs-lts"

__ "Building Unified Kernel Image (UKI)"
# Note: vfio-pci.ids is intentionally omitted here so the EFI framebuffer / HDMI console
# remains active during early boot, networking, and ZFS import for local troubleshooting.
# The Intel UHD 630 iGPU (0000:00:02.0) is dynamically bound to vfio-pci when talos-vm starts.
CMDLINE="rdinit=/sbin/init console=ttyS0,115200n8 console=tty0 intel_iommu=on amd_iommu=on iommu=pt"

ukify build \
    --output "$1" \
    --cmdline "$CMDLINE" \
    --linux "$ROOTFS_DEST/boot/vmlinuz-lts" \
    --initrd "$ROOTFS_DEST/boot/intel-ucode.img" \
    --initrd "$ROOTFS_DEST/boot/amd-ucode.img" \
    --initrd "$ROOTFS_DEST/boot/initramfs-lts" \
    --os-release "@$ROOTFS_DEST/etc/drift-release"

__ "Build complete: $1 ($(ls -lh "$1" | awk '{print $5}'))"
