#include "ffi_llvm_jit.h"

VALUE rb_mFFI;
VALUE rb_mFFILLVMJIT;
VALUE rb_mFFILLVMJITLibrary;

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
  // rb_define_module_function uses rb_define_private_method instead of rb_define_method
  rb_define_singleton_method(module, name, func, argc);
  rb_define_method(module, name, func, argc);

  // return self;
  return module;
}

RUBY_FUNC_EXPORTED void
Init_ffi_llvm_jit(void)
{
  rb_mFFI = rb_define_module("FFI");
  rb_mFFILLVMJIT = rb_define_module_under(rb_mFFI, "LLVMJIT");
  rb_mFFILLVMJITLibrary = rb_define_module_under(rb_mFFILLVMJIT, "Library");
  rb_define_method(rb_mFFILLVMJITLibrary, "attach_llvm_jit_function", attach_llvm_jit_function, 3);
}
