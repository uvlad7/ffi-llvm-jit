# frozen_string_literal: true

require_relative 'ffi_llvm_jit/version'
require_relative 'ffi_llvm_jit/ffi_llvm_jit'

require 'llvm/core'
require 'llvm/execution_engine'
# Patch ruby-llvm gem to load bitcode
# module LLVM::C
#   # Orig uses this https://llvm.org/doxygen/group__LLVMCCoreModule.html
#   # LLVMModuleRef 	LLVMModuleCreateWithName (const char *ModuleID)
#   # attach_function :module_create_with_name, :LLVMModuleCreateWithName, [:string], :pointer

#   # We are gonna use this https://llvm.org/doxygen/group__LLVMCBitReader.html
#   # LLVMBool 	LLVMParseBitcode (LLVMMemoryBufferRef MemBuf, LLVMModuleRef *OutModule, char **OutMessage)
#   # LLVMBool 	LLVMParseBitcode2 (LLVMMemoryBufferRef MemBuf, LLVMModuleRef *OutModule)
#   # (already present, parse_bitcode, parse_bitcode2)
#   # and this https://llvm.org/doxygen/group__LLVMCCoreMemoryBuffers.html
#   # LLVMBool 	LLVMCreateMemoryBufferWithContentsOfFile (const char *Path, LLVMMemoryBufferRef *OutMemBuf, char **OutMessage)
#   # (already present, create_memory_buffer_with_contents_of_file)
# end
# UPD: present in llvm/core/bitcode.rb

module FfiLlvmJit
  class Error < StandardError; end

  module Library
    include ::FFI::Library

    FFI_LLVM_JIT_MOD = LLVM::Module.parse_bitcode(File.expand_path("ffi_llvm_jit/llvm_bitcode.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__))
    LLVM.init_jit
    FFI_LLVM_JIT_ENG = LLVM::JITCompiler.new(FFI_LLVM_JIT_MOD, opt_level: 3)
    # FFI_LLVM_JIT_ENG.dispose is never called
    # FFI_LLVM_JIT_MOD.dump

    #  # Native integer type
    # bits = FFI.type_size(:int) * 8
    # ::LLVM::Int = const_get("Int#{bits}")
    # @LLVMinst inttoptr
    POINTER = LLVM.const_get("Int#{FFI.type_size(:pointer) * 8}")
    VALUE = POINTER

    # TODO: Support all orig params
    def attach_function(name, func, args, returns)
      arg_types = args.map { |e| find_type(e) }
      function = ffi_libraries.find do |lib|
        fn = nil
        function_names(func, arg_types).find do |fname|
          fn = lib.find_function(fname)
        end
        break fn if fn
      end

      # string -> LLVM.Pointer; size_t -> LLVM::Int64
      fn_type = LLVM.Function([LLVM.Pointer(LLVM::Int8)], LLVM.const_get("Int#{FFI.type_size(:size_t) * 8}"))
      fn_ptr_type = LLVM.Pointer(fn_type)
      # Unnamed, can change '' into :"#{func}_ptr" for debugging, but unnamed is better to prevent name clashes
      func_ptr = FFI_LLVM_JIT_MOD.globals.add(POINTER, '') do |var|
        var.linkage = :private
        var.global_constant = true
        var.unnamed_addr = true
        var.initializer = POINTER.from_i(function.address)
      end

      rb_func = FFI_LLVM_JIT_MOD.functions.add(:"rb_#{name}", [VALUE, VALUE], VALUE) do |llvm_function, rb_self, param|
        llvm_function.basic_blocks.append('entry').build do |b|
          converted_param = b.call(FFI_LLVM_JIT_MOD.functions['ffi_llvm_jit_value_to_string'], param)
          func_ptr_val = b.int2ptr(func_ptr, fn_ptr_type)
          res = b.call2(fn_type, b.load2(fn_ptr_type, func_ptr_val), converted_param)
          b.ret b.call(FFI_LLVM_JIT_MOD.functions['ffi_llvm_jit_ulong_to_value'], res)
        end
      end

      attach_llvm_jit_function(name.to_s, FFI_LLVM_JIT_ENG.function_address(rb_func.name), args.size)
    end
  end

  # Your code goes here...
end
