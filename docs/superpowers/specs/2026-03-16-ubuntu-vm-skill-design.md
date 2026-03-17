# Ubuntu VM Skill — Design Spec

**Date:** 2026-03-16
**Skill name:** `ubuntu-vm`
**Purpose:** Create an Ubuntu Desktop VM on Steam Deck (SteamOS) via KVM/Virt-Manager with SSH access for AI Agent automation.

## Context

Steam Deck runs SteamOS (Arch-based, read-only filesystem). Testing software on Ubuntu requires a VM. The process involves many SteamOS-specific pitfalls (firewalld zones, system partition space, sudo timeout, terminal line-wrapping breaking long commands). This skill captures the full workflow so any AI Agent can reliably create and connect to an Ubuntu VM.

## Scope

- **In scope:** VM creation, SSH setup, connectivity verification
- **Out of scope:** Guest OS customization (locale, input methods, dev tools). Consumers of the VM handle their own setup after SSH is available.

## Prerequisites

| Check | How | Fix |
|-------|-----|-----|
| KVM support | `grep -c svm /proc/cpuinfo` + `lsmod \| grep kvm` | Kernel module issue — not fixable by script |
| steamos-readonly | `steamos-readonly status` | `sudo steamos-readonly disable` (re-enable after setup) |
| Packages | `pacman -Q qemu-desktop libvirt dnsmasq virt-install edk2-ovmf` | `sudo pacman -S --noconfirm <missing>` |
| Virt-Manager | `flatpak list \| grep virt-manager` | Pre-installed by user via Flatpak |
| libvirtd service | `systemctl is-active libvirtd` | `sudo systemctl start libvirtd && sudo systemctl enable libvirtd` |
| firewalld libvirt zone | `sudo virsh net-start default` fails with "can't find libvirt zone" | Write correct XML to `/etc/firewalld/zones/libvirt.xml`, `sudo firewall-cmd --reload` |
| default network | `sudo virsh net-list` | `sudo virsh net-start default && sudo virsh net-autostart default` |
| Disk space | `df -h /home/deck` | Need ~32GB free (6GB ISO + 25GB disk image) |
| SSH key | `~/.ssh/id_ed25519` exists | `ssh-keygen -t ed25519 -N ""` |

## VM Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| Name | `ubuntu-<ver>` (e.g. `ubuntu-2404`) | Derived from Ubuntu version |
| RAM | 8192 MB | Steam Deck has 16GB; Ubuntu Desktop + GNOME needs headroom |
| vCPUs | 4 | |
| Disk size | 25 GB | |
| Disk format | qcow2 | |
| Disk path | `~/VMs/<name>.qcow2` | Avoids `/var/lib/libvirt/images/` (system partition, ~200MB free) |
| Network | NAT (default) | |
| Graphics | SPICE + virtio video | |
| ISO path | `~/Downloads/<auto-detected>.iso` | |

## Workflow

### Phase 1: Infrastructure (Agent-automated)

All sudo commands are batched into `.sh` scripts to avoid sudo timeout issues. Agent writes scripts via tool, then prompts user to run with sudo.

**Step 1 — Check & install packages**

First check if VM with the target name already exists (`virsh dominfo <vm-name> 2>/dev/null`). If it does, ask user whether to use existing VM or recreate.

Write `/tmp/vm-setup-phase1.sh`:
```bash
#!/bin/bash
set -e
steamos-readonly disable
pacman -S --noconfirm --needed qemu-desktop libvirt dnsmasq virt-install edk2-ovmf
systemctl start libvirtd
systemctl enable libvirtd
usermod -aG libvirt deck
```

Prompt user: `sudo bash /tmp/vm-setup-phase1.sh`

**Step 2 — Fix firewalld + start network**

Write `/tmp/vm-setup-network.sh`:
```bash
#!/bin/bash
set -e
# Write libvirt zone (overwrites if broken — standard libvirt zone content)
cat > /etc/firewalld/zones/libvirt.xml << 'ZONEEOF'
<?xml version="1.0" encoding="utf-8"?>
<zone target="ACCEPT">
  <short>libvirt</short>
  <description>The libvirt zone for virtual network interfaces.</description>
  <interface name="virbr0"/>
  <protocol value="icmp"/>
  <protocol value="ipv6-icmp"/>
  <service name="dhcp"/>
  <service name="dhcpv6"/>
  <service name="dns"/>
  <service name="ssh"/>
  <service name="tftp"/>
</zone>
ZONEEOF
firewall-cmd --reload
virsh net-start default 2>/dev/null || true
virsh net-autostart default
```

Prompt user: `sudo bash /tmp/vm-setup-network.sh`

**Step 3 — Download Ubuntu ISO**

1. Use WebFetch or `wget -qO-` to fetch `https://releases.ubuntu.com/<version>/` (default: `24.04`)
2. Parse HTML for the `ubuntu-*-desktop-amd64.iso` filename (e.g. `ubuntu-24.04.4-desktop-amd64.iso`)
3. Check if ISO already exists in `~/Downloads/` (skip download if present)
4. `wget -c -P ~/Downloads https://releases.ubuntu.com/<version>/<iso-filename>`

**Step 4 — Create VM**

Check idempotency: if `virsh dominfo <vm-name>` succeeds, the VM already exists. Ask user before proceeding.

Write `/tmp/vm-create.sh` (with actual values substituted):
```bash
#!/bin/bash
set -e
mkdir -p /home/deck/VMs
virt-install --name <vm-name> --ram 8192 --vcpus 4 \
  --disk path=/home/deck/VMs/<vm-name>.qcow2,size=25,format=qcow2 \
  --cdrom /home/deck/Downloads/<iso-filename> \
  --os-variant ubuntu24.04 \
  --network network=default \
  --graphics spice --video virtio \
  --check disk_size=off \
  --noautoconsole
```

Prompt user: `sudo bash /tmp/vm-create.sh`

### Phase 2: Ubuntu Installation (User-interactive)

1. Prompt user: open **Virt-Manager** (Flatpak) and double-click the VM
2. **Important:** Instruct user to click **"Install Ubuntu"** (not just use the Live session)
3. After installation completes, user provides: **username** and **password**
4. Instruct user to open a terminal inside the VM and run:
   ```
   sudo apt install -y openssh-server ssh-askpass-gnome
   ```

### Phase 3: SSH Setup (Agent-automated)

**Step 5 — SSH key setup (host side)**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" 2>/dev/null || true
```

(Skip if key already exists)

**Step 6 — Get VM IP**

Use `virsh net-dhcp-leases default` (more reliable than `virsh domifaddr` which requires qemu-guest-agent):

Write `/tmp/vm-get-ip.sh`:
```bash
#!/bin/bash
virsh net-dhcp-leases default
```

Prompt user: `sudo bash /tmp/vm-get-ip.sh`

Parse IP from output (the row matching the VM's MAC address).

**Step 7 — SSH key copy**

```bash
ssh-copy-id <user>@<ip>
```

User enters VM password when prompted.

**Step 8 — Verify SSH**

```bash
ssh <user>@<ip> echo "VM ready"
```

**Step 9 — Eject ISO**

Write `/tmp/vm-eject.sh`:
```bash
#!/bin/bash
# Discover CDROM device name
CDROM_DEV=$(virsh domblklist <vm-name> | grep iso | awk '{print $1}')
[ -n "$CDROM_DEV" ] && virsh change-media <vm-name> "$CDROM_DEV" --eject 2>/dev/null || true
echo "ISO ejected (device: $CDROM_DEV)"
```

Prompt user: `sudo bash /tmp/vm-eject.sh`

Note: ISO eject is done AFTER SSH is verified (not before), because rebooting before SSH setup could change the VM's DHCP-assigned IP.

## Known SteamOS Pitfalls

| Problem | Cause | Solution |
|---------|-------|----------|
| Long commands break when pasted | Terminal auto-wraps and splits at spaces | Always write commands to `.sh` files |
| sudo times out between commands | SteamOS default sudo timeout is short | Batch all sudo commands in one script |
| `/var/lib/libvirt/images/` full | System partition ~200MB free | Use `~/VMs/` on home partition |
| `virsh net-start default` fails | firewalld missing libvirt zone | Write zone XML + reload firewalld |
| VM boots to "No bootable device" | User exited Live CD without installing | Re-attach ISO: `virsh change-media <vm> <dev> <iso> --insert` |
| Packages disappear after SteamOS update | SteamOS resets system partition | Re-run Phase 1; consider `steamos-readonly enable` after setup |
| SSH from Claude Code sandbox fails | No askpass helper / password auth | Install ssh-askpass-gnome in VM + use key auth |
| `virsh domifaddr` returns empty | qemu-guest-agent not installed in VM | Use `virsh net-dhcp-leases default` instead |
| CDROM device name varies | Depends on bus type (IDE=hda, SATA=sda) | Discover via `virsh domblklist` |
| Group membership not active | `usermod -aG libvirt` needs re-login | Use `sudo` for all virsh commands throughout |
| VM already exists on re-run | Previous partial run left artifacts | Check `virsh dominfo` before creating |

## Output

On success, the skill produces:
- A running Ubuntu VM accessible via `ssh <user>@<ip>`
- VM name, IP, username reported to the user/agent
- Agent can execute arbitrary commands in VM via SSH

## Future Enhancements

- `cloud-init` / `autoinstall` for fully unattended Ubuntu installation
- `--boot uefi` option for UEFI-based installation
- Snapshot support for quick reset to clean state
