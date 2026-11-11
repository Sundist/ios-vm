#ifndef POCKETVM_QEMU_SHIM_H
#define POCKETVM_QEMU_SHIM_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Called on the QEMU thread when QEMU has stopped. `status` is 0 for a
/// normal shutdown, the qemu_init() result if it failed, or -1 if QEMU
/// called exit().
typedef void (*pvm_qemu_done_fn)(int status, void *context);

/// Loads the QEMU library at `library_path`, then runs
/// qemu_init/qemu_main_loop/qemu_cleanup on a new thread with a large stack.
/// Returns 0 if the thread was started, otherwise -1 with a message in
/// `error` (dlopen/dlsym failures). QEMU can only run once per process.
int pvm_qemu_start(const char *library_path, int argc, const char *const *argv,
                   pvm_qemu_done_fn done, void *context,
                   char *error, size_t error_size);

/// 1 if a debugger has enabled JIT for this process (CS_DEBUGGED).
int pvm_jit_enabled(void);

#ifdef __cplusplus
}
#endif

#endif
