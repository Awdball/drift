# `drift` — Universal Immutable Alpine UKI Hypervisor & Storage Host

`drift` builds a single-file Unified Kernel Image (`.efi`) containing an entire Alpine Linux system in an `initramfs` (`zstd` compressed), inspired by Filippo Valsorda's [`frood`](https://words.filippo.io/dispatches/frood/).

It can boot as an immutable, in-memory RAM OS on **any x86_64 host machine** or VM. It auto-discovers network interfaces, computes proportional CPU/RAM sizing, detects hardware accelerators (e.g. Intel QuickSync iGPU), and launches a nested [Talos Linux](https://www.talos.dev/) KVM virtual machine automatically.

---

## Architecture & Explicit State Machines

`drift` is hardware-agnostic, self-configuring, and governed by explicit runtime state machines tracked in `/run/drift/` (`identity.env`, `talos-vm.env`, and `state.json`):

1. **Carrier-Active NIC Discovery (`NIC_STATE`):**
   - `probing` → `carrier_up` | `no_carrier_fallback` | `virtual_nic` | `default_eth0`
   - Brings candidate physical network adapters administratively `UP` during early boot and polls for PHY carrier negotiation before binding to `br0` with hardware MAC lock.

2. **Dynamic Host, Seed & Secret Identity (`IDENTITY_STATE`, `SEED_STATE`, `SSH_KEY_STATE`):**
   - `IDENTITY_STATE`: `seed_override` | `hardware_profile` (`hv`, `steam-worker`) | `dynamic_mac` (`drift-<mac_suffix>`)
   - `SEED_STATE`: `loaded` | `none_found` (deduplicating candidate VFAT block devices by canonical path)
   - `SSH_KEY_STATE`: `esp_restored` | `esp_persisted` | `baked_initramfs` | `ephemeral_ram`

3. **Storage & Host NVMe / NFS Export Lifecycle (`STORAGE_STATE`, `NVME_STATE`, `PLEX_EXPORT_STATE`):**
   - `STORAGE_STATE`: `persistent_block` | `persistent_image` (`.raw` / `.qcow2`) | `ephemeral_qcow2` | `skipped_small_host`
   - Decouples host NVMe carrier mounting (`/mnt/nvme` and `/plex/config` NFS bind-mount) from guest system disk discovery, and preserves ephemeral QCOW2 disks across service restarts.

4. **Hypervisor Acceleration & Intel iGPU VFIO Passthrough (`ACCEL_STATE`, `GPU_STATE`):**
   - `ACCEL_STATE`: `kvm` (hardware VT-x/SVM + `vhost-net`) | `tcg` (software emulation fallback)
   - `GPU_STATE`: `bound_vfio` | `disabled` | `not_present` | `iommu_unavailable` | `bind_failed_headless`
   - Verifies active IOMMU group presence before unbinding host display consoles and skips redundant rebinds on service restart.

5. **Talos Guest Lifecycle, Graceful QMP Shutdown & Bootstrap (`VM_STATE`, `BOOTSTRAP_STATE`):**
   - `VM_STATE`: `starting` → `running` → `shutting_down` → `stopped` | `skipped`
   - `BOOTSTRAP_STATE`: `idle` | `skipped_no_config` | `skipped_unknown_target` | `probing` | `already_configured` | `config_applied` | `timeout`
   - Sends QMP `system_powerdown` and polls for clean guest ACPI exit before OpenRC sends `SIGTERM`.

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

# Talos VM sizing & optional bootstrap IP
VM_CPUS="8"
VM_MEM="16G"
VM_MAC="52:54:00:12:34:56"
TALOS_VM_IP="192.168.10.55"

# Hardware passthrough: "auto", "disable", or specific PCI BDF (e.g. "0000:00:02.0")
PASSTHROUGH_GPU="auto"

# Custom storage path (block device or .raw/.qcow2 image file)
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

## Operations, Observability & Deployment

### Inspect Runtime State Machines (Human & Agent JSON)
Inspect all hypervisor, memory, ZFS ARC, network, VFIO, and Talos guest state machines:
```sh
./drift status          # or: drift-status
./drift status --json   # or: drift-status --json (writes /run/drift/state.json)
```

### Run Syntax & State Machine Self-Tests
```sh
./drift test
```

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

### Deploy to Local EFI System Partition (511 MB Safe Atomic Rotation)
Deploys the latest verified UKI to `/boot/efi/EFI/drift/drift.efi` (or custom path), automatically mounting the ESP if needed, rotating `.prev` within the 2-image 511 MB FAT32 budget, and rolling back automatically if staging fails:
```sh
./drift deploy
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
