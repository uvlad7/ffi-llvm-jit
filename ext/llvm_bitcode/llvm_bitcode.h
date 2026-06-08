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
extern void *ffi_llvm_jit_value_to_pointer(VALUE arg);
extern void *ffi_llvm_jit_value_to_buffer_in(VALUE arg);
extern void *ffi_llvm_jit_value_to_buffer_out(VALUE arg);
extern void *ffi_llvm_jit_value_to_buffer_inout(VALUE arg);
extern VALUE ffi_llvm_jit_pointer_to_value(void *ptr);

extern void ffi_llvm_jit_save_errno(void);

// void * rb_thread_call_without_gvl (void *(*func)(void *), void *data1, rb_unblock_function_t *ubf, void *data2)
// VALUE rb_rescue2(VALUE (* b_proc) (VALUE), VALUE data1, VALUE (* r_proc) (VALUE, VALUE), VALUE data2, ...)

__attribute__((used)) static void *llvm_keepalive[] = {
    (void *)ffi_llvm_jit_value_to_pointer,
    (void *)ffi_llvm_jit_value_to_buffer_in,
    (void *)ffi_llvm_jit_value_to_buffer_out,
    (void *)ffi_llvm_jit_value_to_buffer_inout,
    (void *)ffi_llvm_jit_pointer_to_value,
    (void *)ffi_llvm_jit_save_errno,
    (void *)rb_thread_call_without_gvl,
    (void *)rb_rescue2,
};

__attribute__((used)) static VALUE *llvm_keepalive_values[] = {
    &rb_eException,
};

#endif /* FFI_LLVM_JIT_LLVM_BITCODE_H */
