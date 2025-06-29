#include "ffi_llvm_jit.h"

// See https://github.com/ffi/ffi/blob/master/ext/ffi_c/Call.c
char * ffi_llvm_jit_convert_string(VALUE arg) {
    return NIL_P(arg) ? NULL : StringValueCStr(arg);
}
