add_executable(pd3_memory_backend main.cpp)

target_link_libraries(pd3_memory_backend PRIVATE
  pd3_rdma_backend
  pthread
  fmt::fmt
)
