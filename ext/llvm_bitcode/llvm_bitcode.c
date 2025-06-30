#include "llvm_bitcode.h"

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Call.c
char * ffi_llvm_jit_value_to_string(VALUE arg) {
    VALUE v = rb_sprintf("%+" PRIsVALUE "\n", arg);
    printf("%s", StringValueCStr(v));
    return NIL_P(arg) ? NULL : StringValueCStr(arg);
}

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Types.c
VALUE ffi_llvm_jit_uint_to_value(unsigned int arg) {
    return UINT2NUM(arg);
}

// FFI.find_type(:size_t)
VALUE ffi_llvm_jit_ulong_to_value(unsigned long arg) {
    return ULONG2NUM(arg);
}
