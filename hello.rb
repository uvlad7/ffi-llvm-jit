# LLVM 'Hello, World!' example from
# http://llvm.org/docs/LangRef.html#module-structure
require 'ffi'
require 'llvm/core'
require 'llvm/execution_engine'
require_relative 'lib/ffi/llvm_jit/lljit'

HELLO_STRING = "Hello, World!"

mod = LLVM::Module.parse_bitcode(
        File.expand_path("lib/ffi/llvm_jit/llvm_bitcode.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__),
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

# rb_string_value_cstr is already declared external in the bitcode (from StringValueCStr).
# Re-adding with the same name makes LLVM rename ours to rb_string_value_cstr.1 — use existing.
rb_string_value_cstr = mod.functions['rb_string_value_cstr'] ||
  mod.functions.add('rb_string_value_cstr', [LLVM.Pointer(VALUE)], LLVM.Pointer) do |function, string|
    function.add_attribute :no_unwind_attribute
    string.add_attribute :no_capture_attribute
  end

# Definition of main function
main = mod.functions.add('main', [VALUE], LLVM::Int32) do |function, arg|
  function.basic_blocks.append.build do |b|
    zero = LLVM.Int(0)

    slot = b.alloca VALUE, "slot"
    b.store arg, slot
    res = b.call rb_string_value_cstr, slot
    b.ret res
  end
end

puts "------------------------------"

puts 'init_jit'
LLVM.init_jit

puts 'LLJit'
engine = LLVM::LLJit.new

if Gem.win_platform?
  ffi_ext = File.expand_path("lib/ffi/llvm_jit/ffi_llvm_jit.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__)
  engine.add_dll_generator(ffi_ext)

  # MinGW SSP symbols: __stack_chk_guard is a global holding the canary value;
  # __stack_chk_fail is called when the canary is corrupted.
  # Ruby's -fstack-protector-strong in $CFLAGS means they land in the bitcode even
  # with our -fno-stack-protector append, so provide them as stubs.
  # All three globals must outlive the JIT engine — keep in $ vars.
  $ssp_guard = FFI::MemoryPointer.new(:uint64)
  $ssp_guard.write_uint64(rand(2**64))
  engine.add_absolute_symbol('__stack_chk_guard', $ssp_guard.address)
  $ssp_fail = FFI::Function.new(:void, []) { abort 'stack smashing detected' }
  engine.add_absolute_symbol('__stack_chk_fail', $ssp_fail.to_i)

  # ORC JIT generates __orc_init_func for every COFF module and calls __main from it.
  # Our bitcode has no global ctors; a no-op stub is sufficient.
  $__main_stub = FFI::Function.new(:void, []) {}
  engine.add_absolute_symbol('__main', $__main_stub.to_i)
end

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
