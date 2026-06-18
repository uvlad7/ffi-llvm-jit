# LLVM 'Hello, World!' example from
# http://llvm.org/docs/LangRef.html#module-structure
require 'llvm/core'
require 'llvm/execution_engine'
require_relative 'lib/ffi/llvm_jit/lljit'

HELLO_STRING = "Hello, World!"

# modules hold functions and variables
# mod = LLVM::Module.new('hello')
mod = LLVM::Module.parse_bitcode(
        File.expand_path("lib/ffi/llvm_jit/llvm_bitcode.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__),
      )
      LLVM::C.add_symbol(
        'ffi_llvm_jit_save_errno',
        FFI::DynamicLibrary.send(
          :load_library, FFI::CURRENT_PROCESS, nil,
        ).find_function('rbffi_save_errno'),
      )


# Declare the string constant as a global constant.
hello = mod.globals.add(LLVM::ConstantArray.string(HELLO_STRING) , :hello) do |var|
  var.linkage = :private
  var.global_constant = true
  var.unnamed_addr = true
  var.initializer = LLVM::ConstantArray.string(HELLO_STRING)
end


require 'fiddle'
VALUE = LLVM.const_get("Int#{FFI.type_size(:pointer) * 8}")

# # External declaration of the `puts` function
rb_string_value_cstr = mod.functions.add('rb_string_value_cstr', [LLVM.Pointer(VALUE)], LLVM.Pointer) do |function, string|
  function.add_attribute :no_unwind_attribute
  string.add_attribute :no_capture_attribute
end

# Definition of main function
# a function is made up of connected BasicBlocks and must have _one entry and exit
# basic blocks are (mostly) simple machine instructions and can be connected in a graph
main = mod.functions.add('main', [VALUE], LLVM::Int32) do |function, arg|
  function.basic_blocks.append.build do |b|
    zero = LLVM.Int(0) # a LLVM Constant value

    slot = b.alloca VALUE, "slot"
    b.store arg, slot
    res = b.call rb_string_value_cstr, slot
    b.ret res
  end
end

# mod.dump
#mod.dispose
puts "------------------------------"

puts 'init_jit'
LLVM.init_jit

puts 'LLJit'
engine = LLVM::LLJit.new
engine.add_module(mod)
puts 'function_address'
addr = engine.function_address(main.name)
puts addr
puts 'call'
str = "Ooops"
fn = Fiddle::Function.new(Fiddle::Pointer.new(addr), [Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
p fn.call(Fiddle.dlwrap(str))
puts 'dispose'
engine.dispose
