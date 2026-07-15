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

/* ABI-SENSITIVE COPY — READ BEFORE TOUCHING.
 *
 * This struct mirrors rbffi_frame_t from ffi/ext/ffi_c/Thread.h verbatim.
 * It must stay byte-for-byte identical to the FFI struct in field order,
 * types, and alignment, or rbffi_frame_push/pop will corrupt their thread-
 * local frame stack and produce use-after-free / wrong-exception bugs.
 *
 * VERIFIED against ffi gem versions: 1.16.3 – 1.17.4.
 * Run `git -C ~/ffi diff v1.16.3 -- ext/ffi_c/Thread.*` to re-check if you
 * update the ffi dependency in ffi_llvm_jit.gemspec.
 *
 * TODO (safe alternative): ask the ffi project to expose:
 *   rbffi_frame_t* rbffi_frame_alloc(void);    -- heap-allocates + zeroes
 *   void           rbffi_frame_free(rbffi_frame_t*);
 *   void           rbffi_frame_raise(rbffi_frame_t*); -- raise if exc != Qnil
 * Using those would remove the ABI coupling and let us drop this struct copy.
 */
typedef struct ffi_llvm_jit_frame {
    void* td;
    struct ffi_llvm_jit_frame* prev;
    VALUE exc;
} ffi_llvm_jit_frame_t;
__attribute__((used)) static ffi_llvm_jit_frame_t ffi_llvm_jit_frame_keepalive = {};

/* Resolved at JIT load time via LLVM::C.add_symbol (same as ffi_llvm_jit_save_errno):
 *   ffi_llvm_jit_frame_push          → rbffi_frame_push
 *   ffi_llvm_jit_frame_pop           → rbffi_frame_pop
 *   ffi_llvm_jit_save_frame_exception → rbffi_save_frame_exception  */
extern void  ffi_llvm_jit_frame_push(ffi_llvm_jit_frame_t* frame);
extern void  ffi_llvm_jit_frame_pop(ffi_llvm_jit_frame_t* frame);
extern VALUE ffi_llvm_jit_save_frame_exception(VALUE data, VALUE exc);
#endif

#ifdef FFI_LLVM_JIT_WIN_PLATFORM
// Future: #include <windows.h> — needed for APC-based UBF, see llvm_bitcode.c.

/* LLVM's StackProtector codegen pass on Windows COFF inserts __stack_chk_fail
 * references even when the IR has no SSP attributes. Define both symbols here
 * so MCJIT resolves them within LLVM_MOD without needing an external library. */
// volatile uintptr_t __stack_chk_guard = 0x595e9fbd94fda766ULL;
// __attribute__((noreturn)) void __stack_chk_fail(void) { __builtin_trap(); }

// /* clang-cl /GS (buffer security check) inserts __security_check_cookie references.
//  * Define stub symbols so MCJIT resolves them without needing the MSVC runtime. */
// uintptr_t __security_cookie = 0x595e9fbd94fda767ULL;
// uintptr_t __security_cookie_complement = ~(uintptr_t)0x595e9fbd94fda767ULL;
// void __cdecl __security_check_cookie(uintptr_t cookie) { (void)cookie; }

// Future: APC-based UBF for interruptible alertable waits — see llvm_bitcode.c.
// static void CALLBACK ffi_llvm_jit_win32_empty_apc(ULONG_PTR param) { (void)param; }
// static void ffi_llvm_jit_win32_ubf(void *ptr) {
//     QueueUserAPC(ffi_llvm_jit_win32_empty_apc, (HANDLE)ptr, 0);
// }

#endif

__attribute__((used)) static void *llvm_keepalive[] = {
#ifndef FFI_LLVM_JIT_WIN_PLATFORM
    (void *)ffi_llvm_jit_save_errno,
    (void *)ffi_llvm_jit_frame_push,
    (void *)ffi_llvm_jit_frame_pop,
    (void *)ffi_llvm_jit_save_frame_exception,
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
