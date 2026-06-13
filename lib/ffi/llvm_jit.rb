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
    class UnsupportedError < RuntimeError; end

    # Extension to FFI::Library to support JIT compilation using LLVM
    module Library # rubocop:disable Metrics/ModuleLength
      include ::FFI::Library

      LLVM_MOD = LLVM::Module.parse_bitcode(
        File.expand_path("llvm_jit/llvm_bitcode.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__),
      )
      # puts LLVM_MOD.to_s[/producer: "[^"]+"/]
      LLVM_MOD.verify!

      # Register FFI converter addresses with LLVM's global symbol table
      # before JIT engine creation so they are resolved on first compilation.
      LLVM::C.add_symbol(
        'ffi_llvm_jit_save_errno',
        FFI::DynamicLibrary.send(
          :load_library, FFI::CURRENT_PROCESS, nil,
        ).find_function('rbffi_save_errno'),
      )

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
      VOID_PTR_T = LLVM.Pointer(LLVM::Void()) # Opaque pointer I guess

      # Modern LLVM doesn't persist the type
      # from_type raises in v21 on null ptr so we need to check explicitly
      blocking_call_t_ptr = LLVM::C.get_type_by_name(LLVM_MOD, 'struct.ffi_llvm_jit_blocking_call_t')
      blocking_call_t = LLVM::Type.from_ptr(blocking_call_t_ptr) unless blocking_call_t_ptr.null?
      BLOCKING_CALL_T = blocking_call_t || LLVM::Struct(
        LLVM::Pointer(LLVM::Function([VOID_PTR_T], VOID_PTR_T)),
        VOID_PTR_T,
      )

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
      }.freeze

      private_constant :INTPTR, :VALUE, :VOID_PTR_T, :BLOCKING_CALL_T, :LLVM_TYPES, :LLVM_STDCALL

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

      INIT_PID = Process.pid
      private_constant :INIT_PID

      # rubocop:disable Metrics/MethodLength, Metrics/BlockLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

      # @see https://www.rubydoc.info/gems/ffi/FFI/Library#attach_function-instance_method FFI::Library.attach_function
      def attach_function(name, func, args, returns = nil, options = nil)
        mname, cname, arg_types, ret_type, options = convert_attach_function_params(name, func, args, returns, options)
        function_handle = find_function_handle(cname, arg_types)
        attach_function_handle(function_handle, mname, arg_types, ret_type, options)
      end

      # Same as +attach_function+, but raises an exception if cannot create JIT function
      # instead of falling back to the regular FFI function
      def attach_llvm_jit_function(name, func, args, returns = nil, options = nil)
        # TODO: support LLVM call_conv; note that function_names must be patched for that
        # (they also forgot an underscore on Windows for cdecl)
        # https://en.wikipedia.org/wiki/Name_mangling#C
        # (see core_ffi.rb and https://llvm.org/doxygen/namespacellvm_1_1CallingConv.html)
        mname, cname, arg_types, ret_type, options = convert_attach_function_params(name, func, args, returns, options)
        function_handle = find_function_handle(cname, arg_types)
        attach_function_handle(function_handle, mname, arg_types, ret_type, options, jit_only: true)
      end

      private

      # Part copied from refactored FFI for compatibility

      def convert_attach_function_params(name, func, args, returns, options)
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
        ret_type = find_type(ret_type)
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

      def find_function_handle(cname, arg_types)
        ffi_libraries.each do |lib|
          function_names(cname, arg_types).each do |fname|
            fn = lib.find_function(fname)
            return fn if fn
          end
        rescue LoadError
          # Ignored
        end

        raise FFI::NotFoundError.new(cname.to_s, ffi_libraries.map(&:name))
      end

      ###### End ######

      def attach_function_handle(function_handle, mname, arg_types, ret_type, options, jit_only: false)
        attach_llvm_jit_function_handle(function_handle, mname, arg_types, ret_type, options)
      rescue UnsupportedError
        raise if jit_only

        # Part copied from refactored FFI for compatibility
        invoker = if arg_types[-1] == FFI::NativeType::VARARGS
                    VariadicInvoker.new(function_handle, arg_types, ret_type, options)
                  else
                    Function.new(ret_type, arg_types, function_handle, options)
                  end
        invoker.attach(self, mname.to_s)
        invoker
      else
        return if jit_only

        invoker = Function.new(ret_type, arg_types, function_handle, options)
        @ffi_functions ||= {}
        @ffi_functions[mname.to_s.to_sym] = invoker
        invoker
      end

      def attach_llvm_jit_function_handle(function_handle, mname, arg_types, ret_type, options)
        raise UnsupportedError, "Can't use LLVM after fork" unless Process.pid == INIT_PID

        unknown_options = options.keys - %i[convention type_map blocking enums]
        unless unknown_options.empty?
          raise UnsupportedError, "Unsupported option#{'s' if unknown_options.size > 1}: #{unknown_options.join(', ')}"
        end

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
          type_mappers[arg_types.size].unshift(ret_type)
          ret_type = ret_type.native_type
        end

        # TODO: support call conventions other than stdcall (rb_func.call_conv=)
        # TODO: support call_without_gvl
        # Variadic functions are not supported; we could support known arguments,
        # but we'd still need to know use libffi to create varargs
        ret_type_name = SUPPORTED_FROM_NATIVE.fetch(ret_type) do
          raise UnsupportedError, "Unsupported return type: #{ret_type.inspect}"
        end

        arg_type_names = arg_types.map do |arg_type|
          SUPPORTED_TO_NATIVE.fetch(arg_type) do
            raise UnsupportedError, "Unsupported argument type: #{arg_type.inspect}"
          end
        end
        enum_types = []
        unless options[:enums].nil?
          arg_type_names.each_with_index { |arg_type_name, i| enum_types.push(i) if ENUM_TYPES.include?(arg_type_name) }
        end
        # Value type_map from opts is ignored by FFI for regular functions and is used only in Variadic
        # Here we do the same and don't need to guard against type_map

        call_conv = options[:convention]&.to_s == 'stdcall' ? LLVM_STDCALL : nil
        rb_func_addr, uniq_id = llvm_jit_function_addr(
          mname, function_handle.address, arg_type_names, ret_type_name, call_conv,
          blocking: options[:blocking],
        )
        attach_jit_and_wrappers(mname, rb_func_addr, uniq_id, arg_types, enum_types, type_mappers, options)
      end

      # rubocop:disable Metrics/ParameterLists
      def attach_jit_and_wrappers(mname, rb_func_addr, uniq_id, arg_types, enum_types, type_mappers, options)
        if enum_types.empty? && type_mappers.empty?
          attach_rb_wrap_function(mname.to_s, rb_func_addr, arg_types.size, false)
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
                arg_types.size.times.map do |i|
                  next unless type_mappers[i]

                  "type_mappers[#{i}].each { |mapper| arg_#{i} = mapper.to_native(arg_#{i}, nil) }"
                end.join("\n")
              }
              #{enum_types.map { |i| "arg_#{i} = enums.__map_symbol(arg_#{i}) if arg_#{i}.is_a?(Symbol)" }.join("\n")}
              res = #{mname}_#{uniq_id}(#{arg_types.size.times.map { |i| "arg_#{i}" }.join(', ')})
              #{
                if type_mappers[arg_types.size]
                  i = arg_types.size
                  "type_mappers[#{i}].each { |mapper| res = mapper.from_native(res, nil) }"
                end
              }
              res
            end

            def #{mname}(#{arg_types.size.times.map { |i| "arg_#{i}" }.join(', ')})
              enums, type_mappers = self.class.instance_variable_get(:@_ffi_jit_enums_and_mappers_#{uniq_id})
              #{
                arg_types.size.times.map do |i|
                  next unless type_mappers[i]

                  "type_mappers[#{i}].each { |mapper| arg_#{i} = mapper.to_native(arg_#{i}, nil) }"
                end.join("\n")
              }
              #{enum_types.map { |i| "arg_#{i} = enums.__map_symbol(arg_#{i}) if arg_#{i}.is_a?(Symbol)" }.join("\n")}
              res = #{mname}_#{uniq_id}(#{arg_types.size.times.map { |i| "arg_#{i}" }.join(', ')})
              #{
                if type_mappers[arg_types.size]
                  i = arg_types.size
                  "type_mappers[#{i}].each { |mapper| res = mapper.from_native(res, nil) }"
                end
              }
              res
            end
          CODE
          attach_rb_wrap_function("#{mname}_#{uniq_id}", rb_func_addr, arg_types.size, true)
          module_eval code, __FILE__, __LINE__
        end
      end
      # rubocop:enable Metrics/ParameterLists

      def llvm_jit_function_addr(rb_name, c_address, arg_type_names, ret_type_name, call_conv, blocking:)
        # AFAIK name doesn't need to be unique
        llvm_mod = LLVM::Module.new('llvm_jit')
        # string -> LLVM.Pointer; size_t -> LLVM::Int64
        arg_types = arg_type_names.map { |arg_type| LLVM_TYPES[arg_type] }
        ret_type = LLVM_TYPES[ret_type_name]
        func_t = LLVM.Function(arg_types, ret_type)
        func_ptr_t = LLVM.Pointer(func_t)
        # Unnamed, can change '' into :"#{cname}_ptr" for debugging, but unnamed is better to prevent name clashes
        func_ptr = llvm_mod.globals.add(func_ptr_t, '') do |var|
          var.linkage = :private
          var.global_constant = true
          var.unnamed_addr = true
          var.initializer = INTPTR.from_i(c_address).int_to_ptr(func_ptr_t)
        end
        void_ret = ret_type_name == :void

        if blocking
          params_store_fields = [*arg_types, *(ret_type unless void_ret)]
          params_store_t = LLVM.Struct(*params_store_fields) unless params_store_fields.empty?
          call_blocking_func = llvm_mod.functions.add(
            '', [VOID_PTR_T], VOID_PTR_T,
          ) do |llvm_function, params_store|
            llvm_function.basic_blocks.append('entry').build do |builder|
              converted_params = arg_types.map.with_index do |t, i|
                builder.load2(t, builder.gep2(params_store_t, params_store, [LLVM::Int(0), LLVM::Int(i)], ''))
              end
              ret = emit_cfunc_call(
                builder, call_conv, converted_params, func_ptr, func_t,
              )
              unless void_ret
                builder.store(
                  ret, builder.gep2(params_store_t, params_store, [LLVM::Int(0), LLVM::Int(arg_types.size)], ''),
                )
              end
              builder.ret(VOID_PTR_T.null)
            end
          end
        end

        # Something is wrong in case of name collision; and even though you can
        # update rb_func.name=, function_address is still zero
        # Upd: It happens if functions are the same even though their names are different
        rb_func = llvm_mod.functions.add(
          :"rb_llvm_jit_wrap_#{rb_name}_#{llvm_mod.to_ptr.address}", [VALUE] * (1 + arg_type_names.size), VALUE,
        ) do |llvm_function, _rb_self, *params|
          llvm_function.basic_blocks.append('entry').build do |builder|
            # less readable, but easier that to position builder
            # TODO: figure out builder.position stuff
            if blocking
              params_store = builder.alloca(params_store_t) if params_store_t
              call_data = builder.alloca(BLOCKING_CALL_T)
              exc_store = builder.alloca(VALUE)
            end
            converted_params = arg_type_names.zip(params).map do |arg_type, param|
              builder.call(
                link_external_function(llvm_mod, "ffi_llvm_jit_value_to_#{arg_type}"),
                param,
              )
            end
            res = if blocking
                    emit_blocking_call(
                      builder, llvm_mod, params_store_t, exc_store, converted_params, call_blocking_func,
                      void_ret ? nil : ret_type, params_store, call_data,
                    )
                  else
                    emit_cfunc_call(
                      builder, call_conv, converted_params, func_ptr, func_t,
                    )
                  end
            # TODO: make it optional - in orig FFI there is ignoreErrno flag that's never set
            builder.call(link_external_function(llvm_mod, 'ffi_llvm_jit_save_errno'))
            # In FFI it's also used to re-raise from callbacks, but here it's only for blocking calls
            if blocking
              builder.call(
                link_external_function(llvm_mod, 'ffi_llvm_jit_raise_exception'), builder.load(exc_store),
              )
            end
            builder.ret(
              if void_ret
                builder.load2(VALUE, link_external_global(llvm_mod, 'ffi_llvm_jit_Qnil'))
              else
                # Note for future: in FFI struct layout redefinition doesn't change ffiParameterTypes of
                #   already attached functions
                builder.call(
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

          # Ruby llvm_mod object isn't kept around and might be GCed, but
          # it doesn't call +dispose+ automatically, so it's ok.
          # Note that in function name +llvm_mod.hash+ is used and it
          # mustn't be reused until the module is disposed, unlike
          # Ruby's object_id, which may be reused and cause name clashes in some rare cases.
          LLVM_ENG.modules.add(llvm_mod)
          call_blocking_func&.verify!
          rb_func.verify!
          llvm_mod.verify!
          # rb_func.name isn't always the same as rb_name, in case of name clashes
          # it contains a postfix like "rb_llvm_jit_wrap_strlen.1"
          # https://llvm.org/doxygen/group__LLVMCExecutionEngine.html
          LLVM_ENG.function_address(rb_func.name)
        end
        # I'm not sure whether func addr can be the same in ORC JIT, but I'm pretty sure module address is unique
        [rb_func_addr, llvm_mod.to_ptr.address]
      end

      # rubocop:disable Metrics/ParameterLists
      def emit_blocking_call(
        builder, llvm_mod, params_store_t, exc_store, converted_params, call_blocking_func, ret_type,
        params_store, call_data
      )
        builder.store(
          # Maybe use Qnil here? But const is probably faster
          VALUE.from_i(0),
          exc_store,
        )
        converted_params.each_with_index do |p, i|
          builder.store(p, builder.gep2(params_store_t, params_store, [LLVM::Int(0), LLVM::Int(i)], ''))
        end
        builder.store(call_blocking_func, builder.gep2(BLOCKING_CALL_T, call_data, [LLVM::Int(0), LLVM::Int(0)], ''))
        builder.store(
          params_store || VOID_PTR_T.null,
          builder.gep2(BLOCKING_CALL_T, call_data, [LLVM::Int(0), LLVM::Int(1)], ''),
        )
        builder.call(
          link_external_function(llvm_mod, 'rb_rescue2'),
          link_external_function(llvm_mod, 'ffi_llvm_jit_blocking_call'),
          builder.ptr2int(call_data, VALUE),
          link_external_function(llvm_mod, 'ffi_llvm_jit_save_exception'),
          builder.ptr2int(exc_store, VALUE),
          builder.load2(VALUE, link_external_global(llvm_mod, 'rb_eException')),
          VALUE.from_i(0),
        )
        return unless ret_type

        builder.load2(
          ret_type,
          builder.gep2(params_store_t, params_store, [LLVM::Int(0), LLVM::Int(converted_params.size)], ''),
        )
      end
      # rubocop:enable Metrics/ParameterLists

      def emit_cfunc_call(builder, call_conv, converted_params, func_ptr, func_t)
        func_ptr_val = builder.load(func_ptr)
        # See value.rb (Function) and builder.rb (Builder#call2)
        # func_ptr_val is actually an Instruction, can't set call_conv
        res = builder.call2(func_t, func_ptr_val, *converted_params)
        res.call_conv = call_conv if call_conv
        res
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
          glob = mod.globals.add(LLVM::Type.from_ptr(LLVM::C.get_value_type(LLVM_MOD.globals[name])), name)
          glob.linkage = :external
        end
        mod.globals[name]
      end

      # rubocop:enable Metrics/MethodLength, Metrics/BlockLength, Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
    end
  end
end
