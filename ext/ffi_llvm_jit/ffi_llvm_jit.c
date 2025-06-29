#include "ffi_llvm_jit.h"

VALUE rb_mFfiLlvmJit;

RUBY_FUNC_EXPORTED void
Init_ffi_llvm_jit(void)
{
  rb_mFfiLlvmJit = rb_define_module("FfiLlvmJit");
}
