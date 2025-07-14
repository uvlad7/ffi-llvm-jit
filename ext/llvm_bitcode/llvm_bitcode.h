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

#endif /* FFI_LLVM_JIT_LLVM_BITCODE_H */
