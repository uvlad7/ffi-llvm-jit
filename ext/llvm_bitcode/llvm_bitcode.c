#include "llvm_bitcode.h"

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Call.c
__attribute__((always_inline)) char * ffi_llvm_jit_value_to_string(VALUE arg) {
    return NIL_P(arg) ? NULL : StringValueCStr(arg);
}

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Types.c
__attribute__((always_inline)) VALUE ffi_llvm_jit_int_to_value(int arg) {
    return INT2NUM(arg);
}

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Types.c
__attribute__((always_inline)) VALUE ffi_llvm_jit_uint_to_value(unsigned int arg) {
    return UINT2NUM(arg);
}

// FFI.find_type(:size_t)
__attribute__((always_inline)) VALUE ffi_llvm_jit_ulong_to_value(unsigned long arg) {
    return ULONG2NUM(arg);
}
