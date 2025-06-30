#include "ffi_llvm_jit.h"

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Call.c
char * ffi_llvm_jit_convert_string(VALUE arg) {
    VALUE v = rb_sprintf("%+" PRIsVALUE "\n", arg);
    printf("%s", StringValueCStr(v));
    return NIL_P(arg) ? NULL : StringValueCStr(arg);
}
