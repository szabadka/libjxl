#!/bin/bash
# Copyright (c) the JPEG XL Project
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Continuous integration helper module. This module is meant to be called from
# the .gitlab-ci.yml file during the continuous integration build, as well as
# from the command line for developers.

set -eu

OS=`uname -s`

MYDIR=$(dirname $(realpath "$0"))

### Environment parameters:
CMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE:-RelWithDebInfo}
CMAKE_PREFIX_PATH=${CMAKE_PREFIX_PATH:-}
SKIP_TEST="${SKIP_TEST:-0}"
BUILD_TARGET="${BUILD_TARGET:-}"
if [[ -n "${BUILD_TARGET}" ]]; then
  BUILD_DIR="${BUILD_DIR:-${MYDIR}/build-${BUILD_TARGET%%-*}}"
else
  BUILD_DIR="${BUILD_DIR:-${MYDIR}/build}"
fi
# Whether we should post a message in the MR when the build fails.
POST_MESSAGE_ON_ERROR="${POST_MESSAGE_ON_ERROR:-1}"

# Version inferred from the CI variables.
CI_COMMIT_SHA=${CI_COMMIT_SHA:-$(git log | head -n 1 | cut -b 8-)}
JPEGXL_VERSION=${JPEGXL_VERSION:-${CI_COMMIT_SHA:0:8}}

echo "Version: $JPEGXL_VERSION"
# Convenience flag to pass both CMAKE_C_FLAGS and CMAKE_CXX_FLAGS
CMAKE_FLAGS="${CMAKE_FLAGS:-} -DJPEGXL_VERSION=\\\"${JPEGXL_VERSION}\\\""
CMAKE_C_FLAGS="${CMAKE_C_FLAGS:-} ${CMAKE_FLAGS}"
CMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS:-} ${CMAKE_FLAGS}"
CMAKE_CROSSCOMPILING_EMULATOR=${CMAKE_CROSSCOMPILING_EMULATOR:-}
CMAKE_EXE_LINKER_FLAGS=${CMAKE_EXE_LINKER_FLAGS:-}
CMAKE_MODULE_LINKER_FLAGS=${CMAKE_MODULE_LINKER_FLAGS:-}
CMAKE_SHARED_LINKER_FLAGS=${CMAKE_SHARED_LINKER_FLAGS:-}
CMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE:-}


# Benchmark parameters
STORE_IMAGES=${STORE_IMAGES:-1}
BENCHMARK_CORPORA="${MYDIR}/third_party/corpora"

# Local flags passed to sanitizers.
UBSAN_FLAGS=(
  -fsanitize=alignment
  -fsanitize=bool
  -fsanitize=bounds
  -fsanitize=builtin
  -fsanitize=enum
  -fsanitize=float-cast-overflow
  -fsanitize=float-divide-by-zero
  -fsanitize=integer-divide-by-zero
  -fsanitize=null
  -fsanitize=object-size
  -fsanitize=pointer-overflow
  -fsanitize=return
  -fsanitize=returns-nonnull-attribute
  -fsanitize=shift-base
  -fsanitize=shift-exponent
  -fsanitize=unreachable
  -fsanitize=vla-bound

  -fno-sanitize-recover=undefined
  # Brunsli uses unaligned accesses to uint32_t, so alignment is just a warning.
  -fsanitize-recover=alignment
)
# -fsanitize=function doesn't work on aarch64 and arm.
if [[ "${BUILD_TARGET%%-*}" != "aarch64" &&
    "${BUILD_TARGET%%-*}" != "arm" ]]; then
  UBSAN_FLAGS+=(
    -fsanitize=function
  )
fi
if [[ "${BUILD_TARGET%%-*}" != "arm" ]]; then
  UBSAN_FLAGS+=(
    -fsanitize=signed-integer-overflow
  )
fi

CLANG_TIDY_BIN=$(which clang-tidy-6.0 clang-tidy-7 clang-tidy-8 | head -n 1)
# Default to "cat" if "colordiff" is not installed or if stdout is not a tty.
if [[ -t 1 ]]; then
  COLORDIFF_BIN=$(which colordiff cat | head -n 1)
else
  COLORDIFF_BIN="cat"
fi

CLANG_VERSION="${CLANG_VERSION:-}"
# Detect the clang version suffix and store it in CLANG_VERSION. For example,
# "6.0" for clang 6 or "7" for clang 7.
detect_clang_version() {
  if [[ -n "${CLANG_VERSION}" ]]; then
    return 0
  fi
  local clang_version=$("${CC:-clang}" --version | head -n1)
  local llvm_tag
  case "${clang_version}" in
    "clang version 6."*)
      CLANG_VERSION="6.0"
      ;;
    "clang version 7."*)
      CLANG_VERSION="7"
      ;;
    "clang version 8."*)
      CLANG_VERSION="8"
      ;;
    "clang version 9."*)
      CLANG_VERSION="9"
      ;;
    *)
      echo "Unknown clang version: ${clang_version}" >&2
      return 1
  esac
}

# Temporary files cleanup hooks.
CLEANUP_FILES=()
cleanup() {
  if [[ ${#CLEANUP_FILES[@]} -ne 0 ]]; then
    rm -fr "${CLEANUP_FILES[@]}"
  fi
}

# Executed on exit.
on_exit() {
  local retcode="$1"
  # Always cleanup the CLEANUP_FILES.
  cleanup

  # Post a message in the MR when requested with POST_MESSAGE_ON_ERROR but only
  # if the run failed and we are not running from a MR pipeline.
  if [[ ${retcode} -ne 0 && -n "${CI_BUILD_NAME:-}" &&
        -n "${POST_MESSAGE_ON_ERROR}" && -z "${CI_MERGE_REQUEST_ID:-}" &&
        "${CI_BUILD_REF_NAME}" = "master" ]]; then
    load_mr_vars_from_commit
    { set +xeu; } 2>/dev/null
    local message="**Run ${CI_BUILD_NAME} @ ${CI_COMMIT_SHORT_SHA} failed.**

Check the output of the job at ${CI_JOB_URL:-} to see if this was your problem.
If it was, please rollback this change or fix the problem ASAP, broken builds
slow down development. Check if the error already existed in the previous build
as well.

Pipeline: ${CI_PIPELINE_URL}

Previous build commit: ${CI_COMMIT_BEFORE_SHA}
"
    cmd_post_mr_comment "${message}"
  fi
}

trap 'retcode=$?; { set +x; } 2>/dev/null; on_exit ${retcode}' INT TERM EXIT


# These variables are populated when calling merge_request_commits().

# The current hash at the top of the current branch or merge request branch (if
# running from a merge request pipeline).
MR_HEAD_SHA=""
# The common ancestor between the current commit and the tracked branch, such
# as master. This includes a list
MR_ANCESTOR_SHA=""

# Populate MR_HEAD_SHA and MR_ANCESTOR_SHA.
merge_request_commits() {
  { set +x; } 2>/dev/null
  # CI_BUILD_REF is the reference currently being build in the CI workflow.
  MR_HEAD_SHA=$(git -C "${MYDIR}" rev-parse -q "${CI_BUILD_REF:-HEAD}")
  if [[ -z "${CI_MERGE_REQUEST_IID:-}" ]]; then
    # We are in a local branch, not a merge request.
    MR_ANCESTOR_SHA=$(git -C "${MYDIR}" rev-parse -q HEAD@{upstream} || true)
  else
    # Merge request pipeline in CI. In this case the upstream is called "origin"
    # but it refers to the forked project that's the source of the merge
    # request. We need to get the target of the merge request, for which we need
    # to query that repository using our CI_JOB_TOKEN.
    echo "machine gitlab.com login gitlab-ci-token password ${CI_JOB_TOKEN}" \
      >> "${HOME}/.netrc"
    git -C "${MYDIR}" fetch "${CI_MERGE_REQUEST_PROJECT_URL}" \
      "${CI_MERGE_REQUEST_TARGET_BRANCH_NAME}"
    MR_ANCESTOR_SHA=$(git -C "${MYDIR}" rev-parse -q FETCH_HEAD)
  fi
  if [[ -z "${MR_ANCESTOR_SHA}" ]]; then
    echo "Warning, not tracking any branch, using the last commit in HEAD.">&2
    # This prints the return value with just HEAD.
    MR_ANCESTOR_SHA=$(git -C "${MYDIR}" rev-parse -q "${MR_HEAD_SHA}^")
  else
    MR_ANCESTOR_SHA=$(git -C "${MYDIR}" merge-base --all \
      "${MR_ANCESTOR_SHA}" "${MR_HEAD_SHA}")
  fi
  set -x
}

# Load the MR iid from the landed commit message when running not from a
# merge request workflow. This is useful to post back results at the merge
# request when running pipelines from master.
load_mr_vars_from_commit() {
  { set +x; } 2>/dev/null
  if [[ -z "${CI_MERGE_REQUEST_IID:-}" ]]; then
    local mr_iid=$(git rev-list --format=%B --max-count=1 HEAD |
      grep -F "${CI_PROJECT_URL}/merge_requests" | head -n 1)
    # mr_iid contains a string like this if it matched:
    #  Part-of: <https://gitlab.com/wg1/jpeg-xlm/merge_requests/123456>
    if [[ -n "${mr_iid}" ]]; then
      mr_iid=$(echo "${mr_iid}" |
        sed -E 's,^.*merge_requests/([0-9]+)>.*$,\1,')
      CI_MERGE_REQUEST_IID="${mr_iid}"
      CI_MERGE_REQUEST_PROJECT_ID=${CI_PROJECT_ID}
    fi
  fi
  set -x
}

# Posts a comment to the current merge request.
cmd_post_mr_comment() {
  { set +x; } 2>/dev/null
  local comment="$1"
  if [[ -n "${BOT_TOKEN:-}" && -n "${CI_MERGE_REQUEST_IID:-}" ]]; then
    local url="${CI_API_V4_URL}/projects/${CI_MERGE_REQUEST_PROJECT_ID}/merge_requests/${CI_MERGE_REQUEST_IID}/notes"
    curl -X POST -g \
      -H "PRIVATE-TOKEN: ${BOT_TOKEN}" \
      --data-urlencode "body=${comment}" \
      --output /dev/null \
      "${url}"
  fi
  set -x
}

cmake_configure() {
  local args=(
    -B"${BUILD_DIR}" -H"${MYDIR}"
    -DCMAKE_BUILD_TYPE="${CMAKE_BUILD_TYPE}"
    -G Ninja
    -DCMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS}"
    -DCMAKE_C_FLAGS="${CMAKE_C_FLAGS}"
    -DCMAKE_TOOLCHAIN_FILE="${CMAKE_TOOLCHAIN_FILE}"
    -DCMAKE_EXE_LINKER_FLAGS="${CMAKE_EXE_LINKER_FLAGS}"
    -DCMAKE_MODULE_LINKER_FLAGS="${CMAKE_MODULE_LINKER_FLAGS}"
    -DCMAKE_SHARED_LINKER_FLAGS="${CMAKE_SHARED_LINKER_FLAGS}"
    -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH}"
  )
  if [[ -n "${BUILD_TARGET}" ]]; then
    # If set, BUILD_TARGET must be the target triplet such as
    # x86_64-unknown-linux-gnu.
    args+=(
      -DCMAKE_C_COMPILER_TARGET="${BUILD_TARGET}"
      -DCMAKE_CXX_COMPILER_TARGET="${BUILD_TARGET}"
      # Only the first element of the target triplet.
      -DCMAKE_SYSTEM_PROCESSOR="${BUILD_TARGET%%-*}"
      -DCMAKE_SYSTEM_NAME=Linux
      # These are needed to make googletest work when cross-compiling.
      -DCMAKE_CROSSCOMPILING=1
      -DHAVE_STD_REGEX=0
      -DHAVE_POSIX_REGEX=0
      -DHAVE_GNU_POSIX_REGEX=0
      -DHAVE_STEADY_CLOCK=0
      -DHAVE_THREAD_SAFETY_ATTRIBUTES=0
    )
    # Use pkg-config for the target:
    local pkg_config=$(which "${BUILD_TARGET}-pkg-config" || true)
    if [[ -n "${pkg_config}" ]]; then
      args+=(-DPKG_CONFIG_EXECUTABLE="${pkg_config}")
    fi
  fi
  if [[ -n "${CMAKE_CROSSCOMPILING_EMULATOR}" ]]; then
    args+=(
      -DCMAKE_CROSSCOMPILING_EMULATOR="${CMAKE_CROSSCOMPILING_EMULATOR}"
    )
  fi
  cmake "${args[@]}" "$@"
}

cmake_build_and_test() {
  # gtest_discover_tests() runs the test binaries to discover the list of tests
  # at build time, which fails under qemu.
  ASAN_OPTIONS=detect_leaks=0 cmake --build "${BUILD_DIR}"
  # Pack test binaries if requested.
  if [[ "${PACK_TEST:-}" == "1" ]]; then
    (cd "${BUILD_DIR}"
     find -name '*.cmake' -a '!' -path '*CMakeFiles*'
     find -type d -name tests -a '!' -path '*CMakeFiles*'
    ) | tar -C "${BUILD_DIR}" -cf "${BUILD_DIR}/tests.tar.xz" -T - \
      --use-compress-program="xz --threads=$(nproc --all || echo 1) -6"
    du -h "${BUILD_DIR}/tests.tar.xz"
    # Pack coverage data if also available.
    touch "${BUILD_DIR}/gcno.sentinel"
    (cd "${BUILD_DIR}"; echo gcno.sentinel; find -name '*gcno') | \
      tar -C "${BUILD_DIR}" -cvf "${BUILD_DIR}/gcno.tar.xz" -T - \
        --use-compress-program="xz --threads=$(nproc --all || echo 1) -6"
  fi

  if [[ "${SKIP_TEST}" -ne "1" ]]; then
    (cd "${BUILD_DIR}"
     export UBSAN_OPTIONS=print_stacktrace=1
     ctest -j $(nproc --all || echo 1) --output-on-failure)
  fi
}

# Configure the build to strip unused functions. This considerably reduces the
# output size, specially for tests which only use a small part of the whole
# library.
strip_dead_code() {
  # Emscripten does tree shaking without any extra flags.
  if [[ "${CMAKE_TOOLCHAIN_FILE##*/}" == "Emscripten.cmake" ]]; then
    return 0
  fi
  # -ffunction-sections, -fdata-sections and -Wl,--gc-sections effectively
  # discard all unreachable code, reducing the code size. For this to work, we
  # need to also pass --no-export-dynamic to prevent it from exporting all the
  # internal symbols (like functions) making them all reachable and thus not a
  # candidate for removal.
  CMAKE_CXX_FLAGS+=" -ffunction-sections -fdata-sections"
  CMAKE_C_FLAGS+=" -ffunction-sections -fdata-sections"
  if [[ "${OS}" == "Darwin" ]]; then
    CMAKE_EXE_LINKER_FLAGS+=" -dead_strip"
    CMAKE_SHARED_LINKER_FLAGS+=" -dead_strip"
  else
    CMAKE_EXE_LINKER_FLAGS+=" -Wl,--gc-sections -Wl,--no-export-dynamic"
    CMAKE_SHARED_LINKER_FLAGS+=" -Wl,--gc-sections -Wl,--no-export-dynamic"
  fi
}

### Externally visible commands

cmd_debug() {
  CMAKE_BUILD_TYPE="Debug"
  cmake_configure "$@"
  cmake_build_and_test
}

cmd_release() {
  CMAKE_BUILD_TYPE="Release"
  strip_dead_code
  cmake_configure "$@"
  cmake_build_and_test
}

cmd_opt() {
  CMAKE_BUILD_TYPE="RelWithDebInfo"
  CMAKE_CXX_FLAGS+=" -DJXL_DEBUG_WARNING -DJXL_DEBUG_ON_ERROR"
  cmake_configure "$@"
  cmake_build_and_test
}

cmd_coverage() {
  cmd_release -DJPEGXL_ENABLE_COVERAGE=ON "$@"

  if [[ "${SKIP_TEST}" -ne "1" ]]; then
    # If we didn't run the test we also don't print a coverage report.
    cmd_coverage_report
  fi
}

cmd_coverage_report() {
  detect_clang_version
  LLVM_COV=$(which "llvm-cov-${CLANG_VERSION}")
  local real_build_dir=$(realpath ${BUILD_DIR})
  local gcovr_args=(
    -r "${real_build_dir}"
    --gcov-executable "${LLVM_COV} gcov"
    # Only print coverage information for the jxl and fuif directories. The rest
    # is not part of the code under test.
    --filter '.*jxl/.*'
    --exclude '.*_test.cc'
    --object-directory "${real_build_dir}"
  )

  (
   cd "${real_build_dir}"
    gcovr "${gcovr_args[@]}" --html --html-details \
      --output="${real_build_dir}/coverage.html"
    gcovr "${gcovr_args[@]}" --print-summary |
      tee "${real_build_dir}/coverage.txt"
    gcovr "${gcovr_args[@]}" --xml --output="${real_build_dir}/coverage.xml"
  )
}

cmd_test() {
  # Unpack tests if needed.
  if [[ -e "${BUILD_DIR}/tests.tar.xz" && ! -d "${BUILD_DIR}/tests" ]]; then
    tar -C "${BUILD_DIR}" -Jxvf "${BUILD_DIR}/tests.tar.xz"
  fi
  if [[ -e "${BUILD_DIR}/gcno.tar.xz" && ! -d "${BUILD_DIR}/gcno.sentinel" ]]; then
    tar -C "${BUILD_DIR}" -Jxvf "${BUILD_DIR}/gcno.tar.xz"
  fi
  (cd "${BUILD_DIR}"
   export UBSAN_OPTIONS=print_stacktrace=1
   ctest -j $(nproc --all || echo 1) --output-on-failure)
}

cmd_asan() {
  detect_clang_version
  LLVM_SYMBOLIZER=$(which llvm-symbolizer "llvm-symbolizer-${CLANG_VERSION}" | \
    head -n1)
  LLVM_SYMBOLIZER="$(realpath "${LLVM_SYMBOLIZER}" || true)"

  CMAKE_C_FLAGS+=" -DJXL_ENABLE_ASSERT=1 -g -DADDRESS_SANITIZER \
    -fsanitize=address ${UBSAN_FLAGS[@]}"
  CMAKE_CXX_FLAGS+=" -DJXL_ENABLE_ASSERT=1 -g -DADDRESS_SANITIZER \
    -fsanitize=address ${UBSAN_FLAGS[@]}"
  strip_dead_code
  cmake_configure "$@" -DJPEGXL_ENABLE_TCMALLOC=OFF
  export ASAN_SYMBOLIZER_PATH="${LLVM_SYMBOLIZER}"
  export UBSAN_SYMBOLIZER_PATH="${LLVM_SYMBOLIZER}"
  cmake_build_and_test
}

cmd_tsan() {
  local tsan_args=(
    -DJXL_ENABLE_ASSERT=1
    -g
    -DTHREAD_SANITIZER
    ${UBSAN_FLAGS[@]}
    -fsanitize=thread
  )
  CMAKE_C_FLAGS+=" ${tsan_args[@]}"
  CMAKE_CXX_FLAGS+=" ${tsan_args[@]}"

  CMAKE_BUILD_TYPE="RelWithDebInfo"
  cmake_configure "$@" -DJPEGXL_ENABLE_TCMALLOC=OFF
  cmake_build_and_test
}

cmd_msan() {
  detect_clang_version
  local msan_prefix="${HOME}/.msan/${CLANG_VERSION}"
  if [[ ! -d "${msan_prefix}" || -e "${msan_prefix}/lib/libc++abi.a" ]]; then
    # Install msan libraries for this version if needed or if an older version
    # with libc++abi was installed.
    cmd_msan_install
  fi

  local msan_c_flags=(
    -fsanitize=memory
    -fno-omit-frame-pointer
    -fsanitize-memory-track-origins

    -DJXL_ENABLE_ASSERT=1
    -g
    -DMEMORY_SANITIZER

    # Force gtest to not use the cxxbai.
    -DGTEST_HAS_CXXABI_H_=0
  )
  local msan_cxx_flags=(
    "${msan_c_flags[@]}"

    # Some C++ sources don't use the std at all, so the -stdlib=libc++ is unused
    # in those cases. Ignore the warning.
    -Wno-unused-command-line-argument
    -stdlib=libc++

    # We include the libc++ from the msan directory instead, so we don't want
    # the std includes.
    -nostdinc++
    -cxx-isystem"${msan_prefix}/include/c++/v1"
  )

  local msan_linker_flags=(
    -L"${msan_prefix}"/lib
    -Wl,-rpath -Wl,"${msan_prefix}"/lib/
  )

  LLVM_SYMBOLIZER=$(which llvm-symbolizer "llvm-symbolizer-${CLANG_VERSION}" | \
    head -n1)
  LLVM_SYMBOLIZER="$(realpath "${LLVM_SYMBOLIZER}" || true)"

  CMAKE_C_FLAGS+=" ${msan_c_flags[@]} ${UBSAN_FLAGS[@]}"
  CMAKE_CXX_FLAGS+=" ${msan_cxx_flags[@]} ${UBSAN_FLAGS[@]}"
  CMAKE_EXE_LINKER_FLAGS+=" ${msan_linker_flags[@]}"
  CMAKE_MODULE_LINKER_FLAGS+=" ${msan_linker_flags[@]}"
  CMAKE_SHARED_LINKER_FLAGS+=" ${msan_linker_flags[@]}"
  strip_dead_code
  cmake_configure "$@" \
    -DCMAKE_CROSSCOMPILING=1 -DRUN_HAVE_STD_REGEX=0 -DRUN_HAVE_POSIX_REGEX=0 \
    -DJPEGXL_ENABLE_TCMALLOC=OFF
  export MSAN_SYMBOLIZER_PATH="${LLVM_SYMBOLIZER}"
  export UBSAN_SYMBOLIZER_PATH="${LLVM_SYMBOLIZER}"
  cmake_build_and_test
}

# Install libc++ libraries compiled with msan in the msan_prefix for the current
# compiler version.
cmd_msan_install() {
  local tmpdir=$(mktemp -d)
  CLEANUP_FILES+=("${tmpdir}")
  # Detect the llvm to install:
  export CC="${CC:-clang}"
  export CXX="${CXX:-clang++}"
  detect_clang_version
  local llvm_tag
  case "${CLANG_VERSION}" in
    "6.0")
      llvm_tag="llvmorg-6.0.1"
      ;;
    "7")
      llvm_tag="llvmorg-7.0.1"
      ;;
    "8")
      llvm_tag="llvmorg-8.0.0"
      ;;
    "9")
      llvm_tag="llvmorg-9.0.0"
      ;;
    *)
      echo "Unknown clang version: ${CLANG_VERSION}" >&2
      return 1
  esac
  local llvm_targz="${tmpdir}/${llvm_tag}.tar.gz"
  curl -L --show-error -o "${llvm_targz}" \
    "https://github.com/llvm/llvm-project/archive/${llvm_tag}.tar.gz"
  tar -C "${tmpdir}" -zxf "${llvm_targz}"
  local llvm_root="${tmpdir}/llvm-project-${llvm_tag}"

  local msan_prefix="${HOME}/.msan/${CLANG_VERSION}"
  rm -rf "${msan_prefix}"

  declare -A CMAKE_EXTRAS
  CMAKE_EXTRAS[libcxx]="\
    -DLIBCXX_CXX_ABI=libstdc++ \
    -DLIBCXX_INSTALL_EXPERIMENTAL_LIBRARY=ON"

  for project in libcxx; do
    local proj_build="${tmpdir}/build-${project}"
    local proj_dir="${llvm_root}/${project}"
    mkdir -p "${proj_build}"
    cmake -B"${proj_build}" -H"${proj_dir}" \
      -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DLLVM_USE_SANITIZER=Memory \
      -DLLVM_PATH="${llvm_root}/llvm" \
      -DLLVM_CONFIG_PATH="$(which llvm-config llvm-config-7 llvm-config-6.0 | \
                            head -n1)" \
      -DCMAKE_CXX_FLAGS="${CMAKE_CXX_FLAGS}" \
      -DCMAKE_C_FLAGS="${CMAKE_C_FLAGS}" \
      -DCMAKE_EXE_LINKER_FLAGS="${CMAKE_EXE_LINKER_FLAGS}" \
      -DCMAKE_SHARED_LINKER_FLAGS="${CMAKE_SHARED_LINKER_FLAGS}" \
      -DCMAKE_INSTALL_PREFIX="${msan_prefix}" \
      ${CMAKE_EXTRAS[${project}]}
    cmake --build "${proj_build}"
    ninja -C "${proj_build}" install
  done
}

cmd_fast_benchmark() {
  local small_corpus_tar="${BENCHMARK_CORPORA}/jyrki-full.tar"
  mkdir -p "${BENCHMARK_CORPORA}"
  curl --show-error -o "${small_corpus_tar}" -z "${small_corpus_tar}" \
    "https://storage.googleapis.com/artifacts.jpegxl.appspot.com/corpora/jyrki-full.tar"

  local tmpdir=$(mktemp -d)
  CLEANUP_FILES+=("${tmpdir}")
  tar -xf "${small_corpus_tar}" -C "${tmpdir}"

  run_benchmark "${tmpdir}" 1048576
}

cmd_benchmark() {
  local nikon_corpus_tar="${BENCHMARK_CORPORA}/nikon-subset.tar"
  mkdir -p "${BENCHMARK_CORPORA}"
  curl --show-error -o "${nikon_corpus_tar}" -z "${nikon_corpus_tar}" \
    "https://storage.googleapis.com/artifacts.jpegxl.appspot.com/corpora/nikon-subset.tar"

  local tmpdir=$(mktemp -d)
  CLEANUP_FILES+=("${tmpdir}")
  tar -xvf "${nikon_corpus_tar}" -C "${tmpdir}"

  local sem_id="jpegxl_benchmark-$$"
  local nprocs=$(nproc --all || echo 1)
  images=()
  local filename
  while IFS= read -r filename; do
    # This removes the './'
    filename="${filename:2}"
    local mode
    if [[ "${filename:0:4}" == "srgb" ]]; then
      mode="RGB_D65_SRG_Rel_SRG"
    elif [[ "${filename:0:5}" == "adobe" ]]; then
      mode="RGB_D65_Ado_Rel_Ado"
    else
      echo "Unknown image colorspace: ${filename}" >&2
      exit 1
    fi
    png_filename="${filename%.ppm}.png"
    png_filename=$(echo "${png_filename}" | tr '/' '_')
    sem --bg --id "${sem_id}" -j"${nprocs}" -- \
      "${BUILD_DIR}/tools/decode_and_encode" \
        "${tmpdir}/${filename}" "${mode}" "${tmpdir}/${png_filename}"
    images+=( "${png_filename}" )
  done < <(cd "${tmpdir}"; find . -name '*.ppm' -type f)
  sem --id "${sem_id}" --wait

  # We need about 10 GiB per thread on these images.
  run_benchmark "${tmpdir}" 10485760
}

get_mem_available() {
  if [[ "${OS}" == "Darwin" ]]; then
    echo $(vm_stat | grep -F 'Pages free:' | awk '{print $3 * 4}')
  else
    echo $(grep -F MemAvailable: /proc/meminfo | awk '{print $2}')
  fi
}

run_benchmark() {
  local src_img_dir="$1"
  local mem_per_thread="${2:-10485760}"

  local output_dir="${BUILD_DIR}/benchmark_results"
  mkdir -p "${output_dir}"

  # The memory available at the beginning of the benchmark run in kB. The number
  # of threads depends on the available memory, and the passed memory per
  # thread. We also add a 2 GiB of constant memory.
  local mem_available="$(get_mem_available)"
  # Check that we actually have a MemAvailable value.
  [[ -n "${mem_available}" ]]
  local num_threads=$(( (${mem_available} - 1048576) / ${mem_per_thread} ))
  if [[ ${num_threads} -le 0 ]]; then
    num_threads=1
  fi

  local benchmark_args=(
    --input "${src_img_dir}/*.png"
    --codec=jpeg:yuv420:q85,webp:q80,jxl:fast:d1,jxl:fast:d1:downsampling=8,jxl:fast:d4,jxl:fast:d4:downsampling=8,jxl:mg:nl,jxl:mg,jxl:mg:P7,jxl:mg:q80
    --output_dir "${output_dir}"
    --noprofiler --show_progress
    --num_threads="${num_threads}"
  )
  if [[ "${STORE_IMAGES}" == "1" ]]; then
    benchmark_args+=(--save_decompressed --save_compressed)
  fi
  "${BUILD_DIR}/tools/benchmark_xl" "${benchmark_args[@]}" | \
     tee "${output_dir}/results.txt"
  # Check error code for benckmark_xl command. This will exit if not.
  [[ "${PIPESTATUS[0]}" == 0 ]]

  if [[ -n "${CI_BUILD_NAME:-}" ]]; then
    { set +x; } 2>/dev/null
    local message="Results for ${CI_BUILD_NAME} @ ${CI_COMMIT_SHORT_SHA} (job ${CI_JOB_URL:-}):

$(cat "${output_dir}/results.txt")
"
    cmd_post_mr_comment "${message}"
    set -x
  fi
}

# Helper function to wait for the CPU temperature to cool down on ARM.
wait_for_temp() {
  { set +x; } 2>/dev/null
  local temp_limit=${1:-37000}
  if [[ -z "${THERMAL_FILE:-}" ]]; then
    echo "Must define the THERMAL_FILE with the thermal_zoneX/temp file" \
      "to read the temperature from. This is normally set in the runner." >&2
    exit 1
  fi
  local org_temp=$(cat "${THERMAL_FILE}")
  if [[ "${org_temp}" -ge "${temp_limit}" ]]; then
    echo -n "Waiting for temp to get down from ${org_temp}... "
  fi
  local temp="${org_temp}"
  while [[ "${temp}" -ge "${temp_limit}" ]]; do
    sleep 1
    temp=$(cat "${THERMAL_FILE}")
  done
  if [[ "${org_temp}" -ge "${temp_limit}" ]]; then
    echo "Done, temp=${temp}"
  fi
  set -x
}

# Helper function to set the cpuset restriction of the current process.
cmd_cpuset() {
  local newset="$1"
  local mycpuset=$(cat /proc/self/cpuset)
  mycpuset="/dev/cpuset${mycpuset}"
  # Check that the directory exists:
  [[ -d "${mycpuset}" ]]
  if [[ -e "${mycpuset}/cpuset.cpus" ]]; then
    echo "${newset}" >"${mycpuset}/cpuset.cpus"
  else
    echo "${newset}" >"${mycpuset}/cpus"
  fi
}

# Return the encoding/decoding speed from the Stats output.
_speed_from_output() {
  local speed="$@"
  speed="${speed%% MP/s*}"
  speed="${speed##* }"
  echo "${speed}"
}

# Run benchmarks on ARM for the big and little CPUs.
cmd_arm_benchmark() {
  local benchmarks=(
    # Lossy options:
    "--jpeg1 --jpeg_quality 90"
    "--jpeg1 --jpeg_quality 85 --jpeg_420"
    "--adaptive_reconstruction=1 --distance=1.0 --speed=cheetah"
    "--adaptive_reconstruction=0 --distance=1.0 --speed=cheetah"
    "--adaptive_reconstruction=1 --distance=8.0 --speed=cheetah"
    "--adaptive_reconstruction=0 --distance=8.0 --speed=cheetah"
    "--modular-group -Q 90"
    "--modular-group -Q 50"
    # Lossless options:
    "--modular-group"
    "--modular-group -E 0 -I 0 -A"
    "--modular-group -P 5 -A"
    "--modular-group --responsive=1"
    # Near-lossless options:
    "--adaptive_reconstruction=0 --distance=0.3 --speed=fast"
    "--modular-group -N 3 -B 11"
    "--modular-group -Q 97"
  )

  local brunsli_benchmarks=(
    "--num_reps=6 --quant=0"
    "--num_reps=6 --quant=20"
  )

  local images=(
    "third_party/testdata/imagecompression.info/flower_foveon.png"
  )

  local cpu_confs=(
    "${RUNNER_CPU_LITTLE}"
    "${RUNNER_CPU_BIG}"
    # The CPU description is something like 3-7, so these configurations only
    # take the first CPU of the group.
    "${RUNNER_CPU_LITTLE%%-*}"
    "${RUNNER_CPU_BIG%%-*}"
  )

  local jpg_dirname="third_party/corpora/jpeg"
  mkdir -p "${jpg_dirname}"
  local jpg_images=()
  local jpg_qualities=( 50 80 95 )
  for src_img in "${images[@]}"; do
    for q in "${jpg_qualities[@]}"; do
      local jpeg_name="${jpg_dirname}/"$(basename "${src_img}" .png)"-q${q}.jpg"
      "${BUILD_DIR}/tools/cjpegxl" --jpeg1 --jpeg_quality "${q}" \
        "${src_img}" "${jpeg_name}"
      jpg_images+=("${jpeg_name}")
    done
  done

  local output_dir="${BUILD_DIR}/benchmark_results"
  mkdir -p "${output_dir}"
  local runs_file="${output_dir}/runs.txt"

  if [[ ! -e "${runs_file}" ]]; then
    echo -e "flags\tsrc_img\tsrc size\tsrc pixels\tcpuset\tenc size (B)\tenc speed (MP/s)\tdec speed (MP/s)" |
      tee -a "${runs_file}"
  fi

  mkdir -p "${BUILD_DIR}/arm_benchmark"
  local flags
  local src_img
  for src_img in "${jpg_images[@]}" "${images[@]}"; do
    local src_img_hash=$(sha1sum "${src_img}" | cut -f 1 -d ' ')
    local img_benchmarks=("${benchmarks[@]}")
    local enc_binary="${BUILD_DIR}/tools/cjpegxl"
    local src_ext="${src_img##*.}"
    if [[ "${src_ext}" == "jpg" ]]; then
      img_benchmarks=("${brunsli_benchmarks[@]}")
      enc_binary="${BUILD_DIR}/tools/cbrunsli"
    fi
    for flags in "${img_benchmarks[@]}"; do
      # Encoding step.
      local enc_file_hash="$flags || ${src_img} || ${src_img_hash}"
      enc_file_hash=$(echo "${enc_file_hash}" | sha1sum | cut -f 1 -d ' ')
      local enc_file="${BUILD_DIR}/arm_benchmark/${enc_file_hash}.jxl"

      for cpu_conf in "${cpu_confs[@]}"; do
        cmd_cpuset "${cpu_conf}"

        echo "Encoding with: img=${src_img} cpus=${cpu_conf} enc_flags=${flags}"
        local enc_output
        if [[ "${flags}" == *"modular-group"* ]]; then
          # We don't benchmark encoding speed in this case.
          if [[ ! -f "${enc_file}" ]]; then
            cmd_cpuset "${RUNNER_CPU_ALL}"
            "${enc_binary}" ${flags} "${src_img}" "${enc_file}.tmp"
            mv "${enc_file}.tmp" "${enc_file}"
            cmd_cpuset "${cpu_conf}"
          fi
          enc_output=" ?? MP/s"
        else
          wait_for_temp
          enc_output=$("${enc_binary}" ${flags} "${src_img}" "${enc_file}.tmp" \
            2>&1 | grep -F "MP/s [")
          mv "${enc_file}.tmp" "${enc_file}"
        fi
        local enc_speed=$(_speed_from_output "${enc_output}")
        local enc_size=$(stat -c "%s" "${enc_file}")

        echo "Decoding with: img=${src_img} cpus=${cpu_conf} enc_flags=${flags}"

        local dec_output
        wait_for_temp
        dec_output=$("${BUILD_DIR}/tools/djpegxl" "${enc_file}" \
          --num_reps=5 2>&1 | grep -F "MP/s [")
        local img_size=$(echo "${dec_output}" | cut -f 1 -d ',')
        local img_size_x=$(echo "${img_size}" | cut -f 1 -d ' ')
        local img_size_y=$(echo "${img_size}" | cut -f 3 -d ' ')
        local img_size_px=$(( ${img_size_x} * ${img_size_y} ))
        local dec_speed=$(_speed_from_output "${dec_output}")

        # Record entry in a tab-separated file.
        local src_img_base=$(basename "${src_img}")
        echo -e "${flags}\t${src_img_base}\t${img_size}\t${img_size_px}\t${cpu_conf}\t${enc_size}\t${enc_speed}\t${dec_speed}" |
          tee -a "${runs_file}"
      done
    done
  done
  cmd_cpuset "${RUNNER_CPU_ALL}"
  cat "${runs_file}"

  if [[ -n "${CI_BUILD_NAME:-}" ]]; then
    load_mr_vars_from_commit
    { set +x; } 2>/dev/null
    local message="Results for ${CI_BUILD_NAME} @ ${CI_COMMIT_SHORT_SHA} (job ${CI_JOB_URL:-}):

\`\`\`
$(column -t -s "	" "${runs_file}")
\`\`\`
"
    cmd_post_mr_comment "${message}"
    set -x
  fi
}

# Runs the linter (clang-format) on the pending CLs.
cmd_lint() {
  merge_request_commits
  # { set +x; } 2>/dev/null
  local versions=(${1:-6.0 7 8 9})
  local clang_format_bins=("${versions[@]/#/clang-format-}" clang-format)
  local tmpdir=$(mktemp -d)
  CLEANUP_FILES+=("${tmpdir}")

  local installed=()
  local clang_patch
  local clang_format
  for clang_format in "${clang_format_bins[@]}"; do
    if ! which "${clang_format}" >/dev/null; then
      continue
    fi
    installed+=("${clang_format}")
    local tmppatch="${tmpdir}/${clang_format}.patch"
    # We include in this linter all the changes including the uncommited changes
    # to avoid printing changes already applied.
    set -x
    git -C "${MYDIR}" "${clang_format}" --binary "${clang_format}" \
      --style=file --diff "${MR_ANCESTOR_SHA}" -- >"${tmppatch}"
    { set +x; } 2>/dev/null

    if grep -E '^--- ' "${tmppatch}">/dev/null; then
      if [[ -n "${LINT_OUTPUT:-}" ]]; then
        cp "${tmppatch}" "${LINT_OUTPUT}"
      fi
      clang_patch="${tmppatch}"
    else
      echo "clang-format check OK" >&2
      return 0
    fi
  done

  if [[ ${#installed[@]} -eq 0 ]]; then
    echo "You must install clang-format for \"git clang-format\"" >&2
    exit 1
  fi

  # clang-format is installed but found problems.
  echo "clang-format findings:" >&2
  "${COLORDIFF_BIN}" < "${clang_patch}"

  echo "clang-format found issues in your patches from ${MR_ANCESTOR_SHA}" \
    "to the current patch. Run \`./ci.sh lint | patch -p1\` from the base" \
    "directory to apply them." >&2
  exit 1
}

# Runs clang-tidy on the pending CLs. If the "all" argument is passed it runs
# clang-tidy over all the source files instead.
cmd_tidy() {
  local what="${1:-}"

  if [[ -z "${CLANG_TIDY_BIN}" ]]; then
    echo "ERROR: You must install clang-tidy-6.0 or newer to use ci.sh tidy" >&2
    exit 1
  fi

  local git_args=()
  if [[ "${what}" == "all" ]]; then
    git_args=(ls-files)
    shift
  else
    merge_request_commits
    git_args=(
        diff-tree --no-commit-id --name-only -r "${MR_ANCESTOR_SHA}"
        "${MR_HEAD_SHA}"
    )
  fi

  # Clang-tidy needs the compilation database generated by cmake.
  if [[ ! -e "${BUILD_DIR}/compile_commands.json" ]]; then
    # Generate the build options in debug mode, since we need the debug asserts
    # enabled for the clang-tidy analyzer to use them.
    CMAKE_BUILD_TYPE="Debug"
    cmake_configure
  fi

  cd "${MYDIR}"
  local nprocs=$(nproc --all || echo 1)
  local ret=0
  if ! parallel -j"${nprocs}" --keep-order -- \
      "${CLANG_TIDY_BIN}" -p "${BUILD_DIR}" -format-style=file -quiet "$@" {} \
      < <(git "${git_args[@]}" | grep -E '(\.cc|\.cpp)$') \
      >"${BUILD_DIR}/clang-tidy.txt"; then
    ret=1
  fi
  { set +x; } 2>/dev/null
  echo "Findings statistics:" >&2
  grep -E ' \[[A-Za-z\.,\-]+\]' -o "${BUILD_DIR}/clang-tidy.txt" | sort \
    | uniq -c >&2

  if [[ $ret -ne 0 ]]; then
    cat >&2 <<EOF
Errors found, see ${BUILD_DIR}/clang-tidy.txt for details.
To automatically fix them, run:

  SKIP_TEST=1 ./ci.sh debug
  ${CLANG_TIDY_BIN} -p ${BUILD_DIR} -fix -format-style=file -quiet $@ \$(git ${git_args[@]} | grep -E '(\.cc|\.cpp)\$')
EOF
  fi

  return ${ret}
}

main() {
  local cmd="${1:-}"
  if [[ -z "${cmd}" ]]; then
    cat >&2 <<EOF
Use: $0 CMD

Where cmd is one of:
 opt       Build and test a Release with symbols build.
 debug     Build and test a Debug build (NDEBUG is not defined).
 release   Build and test a striped Release binary without debug information.
 asan      Build and test an ASan (AddressSanitizer) build.
 msan      Build and test an MSan (MemorySanitizer) build. Needs to have msan
           c++ libs installed with msan_install first.
 tsan      Build and test a TSan (ThreadSanitizer) build.
 test      Run the tests build by opt, debug, release, asan or msan. Useful when
           building with SKIP_TEST=1.
 benchmark Run the benchmark over the default corpus.
 fast_benchmark Run the benchmark over the small corpus.

 coverage  Buils and run tests with coverage support. Runs coverage_report as
           well.
 coverage_report Generate HTML, XML and text coverage report after a coverage
           run.

 lint      Run the linter checks on the current commit or merge request.
 tidy      Run clang-tidy on the current commit or merge request.

 msan_install Install the libc++ libraries required to build in msan mode. This
              needs to be done once.

You can pass some optional environment variables as well:
 - BUILD_DIR: The output build directory (by default "$$repo/build")
 - BUILD_TARGET: The target triplet used when cross-compiling.
 - CMAKE_FLAGS: Convenience flag to pass both CMAKE_C_FLAGS and CMAKE_CXX_FLAGS.
 - CMAKE_PREFIX_PATH: Installation prefixes to be searched by the find_package.
 - LINT_OUTPUT: Path to the output patch from the "lint" command.
 - SKIP_TEST=1: Skip the test stage.
 - STORE_IMAGES=0: Makes the benchmark discard the computed images.

These optional environment variables are forwarded to the cmake call as
parameters:
 - CMAKE_C_FLAGS
 - CMAKE_CXX_FLAGS
 - CMAKE_CROSSCOMPILING_EMULATOR
 - CMAKE_EXE_LINKER_FLAGS
 - CMAKE_MODULE_LINKER_FLAGS
 - CMAKE_SHARED_LINKER_FLAGS
 - CMAKE_TOOLCHAIN_FILE
 - CMAKE_BUILD_TYPE

Example:
  BUILD_DIR=/tmp/build $0 opt
EOF
    exit 1
  fi

  cmd="cmd_${cmd}"
  shift
  set -x
  "${cmd}" "$@"
}

main "$@"
