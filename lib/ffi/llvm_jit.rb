# frozen_string_literal: true

require 'ffi'
require 'llvm/core'
require 'llvm/execution_engine'

require_relative 'llvm_jit/version'
require_relative 'llvm_jit/ffi_llvm_jit'

module FFI
  # https://llvm.org/doxygen/group__LLVMCCoreModule.html
  # https://llvm.org/doxygen/group__LLVMCBitReader.html
  # https://llvm.org/doxygen/group__LLVMCCoreMemoryBuffers.html
  # see llvm/core/bitcode.rb

  # Ruby FFI JIT using LLVM
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
      # see @LLVMinst inttoptr
      POINTER = LLVM.const_get("Int#{FFI.type_size(:pointer) * 8}")
      VALUE = POINTER
      LLVM_TYPES = {
        # Again, not sure. Char resolves into int8, but internally it uses 'signed char'
        void: LLVM.Void,
        int8: LLVM.const_get("Int#{FFI.type_size(:int8) * 8}"),
        uint8: LLVM.const_get("Int#{FFI.type_size(:uint8) * 8}"),
        int16: LLVM.const_get("Int#{FFI.type_size(:int16) * 8}"),
        uint16: LLVM.const_get("Int#{FFI.type_size(:uint16) * 8}"),
        int32: LLVM.const_get("Int#{FFI.type_size(:int32) * 8}"),
        uint32: LLVM.const_get("Int#{FFI.type_size(:uint32) * 8}"),
        int64: LLVM.const_get("Int#{FFI.type_size(:int64) * 8}"),
        uint64: LLVM.const_get("Int#{FFI.type_size(:uint64) * 8}"),
        long: LLVM.const_get("Int#{FFI.type_size(:long) * 8}"),
        ulong: LLVM.const_get("Int#{FFI.type_size(:ulong) * 8}"),
        # These types are actually defined as float and double in FFI
        # and despite they are called float32 and float64 in the definitions
        # and having FFI::NativeType::FLOAT32/FFI::NativeType::FLOAT64 constants,
        # you can't find them through FFI.find_type and therefore use in attach_function
        # anyway, they are just aliases
        float: LLVM::Float,
        double: LLVM::Double,
        bool: LLVM.const_get("Int#{FFI.type_size(:bool) * 8}"),
        string: LLVM.Pointer(LLVM::Int8),
      }.freeze

      private_constant :POINTER, :VALUE, :LLVM_TYPES, :LLVM_STDCALL

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
      private_constant :SUPPORTED_TO_NATIVE, :SUPPORTED_FROM_NATIVE

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # @note Return type doesn't match the original method, but it's usually not used
      # @see https://www.rubydoc.info/gems/ffi/FFI/Library#attach_function-instance_method FFI::Library.attach_function
      def attach_function(name, func, args, returns = nil, options = nil)
        mname, cname, arg_types, ret_type, options = convert_params(name, func, args, returns, options)
        return if attached_llvm_jit_function?(mname, cname, arg_types, ret_type, options)

        super(mname, cname, arg_types, ret_type, options)
      end

      # Same as +attach_function+, but raises an exception if cannot create JIT function
      # instead of falling back to the regular FFI function
      def attach_llvm_jit_function(name, func, args, returns = nil, options = nil)
        # TODO: support LLVM call_conv; not that function_names must be patched for that
        # (they also forgot an underscore on Windows for cdecl)
        # https://en.wikipedia.org/wiki/Name_mangling#C
        # (see core_ffi.rb and https://llvm.org/doxygen/namespacellvm_1_1CallingConv.html)
        mname, cname, arg_types, ret_type, options = convert_params(name, func, args, returns, options)
        return if attached_llvm_jit_function?(mname, cname, arg_types, ret_type, options)

        raise NotImplementedError, "Cannot create JIT function #{name}"
      end

      private

      def convert_params(name, func, args, returns, options)
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

        [mname, cname, arg_types, ret_type, options]
      end

      def attached_llvm_jit_function?(mname, cname, arg_types, ret_type, options)
        # TODO: support stdcall convention (rb_func.call_conv=)
        # TODO: support call_without_gvl
        # Variadic functions are not supported; we could support known arguments,
        # but we'd still need to know use libffi to create varargs
        ret_type_name = SUPPORTED_FROM_NATIVE[find_type(ret_type)]
        arg_type_names = arg_types.map { |arg_type| SUPPORTED_TO_NATIVE[arg_type] }
        if !options[:type_map].nil? || options[:blocking] || options[:enums] ||
           ret_type_name.nil? || arg_type_names.any?(&:nil?)
          return false
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

        call_conv = options[:convention] == :stdcall ? LLVM_STDCALL : nil
        attach_llvm_jit_function_addr(mname, function_handle.address, arg_type_names, ret_type_name, call_conv)
        # singleton_class.alias_method rb_name, jit_name
        # alias_method rb_name, jit_name
        true
      end

      def attach_llvm_jit_function_addr(rb_name, c_address, arg_type_names, ret_type_name, call_conv)
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
          :"rb_llvm_jit_wrap_#{rb_name}_#{llvm_mod.to_ptr.address}", [VALUE] * (arg_type_names.size + 1), VALUE,
        ) do |llvm_function, _rb_self, *params|
          llvm_function.basic_blocks.append('entry').build do |b|
            converted_params = arg_type_names.zip(params).map do |arg_type, param|
              b.call(LLVM_MOD.functions["ffi_llvm_jit_value_to_#{arg_type}"], param)
            end

            func_ptr_val = b.load2(fn_ptr_type, b.int2ptr(func_ptr, fn_ptr_type))
            # See value.rb (Function) and builder.rb (Builder#call2)
            # func_ptr_val is actually an Instruction, can't set call_conv
            res = b.call2(fn_type, func_ptr_val, *converted_params)
            res.call_conv = call_conv if call_conv
            b.ret(
              if ret_type_name == :void
                b.load2(VALUE, LLVM_MOD.globals['ffi_llvm_jit_Qnil'])
              else
                b.call(LLVM_MOD.functions["ffi_llvm_jit_#{ret_type_name}_to_value"], res)
              end,
            )
          end
        end
        # rb_func.dump

        # Ruby llvm_mod object isn't kept arount and might be GCed, but
        # it doesn't call +dispose+ automatically, so it's ok.
        # Note that in function name +llvm_mod.hash+ is used and it
        # mustn't be reused until the module is disposed, unlike
        # Ruby's object_id, which may be reused and cause name clashes in some rare cases.
        LLVM_ENG.modules.add(llvm_mod)
        # rb_func.name isn't always the same as rb_name, in case of name clashes
        # it contains a postfix like "rb_llvm_jit_wrap_strlen.1"
        # https://llvm.org/doxygen/group__LLVMCExecutionEngine.html
        attach_rb_wrap_function(rb_name.to_s, LLVM_ENG.function_address(rb_func.name), arg_type_names.size)
        nil
      end

      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
  end
end
