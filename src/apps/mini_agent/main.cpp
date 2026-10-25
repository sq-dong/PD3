/**
 * Minimal host-side Loading Zone agent for DMA TransferEngine tests.
 *
 * Public release had no mini_agent binary; DPU TE with enable_agent waits up to
 * 60s for agent_export_desc + agent_buf_details.txt. This process creates those
 * files under PD3_HOST_RUNTIME_DIR (default /home/dongshuqi/pd3_runtime) and
 * must stay alive so the DOCA mmap remains valid. Copy the two files to the DPU
 * runtime dir (/tmp/pd3_runtime) before starting DMA Catch2 cases.
 */

#include "PD3/loading_zone/agent.hpp"
#include "local_test_config.hpp"

#include <atomic>
#include <chrono>
#include <iostream>
#include <thread>

#include <signal.h>
#include <unistd.h>

namespace {
std::atomic<bool> g_run{true};
void OnSignal(int) { g_run.store(false, std::memory_order_release); }
} // namespace

int main()
{
  signal(SIGINT, OnSignal);
  signal(SIGTERM, OnSignal);

  dpf::agent::AgentConfig config;
  config.pcie_address = pd3_local::HostPcie();
  config.mmap_export_path =
      pd3_local::Join(pd3_local::HostRuntimeDir(), "agent_export_desc");
  config.buf_details_path =
      pd3_local::Join(pd3_local::HostRuntimeDir(), "agent_buf_details.txt");

  try {
    dpf::agent::Initialize(config);
  } catch (const std::exception& e) {
    std::cerr << "mini_agent init failed: " << e.what() << "\n";
    return 1;
  }

  std::cout << "mini_agent ready\n"
            << "  export: " << config.mmap_export_path << "\n"
            << "  buf:    " << config.buf_details_path << "\n"
            << "Copy both to DPU " << pd3_local::DpuRuntimeDir()
            << " then run DMA TE tests. Ctrl+C to stop.\n";

  while (g_run.load(std::memory_order_acquire)) {
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }
  std::cout << "mini_agent stopped.\n";
  return 0;
}
