# `drift` — Universal Immutable Alpine UKI Hypervisor & Storage Host

`drift` builds a single-file Unified Kernel Image (`.efi`) containing an entire Alpine Linux system in an `initramfs` (`zstd` compressed), inspired by Filippo Valsorda's [`frood`](https://words.filippo.io/dispatches/frood/).

It can boot as an immutable, in-memory RAM OS on **any x86_64 host machine** or VM. It auto-discovers network interfaces, computes proportional CPU/RAM sizing, detects hardware accelerators (e.g. Intel QuickSync iGPU), and launches a nested [Talos Linux](https://www.talos.dev/) KVM virtual machine automatically.

---

## Architecture & Dynamic Self-Configuration

`drift` is hardware-agnostic and self-configuring out of the box:

1. **Carrier-Active NIC Auto-Detection:**
   - Scans physical network adapters for an active carrier link (ignoring virtual, bridge, wireless, or down interfaces).
   - Binds the active adapter to `br0` with hardware MAC preservation so bridge addresses never flip when tap devices attach.

2. **Dynamic Host & VM Identity:**
   - Generates deterministic hostnames (`drift-<mac_suffix>`) and locally-administered unicast VM MACs (`52:54:xx:xx:xx:xx`) derived from the physical NIC MAC.
   - Built-in hardware profiles provide instant recognition for core cluster nodes (e.g. `hv` and `steam-worker`).

3. **Dynamic Resource Sizing:**
   - Computes total physical RAM and allocates ~60% to the Talos guest VM, reserving the remainder for host ZFS ARC, kernel slab, and buffers.
   - Reserves 2 CPU cores for hypervisor operations and assigns the remaining cores to the VM.

4. **Dynamic Accelerator Passthrough (Intel iGPU / QuickSync):**
   - Automatically probes PCI devices for Intel graphics controllers (Vendor `0x8086`, Class `0x0300` / `0x0380`).
   - Late-binds `vfio-pci` and attaches the GPU to the VM.
   - If binding fails or the host lacks an Intel GPU, it logs a warning and falls back to headless operation without interrupting VM launch.

5. **Safe Storage Discovery (Persistent vs Ephemeral):**
   - Discovers storage partitions by GPT partition label (`/dev/disk/by-partlabel/talos-sys`, `/dev/disk/by-partlabel/plex-nvme`) or raw disk images.
   - If no persistent partition is found, it automatically instantiates a non-destructive, ephemeral 20 GiB sparse QCOW2 image in `/tmp` for temporary or rescue operation.

---

## Seed Loader Configuration (`drift.env`)

To customize or override identity, network, or hardware settings without rebuilding the UKI image, place a `drift.env` file in the root or `/EFI/drift/` directory of any FAT32 partition (such as the EFI System Partition or a bootable USB flash drive):

```sh
# /EFI/drift/drift.env or /drift.env

# Host identity and network
NODE_NAME="my-node"
NODE_IP="dhcp"                    # or static IP (e.g. "192.168.10.50")
NODE_NETMASK="255.255.255.0"
NODE_GATEWAY="192.168.10.1"
NODE_DNS="192.168.10.1"

# Talos VM sizing
VM_CPUS="8"
VM_MEM="16G"
VM_MAC="52:54:00:12:34:56"

# Hardware passthrough: "auto", "disable", or specific PCI BDF (e.g. "0000:00:02.0")
PASSTHROUGH_GPU="auto"

# Custom storage path (defaults to /dev/disk/by-partlabel/talos-sys)
TALOS_SYS_DISK="/dev/disk/by-partlabel/talos-sys"

# SSH access
AUTHORIZED_KEYS="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... user@workstation"
```

### Persistent SSH Host Keys

When booting from an ESP or USB drive, `drift` automatically checks for `/EFI/drift/ssh_host_ed25519_key`. If present, it restores the key so SSH fingerprints remain identical across boots. If absent and the drive is writable, `drift` generates a key and saves it to the partition.

---

## Memory Allocation Reference (`31.0 GiB` Usable RAM on `hv`)

| Component | Allocation | Notes |
| :--- | :--- | :--- |
| **Talos Linux KVM Guest (`-m 22G`)** | **22.00 GiB** | `11.5 GiB` active working set + `4.5 GiB` guest VFS cache + `6.0 GiB` `/transcode` RAM burst |
| **Host ZFS ARC (`zfs_arc_max`)** | **5.00 GiB** | Covers `1.81 GiB` pool metadata + MFU hot data **2.75x over** (`99.8%+` metadata hit rate) |
| **`drift` Initramfs OS** | **0.45 GiB** | Uncompressed rootfs in RAM (`linux-lts`, `zfs-lts`, `qemu-system-x86_64`, `nfs-utils`) |
| **Host Kernel Slab & Buffers** | **2.00 GiB** | Kernel slab + network ring buffers + bounded `tmpfs` (`/tmp`, `/run`, `/var/log`) |
| **Host Free Safety Margin** | **1.55 GiB** | Unallocated host headroom (zero swap required) |

---

## Building and Deploying

### Build UKI & Netboot Assets
Builds both the standalone Unified Kernel Image (`images/drift.YYYYMMDDXX.efi`) and the split netboot assets (`images/netboot/vmlinuz-lts`, `images/netboot/initramfs-lts`):

```sh
./drift build
```

### Local Testing with QEMU
Boot the image directly using local UEFI emulation:
```sh
./drift qemu
```

### Deploy to Local EFI System Partition
Deploys the built UKI to `/boot/efi/EFI/BOOT/BOOTX64.EFI` (or custom path) with automatic `.prev` backup:
```sh
./drift deploy /tmp/boot/EFI/drift/drift.efi
```

### Publish to PXE / Netboot Server
Publishes the UKI and split assets to Firewalla Gold's netboot server (`/data/netboot_assets/`):
```sh
./drift publish
```
Assets are immediately available via iPXE at:
- Combined UKI: `http://192.168.10.1:8080/drift.efi`
- Split Kernel: `http://192.168.10.1:8080/drift/vmlinuz-lts`
- Split Initramfs: `http://192.168.10.1:8080/drift/initramfs-lts`
