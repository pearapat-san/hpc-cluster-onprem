#!/usr/bin/env bash
# ============================================================================
# validate-cluster.sh — end-to-end health check for the HPC cluster
#
# Run on the MASTER node. Confirms that provisioning, Slurm, MPI RDMA over
# InfiniBand, and the Lustre client all recovered correctly (e.g. after a
# cold reboot). A log is written to ~/cluster-validation-<date>.log.
#
# Usage:
#   ./validate-cluster.sh
# ============================================================================

set -uo pipefail

LOG="${HOME}/cluster-validation-$(date +%Y%m%d-%H%M%S).log"

# Send all output to both the console and the log file.
exec > >(tee "${LOG}") 2>&1

echo "############################################################"
echo "# HPC cluster validation — $(date)"
echo "# log: ${LOG}"
echo "############################################################"

# --- [1] Cold boot confirmed ---------------------------------------------
echo
echo "=== [1] COLD BOOT CONFIRMED ==="
uptime
who -b

# --- [2] LNet NID: ibs2 only, no eno1 ------------------------------------
echo
echo "=== [2] LNET NID (ibs2 only, no eno1) ==="
lnetctl net show | grep -A4 'net type: tcp'

# --- [3] Lustre client auto-mount ----------------------------------------
echo
echo "=== [3] LUSTRE CLIENT AUTO-MOUNT ==="
systemctl is-enabled lustre-client.service
systemctl is-active  lustre-client.service
mountpoint /mnt/lustre
lfs df -h /mnt/lustre | grep -E 'MDT|OST|summary'

# --- [4] Slurm controller + nodes ----------------------------------------
echo
echo "=== [4] SLURM CONTROLLER + NODES ==="
systemctl is-active slurmctld
sinfo

# --- [5] MPI inter-node RDMA over InfiniBand -----------------------------
# QLogic TrueScale (qib0) uses UCX rc_verbs/ud_verbs — NOT PSM2.
echo
echo "=== [5] MPI INTER-NODE RDMA (UCX rc_verbs / QLogic qib0) ==="
module load gnu14 openmpi5 imb
export OMPI_MCA_pml=ucx
export UCX_TLS=rc_verbs,ud_verbs,sm,self
export UCX_NET_DEVICES=qib0:1
unset OMPI_MCA_mtl OMPI_MCA_mtl_ofi_provider_include FI_PROVIDER
srun -N2 -n2 --mpi=pmix IMB-MPI1 PingPong 2>&1 | awk '/#bytes/{p=1} p'

echo
echo "############################################################"
echo "# Validation complete. Expected highlights:"
echo "#   [2] single NID 192.168.200.10@tcp up on ibs2 (no eno1)"
echo "#   [3] lustre-client enabled+active, /mnt/lustre mounted, MDT+OST online"
echo "#   [4] slurmctld active, partition 'normal' up, nodes compute,master idle"
echo "#   [5] PingPong latency ~7us (RDMA, not ~50us TCP), peak BW ~3.15 GB/s"
echo "############################################################"
