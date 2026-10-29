# `drift` — Drift Hypervisor (Immutable Alpine UKI Hypervisor & ZFS/NFS Host)

`drift` builds a single-file Unified Kernel Image (`.efi`) containing an entire Alpine Linux system in an `initramfs` (`zstd` compressed), inspired by Filippo Valsorda's [`frood`](https://words.filippo.io/dispatches/frood/).

It is tailored specifically for **`hv` (`192.168.10.2`)** in the `awdball.lan` cluster to serve as:
1. **Authoritative ZFS Storage Host:** Imports the 6x 8TB RAIDZ2 `storage` pool (`11.7 TB`) in kernel space (`zfs_arc_max=5 GiB`).
2. **Kernel-Space NFS Server (`nfsd`):** Automatically exports datasets with `sharenfs` properties (`storage/mediaslave`, `storage/containers`, `storage/out-of-band`) before any VM starts.
3. **High-Availability iPXE / TFTP Endpoint:** Runs `keepalived` backup for the floating netboot VIP (`192.168.10.10`) alongside `alpine-rpi4`.
4. **KVM Hypervisor for Talos Linux:** Launches the Talos Control Plane VM (`22 GiB` RAM, `10` vCPUs) with raw `virtio-blk` NVMe partitions (`/dev/nvme0n1p2` for Talos system, `/dev/nvme0n1p3` for Plex SQLite DB) and **late-bound VFIO passthrough** of the Intel UHD Graphics 630 (`0000:00:02.0`) for hardware QuickSync transcoding.

---

## Memory Allocation (`31.0 GiB` Usable RAM on `hv`)

| Component | Allocation | Notes |
| :--- | :--- | :--- |
| **Talos Linux KVM Guest (`-m 22G`)** | **22.00 GiB** | `11.5 GiB` active working set + `4.5 GiB` guest VFS cache + `6.0 GiB` `/transcode` RAM burst |
| **Host ZFS ARC (`zfs_arc_max`)** | **5.00 GiB** | Covers `1.81 GiB` pool metadata + MFU hot data **2.75x over** (`99.8%+` metadata hit rate) |
| **`drift` Initramfs OS** | **0.45 GiB** | Uncompressed rootfs in RAM (`linux-lts`, `zfs-lts`, `qemu-system-x86_64`, `nfs-utils`) |
| **Host Kernel Slab & Buffers** | **2.00 GiB** | Kernel slab + network ring buffers + bounded `tmpfs` (`/tmp`, `/run`, `/var/log`) |
| **Host Free Safety Margin** | **1.55 GiB** | Unallocated host headroom (zero swap required) |

---

## Pre-Build Setup (Injected Host Files)

Before running `./drift build`, populate the gitignored host-specific files (or run `./drift sync-host-secrets` on `hv`):

1. `root/etc/ssh/ssh_host_ed25519_key` & `root/etc/ssh/ssh_host_ed25519_key.pub` — `hv`'s SSH host key so its fingerprint remains constant across reboots.
2. `root/root/.ssh/authorized_keys` — SSH public keys authorized to log into `hv` as `root`.
3. `root/etc/zfs/zpool.cache` — `hv`'s ZFS pool cache file so `zfs-import` imports `storage` instantaneously at boot.

```sh
./drift sync-host-secrets
```

---

## Usage

```sh
# 1. Build a new timestamped UKI image in images/drift.YYYYMMDDXX.efi
./drift build

# 2. Boot and test the UKI image locally in QEMU (Ctrl-A X to exit)
./drift qemu

# 3. Deploy the latest UKI image to hv's EFI System Partition (keeps .prev backup)
./drift deploy
```

