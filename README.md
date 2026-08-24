# pve-debian-cloud-vm

Provision and maintain Debian cloud-image VMs on Proxmox VE with reusable scripts for image updates, VM creation, and cloud-init configuration.

## Overview

`pve-debian-cloud-vm` provides a small set of Bash scripts for quickly creating standardized Debian cloud VMs on Proxmox VE.

The project separates host-specific configuration from reusable provisioning logic:

- `create-debian-vm.sh` is the primary entry point and host configuration layer.
- `update-debian-image.sh` keeps the configured Debian cloud-image cache current.
- `build-debian-vm.sh` performs the low-level VM creation using parameters supplied by the caller.
- `cloudinit-vendor-debian.yml` applies the standard first-boot Debian configuration.

The intended workflow is:

```text
create-debian-vm.sh
        |
        +-- update-debian-image.sh
        |
        +-- build-debian-vm.sh
                |
                +-- Debian cloud image
                +-- Proxmox storage
                +-- cloud-init vendor snippet
```

## Repository Layout

```text
pve-debian-cloud-vm/
├── install.sh
├── scripts/
│   ├── create-debian-vm.sh
│   ├── build-debian-vm.sh
│   └── update-debian-image.sh
├── snippets/
│   └── cloudinit-vendor-debian.yml
├── README.md
└── LICENSE
```

`install.sh` is intended to install the scripts and cloud-init snippet onto a Proxmox VE host. Until that installer is added, the files can be deployed manually.

## Requirements

- Proxmox VE
- Bash
- Internet access to `cloud.debian.org`
- A Proxmox storage supporting the `import` content type
- A Proxmox storage supporting the `images` content type
- A Proxmox storage supporting the `snippets` content type

The scripts use standard Proxmox CLI tools including `pvesm`, `pvesh`, and `qm`.

## Debian Cloud Images

The project currently targets Debian 13 (Trixie) generic cloud images.

`update-debian-image.sh`:

- Determines the latest dated Debian cloud-image build.
- Downloads the image into the configured Proxmox `import` storage.
- Avoids downloading an image that is already present.
- Retains a configurable number of previous images for rollback.
- Uses Proxmox storage IDs rather than hardcoded filesystem paths.

Example Proxmox volume:

```text
local:import/debian-13-genericcloud-amd64-20260819-2575.qcow2
```

## Host Configuration

`create-debian-vm.sh` is intended to be customized for the Proxmox environment where it is installed.

The generic helper scripts do not attempt to infer host policy. The entry-point script supplies values such as:

```bash
HOST_IMPORT_STORAGE=""
HOST_SNIPPET_STORAGE=""
HOST_VM_STORAGE=""

HOST_CPU_TYPE=""

HOST_NETWORK_MODE=""
HOST_NETWORK_BRIDGE=""
HOST_VLAN_BRIDGE_PREFIX=""
HOST_DEFAULT_VLAN=""

HOST_DISK_OPTIONS=""

HOST_ROOT_PASSWORD=""
HOST_ROOT_PASSWORD_HASH=""
```

Blank storage IDs allow the entry-point script to discover and select appropriate Proxmox storage based on content type.

CPU and network settings are intentionally left unset in the canonical repository and should be configured for the target environment.

### Tagged Bridge Networking

Use `tagged-bridge` when multiple VLANs are carried on a single VLAN-aware Proxmox bridge.

Example:

```bash
HOST_IMPORT_STORAGE="local"
HOST_SNIPPET_STORAGE="local"
HOST_VM_STORAGE="local-lvm"

HOST_CPU_TYPE="x86-64-v3"

HOST_NETWORK_MODE="tagged-bridge"
HOST_NETWORK_BRIDGE="vmbr0"
HOST_VLAN_BRIDGE_PREFIX=""
HOST_DEFAULT_VLAN="40"

HOST_DISK_OPTIONS="discard=on,iothread=1,ssd=1"
```

The resulting VM NIC is configured approximately as:

```text
bridge=vmbr0,tag=40
```

### Per-VLAN Bridge Networking

Use `per-vlan-bridge` when each VLAN has its own Proxmox bridge.

Example:

```bash
HOST_IMPORT_STORAGE="ZFS_HDD_Files"
HOST_SNIPPET_STORAGE="ZFS_HDD_Files"
HOST_VM_STORAGE="ZFS_NVMe"

HOST_CPU_TYPE="Skylake-Server-v5"

HOST_NETWORK_MODE="per-vlan-bridge"
HOST_NETWORK_BRIDGE=""
HOST_VLAN_BRIDGE_PREFIX="vlan"
HOST_DEFAULT_VLAN="35"

HOST_DISK_OPTIONS="discard=on,iothread=1,ssd=1"
```

The resulting VM NIC is configured approximately as:

```text
bridge=vlan35
```

## Root Password

A default root password may optionally be configured in the host-specific `create-debian-vm.sh`.

Configure either plaintext:

```bash
HOST_ROOT_PASSWORD="change-me"
HOST_ROOT_PASSWORD_HASH=""
```

or a precomputed SHA-512 crypt hash:

```bash
HOST_ROOT_PASSWORD=""
HOST_ROOT_PASSWORD_HASH='$6$replace-with-generated-hash'
```

A compatible hash can be generated with:

```bash
openssl passwd -6 'change-me'
```

If neither value is configured, the VM creation workflow prompts for a root password interactively.

## VM Creation

Run the primary entry point:

```bash
./create-debian-vm.sh
```

The script updates the Debian image cache first and then interactively prompts for VM-specific settings that were not already supplied.

Typical values include:

- VM name
- VLAN
- RAM
- CPU cores
- disk size
- root password
- whether to start the VM after creation

Values may also be supplied through environment variables or CLI arguments. CLI arguments take precedence over environment variables.

Examples:

```bash
./create-debian-vm.sh \
    --name labserver01 \
    --vlan 40 \
    --ram-gb 8 \
    --cores 4 \
    --disk-gb 32
```

Skip the image update when desired:

```bash
./create-debian-vm.sh --skip-update
```

## VM Defaults

New VMs are created with a standardized Debian/Proxmox configuration including:

- Debian Linux guest type
- UEFI/OVMF
- Q35 machine type
- VirtIO SCSI
- QEMU guest agent
- serial console
- QXL display
- DHCP networking
- cloud-init vendor data
- configurable Proxmox storage
- configurable CPU model
- configurable VLAN networking

New VMs are automatically tagged:

```text
debian13
linux
new
```

The Proxmox Notes field is initialized with:

```text
**Hostname:** <VM name>

**Description:** TBD

**Native Services:** TBD

**Docker Services:** TBD

**OS:** Debian Linux 13 (Trixie)

**Date Created:** <YYYY-MM-DD>

**CNAME Aliases:** N/A

**Notes:**
```

The hostname and creation date are populated automatically.

## Cloud-Init Vendor Configuration

`snippets/cloudinit-vendor-debian.yml` provides the standard first-boot configuration for newly created Debian VMs.

The current baseline includes:

- Package list update and upgrade
- QEMU guest agent
- `parted`
- `gdisk`
- `btop`
- `cron`
- `curl`
- `chrony`
- `xfsprogs`
- DHCP client identification by MAC address
- root SSH login
- SSH password authentication
- IPv6 disabled through persistent sysctl configuration
- standard IPv6 entries commented in `/etc/hosts`
- `chrony` enabled instead of `systemd-timesyncd`
- periodic TRIM through `fstrim.timer`
- systemd SSH generator disabled
- reduced kernel console verbosity
- `quiet audit=0` added to the GRUB kernel command line
- cloud-init disabled after the initial configuration completes

The vendor file is intended to live in a Proxmox storage with the `snippets` content type enabled.

Example:

```text
local:snippets/cloudinit-vendor-debian.yml
```

## Suggested Installation Layout

The planned installer will deploy the scripts under:

```text
/opt/scripts/pve-debian-cloud-vm/
├── create-debian-vm.sh
├── build-debian-vm.sh
├── update-debian-image.sh
└── cloudinit-vendor-debian.yml -> <Proxmox snippet path>
```

A convenience command can then be exposed as:

```text
/usr/local/sbin/create-debian-vm
    -> /opt/scripts/pve-debian-cloud-vm/create-debian-vm.sh
```

This allows VM provisioning from anywhere with:

```bash
create-debian-vm
```

The `cloudinit-vendor-debian.yml` symlink provides a convenient path for editing the authoritative vendor snippet while leaving the actual file inside Proxmox-managed snippet storage.

## License

This project is licensed under the [Zero-Clause BSD License (0BSD)](LICENSE).
