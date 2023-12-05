#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit

declare -gr PLATFORMS=(
  # Linux (GNU/glibc)
  linux-gnu-x86_64
  linux-gnu-aarch64 # not working yet
  # Linux (Alpine/musl)
  linux-musl-x86_64
  linux-musl-aarch64 # not working yet
  # Windows (MSVC)
  windows-msvc-i686
  windows-msvc-x86_64
  windows-msvc-aarch64
)

SCRIPT_DIR=$(dirname -- "$(realpath -m -- "$0")")
declare -gr SCRIPT_DIR
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
declare -gr PROJECT_DIR

function print_usage() {
  cat <<EOF
Usage: $(basename -- "$0") <platform>

Environment variables:
  LIBMEM_BUILD_OUT_DIR: The output directory (default: "build/out/libmem-local-\${platform}").
  LIBMEM_BUILD_SKIP_ARCHIVE: Skip the final archive creation (default: false).

Supported platforms:
$(printf '  - %s\n' "${PLATFORMS[@]}")
EOF
}

function main() {
  if [[ $# -ne 1 ]]; then
    print_usage >&2
    return 1
  fi

  local platform=$1
  if ! array_contains "$platform" "${PLATFORMS[@]}"; then
    printf 'error: Unknown platform: %s\n' "$platform" >&2
    return 1
  fi

  local source_dir=${PROJECT_DIR}
  local out_dir
  if [[ -n "${LIBMEM_BUILD_OUT_DIR:-}" ]]; then
    out_dir=$(realpath -m -- "$LIBMEM_BUILD_OUT_DIR")
    if [[ -d "$out_dir" ]]; then
      printf 'error: Output directory already exists: %s\n' "$out_dir" >&2
      return 1
    fi
  else
    out_dir=$(realpath -m -- "build/out/libmem-local-${platform}")
    rm -rf -- "$out_dir"
  fi
  mkdir -p -- "$out_dir"

  printf 'Platform: %s\n' "$platform"
  printf 'Source directory: %s\n' "$source_dir"
  printf 'Output directory: %s\n' "$out_dir"
  printf '\n'

  case "$platform" in
  linux-*) _build_in_docker "$platform" "$source_dir" "$out_dir" ;;
  *) _build_locally "$platform" "$source_dir" "$out_dir" ;;
  esac

  if [[ "${LIBMEM_BUILD_SKIP_ARCHIVE:-}" != true ]]; then
    printf '[+] Create archive\n'
    tar -czf "${out_dir}.tar.gz" --owner=0 --group=0 --numeric-owner -C "$(dirname -- "$out_dir")" "$(basename -- "$out_dir")"
  fi

  printf '[+] Done\n'
}

function _build_in_docker() {
  local platform=$1 source_dir=$2 out_dir=$3

  local docker_os=unknown docker_platform=unknown
  case "$platform" in
  linux-gnu-*) docker_os=linux-gnu ;;
  linux-musl-*) docker_os=linux-musl ;;
  esac
  case "$platform" in
  *-x86_64) docker_platform=linux/amd64 ;;
  *-aarch64) docker_platform=linux/arm64 ;;
  esac

  local docker_image="libmem-build-${docker_os}-${docker_platform##*/}"
  docker build --platform "$docker_platform" -t "$docker_image" -f "${SCRIPT_DIR}/docker-env/${docker_os}.Dockerfile" "${SCRIPT_DIR}/docker-env"
  docker run --platform "$docker_platform" --rm \
    -e "PUID=$(id -u)" \
    -e "PGID=$(id -g)" \
    -e "_PLATFORM=${platform}" \
    -e "_SOURCE_DIR=/source" \
    -e "_BUILD_DIR=/build" \
    -e "_OUT_DIR=/out" \
    -v "${source_dir}:/source:ro" \
    -v "${out_dir}:/out:rw" \
    -i "$docker_image" \
    bash <<<"set -Eeuo pipefail; shopt -s inherit_errexit; $(declare -f do_build); do_build; exit 0"
}

function _build_locally() {
  local platform=$1 source_dir=$2 out_dir=$3

  local local_env="${platform%-*}"
  local local_env_arch="${platform##*-}"

  init_temp_dir
  _=_ \
    _PLATFORM="$platform" \
    _SOURCE_DIR="$source_dir" \
    _BUILD_DIR="${g_temp_dir}/build" \
    _OUT_DIR="$out_dir" \
    "${SCRIPT_DIR}/local-env/${local_env}.sh" "$local_env_arch" \
    bash <<<"set -Eeuo pipefail; shopt -s inherit_errexit; $(declare -f do_build); do_build; exit 0"
}

# Perform the build and copy the results to the output directory.
# This function must self-contained and exportable.
# Inputs:
#   _PLATFORM: The target platform.
#   _SOURCE_DIR: The absolute path to the source directory.
#   _BUILD_DIR: The absolute path to the build directory.
#   _OUT_DIR: The absolute path to the output directory.
function do_build() {
  true "${_PLATFORM?required}" "${_SOURCE_DIR?required}" "${_BUILD_DIR?required}" "${_OUT_DIR?required}"

  # Build variants
  function build_variant() {
    local variant_name=$1
    local variant_build_type=$2
    local variant_conf=("${@:3}")
    printf '[+] Build %s\n' "$variant_name"

    # Prepare config
    case "$_PLATFORM" in
    windows-msvc-*)
      variant_conf+=(-G 'NMake Makefiles')
      ;;
    *)
      local flags
      case "$_PLATFORM" in
      *-x86_64) flags='-march=westmere' ;;
      *-aarch64) flags='-march=armv8-a' ;;
      esac
      variant_conf+=(-G 'Unix Makefiles' -DCMAKE_C_FLAGS="$flags" -DCMAKE_CXX_FLAGS="$flags")
      ;;
    esac
    variant_conf+=(-DLIBMEM_BUILD_TESTS='OFF')

    # Build using CMake
    local variant_build_dir="${_BUILD_DIR}/${variant_name}"
    set -x
    cmake -S "$_SOURCE_DIR" -B "$variant_build_dir" -DCMAKE_BUILD_TYPE="$variant_build_type" "${variant_conf[@]}"
    cmake --build "$variant_build_dir" --config "$variant_build_type" --parallel "$(nproc)"
    { set +x; } 2>/dev/null

    # Copy libraries
    local variant_out_dir="${_OUT_DIR}/lib/${variant_name}"
    mkdir -p -- "$variant_out_dir"
    function copy_lib() {
      install -vD -m644 -- "${variant_build_dir}/${1}" "${variant_out_dir}/${2:-$(basename -- "$1")}"
    }
    case "${_PLATFORM}+${variant_name}" in
    windows-msvc-*+shared*) copy_lib 'libmem.dll' ;;
    windows-msvc-*+static*) copy_lib 'libmem.lib' ;;
    *+shared*) copy_lib 'liblibmem.so' ;;
    *+static*) copy_lib 'liblibmem.a' ;;
    esac
  }

  case "$_PLATFORM" in
  windows-msvc-*)
    build_variant shared-MD Release -DLIBMEM_BUILD_STATIC=OFF -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
    build_variant shared-MDd Debug -DLIBMEM_BUILD_STATIC=OFF -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDebugDLL
    build_variant static-MD Release -DLIBMEM_BUILD_STATIC=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL
    build_variant static-MDd Debug -DLIBMEM_BUILD_STATIC=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDebugDLL
    build_variant static-MT Release -DLIBMEM_BUILD_STATIC=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded
    build_variant static-MTd Debug -DLIBMEM_BUILD_STATIC=ON -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDebug
    ;;
  *)
    build_variant shared Release -DLIBMEM_BUILD_STATIC=OFF
    build_variant static Release -DLIBMEM_BUILD_STATIC=ON
    ;;
  esac

  # Copy headers
  printf '[+] Copy headers\n'
  mkdir -p -- "${_OUT_DIR}/include"
  cp -rT -- "${_SOURCE_DIR}/include" "${_OUT_DIR}/include"

  # Copy licenses
  printf '[+] Copy licenses\n'
  mkdir -p -- "${_OUT_DIR}/licenses"
  function copy_licenses() {
    local name=$1
    local dir="${_SOURCE_DIR}/${2:-$name}"
    find "$dir" -maxdepth 1 -type f \( -iname 'license*' -o -iname 'copying*' -o -iname 'exception*' \) | while read -r file; do
      local file_name
      file_name=$(basename -- "$file")
      file_name=${file_name%.*} # remove extension
      file_name=${file_name,,}  # lowercase
      install -vD -m644 -- "$file" "${_OUT_DIR}/licenses/${name}-${file_name}.txt"
    done
  }
  copy_licenses 'libmem' './'
  copy_licenses 'capstone' 'external/capstone'
  copy_licenses 'keystone' 'external/keystone'
  copy_licenses 'LIEF' 'external/LIEF'
  copy_licenses 'llvm' 'external/llvm'
  copy_licenses 'injector' 'external/injector'

  # Add stdlib information (glibc version, musl version)
  printf '[+] Add stdlib information\n'
  case "$_PLATFORM" in
  linux-gnu-*)
    # ldd --version can cause exit 141 when stdout is closed early.
    { ldd --version || true; } | head -n1 | awk '{print $NF}' | install -vD -m644 -- /dev/stdin "${_OUT_DIR}/GLIBC_VERSION.txt"
    ;;
  linux-musl-*)
    apk info musl 2>/dev/null | head -n1 | awk '{print $1}' | sed 's/^musl-//' | install -vD -m644 -- /dev/stdin "${_OUT_DIR}/MUSL_VERSION.txt"
    ;;
  windows-*)
    printf '%s\n' "${VCTOOLSVERSION:-${VSCMD_ARG_VCVARS_VER:-}}" | install -vD -m644 -- /dev/stdin "${_OUT_DIR}/MSVC_VERSION.txt"
    printf '%s\n' "${WINDOWSSDKVERSION:-}" | install -vD -m644 -- /dev/stdin "${_OUT_DIR}/WINSDK_VERSION.txt"
    ;;
  esac
}

# Ensure that the temporary directory exists and is set to an absolute path.
# This directory will be automatically deleted when the script exits.
# This function is idempotent.
# Outputs:
#   g_temp_dir: The absolute path to the temporary directory.
function init_temp_dir() {
  if [[ -v g_temp_dir ]]; then
    return
  fi

  g_temp_dir=$(mktemp -d)
  declare -gr g_temp_dir

  # shellcheck disable=SC2317
  function __temp_dir_cleanup() { rm -rf -- "$g_temp_dir"; }
  trap __temp_dir_cleanup INT TERM EXIT
}

# Check if an array contains a value.
# Inputs:
#   $1: The value to check for.
#   $2+: The array to check.
# Returns:
#   0 if the array contains the value,
#   1 otherwise.
function array_contains() {
  local value=$1
  local element
  for element in "${@:2}"; do
    if [[ "$element" == "$value" ]]; then
      return 0
    fi
  done
  return 1
}

eval 'main "$@";exit "$?"'
