#include "llvm_bitcode.h"

VALUE ffi_llvm_jit_Qnil = Qnil;

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Call.c
// TODO: Since we generate code for every function, we could easily support safe
// non-nullable arguments with almost no overhead.
__attribute__((always_inline)) char * ffi_llvm_jit_value_to_string(VALUE arg) {
    return NIL_P(arg) ? NULL : StringValueCStr(arg);
}

__attribute__((always_inline)) int ffi_llvm_jit_value_to_int(VALUE arg) {
    return NUM2INT(arg);
}

__attribute__((always_inline)) unsigned int ffi_llvm_jit_value_to_uint(VALUE arg) {
    return NUM2UINT(arg);
}

__attribute__((always_inline)) long ffi_llvm_jit_value_to_long(VALUE arg) {
    return NUM2LONG(arg);
}

__attribute__((always_inline)) unsigned long ffi_llvm_jit_value_to_ulong(VALUE arg) {
    return NUM2ULONG(arg);
}

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Types.c
__attribute__((always_inline)) VALUE ffi_llvm_jit_string_to_value(char * arg) {
    return arg != NULL ? rb_str_new2(arg) : Qnil;
}

__attribute__((always_inline)) VALUE ffi_llvm_jit_int_to_value(int arg) {
    return INT2NUM(arg);
}

__attribute__((always_inline)) VALUE ffi_llvm_jit_uint_to_value(unsigned int arg) {
    return UINT2NUM(arg);
}

__attribute__((always_inline)) VALUE ffi_llvm_jit_long_to_value(long arg) {
    return LONG2NUM(arg);
}

__attribute__((always_inline)) VALUE ffi_llvm_jit_ulong_to_value(unsigned long arg) {
    return ULONG2NUM(arg);
}
