#!/usr/bin/env bash
# Orchestrate PD3-test-apps.md §6 from the Compute host (memserver16).
# Cannot be a single local process: Memory=72, TE=DPU, Client=host.
#
# Usage (on memserver16):
#   ./scripts/run_section6.sh              # memory + prefetch + DMA (needs mini_agent) + Refresh + Client
#   ./scripts/run_section6.sh --prefetch-only
#   ./scripts/run_section6.sh --skip-dma
#   ./scripts/run_section6.sh --skip-client
#
# Prereq: binaries built (incl. mini_agent on host); IPoIB up; SSH to 72 + DPU.

set -euo pipefail

HOST_PD3="${HOST_PD3:-/home/dongshuqi/PD3}"
REMOTE_PD3="${REMOTE_PD3:-/home/dongshuqi/PD3}"
DPU_HOST="${DPU_HOST:-dongshuqi@192.168.100.2}"
MEM_HOST="${MEM_HOST:-bfhost_72}"
HOST_RUNTIME="${HOST_RUNTIME:-/home/dongshuqi/pd3_runtime}"
DPU_RUNTIME="${DPU_RUNTIME:-/tmp/pd3_runtime}"

PREFETCH_ONLY=0
SKIP_DMA=0
SKIP_CLIENT=0
SKIP_REFRESH=0

for arg in "$@"; do
  case "$arg" in
    --prefetch-only) PREFETCH_ONLY=1 ;;
    --skip-dma) SKIP_DMA=1 ;;
    --with-dma) SKIP_DMA=0 ;; # default already runs DMA; kept for compat
    --skip-client) SKIP_CLIENT=1 ;;
    --skip-refresh) SKIP_REFRESH=1 ;;
    -h|--help)
      sed -n '2,14p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

# ClearAllForwardings: bfhost_72 has RemoteForward 7890 which often fails and can
# trip ExitOnForwardFailure. Kill pattern must NOT appear in the ssh cmdline path
# (e.g. avoid pkill + /tmp/pd3_memory_backend.log in one remote command — pkill -f
# matches the log path and suicides the remote shell → ssh exit 255).
ssh_mem() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes "$MEM_HOST" "$@"; }
ssh_dpu() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o ClearAllForwardings=yes "$DPU_HOST" "$@"; }
kill_mem_backend() {
  ssh_mem 'pkill -f "/build/bin/pd3_memory_backend" || true' || true
}

cleanup() {
  echo "[cleanup] stopping helpers..."
  pkill -f '[m]ini_agent' 2>/dev/null || true
  kill_mem_backend 2>/dev/null || true
  ssh_dpu 'pkill -f "[t]ransfer_engine_test" || true; pkill -f "[/]build/bin/tests" || true' 2>/dev/null || true
}
trap cleanup EXIT

echo "=== §6 orchestrator (host=$(hostname)) ==="

echo "[1/6] start pd3_memory_backend on $MEM_HOST"
# Truncate log in a separate ssh from pkill (see kill_mem_backend comment above).
kill_mem_backend
sleep 1
ssh_mem ': > /tmp/pd3_mem.log' || true
ssh_mem "ip -br a show ibs2f0 2>/dev/null || ip -br a | grep -E 'ib|mlx' || true" || true
mem_ok=0
for attempt in 1 2 3; do
  ssh -f -o BatchMode=yes -o ClearAllForwardings=yes "$MEM_HOST" \
    "cd '$REMOTE_PD3' && export LD_LIBRARY_PATH=\$PWD/build/lib && \
     export PD3_MEMORY_RDMA_IP=10.10.1.72 PD3_RDMA_PORT=51216 && \
     nohup ./build/bin/pd3_memory_backend >> /tmp/pd3_mem.log 2>&1 &"
  sleep 3
  if ssh_mem 'pgrep -f "/build/bin/pd3_memory_backend" >/dev/null \
      && grep -qE "RDMA listen started|listening on" /tmp/pd3_mem.log \
      && ! grep -q "Failed to bind address" /tmp/pd3_mem.log'; then
    mem_ok=1
    break
  fi
  echo "  memory start attempt $attempt failed; retrying..." >&2
  kill_mem_backend
  sleep 2
  ssh_mem ': > /tmp/pd3_mem.log' || true
done
if [[ "$mem_ok" -ne 1 ]]; then
  echo "memory backend failed to start; log:" >&2
  ssh_mem 'tail -40 /tmp/pd3_mem.log' >&2 || true
  echo "Hint: on bfhost_72 run: sudo bash ~/setup_ipoib.sh memory  (need ibs2f0 = 10.10.1.72)" >&2
  exit 1
fi
echo "  memory OK"

echo "[2/6] DPU RDMA prefetch (no DMA)"
# set -e: do not print "prefetch OK" if Catch2 failed (was masking empty responses).
if ssh_dpu "cd '$REMOTE_PD3' && export LD_LIBRARY_PATH=\$PWD/build/lib && \
  export PD3_DPU_PCIE=03:00.0 PD3_DPU_RDMA_IP=10.10.1.201 && \
  export PD3_MEMORY_RDMA_IP=10.10.1.72 PD3_RDMA_PORT=51216 && \
  ./build/bin/tests 'TransferEngine Prefetching no DMA,TransferEngine Prefetching Throughput' -r compact"; then
  echo "  prefetch OK"
else
  echo "  prefetch FAILED (often memory bind/IPoIB; see 72 /tmp/pd3_mem.log)" >&2
  exit 1
fi

if [[ "$PREFETCH_ONLY" -eq 1 ]]; then
  echo "=== done (--prefetch-only) ==="
  exit 0
fi

if [[ "$SKIP_DMA" -eq 0 ]]; then
  echo "[3/6] start mini_agent on host + scp agent files to DPU"
  pkill -f '[m]ini_agent' 2>/dev/null || true
  mkdir -p "$HOST_RUNTIME"
  (
    cd "$HOST_PD3"
    export LD_LIBRARY_PATH=$PWD/build/lib
    export PD3_HOST_PCIE=98:00.0 PD3_HOST_RUNTIME_DIR="$HOST_RUNTIME"
    nohup ./build/bin/mini_agent > /tmp/pd3_mini_agent.log 2>&1 &
  )
  for i in $(seq 1 30); do
    if [[ -f "$HOST_RUNTIME/agent_export_desc" && -f "$HOST_RUNTIME/agent_buf_details.txt" ]]; then
      break
    fi
    sleep 0.5
  done
  if [[ ! -f "$HOST_RUNTIME/agent_export_desc" ]]; then
    echo "mini_agent failed to write export files; log:" >&2
    tail -30 /tmp/pd3_mini_agent.log >&2 || true
    exit 1
  fi
  ssh_dpu "mkdir -p '$DPU_RUNTIME'"
  scp -o BatchMode=yes \
    "$HOST_RUNTIME/agent_export_desc" "$HOST_RUNTIME/agent_buf_details.txt" \
    "$DPU_HOST:$DPU_RUNTIME/"
  echo "  mini_agent OK; files on DPU"

  echo "[3b/6] DPU DMA suite"
  ssh_dpu "cd '$REMOTE_PD3' && export LD_LIBRARY_PATH=\$PWD/build/lib && \
    mkdir -p '$DPU_RUNTIME' && export PD3_DPU_RUNTIME_DIR='$DPU_RUNTIME' && \
    export PD3_DPU_PCIE=03:00.0 PD3_DPU_RDMA_IP=10.10.1.201 && \
    export PD3_MEMORY_RDMA_IP=10.10.1.72 PD3_RDMA_PORT=51216 && \
    ./build/bin/tests 'TransferEngine Prefetching with DMA Correctness,TransferEngine DMA Prefetching Throughput,TransferEngine DMA Prefetching and TE Reads Throughput' -r compact" \
    || echo "  DMA suite had failures (see DPU output; some cases still need TE source uncomment)"
fi

# Host TransferClient writes tc_*; DPU TE waits for / reads them (host → DPU scp).
# Stale DPU tc_* make TE "succeed" wait with a dead mmap — always clear first.
wait_host_tc() {
  local i
  for i in $(seq 1 50); do
    if [[ -f "$HOST_RUNTIME/tc_export_desc" && -f "$HOST_RUNTIME/tc_buf_details.txt" ]]; then
      return 0
    fi
    sleep 0.2
  done
  echo "host tc_* not written in time" >&2
  return 1
}

scp_tc_host_to_dpu() {
  scp -o BatchMode=yes \
    "$HOST_RUNTIME/tc_export_desc" "$HOST_RUNTIME/tc_buf_details.txt" \
    "$DPU_HOST:$DPU_RUNTIME/"
}

run_refresh() {
  local n="$1"
  local hv_pid=""
  echo "[4/6] Refresh Test $n (DPU Catch2 waits; host hv_refresh writes tc_* → scp to DPU)"
  mkdir -p "$HOST_RUNTIME"
  rm -f "$HOST_RUNTIME"/tc_*
  ssh_dpu "mkdir -p '$DPU_RUNTIME'; rm -f '$DPU_RUNTIME'/tc_*; pkill -f '[/]build/bin/tests' || true; pkill -f '[t]ransfer_engine_test' || true"

  ssh -f -o BatchMode=yes "$DPU_HOST" \
    "cd '$REMOTE_PD3' && export LD_LIBRARY_PATH=\$PWD/build/lib && \
     mkdir -p '$DPU_RUNTIME' && export PD3_DPU_RUNTIME_DIR='$DPU_RUNTIME' && \
     export PD3_DPU_PCIE=03:00.0 PD3_DPU_RDMA_IP=10.10.1.201 && \
     export PD3_MEMORY_RDMA_IP=10.10.1.72 PD3_RDMA_PORT=51216 && \
     nohup ./build/bin/tests \"TransferEngine Refresh Test $n\" -r compact \
       > /tmp/pd3_refresh_${n}.log 2>&1 &"
  sleep 1

  (
    cd "$HOST_PD3"
    export LD_LIBRARY_PATH=$PWD/build/lib
    export PD3_HOST_PCIE=98:00.0 PD3_HOST_RUNTIME_DIR="$HOST_RUNTIME"
    # timeout: avoid infinite PollCompletions if DPU never arms
    timeout 90 ./build/bin/hv_refresh "$n"
  ) >"/tmp/pd3_hv_refresh_${n}.log" 2>&1 &
  hv_pid=$!

  if ! wait_host_tc; then
    kill "$hv_pid" 2>/dev/null || true
    ssh_dpu "tail -30 /tmp/pd3_refresh_${n}.log || true"
    return 1
  fi
  scp_tc_host_to_dpu
  echo "  scp tc_* host → DPU done"

  # hv_refresh finishes after completions; Catch2 then asserts
  if ! wait "$hv_pid"; then
    echo "  hv_refresh $n failed/timeout; log:" >&2
    tail -30 "/tmp/pd3_hv_refresh_${n}.log" >&2 || true
  fi
  sleep 3
  ssh_dpu "tail -30 /tmp/pd3_refresh_${n}.log || true"
  ssh_dpu "pkill -f '[/]build/bin/tests' || true"
  if ssh_dpu "grep -q 'All tests passed' /tmp/pd3_refresh_${n}.log 2>/dev/null"; then
    echo "  Refresh $n OK"
    return 0
  fi
  echo "  Refresh $n did not pass (see DPU /tmp/pd3_refresh_${n}.log)" >&2
  return 1
}

if [[ "$SKIP_REFRESH" -eq 0 ]]; then
  run_refresh 1 || echo "  Refresh 1 had errors (see DPU /tmp/pd3_refresh_1.log)"
  run_refresh 2 || echo "  Refresh 2 had errors"
  run_refresh 3 || echo "  Refresh 3 had errors"
fi

# Each Catch2 TransferClient case does its own Initialize() (new host mmap + tc_*).
# One long-lived DPU TE keeps the first export; after case 1 the host mmap is gone →
# later cases hang until timeout (SIGTERM). Restart DPU TE + scp per case.
run_transfer_client_case() {
  local name="$1"
  local tmo="${2:-300}"
  local log="/tmp/pd3_tc_$(echo "$name" | tr ' /' '__').log"
  local tc_pid=""

  echo "[5/6] TransferClient: $name (fresh DPU TE + host→DPU tc_*)"
  mkdir -p "$HOST_RUNTIME"
  rm -f "$HOST_RUNTIME"/tc_*
  ssh_dpu "pkill -f '[t]ransfer_engine_test' || true; pkill -f '[/]build/bin/tests' || true; \
    mkdir -p '$DPU_RUNTIME'; rm -f '$DPU_RUNTIME'/tc_*"
  sleep 1
  ssh -f -o BatchMode=yes "$DPU_HOST" \
    "cd '$REMOTE_PD3' && export LD_LIBRARY_PATH=\$PWD/build/lib && \
     mkdir -p '$DPU_RUNTIME' && export PD3_DPU_RUNTIME_DIR='$DPU_RUNTIME' && \
     export PD3_DPU_PCIE=03:00.0 PD3_DPU_RDMA_IP=10.10.1.201 && \
     export PD3_MEMORY_RDMA_IP=10.10.1.72 PD3_RDMA_PORT=51216 && \
     nohup ./build/bin/transfer_engine_test > /tmp/pd3_te.log 2>&1 &"
  sleep 1

  (
    cd "$HOST_PD3"
    export LD_LIBRARY_PATH=$PWD/build/lib
    export PD3_HOST_PCIE=98:00.0 PD3_HOST_RUNTIME_DIR="$HOST_RUNTIME"
    timeout "$tmo" ./build/bin/tests "$name" -r compact
  ) >"$log" 2>&1 &
  tc_pid=$!

  if ! wait_host_tc; then
    kill "$tc_pid" 2>/dev/null || true
    echo "  $name: host tc_* missing" >&2
    ssh_dpu "tail -20 /tmp/pd3_te.log || true"
    return 1
  fi
  scp_tc_host_to_dpu
  echo "  scp tc_* host → DPU done"

  # Catch2 Stress cases often have zero REQUIRE/CHECK macros → exit 0 with
  # "test cases: 1 | 1 passed" / "assertions: - none -", not "All tests passed".
  local ec=0
  wait "$tc_pid" || ec=$?
  if [[ "$ec" -eq 0 ]]; then
    echo "  $name OK"
    return 0
  fi
  echo "  $name FAILED (exit=$ec); log:" >&2
  tail -40 "$log" >&2 || true
  ssh_dpu "tail -20 /tmp/pd3_te.log || true"
  return 1
}

if [[ "$SKIP_CLIENT" -eq 0 ]]; then
  echo "[5/6] TransferClient suite (one DPU TE lifecycle per case)"
  tc_fail=0
  run_transfer_client_case "TransferClient One Read/Write Request" 120 || tc_fail=1
  run_transfer_client_case "TransferClient Stress Test" 600 || tc_fail=1
  run_transfer_client_case "TransferClient Stress Test Many Requests" 900 || tc_fail=1
  run_transfer_client_case "TransferClient Stress Test Many Requests Multi Threaded" 600 || tc_fail=1
  ssh_dpu "pkill -f '[t]ransfer_engine_test' || true"
  if [[ "$tc_fail" -eq 0 ]]; then
    echo "  TransferClient suite OK"
  else
    echo "  TransferClient suite had failures" >&2
  fi
fi

echo "[6/6] finished"
echo "=== §6 orchestrator done ==="
# trap cleanup stops memory / mini_agent / TE
