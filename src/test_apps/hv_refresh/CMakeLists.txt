add_executable(hv_refresh hv_refresh.cpp)

# Original: ... common buffer benchmark pthread ...
target_link_libraries(hv_refresh PRIVATE common buffer
  # benchmark
  pthread offload_engine)
