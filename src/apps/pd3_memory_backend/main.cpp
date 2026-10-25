/**
 * Minimal executable entry for PD3MemoryBackend.
 *
 * The public PD3 release ships the library (src/PD3/rdma_backend) but not
 * src/apps/; README's `make pd3_memory_backend` therefore had nothing to build.
 * This main only wires Configure / Bootstrap / RunAync so Memory-node Catch2
 * TransferEngine tests can connect to 10.10.1.72:51216 (defaults overridable).
 */

#include "PD3/rdma_backend/pd3_server.hpp"

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <string>
#include <thread>

#include <signal.h>
#include <unistd.h>

namespace {

std::atomic<bool> g_run{true};
dpf::PD3MemoryBackend* g_backend = nullptr;

const char* EnvOr(const char* key, const char* def)
{
  if (const char* v = std::getenv(key)) {
    if (v[0] != '\0') {
      return v;
    }
  }
  return def;
}

void OnSignal(int)
{
  g_run.store(false, std::memory_order_release);
  if (g_backend) {
    g_backend->Stop();
  }
}

} // namespace

int main(int argc, char** argv)
{
  (void)argc;
  (void)argv;

  // Defaults match docs / local_test_config.hpp (bfhost_72 IPoIB).
  const std::string server_addr = EnvOr("PD3_MEMORY_RDMA_IP", "10.10.1.72");
  const std::string server_port = EnvOr("PD3_RDMA_PORT", "51216");
  const std::string server_name = EnvOr("PD3_MEMORY_SERVER_NAME", "pd3_memory");
  const uint64_t num_keys =
      std::strtoull(EnvOr("PD3_MEMORY_NUM_KEYS", "2000000"), nullptr, 10);
  constexpr uint64_t kValueSize = 8; // must match PD3MemoryBackend::VALUE_SIZE

  JSON config;
  config["server_addr"] = server_addr;
  config["server_port"] = server_port;
  config["server_name"] = server_name;
  config["max_keys"] = num_keys;

  dpf::PD3MemoryBackend backend;
  g_backend = &backend;

  signal(SIGINT, OnSignal);
  signal(SIGTERM, OnSignal);

  try {
    backend.Configure(config);
    // Flat lookup: key i -> byte offset i * VALUE_SIZE inside the MR pool.
    backend.Bootstrap(num_keys, [](uint64_t key) { return key * kValueSize; });
  } catch (const std::exception& e) {
    std::cerr << "pd3_memory_backend configure/bootstrap failed: " << e.what()
              << "\n";
    return 1;
  }

  std::cout << "pd3_memory_backend listening on " << server_addr << ":"
            << server_port << " (num_keys=" << num_keys << ")\n"
            << "Ctrl+C to stop.\n";

  backend.RunAync();

  while (g_run.load(std::memory_order_acquire)) {
    std::this_thread::sleep_for(std::chrono::milliseconds(200));
  }

  backend.Stop();
  g_backend = nullptr;
  std::cout << "pd3_memory_backend stopped.\n";
  return 0;
}
