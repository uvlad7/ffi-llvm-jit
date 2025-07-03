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


__attribute__((always_inline)) long long ffi_llvm_jit_value_to_long_long(VALUE arg) {
    return NUM2LL(arg);
}

__attribute__((always_inline)) unsigned long long ffi_llvm_jit_value_to_ulong_long(VALUE arg) {
    return NUM2ULL(arg);
}

__attribute__((always_inline)) bool ffi_llvm_jit_value_to_bool(VALUE arg) {
    // return RTEST(arg);
    // I'd use RTEST, but FFI enforces that the argument is a boolean.
    switch (TYPE(arg)) {
        case T_TRUE:
            return true;
        case T_FALSE:
            return false;
        default:
            rb_raise(rb_eTypeError, "wrong argument type  (expected a boolean parameter)");
    }
}

__attribute__((always_inline)) float ffi_llvm_jit_value_to_float(VALUE arg) {
    return (float) NUM2DBL(arg);
}

__attribute__((always_inline)) double ffi_llvm_jit_value_to_double(VALUE arg) {
    return NUM2DBL(arg);
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

// TODO: Ruby defines long long differently, see include/ruby/backward/2/long_long.h
// but FFI simply uses `long long`, and so do I
__attribute__((always_inline)) VALUE ffi_llvm_jit_long_long_to_value(long long arg) {
    return LL2NUM(arg);
}

__attribute__((always_inline)) VALUE ffi_llvm_jit_ulong_long_to_value(unsigned long long arg) {
    return ULL2NUM(arg);
}

__attribute__((always_inline)) VALUE ffi_llvm_jit_bool_to_value(bool arg) {
    return arg ? Qtrue : Qfalse;
}

__attribute__((always_inline)) VALUE ffi_llvm_jit_float_to_value(float arg) {
    // FFI uses rb_float_new, I prefer DBL2NUM - which is defined exactly like that - for consistency
    return DBL2NUM(arg);
}

__attribute__((always_inline)) VALUE ffi_llvm_jit_double_to_value(double arg) {
    return DBL2NUM(arg);
}
