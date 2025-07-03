#include "llvm_bitcode.h"

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Call.c
// https://github.com/ffi/ffi/blob/master/ext/ffi_c/Function.c
// rbffi_SetupCallParams
// and
// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Types.c
// rbffi_NativeValue_ToRuby
// typedef union {
// #ifdef USE_RAW
//     signed int s8, s16, s32;
//     unsigned int u8, u16, u32;
// #else
//     signed char s8;
//     unsigned char u8;
//     signed short s16;
//     unsigned short u16;
//     signed int s32;
//     unsigned int u32;
// #endif
//     signed long long i64;
//     unsigned long long u64;
//     signed long sl;
//     unsigned long ul;
//     void* ptr;
//     float f32;
//     double f64;
//     long double ld;
// } FFIStorage;
// typedef enum {
//     NATIVE_VOID,
VALUE ffi_llvm_jit_Qnil = Qnil;
//     NATIVE_INT8,
__attribute__((always_inline)) signed char ffi_llvm_jit_value_to_int8(VALUE arg) {
    return NUM2INT(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_int8_to_value(signed char arg) {
    return INT2NUM(arg);
}
//     NATIVE_UINT8,
__attribute__((always_inline)) unsigned char ffi_llvm_jit_value_to_uint8(VALUE arg) {
    return NUM2UINT(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_uint8_to_value(unsigned char arg) {
    return UINT2NUM(arg);
}
//     NATIVE_INT16,
__attribute__((always_inline)) signed short ffi_llvm_jit_value_to_int16(VALUE arg) {
    return NUM2INT(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_int16_to_value(signed short arg) {
    return INT2NUM(arg);
}
//     NATIVE_UINT16,
__attribute__((always_inline)) unsigned short ffi_llvm_jit_value_to_uint16(VALUE arg) {
    return NUM2UINT(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_uint16_to_value(unsigned short arg) {
    return UINT2NUM(arg);
}
//     NATIVE_INT32,
__attribute__((always_inline)) signed int ffi_llvm_jit_value_to_int32(VALUE arg) {
    return NUM2INT(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_int32_to_value(signed int arg) {
    return INT2NUM(arg);
}
//     NATIVE_UINT32,
__attribute__((always_inline)) unsigned int ffi_llvm_jit_value_to_uint32(VALUE arg) {
    return NUM2UINT(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_uint32_to_value(unsigned int arg) {
    return UINT2NUM(arg);
}
//     NATIVE_INT64,
__attribute__((always_inline)) signed long long ffi_llvm_jit_value_to_int64(VALUE arg) {
    return NUM2LL(arg);
}
// TODO: Ruby defines long long differently, see include/ruby/backward/2/long_long.h
// but FFI simply uses `long long`, and so do I
__attribute__((always_inline)) VALUE ffi_llvm_jit_int64_to_value(signed long long arg) {
    return LL2NUM(arg);
}
//     NATIVE_UINT64,
__attribute__((always_inline)) unsigned long long ffi_llvm_jit_value_to_uint64(VALUE arg) {
    return NUM2ULL(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_uint64_to_value(unsigned long long arg) {
    return ULL2NUM(arg);
}
//     NATIVE_LONG,
__attribute__((always_inline)) signed long ffi_llvm_jit_value_to_long(VALUE arg) {
    return NUM2LONG(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_long_to_value(signed long arg) {
    return LONG2NUM(arg);
}
//     NATIVE_ULONG,
__attribute__((always_inline)) unsigned long ffi_llvm_jit_value_to_ulong(VALUE arg) {
    return NUM2ULONG(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_ulong_to_value(unsigned long arg) {
    return ULONG2NUM(arg);
}
//     NATIVE_FLOAT32,
__attribute__((always_inline)) VALUE ffi_llvm_jit_float_to_value(float arg) {
    // FFI uses rb_float_new, I prefer DBL2NUM - which is defined exactly like that - for consistency
    return DBL2NUM(arg);
}
__attribute__((always_inline)) float ffi_llvm_jit_value_to_float(VALUE arg) {
    return (float) NUM2DBL(arg);
}
//     NATIVE_FLOAT64,
__attribute__((always_inline)) VALUE ffi_llvm_jit_double_to_value(double arg) {
    return DBL2NUM(arg);
}
__attribute__((always_inline)) double ffi_llvm_jit_value_to_double(VALUE arg) {
    return NUM2DBL(arg);
}
//     NATIVE_LONGDOUBLE,
//     NATIVE_POINTER,
//     NATIVE_FUNCTION,
//     NATIVE_BUFFER_IN,
//     NATIVE_BUFFER_OUT,
//     NATIVE_BUFFER_INOUT,
//     NATIVE_BOOL,
// They use signed char as return value, but unsigned char as param when convert into Ruby, for some reason
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
__attribute__((always_inline)) VALUE ffi_llvm_jit_bool_to_value(bool arg) {
    return arg ? Qtrue : Qfalse;
}
//     /** An immutable string.  Nul terminated, but only copies in to the native function */
//     NATIVE_STRING,
//
// TODO: Since we generate code for every function, we could easily support safe
// non-nullable arguments with almost no overhead.
__attribute__((always_inline)) char * ffi_llvm_jit_value_to_string(VALUE arg) {
    return NIL_P(arg) ? NULL : StringValueCStr(arg);
}
__attribute__((always_inline)) VALUE ffi_llvm_jit_string_to_value(char * arg) {
    return arg != NULL ? rb_str_new2(arg) : Qnil;
}
//     /** The function takes a variable number of arguments */
//     NATIVE_VARARGS,

//     /** Struct-by-value param or result */
//     NATIVE_STRUCT,

//     /** An array type definition */
//     NATIVE_ARRAY,

//     /** Custom native type */
//     NATIVE_MAPPED,
// } NativeType;
