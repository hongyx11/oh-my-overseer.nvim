cmake_minimum_required(VERSION 3.21)
project(OMO_REMOTE_SMOKE LANGUAGES NONE)
set(probe "${CMAKE_BINARY_DIR}/bin/omo_probe")
add_custom_command(
  OUTPUT "${probe}"
  COMMAND "${CMAKE_COMMAND}" -E make_directory "${CMAKE_BINARY_DIR}/bin"
  COMMAND "${CMAKE_COMMAND}" -E copy "${CMAKE_CURRENT_SOURCE_DIR}/probe.py" "${probe}"
  DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/probe.py"
)
add_custom_target(omo_probe ALL DEPENDS "${probe}")
