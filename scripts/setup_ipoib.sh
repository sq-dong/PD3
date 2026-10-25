#!/usr/bin/env bash
# Bring up IPoIB for PD3 RDMA tests (needs sudo).
# memserver16 (Compute host): ibs6f0 -> 10.10.1.16/24
# bfhost_72  (Memory):        ibs2f0 -> 10.10.1.72/24
# DPU ARM: assign 10.10.1.201/24 on the DPU's IB netdev (see ibdev2netdev).

set -euo pipefail

ROLE="${1:-}"
if [[ -z "${ROLE}" ]]; then
  echo "Usage: $0 host|memory|dpu [iface]"
  echo "  host   - memserver16, default iface ibs6f0 -> 10.10.1.16/24"
  echo "  memory - bfhost_72,  default iface ibs2f0 -> 10.10.1.72/24"
  echo "  dpu    - DPU ARM,    default iface from ibdev2netdev (ACTIVE IB) -> 10.10.1.201/24"
  exit 1
fi

case "${ROLE}" in
  host)
    IFACE="${2:-ibs6f0}"
    ADDR="10.10.1.16/24"
    ;;
  memory)
    IFACE="${2:-ibs2f0}"
    ADDR="10.10.1.72/24"
    ;;
  dpu)
    IFACE="${2:-}"
    if [[ -z "${IFACE}" ]]; then
      IFACE="$(ibdev2netdev 2>/dev/null | awk '/ACTIVE/ && /==>/ {print $NF; exit}' | tr -d '()' || true)"
    fi
    if [[ -z "${IFACE}" || "${IFACE}" == "Down" ]]; then
      echo "Could not auto-detect DPU IB netdev; pass iface explicitly."
      ibdev2netdev -v || true
      exit 1
    fi
    ADDR="10.10.1.201/24"
    ;;
  *)
    echo "Unknown role: ${ROLE}"
    exit 1
    ;;
esac

echo "Configuring ${IFACE} -> ${ADDR}"
sudo ip link set "${IFACE}" up
sudo ip addr replace "${ADDR}" dev "${IFACE}"
ip -br addr show "${IFACE}"
echo "Done. Export matching env if needed:"
echo "  export PD3_MEMORY_RDMA_IP=10.10.1.72"
echo "  export PD3_DPU_RDMA_IP=10.10.1.201"
