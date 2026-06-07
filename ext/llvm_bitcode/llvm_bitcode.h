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

/* Resolved at JIT load time via LLVM::C.add_symbol */
extern void ffi_llvm_jit_save_errno(void);

__attribute__((used)) static void *llvm_keepalive[] = {
    (void *)ffi_llvm_jit_save_errno,
    (void *)rb_thread_call_without_gvl,
    (void *)rb_rescue2,
};

__attribute__((used)) static VALUE *llvm_keepalive_values[] = {
    &rb_eException,
};

#endif /* FFI_LLVM_JIT_LLVM_BITCODE_H */
