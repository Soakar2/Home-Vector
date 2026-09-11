cmake_minimum_required(VERSION 3.16)
project(iot_telemetry_service LANGUAGES CXX)

# C++17 is enough for everything this service uses. Deliberately NOT C++20:
# libpqxx 8.x requires C++20 and internally uses std::format (<format>),
# which needs GCC 13+ -- but Debian bookworm (used for the Docker build,
# pinned to match the runtime image's glibc) ships GCC 12, whose libstdc++
# doesn't have <format> at all. Staying on libpqxx 7.x avoids that entirely
# without having to chase newer compilers into the container.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# --- Hardening --------------------------------------------------------
# Baseline compiler hardening for a network-facing service that parses
# untrusted input. These flags are cheap and catch real bugs; they are
# not a substitute for the input validation done in TelemetryPayload.hpp.
add_compile_options(
    -Wall
    -Wextra
    -Wpedantic
    -fstack-protector-strong
)
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    add_compile_definitions(_FORTIFY_SOURCE=2)
endif()

# --- System dependency: PostgreSQL client library (libpq) -------------
# libpqxx links against libpq; it is a system dependency, not something
# CMake fetches for you. Fail fast with a clear message rather than
# letting the error surface deep inside libpqxx's own build.
#   Debian/Ubuntu: sudo apt-get install libpq-dev
#   RHEL/Fedora:   sudo dnf install libpq-devel
#   macOS:         brew install libpq
find_package(PostgreSQL REQUIRED)

include(FetchContent)

# --- Crow: HTTP microframework ----------------------------------------
FetchContent_Declare(
    Crow
    GIT_REPOSITORY https://github.com/CrowCpp/Crow.git
    GIT_TAG        v1.3.4
    GIT_SHALLOW    TRUE
)

# --- nlohmann/json: JSON parsing and validation -----------------------
FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG        v3.12.0
    GIT_SHALLOW    TRUE
)

# --- libpqxx: official C++ client for PostgreSQL -----------------------
# Pinned to the 7.x line (not 8.x) specifically to stay on C++17 -- see the
# comment above.
set(SKIP_BUILD_TEST ON CACHE BOOL "Don't build libpqxx's own test suite" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "Link libpqxx statically" FORCE)
FetchContent_Declare(
    libpqxx
    GIT_REPOSITORY https://github.com/jtv/libpqxx.git
    GIT_TAG        7.10.7
    GIT_SHALLOW    TRUE
)

FetchContent_MakeAvailable(Crow nlohmann_json libpqxx)

find_package(Threads REQUIRED)

add_executable(telemetry_service
    src/main.cpp
)

target_include_directories(telemetry_service PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(telemetry_service PRIVATE
    Crow::Crow
    nlohmann_json::nlohmann_json
    pqxx
    Threads::Threads
)
