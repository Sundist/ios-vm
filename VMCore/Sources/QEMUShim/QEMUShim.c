// Runs QEMU (built as a shared library, see UTM's QEMU fork) inside the app
// process, the way UTM does on iOS where spawning processes is not allowed.
// Approach adapted from UTM (Services/UTMProcess.m, Apache-2.0).

#include "QEMUShim.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*qemu_init_fn)(int, const char **, const char **);
typedef void (*qemu_void_fn)(void);

typedef struct {
    qemu_init_fn init;
    qemu_void_fn main_loop;
    qemu_void_fn cleanup;
    int argc;
    char **argv;
    pvm_qemu_done_fn done;
    void *context;
    int status;
} pvm_qemu_run;

static pthread_t qemu_thread;
static volatile int qemu_thread_valid = 0;
static int exit_hook_installed = 0;

// QEMU calls exit() on fatal errors (and some quit paths). Instead of
// terminating the app, end only the QEMU thread; its cleanup handler then
// reports the stop.
static void pvm_exit_hook(void) {
    if (qemu_thread_valid && pthread_equal(pthread_self(), qemu_thread)) {
        pthread_exit(NULL);
    }
}

static void pvm_qemu_finished(void *arg) {
    pvm_qemu_run *run = arg;
    qemu_thread_valid = 0;
    if (run->done) {
        run->done(run->status, run->context);
    }
    for (int i = 0; i < run->argc; i++) {
        free(run->argv[i]);
    }
    free(run->argv);
    free(run);
}

static void *pvm_qemu_thread(void *arg) {
    pvm_qemu_run *run = arg;
    run->status = -1; // stays -1 if QEMU leaves through exit()
    pthread_cleanup_push(pvm_qemu_finished, run);
    const char *envp[] = { NULL };
    int ret = run->init(run->argc, (const char **)run->argv, envp);
    if (ret == 0) {
        run->main_loop();
        run->cleanup();
    }
    run->status = ret;
    pthread_cleanup_pop(1);
    return NULL;
}

int pvm_qemu_start(const char *library_path, int argc, const char *const *argv,
                   pvm_qemu_done_fn done, void *context,
                   char *error, size_t error_size) {
    if (qemu_thread_valid) {
        snprintf(error, error_size, "QEMU is already running");
        return -1;
    }
    void *handle = dlopen(library_path, RTLD_LOCAL);
    if (!handle) {
        snprintf(error, error_size, "%s", dlerror());
        return -1;
    }
    pvm_qemu_run *run = calloc(1, sizeof(*run));
    run->init = (qemu_init_fn)dlsym(handle, "qemu_init");
    run->main_loop = (qemu_void_fn)dlsym(handle, "qemu_main_loop");
    run->cleanup = (qemu_void_fn)dlsym(handle, "qemu_cleanup");
    if (!run->init || !run->main_loop || !run->cleanup) {
        snprintf(error, error_size, "the QEMU library does not export qemu_init/qemu_main_loop/qemu_cleanup");
        free(run);
        return -1;
    }
    run->argc = argc;
    run->argv = calloc((size_t)argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) {
        run->argv[i] = strdup(argv[i]);
    }
    run->done = done;
    run->context = context;

    if (!exit_hook_installed) {
        atexit(pvm_exit_hook);
        exit_hook_installed = 1;
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);
#ifdef __APPLE__
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
#endif
    qemu_thread_valid = 1;
    int rc = pthread_create(&qemu_thread, &attr, pvm_qemu_thread, run);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        qemu_thread_valid = 0;
        snprintf(error, error_size, "could not start the QEMU thread (%d)", rc);
        for (int i = 0; i < argc; i++) free(run->argv[i]);
        free(run->argv);
        free(run);
        return -1;
    }
    return 0;
}

#ifdef __APPLE__
// Private but stable libsystem call; used the same way by UTM and others.
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define PVM_CS_OPS_STATUS 0
#define PVM_CS_DEBUGGED 0x10000000
#endif

int pvm_jit_enabled(void) {
#ifndef __APPLE__
    return 0;
#else
    unsigned int flags = 0;
    if (csops(getpid(), PVM_CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return 0;
    }
    return (flags & PVM_CS_DEBUGGED) != 0;
#endif
}
