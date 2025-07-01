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
    module Library # rubocop:disable Metrics/ModuleLength
      include ::FFI::Library

      LLVM_MOD = LLVM::Module.parse_bitcode(
        File.expand_path("llvm_jit/llvm_bitcode.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__),
      )
      LLVM.init_jit
      LLVM_ENG = LLVM::JITCompiler.new(LLVM_MOD, opt_level: 3)

      private_constant :LLVM_MOD, :LLVM_ENG

      # LLVM_ENG.dispose is never called
      # https://llvm.org/doxygen/group__LLVMCTarget.html#gaaa9ce583969eb8754512e70ec4b80061
      # LLVM_MOD.dump

      # # Native integer type
      # bits = FFI.type_size(:int) * 8
      # ::LLVM::Int = const_get("Int#{bits}")
      # @LLVMinst inttoptr
      POINTER = LLVM.const_get("Int#{FFI.type_size(:pointer) * 8}")
      VALUE = POINTER
      LLVM_TYPES = {
        string: LLVM.Pointer(LLVM::Int8),
        # uint, not uint32, because converters support platform-specific types
        int: LLVM.const_get("Int#{FFI.type_size(:int) * 8}"),
        uint: LLVM.const_get("Int#{FFI.type_size(:uint) * 8}"),
        long: LLVM.const_get("Int#{FFI.type_size(:long) * 8}"),
        ulong: LLVM.const_get("Int#{FFI.type_size(:ulong) * 8}"),
        void: LLVM.Void,
      }.freeze

      private_constant :POINTER, :VALUE, :LLVM_TYPES

      # TODO: LLVM args
      # FFI::Type::Builtin to LLVM types
      # FFI::NativeType.constants
      # https://github.com/ffi/ffi/blob/master/ext/ffi_c/Type.c#L410

      # rubocop:disable Style/MutableConstant
      # Frozen later
      SUPPORTED_TO_NATIVE = {}
      SUPPORTED_FROM_NATIVE = {}
      # rubocop:enable Style/MutableConstant

      LLVM_MOD.functions.each do |func|
        name = func.name
        if name[/\Affi_llvm_jit_value_to_(.*)\z/, 1]
          type = Regexp.last_match(1).to_sym
          SUPPORTED_TO_NATIVE[FFI.find_type(type)] = type
        elsif name[/\Affi_llvm_jit_(.*)_to_value\z/]
          type = Regexp.last_match(1).to_sym
          SUPPORTED_FROM_NATIVE[FFI.find_type(type)] = type
        end

        raise "Conversion function #{name} defined, but LLVM type #{type} is unknown" if type && !LLVM_TYPES.key?(type)
      end

      SUPPORTED_FROM_NATIVE[FFI.find_type(:void)] = :void
      SUPPORTED_TO_NATIVE.freeze
      SUPPORTED_FROM_NATIVE.freeze

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # @note Return type doesn't match the original method, but it's usually not used
      def attach_function(name, func, args, returns = nil, options = nil)
        mname = name
        a2 = func
        a3 = args
        a4 = returns
        a5 = options
        cname, arg_types, ret_type, opts = if a4 && (a2.is_a?(String) || a2.is_a?(Symbol))
                                             [a2, a3, a4, a5]
                                           else
                                             [mname.to_s, a2, a3, a4]
                                           end
        # Convert :foo to the native type
        arg_types = arg_types.map { |e| find_type(e) }
        options = {
          convention: ffi_convention,
          type_map: defined?(@ffi_typedefs) ? @ffi_typedefs : nil,
          blocking: defined?(@blocking) && @blocking,
          enums: defined?(@ffi_enums) ? @ffi_enums : nil,
        }

        @blocking = false
        options.merge!(opts) if opts.is_a?(Hash)

        # TODO: support stdcall convention (rb_func.call_conv=)
        # TODO: support call_without_gvl
        # Variadic functions are not supported; we could support known arguments,
        # but we'd still need to know use libffi to create varargs
        ret_type_name = SUPPORTED_FROM_NATIVE[find_type(ret_type)]
        arg_type_names = arg_types.map { |arg_type| SUPPORTED_TO_NATIVE[arg_type] }
        if options[:convention] != :default || !options[:type_map].nil? ||
           options[:blocking] || options[:enums] || ret_type_name.nil? || arg_type_names.any?(&:nil?)
          return super(mname, cname, arg_types, ret_type, options)
        end

        function_handle = ffi_libraries.find do |lib|
          fn = nil
          begin
            function_names(cname, arg_types).find do |fname|
              fn = lib.find_function(fname)
            end
          rescue LoadError
            # Ignored
          end
          break fn if fn
        end
        raise FFI::NotFoundError.new(cname.to_s, ffi_libraries.map(&:name)) unless function_handle

        attach_llvm_jit_function(mname, function_handle.address, arg_type_names, ret_type_name)
      end

      private

      def attach_llvm_jit_function(rb_name, c_address, arg_type_names, ret_type_name)
        # AFAIK name doesn't need to be unique
        llvm_mod = LLVM::Module.new('llvm_jit')
        # string -> LLVM.Pointer; size_t -> LLVM::Int64
        fn_type = LLVM.Function(
          arg_type_names.map { |arg_type| LLVM_TYPES[arg_type] },
          LLVM_TYPES[ret_type_name],
        )
        fn_ptr_type = LLVM.Pointer(fn_type)
        # Unnamed, can change '' into :"#{cname}_ptr" for debugging, but unnamed is better to prevent name clashes
        func_ptr = llvm_mod.globals.add(POINTER, '') do |var|
          var.linkage = :private
          var.global_constant = true
          var.unnamed_addr = true
          var.initializer = POINTER.from_i(c_address)
        end

        # Something is wrong in case of name collizion; and even though you can
        # update rb_func.name=, function_address is still zero
        # Upd: It happens if functions are the same even though their names are different

        rb_func = llvm_mod.functions.add(
          :"rb_llvm_jit_wrap_#{rb_name}", [VALUE] * (arg_type_names.size + 1), VALUE,
        ) do |llvm_function, _rb_self, *params|
          llvm_function.basic_blocks.append('entry').build do |b|
            converted_params = arg_type_names.zip(params).map do |arg_type, param|
              b.call(LLVM_MOD.functions["ffi_llvm_jit_value_to_#{arg_type}"], param)
            end

            func_ptr_val = b.int2ptr(func_ptr, fn_ptr_type)
            res = b.call2(fn_type, b.load2(fn_ptr_type, func_ptr_val), *converted_params)
            b.ret(
              if ret_type_name == :void
                b.load2(VALUE, LLVM_MOD.globals['ffi_llvm_jit_Qnil'])
              else
                b.call(LLVM_MOD.functions["ffi_llvm_jit_#{ret_type_name}_to_value"], res)
              end,
            )
          end
        end

        LLVM_ENG.modules.add(llvm_mod)
        # rb_func.name isn't always the same as rb_name, in case of name clashes
        # it contains a postfix like "rb_llvm_jit_wrap_strlen.1"
        jit_name = "llvm_jit_#{rb_name}"
        # https://llvm.org/doxygen/group__LLVMCExecutionEngine.html
        attach_rb_wrap_function(jit_name, LLVM_ENG.function_address(rb_func.name), arg_type_names.size)
        singleton_class.alias_method rb_name, jit_name
        alias_method rb_name, jit_name
        nil
      end

      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
  end
end
