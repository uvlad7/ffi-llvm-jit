#ifndef FFI_LLVM_JIT_LLVM_BITCODE_H
#define FFI_LLVM_JIT_LLVM_BITCODE_H 1

#include "ruby.h"
#include "ruby/thread.h"
// #include <stdint.h>
#include <stdbool.h>

#ifdef __GNUC__
#  define likely(x) __builtin_expect((x), 1)
#  define unlikely(x) __builtin_expect((x), 0)
#else
#  define likely(x) (x)
#  define unlikely(x) (x)
#endif

#ifndef FFI_LLVM_JIT_WIN_PLATFORM
/* Resolved at JIT load time via LLVM::C.add_symbol */
extern void ffi_llvm_jit_save_errno(void);
#endif

#ifdef FFI_LLVM_JIT_WIN_PLATFORM
// Future: #include <windows.h> — needed for APC-based UBF, see llvm_bitcode.c.

/* LLVM's StackProtector codegen pass on Windows COFF inserts __stack_chk_fail
 * references even when the IR has no SSP attributes. Define both symbols here
 * so MCJIT resolves them within LLVM_MOD without needing an external library. */
volatile uintptr_t __stack_chk_guard = 0x595e9fbd94fda766ULL;
__attribute__((noreturn)) void __stack_chk_fail(void) { __builtin_trap(); }

// Future: APC-based UBF for interruptible alertable waits — see llvm_bitcode.c.
// static void CALLBACK ffi_llvm_jit_win32_empty_apc(ULONG_PTR param) { (void)param; }
// static void ffi_llvm_jit_win32_ubf(void *ptr) {
//     QueueUserAPC(ffi_llvm_jit_win32_empty_apc, (HANDLE)ptr, 0);
// }

#endif

__attribute__((used)) static void *llvm_keepalive[] = {
#ifndef FFI_LLVM_JIT_WIN_PLATFORM
    (void *)ffi_llvm_jit_save_errno,
#endif
    (void *)rb_thread_call_without_gvl,
    (void *)rb_rescue2,
};

// Can't use a static initializer here: on Windows, rb_eException is
// __declspec(dllimport), so &rb_eException is not a compile-time constant.
// A constructor achieves the same effect (forces rb_eException into the
// extension's IAT) without requiring a static initializer.
__attribute__((used)) static VALUE *llvm_keepalive_values[1];
__attribute__((constructor)) static void ffi_llvm_jit_init_keepalive(void) {
    llvm_keepalive_values[0] = &rb_eException;
}

#endif /* FFI_LLVM_JIT_LLVM_BITCODE_H */
