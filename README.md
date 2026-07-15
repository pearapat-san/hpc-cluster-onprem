[README.md](https://github.com/user-attachments/files/30042791/README.md)
# On-Premises HPC Cluster

A three-node, on-premises High-Performance Computing (HPC) cluster built on **Rocky Linux 9.8** and the **OpenHPC 3.4** software stack. The cluster provides diskless (stateless) provisioning with **Warewulf 4**, job scheduling with **Slurm**, low-latency **InfiniBand** RDMA interconnect for MPI, and a shared **Lustre** parallel filesystem.

The design and every deployment step were validated end-to-end, including survival of a full cold reboot with no manual intervention required. This README is written as a reproducible build guide.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Software Stack](#software-stack)
- [Network Topology](#network-topology)
- [Prerequisites](#prerequisites)
- [Deployment Guide](#deployment-guide)
  - [1. Prepare the Master Node](#1-prepare-the-master-node)
  - [2. Install OpenHPC](#2-install-openhpc)
  - [3. Configure Warewulf 4 Provisioning](#3-configure-warewulf-4-provisioning)
  - [4. Build the Compute Image](#4-build-the-compute-image)
  - [5. Register and Boot Nodes](#5-register-and-boot-nodes)
  - [6. Configure Slurm](#6-configure-slurm)
  - [7. Configure the Lustre Filesystem](#7-configure-the-lustre-filesystem)
- [Validation](#validation)
- [Persistence & Cold-Boot Behavior](#persistence--cold-boot-behavior)
- [Troubleshooting](#troubleshooting)
- [Lessons Learned](#lessons-learned)
- [Roadmap](#roadmap)
- [License](#license)

---

## Overview

| Node | Role | Provisioning | Storage |
|------|------|--------------|---------|
| **master** | Login node, Warewulf provisioner, Slurm controller, Lustre client | Stateful (local disk) | Local disk |
| **compute** | Slurm execution node, MPI compute | Stateless (PXE boot from master) | Diskless |
| **lustre** | Lustre server (MGS + MDS + OSS on a ZFS pool), Lustre client | Stateless (PXE boot from master) | ZFS `lustre-pool` |

Key characteristics:

- **Diskless compute:** compute and lustre nodes boot over the network via Warewulf 4; only the master node keeps state on local disk.
- **RDMA MPI:** inter-node MPI traffic runs over InfiniBand using UCX `rc_verbs` (true RDMA, ~7 µs latency), not TCP fallback.
- **Self-healing boot order:** a retry service resolves boot-order races so that nodes can start in any order after the master is up.
- **Cold-reboot resilient:** LNet pinning, the Lustre client mount, Slurm, and MPI RDMA all recover automatically after a full power cycle.

---

## Architecture

```
                 public switch (192.168.111.0/24)
                              │
                              │  eno1: 192.168.111.53
                       ┌──────┴───────┐
                       │    master    │  Rocky 9.8
                       │ login +      │  Warewulf 4 + Slurm ctld
                       │ provisioner  │  Lustre client
                       └──────┬───────┘
                              │  eno2: 192.168.100.10
              private / provisioning switch (192.168.100.0/24)
                     ┌────────┴─────────┐
                     │                  │
              ┌──────┴──────┐    ┌──────┴──────┐
              │   compute   │    │   lustre    │
              │ .11 (PXE)   │    │ .12 (PXE)   │
              └──────┬──────┘    └──────┬──────┘
                     │                  │
                     └── InfiniBand ────┘
              (ibs2, 192.168.200.0/24, QDR 40 Gb)
              master .10 · compute .11 · lustre .12
```

The **private switch** is the provisioning and management network. Warewulf uses it for DHCP / TFTP / PXE boot. **PXE does not run over InfiniBand** because the QLogic HCA does not support PXE boot; InfiniBand carries only MPI and storage (LNet/IPoIB) traffic.

---

## Software Stack

| Component | Version / Detail |
|-----------|------------------|
| Operating system | Rocky Linux 9.8 (Blue Onyx) |
| Kernel | `5.14.0-687.24.1.el9_8.x86_64` |
| HPC stack | OpenHPC 3.4 (EL9) |
| Provisioning | Warewulf 4 (`ohpc-warewulf`) |
| Resource manager | Slurm (`ohpc` packages) |
| InfiniBand HCA | QLogic IBA7322 QDR (TrueScale), driver `ib_qib` |
| RDMA transport | UCX `rc_verbs` / `ud_verbs` over `qib0` |
| Parallel filesystem | Lustre (server on ZFS pool + clients) |
| LNet | `tcp` (ksocklnd) over IPoIB, pinned to `ibs2` |
| Firmware mode | Legacy BIOS (no UEFI / Secure Boot) |

> **Important stack constraints**
> - OpenHPC 3.x supports **Warewulf 4 only** — there is no Warewulf 3 package in the `ohpc` repository.
> - The QLogic TrueScale HCA uses **verbs via UCX**, **not** PSM2. `libpsm2` targets Omni-Path hardware and does **not** work with this card.
> - `kmod-ib_qib` is tied to an exact kernel version; the kernel must match on the master and inside every compute image.

---

## Network Topology

| Interface | Node | Address | Network | Purpose |
|-----------|------|---------|---------|---------|
| `eno1` | master | 192.168.111.53/24 | Public switch | External / login access |
| `eno2` | master | 192.168.100.10/24 | Private switch | Provisioning (DHCP/TFTP/PXE) |
| `ibs2` | master | 192.168.200.10/24 | InfiniBand | MPI + Lustre (LNet) |
| provisioning | compute | 192.168.100.11/24 | Private switch | PXE / management |
| `ibs2` | compute | 192.168.200.11/24 | InfiniBand | MPI + Lustre |
| provisioning | lustre | 192.168.100.12/24 | Private switch | PXE / management |
| `ibs2` | lustre | 192.168.200.12/24 | InfiniBand | Lustre server (LNet) |

Node numbering convention: **1 = master, 2 = compute, 3 = lustre.**

---

## Prerequisites

- Three x86-64 servers with **matching QLogic TrueScale InfiniBand HCAs** (the compute node HCA must match the master so the embedded driver works).
- A managed or unmanaged switch for the private provisioning network, plus an InfiniBand switch with an active subnet manager (SM).
- Rocky Linux 9.8 installation media for the master node.
- Legacy BIOS PXE boot enabled on the compute/lustre nodes' NICs.
- Administrative (`sudo` / root) access on the master node.

> **Subnet manager:** the InfiniBand fabric already runs a subnet manager (e.g. from the switch, `SM lid=1`). **Do not** start `opensm` on the master — running a second SM will conflict with the existing one.

---

## Deployment Guide

The steps below are run on the **master** node. The cluster was built entirely via an operator walkthrough (each command run manually and its output verified) — no remote automation is assumed.

### 1. Prepare the Master Node

Install Rocky Linux 9.8 and confirm the kernel and firmware mode:

```bash
uname -r                 # expect 5.14.0-687.24.1.el9_8.x86_64
mokutil --sb-state       # expect "SecureBoot disabled" / legacy BIOS
```

Configure the three networks (`eno1` public, `eno2` private, `ibs2` InfiniBand) with the addresses from the [topology table](#network-topology).

Install the InfiniBand driver stack. **Update and reboot first so the kernel is stable, then install the `kmod` that matches the running kernel exactly:**

```bash
# 1) Get the kernel to its final version first
dnf update -y && reboot

# 2) After reboot, install the RDMA userspace + matching kernel module
dnf install -y rdma-core libibverbs libibverbs-utils infiniband-diags perftest
dnf install -y kmod-ib_qib          # must match `uname -r`
depmod -a
modprobe ib_qib

# 3) Verify the link is Active at QDR (40 Gb)
ibstat
```

> **Order matters:** never run `dnf update` *after* installing a `kmod` — a kernel bump will leave the module version mismatched. Verify with `dnf list available kmod-ib_qib` against `uname -r` before installing.

### 2. Install OpenHPC

```bash
dnf install -y http://repos.openhpc.community/OpenHPC/3/EL_9/x86_64/ohpc-release-3-1.el9.x86_64.rpm
dnf repolist | grep -i ohpc         # expect: OpenHPC and OpenHPC-updates
dnf install -y ohpc-base ohpc-warewulf
```

`ohpc-warewulf` pulls in Warewulf 4 (`warewulf-ohpc`). **Do not install Warewulf from any other repository** — it will conflict with the OpenHPC package.

### 3. Configure Warewulf 4 Provisioning

Point Warewulf at the private provisioning interface (`eno2`, 192.168.100.10):

```bash
# /etc/warewulf/warewulf.conf
#   ipaddr:  192.168.100.10
#   netmask: 255.255.255.0
#   network: 192.168.100.0
#   dhcp:    enabled = true
#   tftp:    enabled = true

wwctl configure --all               # generate DHCP / TFTP / PXE config
```

> **Legacy BIOS PXE:** Warewulf 4 defaults toward UEFI/iPXE. On legacy-BIOS hardware, confirm the node chainloads the BIOS iPXE binary (`undionly.kpxe`) rather than a UEFI-only image. Debug the first compute boot with `journalctl -u dhcpd`, `/var/log/messages`, and `tcpdump port 69`.

### 4. Build the Compute Image

Import a Rocky 9 container/OS image and **embed the full InfiniBand stack** so compute nodes come up with working RDMA:

```bash
wwctl container import docker://rockylinux:9 rocky9
```

Inside the image, install a kernel that matches `5.14.0-687.24.1.el9_8`, plus:

- `kmod-ib_qib` (exactly matching the image kernel)
- `rdma-core`, `libibverbs`, `infiniband-diags`
- UCX and the MPI toolchain (`gnu14`, `openmpi5`, etc. from OpenHPC)

If the IB stack is missing from the image, compute nodes will either have no InfiniBand or only partial support, and MPI will silently fall back to slow TCP over IPoIB.

The built image lives at `/srv/warewulf/provision/images/rocky9.img.gz`; the chroot is `/srv/warewulf/chroots/rocky9/rootfs`; overlays are under `/srv/warewulf/overlays`.

### 5. Register and Boot Nodes

Register the compute and lustre nodes, attach the appropriate overlays, build them, and PXE boot:

```bash
wwctl node add compute --netdev eno2 --hwaddr <COMPUTE_MAC> --ipaddr 192.168.100.11
wwctl node add lustre  --netdev eno2 --hwaddr <LUSTRE_MAC>  --ipaddr 192.168.100.12

# Assign site overlays (note: `-O` REPLACES the overlay list — always pass the full set)
wwctl node set compute -O slurm,lustre-client
wwctl node set lustre  -O lustre-srv

wwctl overlay build
```

Set the InfiniBand address on each node (192.168.200.11 / .12) via overlay or post-boot configuration, then PXE boot the nodes. **Always power on the master first**; the stateless nodes boot from it.

### 6. Configure Slurm

Define the controller and partition in `slurm.conf`, and synchronize the munge key through a Warewulf overlay:

```ini
# /etc/slurm/slurm.conf (excerpt)
NodeName=compute ...
NodeName=master  ...
PartitionName=normal Nodes=compute,master Default=YES State=UP
```

Enable and start the controller, then confirm the nodes register:

```bash
systemctl enable --now slurmctld
sinfo        # partition "normal" up, nodes idle
```

### 7. Configure the Lustre Filesystem

The lustre node runs a single-server Lustre deployment (MGS + MDS + OSS) backed by a ZFS pool (`lustre-pool`). Clients mount it over LNet (`tcp` / ksocklnd on IPoIB):

```bash
# On clients (master, compute)
mount -t lustre 192.168.200.12@tcp:/lustre /mnt/lustre
```

Pin LNet to the InfiniBand interface so it never binds to the wrong NIC after reboot:

```bash
# /etc/modprobe.d/lnet.conf
options lnet networks="tcp0(ibs2)"
```

A `lustre-client.service` (enabled) retries the mount to absorb boot-order races so `/mnt/lustre` comes back automatically on every boot.

---

## Validation

Run the following on the master to confirm the full stack is healthy. Wrap the block with `2>&1 | tee ~/cluster-validation-$(date +%Y%m%d).log` to capture evidence.

```bash
# [1] COLD BOOT CONFIRMED
echo "=== [1] COLD BOOT CONFIRMED ===" && uptime && who -b

# [2] LNET NID (ibs2 only, no eno1)
echo "=== [2] LNET NID (ibs2 only, no eno1) ===" && lnetctl net show | grep -A4 'net type: tcp'

# [3] LUSTRE CLIENT AUTO-MOUNT
echo "=== [3] LUSTRE CLIENT AUTO-MOUNT ===" && \
  systemctl is-enabled lustre-client.service && \
  systemctl is-active lustre-client.service && \
  mountpoint /mnt/lustre && \
  lfs df -h /mnt/lustre | grep -E 'MDT|OST|summary'

# [4] SLURM CONTROLLER + NODES
echo "=== [4] SLURM CONTROLLER + NODES ===" && systemctl is-active slurmctld && sinfo

# [5] MPI INTER-NODE RDMA (UCX rc_verbs / QLogic qib0)
module load gnu14 openmpi5 imb
export OMPI_MCA_pml=ucx UCX_TLS=rc_verbs,ud_verbs,sm,self UCX_NET_DEVICES=qib0:1
unset OMPI_MCA_mtl OMPI_MCA_mtl_ofi_provider_include FI_PROVIDER
echo "=== [5] MPI INTER-NODE RDMA ===" && \
  srun -N2 -n2 --mpi=pmix IMB-MPI1 PingPong 2>&1 | awk '/#bytes/{p=1} p'
```

**Expected results (validated):**

| Check | Result |
|-------|--------|
| Cold boot | `who -b` shows a fresh boot time; `uptime` low |
| LNet | Single NID `192.168.200.10@tcp` up on `ibs2`; `eno1` does **not** appear |
| Lustre client | `lustre-client.service` enabled + active; `/mnt/lustre` mounted; MDT0000 + OST0000 online |
| Slurm | `slurmctld` active; partition `normal` up with nodes `compute,master` idle |
| MPI RDMA | PingPong latency ~**7 µs** (true RDMA, not ~50 µs TCP); peak bandwidth ~**3.15 GB/s** at 4 MB |

---

## Persistence & Cold-Boot Behavior

The cluster was verified to fully recover from a hard power cycle with **zero manual steps**:

- **Master** is the only stateful node. Persistence is achieved with a `/etc/modprobe.d/lnet.conf` pin and systemd services.
- **LNet pinning** (`tcp0(ibs2)`) survives reboot, so LNet never re-binds to `eno1`.
- **Lustre client** re-mounts automatically via the enabled retry service, absorbing boot-order races.
- **Slurm** controller restarts and compute rejoins within ~3 minutes of PXE boot.
- **MPI RDMA** comes back on the InfiniBand fabric without reconfiguration.
- **Boot order:** always start the master first; compute and lustre are stateless and PXE-boot from it. The retry service allows lustre/compute to start in any order relative to each other.
- **MEMLOCK:** slurmd jobs receive `LimitMEMLOCK=infinity` via a systemd drop-in (a plain login shell's `ulimit -l` is unrelated).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| MPI latency ~50 µs instead of ~7 µs | MPI fell back to TCP over IPoIB | Ensure UCX env is set (`OMPI_MCA_pml=ucx`, `UCX_TLS=rc_verbs,...`, `UCX_NET_DEVICES=qib0:1`) and IB stack is present in the image |
| `modprobe ib_qib` fails after update | Kernel and `kmod-ib_qib` version mismatch | Update + reboot to a stable kernel first, then install the matching `kmod`; verify with `dnf list available kmod-ib_qib` vs `uname -r` |
| Compute node never PXE boots | Warewulf served a UEFI-only image to legacy BIOS | Confirm BIOS iPXE chainload (`undionly.kpxe`); inspect `journalctl -u dhcpd`, `tcpdump port 69` |
| IB port shows Down after setting IP | IP was set on the inactive port (`ibs2d1`, no cable) | Check `ibstat` / `ip link` and configure only the Active port (`ibs2`) |
| LNet binds to `eno1` after reboot | Missing modprobe pin | Set `options lnet networks="tcp0(ibs2)"` in `/etc/modprobe.d/lnet.conf` |
| `/mnt/lustre` missing after boot | Boot-order race with the Lustre server | Rely on the enabled `lustre-client.service` retry; ensure it is `enabled` |
| Fabric errors after enabling `opensm` | Duplicate subnet manager | Do **not** run `opensm` on the master; the switch already provides the SM |

---

## Lessons Learned

- Install the InfiniBand `kmod` **after** the kernel is finalized — updating the kernel afterward breaks the module.
- Verify package names carefully. An earlier attempt installed `kmod-rtw88_usb` (a Realtek Wi-Fi driver) instead of `kmod-ib_qib`.
- Always confirm which InfiniBand port is Active (`ibstat`) before assigning an IP; the second port had no cable.
- OpenHPC 3.x requires Warewulf 4 — do not attempt Warewulf 3.
- The QLogic TrueScale HCA uses verbs via UCX, not PSM2/`libpsm2` (which is for Omni-Path).

---

## Roadmap

Core cluster is complete and validated. Remaining items are optional:

- Decide whether the master remains a permanent Slurm execution node.
- Clean up cosmetic `slurmctld` warnings (`MailProg`, `JobAcctGatherType`).
- Optional IPoIB / verbs performance tuning (TrueScale verbs run below newer-card line rate by nature).
- Expand the Lustre deployment beyond a single server (currently MGS + MDS + OSS on one node) if capacity demands.

---

## License

Released under the [MIT License](LICENSE).
