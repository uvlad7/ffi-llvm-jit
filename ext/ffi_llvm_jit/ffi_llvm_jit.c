#include "ffi_llvm_jit.h"

VALUE rb_mFfiLlvmJit;
VALUE rb_mFfiLlvmJitLibrary;

// https://github.com/ffi/ffi/blob/master/ext/ffi_c/Function.c
/*
 * call-seq: attach(m, name)
//  * @param [Module] m
 * @param [String] name
 * @return [self]
 * Attach a Function to the Module +m+ as +name+.
 */
static VALUE
attach_llvm_jit_function(VALUE module, VALUE name_val, VALUE func_val, VALUE argc_val)
{
  const char * name = StringValueCStr(name_val);
  VALUE (*func)(ANYARGS);
  int argc;
  // if (!rb_obj_is_kind_of(module, rb_cModule))
  // {
  //   rb_raise(rb_eRuntimeError, "trying to attach function to non-module");
  //   return Qnil;
  // }
  func = (VALUE (*)(VALUE))NUM2PTR(func_val);
  if (func == NULL)
  {
    rb_raise(rb_eRuntimeError, "trying to attach NULL function");
    return Qnil;
  }
  argc = NUM2INT(argc_val);
  rb_define_singleton_method(module, name, func, argc);

  rb_define_method(module, name, func, argc);

  // return self;
  return module;
}

#include <string.h>
RUBY_FUNC_EXPORTED size_t ffi_llvm_jit_strlen(const char *s) {
  printf("ffi_llvm_jit_strlen: %p\n", (void*)&s);
  printf("ffi_llvm_jit_strlen: %s\n", s);
  return strlen(s);
}

RUBY_FUNC_EXPORTED void
Init_ffi_llvm_jit(void)
{
  rb_mFfiLlvmJit = rb_define_module("FfiLlvmJit");
  rb_mFfiLlvmJitLibrary = rb_define_module_under(rb_mFfiLlvmJit, "Library");
  rb_define_method(rb_mFfiLlvmJitLibrary, "attach_llvm_jit_function", attach_llvm_jit_function, 3);
}
