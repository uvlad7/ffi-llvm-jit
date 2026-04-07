#ifndef FFI_LLVM_JIT_LLVM_BITCODE_H
#define FFI_LLVM_JIT_LLVM_BITCODE_H 1

#include "ruby.h"
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

__attribute__((used)) static void *llvm_keepalive[] = {
    (void *)ffi_llvm_jit_value_to_pointer,
    (void *)ffi_llvm_jit_value_to_buffer_in,
    (void *)ffi_llvm_jit_value_to_buffer_out,
    (void *)ffi_llvm_jit_value_to_buffer_inout,
    (void *)ffi_llvm_jit_pointer_to_value,
};


#endif /* FFI_LLVM_JIT_LLVM_BITCODE_H */
