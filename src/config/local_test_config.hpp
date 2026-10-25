#pragma once

/**
 * Local cluster defaults for memserver16 (Compute) + bfhost_72 (Memory+Client).
 *
 * Override any value at runtime with env vars (no rebuild needed):
 *   PD3_HOST_PCIE, PD3_DPU_PCIE,
 *   PD3_MEMORY_RDMA_IP, PD3_DPU_RDMA_IP, PD3_RDMA_PORT,
 *   PD3_HOST_RUNTIME_DIR, PD3_DPU_RUNTIME_DIR
 *
 * IPoIB must be up before RDMA tests (see scripts/setup_ipoib.sh):
 *   host ibs6f0  -> 10.10.1.16/24
 *   memory ibs2f0 -> 10.10.1.72/24
 *   DPU (on ARM)  -> 10.10.1.201/24  (confirm iface with ibdev2netdev)
 */

#include "PD3/transfer_engine/transfer_client.hpp"
#include "PD3/transfer_engine/transfer_engine.hpp"

#include <cstdlib>
#include <string>

namespace pd3_local {

inline std::string EnvOr(const char* key, const char* def)
{
  if (const char* v = std::getenv(key)) {
    if (v[0] != '\0') {
      return v;
    }
  }
  return def;
}

// Host (memserver16) BlueField PCIe BDF as seen by the HOST OS (lspci).
inline std::string HostPcie() { return EnvOr("PD3_HOST_PCIE", "98:00.0"); }

// DOCA device BDF as seen on the DPU ARM OS (confirm with lspci on 192.168.100.2).
inline std::string DpuPcie() { return EnvOr("PD3_DPU_PCIE", "03:00.0"); }

inline std::string MemoryRdmaIp() { return EnvOr("PD3_MEMORY_RDMA_IP", "10.10.1.72"); }
inline std::string DpuRdmaIp() { return EnvOr("PD3_DPU_RDMA_IP", "10.10.1.201"); }
inline std::string RdmaPort() { return EnvOr("PD3_RDMA_PORT", "51216"); }

// Host-visible paths (TransferClient / agent on memserver16).
inline std::string HostRuntimeDir()
{
  return EnvOr("PD3_HOST_RUNTIME_DIR", "/home/dongshuqi/pd3_runtime");
}

// DPU-visible paths (TransferEngine on ARM). Keep in sync with host via scp/nfs.
inline std::string DpuRuntimeDir()
{
  return EnvOr("PD3_DPU_RUNTIME_DIR", "/tmp/pd3_runtime");
}

inline std::string Join(const std::string& dir, const char* name)
{
  if (!dir.empty() && dir.back() == '/') {
    return dir + name;
  }
  return dir + "/" + name;
}

/** Host TransferClient (hv_refresh / transfer_engine_client_test). */
inline void ApplyHostTransferClient(dpf::offload::TransferClientConfig& config)
{
  const auto dir = HostRuntimeDir();
  config.pcie_address = HostPcie();
  config.mmap_export_path = Join(dir, "tc_export_desc");
  config.buf_details_path = Join(dir, "tc_buf_details.txt");
}

/** DPU TransferEngine: RDMA-only / no-DMA tests. */
inline void ApplyDpuNoDma(dpf::offload::TransferEngineConfig& config)
{
  config.use_rdma = true;
  config.local_addr = DpuRdmaIp();
  config.server_addr = MemoryRdmaIp();
  config.server_port = RdmaPort();
  config.testing_mode = true;
}

/**
 * DPU TransferEngine talking to host TransferClient files + remote memory.
 * Matches test_apps/te and Refresh Test 1/2/3 style.
 */
inline void ApplyDpuTransferEngine(dpf::offload::TransferEngineConfig& config)
{
  const auto dir = DpuRuntimeDir();
  config.use_rdma = true;
  config.local_addr = DpuRdmaIp();
  config.server_addr = MemoryRdmaIp();
  config.server_port = RdmaPort();
  config.dpu_pcie_addr = DpuPcie();
  config.enable_agent = false;
  config.enable_transfer = true;
  config.export_desc_agent_file_path = "";
  config.buf_agent_file_path = "";
  config.export_desc_client_file_path = Join(dir, "tc_export_desc");
  config.buf_client_file_path = Join(dir, "tc_buf_details.txt");
}

/** DPU TransferEngine with Loading Zone agent DMA paths enabled. */
inline void ApplyDpuWithAgent(dpf::offload::TransferEngineConfig& config)
{
  const auto dir = DpuRuntimeDir();
  config.use_rdma = true;
  config.local_addr = DpuRdmaIp();
  config.server_addr = MemoryRdmaIp();
  config.server_port = RdmaPort();
  config.dpu_pcie_addr = DpuPcie();
  config.enable_agent = true;
  config.enable_transfer = false;
  config.export_desc_client_file_path = Join(dir, "export_desc_client");
  config.export_desc_agent_file_path = Join(dir, "agent_export_desc");
  config.buf_client_file_path = Join(dir, "buf_client.txt");
  config.buf_agent_file_path = Join(dir, "agent_buf_details.txt");
}

} // namespace pd3_local
