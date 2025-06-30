# frozen_string_literal: true

require 'ffi'
require 'llvm/core'
require 'llvm/execution_engine'

require_relative 'llvm_jit/version'
require_relative 'llvm_jit/ffi_llvm_jit'

# https://llvm.org/doxygen/group__LLVMCCoreModule.html
# https://llvm.org/doxygen/group__LLVMCBitReader.html
# https://llvm.org/doxygen/group__LLVMCCoreMemoryBuffers.html
# see llvm/core/bitcode.rb

module FFI
  module LLVMJIT
    # Extension to FFI::Library to support JIT compilation using LLVM
    module Library
      include ::FFI::Library

      LLVM_MOD = LLVM::Module.parse_bitcode(
        File.expand_path("llvm_jit/llvm_bitcode.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__)
      )
      LLVM.init_jit
      LLVM_ENG = LLVM::JITCompiler.new(LLVM_MOD, opt_level: 3)
      # LLVM_ENG.dispose is never called
      # LLVM_MOD.dump

      #  # Native integer type
      # bits = FFI.type_size(:int) * 8
      # ::LLVM::Int = const_get("Int#{bits}")
      # @LLVMinst inttoptr
      POINTER = LLVM.const_get("Int#{FFI.type_size(:pointer) * 8}")
      VALUE = POINTER

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize

      # TODO: Support all orig params
      def attach_function(name, func, args, _returns)
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
        func_ptr = LLVM_MOD.globals.add(POINTER, '') do |var|
          var.linkage = :private
          var.global_constant = true
          var.unnamed_addr = true
          var.initializer = POINTER.from_i(function.address)
        end

        rb_func = LLVM_MOD.functions.add(:"rb_#{name}", [VALUE, VALUE], VALUE) do |llvm_function, _rb_self, param|
          llvm_function.basic_blocks.append('entry').build do |b|
            converted_param = b.call(LLVM_MOD.functions['ffi_llvm_jit_value_to_string'], param)
            func_ptr_val = b.int2ptr(func_ptr, fn_ptr_type)
            res = b.call2(fn_type, b.load2(fn_ptr_type, func_ptr_val), converted_param)
            b.ret b.call(LLVM_MOD.functions['ffi_llvm_jit_ulong_to_value'], res)
          end
        end

        jit_name = "llvm_jit_#{name}"
        attach_llvm_jit_function(jit_name, LLVM_ENG.function_address(rb_func.name), args.size)
        singleton_class.alias_method name, jit_name
        alias_method name, jit_name
      end

      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize
    end
  end
end
