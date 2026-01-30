# CMakeLists.txt for T2T-C10GX Software
#
# Build instructions:
#   mkdir build && cd build
#   cmake ..
#   make -j$(nproc)
#
# Options:
#   -DBUILD_TESTS=ON    Build unit tests
#   -DBUILD_BENCH=ON    Build benchmarks
#   -DSANITIZE=ON       Enable sanitizers (debug)

cmake_minimum_required(VERSION 3.16)
project(t2t_sw VERSION 1.0.0 LANGUAGES CXX)

# C++20 required
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Build options
option(BUILD_TESTS "Build unit tests" OFF)
option(BUILD_BENCH "Build benchmarks" OFF)
option(SANITIZE "Enable sanitizers" OFF)

# Compiler flags
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wall -Wextra -Wpedantic")
set(CMAKE_CXX_FLAGS_RELEASE "-O3 -march=native -DNDEBUG")
set(CMAKE_CXX_FLAGS_DEBUG "-g -O0")

if(SANITIZE)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fsanitize=address,undefined")
    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -fsanitize=address,undefined")
endif()

# Include directories
include_directories(${CMAKE_SOURCE_DIR}/include)

#=============================================================================
# Core Library
#=============================================================================

add_library(t2t_core STATIC
    src/t2t_device.cpp
)

target_include_directories(t2t_core PUBLIC
    ${CMAKE_SOURCE_DIR}/include
)

# Link with pthread for threading support
target_link_libraries(t2t_core
    pthread
)

#=============================================================================
# Command-line Tools
#=============================================================================

# Main control application
add_executable(t2t_ctl
    src/t2t_ctl.cpp
)
target_link_libraries(t2t_ctl t2t_core)

# Record dumper utility
add_executable(t2t_dump
    src/t2t_dump.cpp
)
target_link_libraries(t2t_dump t2t_core)

# Latency analyzer
add_executable(t2t_latency
    src/t2t_latency.cpp
)
target_link_libraries(t2t_latency t2t_core)

# Symbol loader
add_executable(t2t_symbols
    src/t2t_symbols.cpp
)
target_link_libraries(t2t_symbols t2t_core)

#=============================================================================
# Installation
#=============================================================================

install(TARGETS t2t_ctl t2t_dump t2t_latency t2t_symbols
    RUNTIME DESTINATION bin
)

install(TARGETS t2t_core
    ARCHIVE DESTINATION lib
)

install(DIRECTORY include/
    DESTINATION include
    FILES_MATCHING PATTERN "*.hpp"
)

install(FILES
    scripts/setup_hugepages.sh
    scripts/bind_vfio.sh
    DESTINATION share/t2t
    PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE
                GROUP_READ GROUP_EXECUTE
                WORLD_READ WORLD_EXECUTE
)

#=============================================================================
# Tests (optional)
#=============================================================================

if(BUILD_TESTS)
    enable_testing()
    find_package(GTest REQUIRED)
    
    add_executable(test_device
        tests/test_device.cpp
    )
    target_link_libraries(test_device t2t_core GTest::gtest GTest::gtest_main)
    add_test(NAME test_device COMMAND test_device)
    
    add_executable(test_record
        tests/test_record.cpp
    )
    target_link_libraries(test_record t2t_core GTest::gtest GTest::gtest_main)
    add_test(NAME test_record COMMAND test_record)
endif()

#=============================================================================
# Benchmarks (optional)
#=============================================================================

if(BUILD_BENCH)
    find_package(benchmark REQUIRED)
    
    add_executable(bench_poll
        bench/bench_poll.cpp
    )
    target_link_libraries(bench_poll t2t_core benchmark::benchmark)
endif()

#=============================================================================
# Packaging
#=============================================================================

set(CPACK_PACKAGE_NAME "t2t-tools")
set(CPACK_PACKAGE_VERSION ${PROJECT_VERSION})
set(CPACK_PACKAGE_DESCRIPTION_SUMMARY "T2T-C10GX FPGA Control Tools")
set(CPACK_PACKAGE_VENDOR "T2T Project")
set(CPACK_GENERATOR "DEB;RPM;TGZ")

# Debian package
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "T2T Project")
set(CPACK_DEBIAN_PACKAGE_SECTION "utils")
set(CPACK_DEBIAN_PACKAGE_DEPENDS "libc6 (>= 2.31)")

# RPM package
set(CPACK_RPM_PACKAGE_LICENSE "MIT")
set(CPACK_RPM_PACKAGE_GROUP "Applications/System")

include(CPack)
