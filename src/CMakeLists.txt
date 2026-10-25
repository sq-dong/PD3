
add_subdirectory(libs)
# Original public tree had no src/apps/ at all (README still documents it).
# Previously: # add_subdirectory(apps)
# Now: minimal apps/ with only pd3_memory_backend (see docs/PD3-build-fixes.md).
add_subdirectory(test_apps)
add_subdirectory(PD3)
add_subdirectory(apps)
