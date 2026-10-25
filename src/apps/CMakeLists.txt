# Public release omitted src/apps/. Local minimal restores:
#   pd3_memory_backend — Memory-node RDMA server entry
#   mini_agent         — Host Loading Zone agent for DMA TE tests
# Other paper apps (hash map, Garnet, clients, ...) are still absent.
add_subdirectory(pd3_memory_backend)
add_subdirectory(mini_agent)
