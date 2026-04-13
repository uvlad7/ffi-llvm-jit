# frozen_string_literal: true

require 'set'

require 'ffi'
require 'llvm/core'
require 'llvm/linker'
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
      LLVM_MOD.verify!

      # Register FFI converter addresses with LLVM's global symbol table
      # before JIT engine creation so they are resolved on first compilation.
      reg_converter = proc { |fn_name, fn_ptr| LLVM::C.add_symbol("ffi_llvm_jit_#{fn_name}", fn_ptr) }
      FFI.send(:value_to_native_converters, &reg_converter)
      FFI.send(:native_to_value_converters, &reg_converter)

      LLVM.init_jit
      LLVM_ENG = LLVM::JITCompiler.new(LLVM_MOD, opt_level: 3)
      LLVM_MUTEX = Mutex.new

      # Validate all external declarations in the bitcode module are resolved.
      # LLVM intrinsics (llvm.*) are handled natively by the JIT and not in the symbol table.
      unresolved = LLVM_MOD.functions.select do |f|
        f.declaration?.nonzero? && !f.name.start_with?('llvm.') &&
          LLVM::C.search_for_address_of_symbol(f.name).null?
      end
      raise "Unresolved JIT symbols: #{unresolved.map(&:name).join(', ')}" unless unresolved.empty?

      private_constant :LLVM_MOD, :LLVM_ENG, :LLVM_MUTEX

      # LLVM_ENG.dispose is never called
      # https://llvm.org/doxygen/group__LLVMCTarget.html#gaaa9ce583969eb8754512e70ec4b80061
      # LLVM_MOD.dump

      # # Native integer type
      # bits = FFI.type_size(:int) * 8
      # ::LLVM::Int = const_get("Int#{bits}")
      # see @LLVMinst inttoptr
      INTPTR = LLVM.const_get("Int#{FFI.type_size(:pointer) * 8}")
      VALUE = INTPTR
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
        bool: LLVM::Int1,
        string: LLVM.Pointer(LLVM.const_get("Int#{FFI.type_size(:char) * 8}")),
        pointer: LLVM.Pointer(LLVM.Void),
        buffer_in: LLVM.Pointer(LLVM.Void),
        buffer_out: LLVM.Pointer(LLVM.Void),
        buffer_inout: LLVM.Pointer(LLVM.Void),
        # TODO: long_double
        # long double is tricky - it can be an alias to double, can be x86fp80 - which can be 12 or 16 bytes,
        # fp128, ppcfp128
        # https://en.wikipedia.org/wiki/Long_double
        # TODO: float128
        # TODO: int128
        # TODO: float16/half
      }.freeze

      private_constant :INTPTR, :VALUE, :LLVM_TYPES, :LLVM_STDCALL

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

      ENUM_TYPES = Set[
        :int8, :int16, :int32, :uint8, :uint16, :uint32, :int64, :uint64, :long, :ulong, :float, :double, :long_double,
      ].freeze
      private_constant :ENUM_TYPES

      # rubocop:disable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # Same as +attach_function+, but raises an exception if cannot create JIT function
      # instead of falling back to the regular FFI function
      def attach_llvm_jit_function(name, func, args, returns = nil, options = nil)
        mname, cname, arg_types, ret_type, options = convert_attach_function_params(name, func, args, returns, options)
        function_handle = find_function_handle(cname, arg_types)
        attach_function_handle(function_handle, mname, arg_types, ret_type, options, jit_only: true)
      end

      private

      # @note Return type doesn't match the original method, but it's usually not used
      # @see https://www.rubydoc.info/gems/ffi/FFI/Library#attach_function-instance_method FFI::Library.attach_function
      def attach_function_handle(function_handle, mname, arg_types, ret_type, options, jit_only: false)
        if attach_llvm_jit_function_handle?(function_handle, mname, arg_types, ret_type, options)
          return if jit_only

          invoker = Function.new(ret_type, arg_types, function_handle, options)
          @ffi_functions ||= {}
          @ffi_functions[mname.to_s.to_sym] = invoker
          return invoker
        end
        raise NotImplementedError, "Cannot create JIT function #{mname}" if jit_only

        super(function_handle, mname, arg_types, ret_type, options)
      end

      def attach_llvm_jit_function_handle?(function_handle, mname, arg_types, ret_type, options)
        unknown_options = options.keys - %i[convention type_map blocking enums]
        return false unless unknown_options.empty?

        type_mappers = []
        arg_types = arg_types.map.with_index do |arg_type, i|
          while arg_type.is_a?(Type::Mapped)
            type_mappers[i] ||= []
            type_mappers[i].push(arg_type)
            arg_type = arg_type.native_type
          end
          arg_type
        end

        while ret_type.is_a?(Type::Mapped)
          type_mappers[arg_types.size] ||= []
          type_mappers[arg_types.size].push(ret_type)
          ret_type = ret_type.native_type
        end

        # TODO: support call conventions other than stdcall (rb_func.call_conv=)
        # TODO: support call_without_gvl
        # Variadic functions are not supported; we could support known arguments,
        # but we'd still need to know use libffi to create varargs
        ret_type_name = SUPPORTED_FROM_NATIVE[ret_type]
        arg_type_names = arg_types.map { |arg_type| SUPPORTED_TO_NATIVE[arg_type] }
        enum_types = []
        unless options[:enums].nil?
          arg_type_names.each_with_index { |arg_type_name, i| enum_types.push(i) if ENUM_TYPES.include?(arg_type_name) }
        end
        # Value type_map from opts is ignored by FFI for regular functions and is used only in Variadic
        # Here we do the same and don't need to guard against type_map
        return false if options[:blocking] || ret_type_name.nil? || arg_type_names.any?(&:nil?)

        call_conv = options[:convention]&.to_s == 'stdcall' ? LLVM_STDCALL : nil
        rb_func_addr, uniq_id = llvm_jit_function_addr(
          mname, function_handle.address, arg_type_names, ret_type_name, call_conv,
        )
        if enum_types.empty? && type_mappers.empty?
          attach_rb_wrap_function(mname.to_s, rb_func_addr, arg_type_names.size, false)
        else
          # mapped.to_native is the same as mapped.converter.to_native
          # mapped.from_native is the same as mapped.converter.from_native
          # mapped.native_type is the same as mapped.converter.native_type
          enums_and_mappers = [options[:enums], type_mappers] # rubocop:disable Lint/UselessAssignment
          code = <<-CODE
            @_ffi_jit_enums_and_mappers_#{uniq_id} = enums_and_mappers

            def self.included(base)
              base.instance_variable_set(:@_ffi_jit_enums_and_mappers_#{uniq_id}, @_ffi_jit_enums_and_mappers_#{uniq_id})
              super
            end

            def self.#{mname}(#{arg_types.size.times.map { |i| "arg_#{i}" }.join(', ')})
              enums, type_mappers = @_ffi_jit_enums_and_mappers_#{uniq_id}
              #{
                arg_types.size.times.flat_map do |i|
                  next unless type_mappers[i]

                  type_mappers[i].size.times.map { |j| "arg_#{i} = type_mappers[#{i}][#{j}].to_native(arg_#{i}, nil)" }
                end.join("\n")
              }
              #{enum_types.map { |i| "arg_#{i} = enums.__map_symbol(arg_#{i}) if arg_#{i}.is_a?(Symbol)" }.join("\n")}
              res = #{mname}_#{uniq_id}(#{arg_types.size.times.map { |i| "arg_#{i}" }.join(', ')})
              #{
                if type_mappers[arg_types.size]
                  i = arg_types.size
                  type_mappers[i].size.times.map { |j| "res = type_mappers[#{i}][#{j}].from_native(res, nil)" }.join("\n")
                end
              }
              res
            end

            def #{mname}(#{arg_types.size.times.map { |i| "arg_#{i}" }.join(', ')})
              enums, type_mappers = self.class.instance_variable_get(:@_ffi_jit_enums_and_mappers_#{uniq_id})
              #{
                arg_types.size.times.flat_map do |i|
                  next unless type_mappers[i]

                  type_mappers[i].size.times.map { |j| "arg_#{i} = type_mappers[#{i}][#{j}].to_native(arg_#{i}, nil)" }
                end.join("\n")
              }
              #{enum_types.map { |i| "arg_#{i} = enums.__map_symbol(arg_#{i}) if arg_#{i}.is_a?(Symbol)" }.join("\n")}
              res = #{mname}_#{uniq_id}(#{arg_types.size.times.map { |i| "arg_#{i}" }.join(', ')})
              #{
                if type_mappers[arg_types.size]
                  i = arg_types.size
                  type_mappers[i].size.times.map { |j| "res = type_mappers[#{i}][#{j}].from_native(res, nil)" }.join("\n")
                end
              }
              res
            end
          CODE
          attach_rb_wrap_function("#{mname}_#{uniq_id}", rb_func_addr, arg_type_names.size, true)
          module_eval code, __FILE__, __LINE__
        end
        true
      end

      def llvm_jit_function_addr(rb_name, c_address, arg_type_names, ret_type_name, call_conv)
        # AFAIK name doesn't need to be unique
        llvm_mod = LLVM::Module.new('llvm_jit')
        # string -> LLVM.Pointer; size_t -> LLVM::Int64
        func_t = LLVM.Function(
          arg_type_names.map { |arg_type| LLVM_TYPES[arg_type] },
          LLVM_TYPES[ret_type_name],
        )
        func_ptr_t = LLVM.Pointer(func_t)
        # Unnamed, can change '' into :"#{cname}_ptr" for debugging, but unnamed is better to prevent name clashes
        func_ptr = llvm_mod.globals.add(func_ptr_t, '') do |var|
          var.linkage = :private
          var.global_constant = true
          var.unnamed_addr = true
          var.initializer = INTPTR.from_i(c_address).int_to_ptr(func_ptr_t)
        end

        # Something is wrong in case of name collizion; and even though you can
        # update rb_func.name=, function_address is still zero
        # Upd: It happens if functions are the same even though their names are different
        rb_func = llvm_mod.functions.add(
          :"rb_llvm_jit_wrap_#{rb_name}_#{llvm_mod.to_ptr.address}", [VALUE] * (1 + arg_type_names.size), VALUE,
        ) do |llvm_function, _rb_self, *params|
          llvm_function.basic_blocks.append('entry').build do |b|
            converted_params = arg_type_names.zip(params).map do |arg_type, param|
              b.call(
                link_external_function(llvm_mod, "ffi_llvm_jit_value_to_#{arg_type}"),
                param,
              )
            end

            func_ptr_val = b.load(func_ptr)
            # See value.rb (Function) and builder.rb (Builder#call2)
            # func_ptr_val is actually an Instruction, can't set call_conv
            res = b.call2(func_t, func_ptr_val, *converted_params)
            res.call_conv = call_conv if call_conv
            # TODO: make it optional - in orig FFI there is ignoreErrno flag that's never set
            b.call(link_external_function(llvm_mod, 'ffi_llvm_jit_save_errno'))
            b.ret(
              if ret_type_name == :void
                b.load2(VALUE, link_external_global(llvm_mod, 'ffi_llvm_jit_Qnil'))
              else
                # Note for future: in FFI struct layout redefinition doesn't change ffiParameterTypes of
                #   already attached functions
                b.call(
                  link_external_function(llvm_mod, "ffi_llvm_jit_#{ret_type_name}_to_value"),
                  res,
                )
              end,
            )
          end
        end

        rb_func_addr = LLVM_MUTEX.synchronize do
          # TODO: investigate what's more performant: function linking or link module into
          # LLVM_MOD.link_into(llvm_mod)
          # rb_func.dump

          # Ruby llvm_mod object isn't kept arount and might be GCed, but
          # it doesn't call +dispose+ automatically, so it's ok.
          # Note that in function name +llvm_mod.hash+ is used and it
          # mustn't be reused until the module is disposed, unlike
          # Ruby's object_id, which may be reused and cause name clashes in some rare cases.
          LLVM_ENG.modules.add(llvm_mod)
          rb_func.verify!
          llvm_mod.verify!
          # rb_func.name isn't always the same as rb_name, in case of name clashes
          # it contains a postfix like "rb_llvm_jit_wrap_strlen.1"
          # https://llvm.org/doxygen/group__LLVMCExecutionEngine.html
          LLVM_ENG.function_address(rb_func.name)
        end
        # I'm not sure whether func addr can be the same in ORC JIT, but I'm pretty sure module address in uniq
        [rb_func_addr, llvm_mod.to_ptr.address]
      end

      def link_external_function(mod, name)
        unless mod.functions[name]
          external_function = LLVM_MOD.functions[name]
          func = mod.functions.add(name, external_function.function_type)
          func.linkage = :external
          func.call_conv = external_function.call_conv
          external_function.function_attributes.to_a.each { |attr| func.add_attribute(attr, -1) }
          external_function.return_attributes.to_a.each { |attr| func.add_attribute(attr, 0) }
          external_function.params.size.times do |idx|
            external_function.param_attributes(idx + 1).to_a.each do |attr|
              func.add_attribute(attr, idx + 1)
            end
          end
        end
        mod.functions[name]
      end

      def link_external_global(mod, name)
        unless mod.globals[name]
          glob = mod.globals.add(LLVM_MOD.globals[name].type, name)
          glob.linkage = :external
        end
        mod.globals[name]
      end

      # rubocop:enable Metrics/MethodLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
  end
end
