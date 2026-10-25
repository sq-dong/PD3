add_executable(mini_agent main.cpp)

target_link_libraries(mini_agent PRIVATE
  agent
  common
  buffer
  pthread
  fmt::fmt
)
