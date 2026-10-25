add_executable(transfer_engine_test main.cpp)

# Original: ... common buffer benchmark pthread ...
target_link_libraries(transfer_engine_test PRIVATE common buffer
  # benchmark
  pthread offload_engine)
