#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$SCRIPT_DIR/.."
WORK_DIR="$(mktemp -d /tmp/synurang-c-runtime.XXXXXX)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if ! command -v cc >/dev/null 2>&1; then
    echo 'Skipping C runtime tests: no C compiler found.'
    exit 0
fi

COMMON_FLAGS=(
    -std=c11
    -pedantic
    -Wall
    -Wextra
    -Werror
    -Wstrict-prototypes
    -I"$ROOT_DIR/include"
)

cc "${COMMON_FLAGS[@]}" -pthread \
    "$ROOT_DIR/src/c_runtime.c" \
    "$ROOT_DIR/test/c_runtime/c_runtime_test.c" \
    -o "$WORK_DIR/c_runtime_test"
"$WORK_DIR/c_runtime_test"

# On GNU-compatible linkers, interpose only this test process's pthread mutex
# calls to force the otherwise instruction-sized Send/poll race. The runtime
# has no test hook, and unsupported linkers skip this supplemental pass.
if cc -x c -pthread \
    -Wl,--wrap=pthread_mutex_lock \
    -Wl,--wrap=pthread_mutex_unlock \
    -o "$WORK_DIR/wrap_probe" - >/dev/null 2>&1 <<'EOF'
#if defined(_WIN32) || \
    (defined(__EMSCRIPTEN__) && !defined(__EMSCRIPTEN_PTHREADS__))
#error "the C runtime does not use pthread mutexes on this target"
#endif
int main(void) { return 0; }
EOF
then
    cc "${COMMON_FLAGS[@]}" -pthread \
        -DSYNURANG_TEST_PTHREAD_WRAP \
        "$ROOT_DIR/src/c_runtime.c" \
        "$ROOT_DIR/test/c_runtime/c_runtime_test.c" \
        -Wl,--wrap=pthread_mutex_lock \
        -Wl,--wrap=pthread_mutex_unlock \
        -o "$WORK_DIR/c_runtime_race_test"
    "$WORK_DIR/c_runtime_race_test"
else
    echo 'Skipping deterministic C runtime race pass: native pthread --wrap unavailable.'
fi

# Exercise the synchronous wakeup -> poll -> on_open -> Close regression under
# AddressSanitizer. Compilers without sanitizer support simply skip this pass;
# the strict unsanitized build above remains mandatory.
if [[ "${SYNURANG_SKIP_ASAN:-0}" != 1 ]] && \
    cc "${COMMON_FLAGS[@]}" -pthread \
        -fsanitize=address -fno-omit-frame-pointer \
        "$ROOT_DIR/src/c_runtime.c" \
        "$ROOT_DIR/test/c_runtime/c_runtime_test.c" \
        -o "$WORK_DIR/c_runtime_asan_test" >/dev/null 2>&1; then
    ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=1:halt_on_error=1:abort_on_error=1}" \
        "$WORK_DIR/c_runtime_asan_test"
else
    echo 'Skipping C runtime ASan pass: compiler support unavailable or disabled.'
fi

# The same manual-poll core must remain usable in a WebAssembly-style build
# where the C runtime cannot create or wait on native threads.
cc "${COMMON_FLAGS[@]}" \
    -DSYNURANG_RUNTIME_NO_THREADS \
    -DSYNURANG_TEST_MANUAL_ONLY \
    "$ROOT_DIR/src/c_runtime.c" \
    "$ROOT_DIR/test/c_runtime/c_runtime_test.c" \
    -o "$WORK_DIR/c_runtime_no_threads_test"
"$WORK_DIR/c_runtime_no_threads_test"
