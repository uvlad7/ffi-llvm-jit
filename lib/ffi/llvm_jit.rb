# frozen_string_literal: true

require 'rbconfig'
require 'set'

require 'ffi'
require 'llvm/core'
require 'llvm/linker'
require 'llvm/execution_engine'

require_relative 'llvm_jit/version'
require_relative 'llvm_jit/ffi_llvm_jit'
require_relative 'llvm_jit/lljit' if Gem.win_platform?

module FFI
  # https://llvm.org/doxygen/group__LLVMCCoreModule.html
  # https://llvm.org/doxygen/group__LLVMCBitReader.html
  # https://llvm.org/doxygen/group__LLVMCCoreMemoryBuffers.html
  # see llvm/core/bitcode.rb

  # Ruby FFI JIT using LLVM
  module LLVMJIT
    class UnsupportedError < NotImplementedError; end

    # Extension to FFI::Library to support JIT compilation using LLVM
    module Library # rubocop:disable Metrics/ModuleLength
      include ::FFI::Library

      # RbConfig::CONFIG['host_cpu'] is amd64 on freebsd
      # in LLVM_MOD.triple and LLVM::C.get_default_target_triple it's x86_64
      # but I decided to add amd64 too

      # TODO: use pairs
      # {x86_64: [linux, darwin, freebsd, dragonfly], aarch64: [linux, darwin, freebsd], i386: [linux]}
      SUPPORTED_ARCHS = {
        'x86_64' => :LLVMInitializeX86AsmParser,
        'amd64' => :LLVMInitializeX86AsmParser,
        'i386' => :LLVMInitializeX86AsmParser,
        'i686' => :LLVMInitializeX86AsmParser,
        'aarch64' => :LLVMInitializeAArch64AsmParser,
        'arm64' => :LLVMInitializeAArch64AsmParser,
      }.freeze
      # LLVM_MOD.triple => "arm64-apple-macosx15.0.0" / "x86_64-apple-macosx15.0.0"
      # LLVM::C.get_default_target_triple => "arm64-apple-darwin24.6.0" / "x86_64-apple-darwin24.6.0"
      SUPPORTED_OS = [/linux/, /darwin/, /macos/, /freebsd/].freeze
      private_constant :SUPPORTED_ARCHS, :SUPPORTED_OS

      LLVM_MOD = LLVM::Module.parse_bitcode(
        File.expand_path("llvm_jit/llvm_bitcode.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__),
      )
      # puts LLVM_MOD.to_s[/producer: "[^"]+"/]
      LLVM_MOD.verify!
      # TODO: wrong on mswin
# RbConfig::CONFIG host_cpu=x64 target_cpu=x64
# RbConfig::CONFIG host_os=mswin64_140 target_os=mswin64_140
# RbConfig::MAKEFILE_CONFIG host_cpu=$(target_cpu) target_cpu=x64
# RbConfig::MAKEFILE_CONFIG host_os=$(target_os) target_os=mswin64_140
# LLVM default triple: x86_64-w64-windows-gnu
# LLVM_MOD triple: x86_64-pc-windows-msvc19.44.35228
      LLVM_TRIPLE = LLVM::C.get_default_target_triple.split('-', 3).freeze

        $stderr.puts "CONFIG DEBUG"
        $stderr.puts "RbConfig::CONFIG host_cpu=#{RbConfig::CONFIG['host_cpu']} target_cpu=#{RbConfig::CONFIG['target_cpu']}"
        $stderr.puts "RbConfig::CONFIG host_os=#{RbConfig::CONFIG['host_os']} target_os=#{RbConfig::CONFIG['target_os']}"
        $stderr.puts "RbConfig::MAKEFILE_CONFIG host_cpu=#{RbConfig::MAKEFILE_CONFIG['host_cpu']} target_cpu=#{RbConfig::MAKEFILE_CONFIG['target_cpu']}"
        $stderr.puts "RbConfig::MAKEFILE_CONFIG host_os=#{RbConfig::MAKEFILE_CONFIG['host_os']} target_os=#{RbConfig::MAKEFILE_CONFIG['target_os']}"
        $stderr.puts "LLVM default triple: #{LLVM::C.get_default_target_triple}"
        $stderr.puts "LLVM_MOD triple: #{LLVM_MOD.triple}"
        $stderr.puts "LLVM_TRIPLE parsed: #{LLVM_TRIPLE.inspect}"

      # Register FFI converter addresses with LLVM's global symbol table
      # before JIT engine creation so they are resolved on first compilation.
      #
      # On Windows, ffi_llvm_jit_save_errno is excluded from the bitcode at
      # compile time (FFI_LLVM_JIT_WIN_PLATFORM define in the extconf) because
      # rbffi_save_errno is not exported from ffi_c.dll, so there is no address
      # to register. FFI.errno is therefore unsupported on Windows until
      # rbffi_save_errno is exported (pending in the ffi fork).
      unless Gem.win_platform?
        current_process = FFI::DynamicLibrary.send(:load_library, FFI::CURRENT_PROCESS, nil)
        %w[save_errno frame_push frame_pop save_frame_exception].each do |sym|
          LLVM::C.add_symbol("ffi_llvm_jit_#{sym}", current_process.find_function("rbffi_#{sym}"))
        end
      end

      LLVM.init_jit

      # On 32-bit Windows (MSYS2 i686) LLVMInitializeNativeTarget was observed to
      # register nothing. Headers correctly define LLVM_NATIVE_TARGET=LLVMInitializeX86Target
      # and ruby-llvm's support.cpp calls llvm::InitializeNativeTarget() — root cause TBD.
      # Explicit X86 init is idempotent and ensures the target is always registered.
      if Gem.win_platform? && LLVM_TRIPLE[0].match?(/\Ai[3-6]86\z/)
        {
          llvm_win32_x86_target_info:    :LLVMInitializeX86TargetInfo,
          llvm_win32_x86_target:         :LLVMInitializeX86Target,
          llvm_win32_x86_target_mc:      :LLVMInitializeX86TargetMC,
          llvm_win32_x86_asm_printer:    :LLVMInitializeX86AsmPrinter,
        }.each { |rb, c| LLVM::C.attach_function rb, c, [], :void; LLVM::C.send(rb) }
      end

      asm_parser = SUPPORTED_ARCHS[LLVM_TRIPLE[0]]
      if asm_parser
        LLVM::C.attach_function :llvm_initialize_native_asm_parser, asm_parser, [], :void
        LLVM::C.llvm_initialize_native_asm_parser
      end

      if Gem.win_platform?
        # Diagnostic: inspect what RtlAddFunctionTable base JITLink uses for .pdata.
        module NtDll
          extend FFI::Library
          ffi_lib 'ntdll'
          # PRUNTIME_FUNCTION RtlLookupFunctionEntry(DWORD64 ControlPc, PDWORD64 ImageBase, PVOID HistoryTable)
          attach_function :lookup_function_entry, :RtlLookupFunctionEntry, [:uint64, :pointer, :pointer], :pointer
        end

        LLVM_ENG = LLVM::LLJit.new

        ffi_ext = File.expand_path("llvm_jit/ffi_llvm_jit.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__)

        # load_library_permanently populates LLVM's DynamicLibrary table used by
        # search_for_address_of_symbol (the unresolved check below).
        LLVM::C.load_library_permanently(nil)
        LLVM::C.load_library_permanently(ffi_ext)

        # GCC-style SSP symbols from -fstack-protector-strong in Ruby's $CFLAGS.
        # Not exported from any MSVC DLL. add_symbol populates LLVM's DynamicLibrary
        # table (for the unresolved check below). add_absolute_symbol puts them
        # directly in the JITDylib — on Windows the ORC process generator uses
        # GetProcAddress and won't find manually-added DynamicLibrary entries.
        @ssp_guard = FFI::MemoryPointer.new(:uint64)
        @ssp_guard.write_uint64(rand(2**64))
        LLVM::C.add_symbol('__stack_chk_guard', @ssp_guard)
        LLVM_ENG.add_absolute_symbol('__stack_chk_guard', @ssp_guard.address)
        @ssp_fail = FFI::Function.new(:void, []) { abort 'stack smashing detected' }
        LLVM::C.add_symbol('__stack_chk_fail', @ssp_fail)
        LLVM_ENG.add_absolute_symbol('__stack_chk_fail', @ssp_fail.address)

        # LLJIT resolves externals via generators; also add the extension DLL.
        LLVM_ENG.add_dll_generator(ffi_ext)

        # add_module transfers ownership; clone LLVM_MOD so it remains usable for
        # type/function lookups after this point.
        LLVM_ENG.add_module(LLVM_MOD.clone_module)
      else
        LLVM_ENG = LLVM::JITCompiler.new(LLVM_MOD, opt_level: 3)
      end
      LLVM_MUTEX = Mutex.new
      LLVM_FUNC_SEQ = [0]
      # One-time flag: have we registered .pdata for all base-module JIT helpers?
      JIT_HELPER_PDATA_DONE = [false]

      # Future: register kernel32 symbols for the APC-based UBF — see llvm_bitcode.c.
      # if Gem.win_platform?
      #   k32 = FFI::DynamicLibrary.open('kernel32', FFI::DynamicLibrary::RTLD_LAZY)
      #   %w[OpenThread QueueUserAPC CloseHandle GetCurrentThreadId].each do |sym|
      #     addr = k32.find_function(sym)
      #     LLVM::C.add_symbol(sym, addr) if addr && !addr.null?
      #   end
      # end

      # Validate all external declarations in the bitcode module are resolved.
      # LLVMParseBitcode is eager so the module is fully materialized here.
      # Must run after load_library_permanently but before function_address,
      # which triggers JIT and dies with a fatal LLVM error on missing symbols.
      # LLVM intrinsics (llvm.*) are handled natively by the JIT.
      unresolved = LLVM_MOD.functions.select do |f|
        f.declaration?.nonzero? && !f.name.start_with?('llvm.') &&
          LLVM::C.search_for_address_of_symbol(f.name).null?
      end + LLVM_MOD.globals.select do |g|
        g.declaration?.nonzero? &&
          LLVM::C.search_for_address_of_symbol(g.name).null?
      end
      raise "Unresolved JIT symbols: #{unresolved.map(&:name).join(', ')}" unless unresolved.empty?

      private_constant :LLVM_MOD, :LLVM_ENG, :LLVM_MUTEX, :LLVM_FUNC_SEQ, :LLVM_TRIPLE, :JIT_HELPER_PDATA_DONE

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
      # TODO: with all keepalives type are kept - avoid fallbacks but raise if type isn't fould (LLVM::Type.from_ptr(NULL) is safe, just check later)
      BLOCKING_CALL_T = blocking_call_t || if Gem.win_platform?
        # 3 fields: call_blocking_function_fn, params_store, exc_store (VALUE).
        # Defined here rather than taken from the bitcode because FFI_LLVM_JIT_WIN_PLATFORM
        # may not be set during clang-cl bitcode compilation, leaving only 2 fields there.
        LLVM::Struct(
          LLVM::Pointer(LLVM::Function([VOID_PTR_T], VOID_PTR_T)),
          VOID_PTR_T,
          VALUE,
        )
      else
        LLVM::Struct(
          LLVM::Pointer(LLVM::Function([VOID_PTR_T], VOID_PTR_T)),
          VOID_PTR_T,
        )
      end

      unless Gem.win_platform?
        # ffi_llvm_jit_frame_t: { td: ptr, prev: ptr, exc: VALUE }
        # Windows omits td but frame push/pop/save_frame_exception are unused there.
        frame_t_ptr = LLVM::C.get_type_by_name(LLVM_MOD, 'struct.ffi_llvm_jit_frame')
        require 'pry'
        binding.pry
        frame_t = LLVM::Type.from_ptr(frame_t_ptr) unless frame_t_ptr.null?
        $stderr.puts "ffi_llvm_jit: FRAME_T from bitcode=#{!frame_t.nil?}"
        FRAME_T = frame_t || LLVM::Struct(VOID_PTR_T, VOID_PTR_T, VALUE)
        FRAME_EXC_INDEX = 2
        private_constant :FRAME_T, :FRAME_EXC_INDEX
      end

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

      def yolo!
        # riscv is confirmed to segfault
        # you still can set @yolo yourself if you are feeling lucky
        # YOLO!
        # TODO, todo
        @yolo = true unless LLVM_TRIPLE[0] =~ /riscv/
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
        attach_llvm_jit_function_handle(function_handle, mname, arg_types, ret_type, options, jit_only: jit_only)
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

      def attach_llvm_jit_function_handle(function_handle, mname, arg_types, ret_type, options, jit_only: false)
        # raise UnsupportedErrror, 'FFI.errno is unsupported on Windows' if Gem.win_platform? && !@i_dont_use_errno_i_promise
        raise UnsupportedError, "Can't use LLVM after fork" unless Process.pid == INIT_PID

        # raise UnsupportedError, "MCJIT is not supported on #{LLVM_TRIPLE.join('-')}" unless @yolo ||
        #   SUPPORTED_ARCHS.key?(LLVM_TRIPLE[0]) && SUPPORTED_OS.any? { |r| LLVM_TRIPLE[2] =~ r }

        allowed = %i[convention type_map blocking enums]
        unknown_options = options.keys - allowed
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
        $stderr.puts "JIT: build #{rb_name}(#{arg_type_names.join(',')}) -> #{ret_type_name} blocking=#{blocking}"; $stderr.flush
        # AFAIK name doesn't need to be unique
        llvm_mod = LLVM::Module.new('llvm_jit')
        # Match triple and data layout to the bitcode module so JITLink selects the correct
        # object format and .pdata handling (MSVC COFF on mswin, ELF on Linux, etc.).
        # LLVM::Module.new leaves the triple empty, which causes JITLink to fall back to
        # defaults that may not match the LLJIT's configured target on Windows.
        if Gem.win_platform?
          llvm_mod.triple = LLVM_MOD.triple
          llvm_mod.data_layout = LLVM_MOD.data_layout
        end
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
          # signed = false; 17 uses positional arg, 18 - option
          var.initializer = INTPTR.from_i(c_address, false).int_to_ptr(func_ptr_t)
        end
        void_ret = ret_type_name == :void

        # Pre-compute the sequence number so both the outer wrapper and the inner
        # blocking body can share a predictable naming scheme.  The outer function
        # consumes this number with LLVM_FUNC_SEQ[0] += 1 below.
        _func_seq = LLVM_FUNC_SEQ[0] + 1

        if blocking
          params_store_fields = [*arg_types, *(ret_type unless void_ret)]
          # Note: If StructByValue is ever supported we might want not to copy big structs and store a ptr instead
          params_store_t = LLVM.Struct(*params_store_fields) unless params_store_fields.empty?
          # Named (non-private) so we can call function_address on it and register
          # .pdata; on MSVC x64, RtlUnwindEx must unwind through this frame when the
          # blocking call is interrupted (e.g. via APC/UBF during SleepEx).
          call_blocking_func = llvm_mod.functions.add(
            "rb_llvm_jit_wrap_#{rb_name}_#{_func_seq}_body", [VOID_PTR_T], VOID_PTR_T,
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
          :"rb_llvm_jit_wrap_#{rb_name}_#{LLVM_FUNC_SEQ[0] += 1}", [VALUE] * (1 + arg_type_names.size), VALUE,
        ) do |llvm_function, _rb_self, *params|
          llvm_function.basic_blocks.append('entry').build do |builder|
            # less readable, but easier that to position builder
            # TODO: figure out builder.position stuff
            if blocking
              params_store = builder.alloca(params_store_t) if params_store_t
              call_data = builder.alloca(BLOCKING_CALL_T)
            end
            # No zero-init needed (unlike C's `rbffi_frame_t frame = { 0 }`):
            # rbffi_frame_push does memset(frame, 0, sizeof(*frame)) before any read.
            frame = builder.alloca(FRAME_T) unless Gem.win_platform?
            converted_params = arg_type_names.zip(params).map do |arg_type, param|
              builder.call(
                link_external_function(llvm_mod, "ffi_llvm_jit_value_to_#{arg_type}"),
                param,
              )
            end
            if blocking
              emit_blocking_call(
                builder, llvm_mod, params_store_t, frame, converted_params, call_blocking_func,
                params_store, call_data,
              )
              res = void_ret ? nil : builder.load2(
                ret_type,
                builder.gep2(params_store_t, params_store, [LLVM::Int(0), LLVM::Int(arg_types.size)], ''),
              )
            else
              res = emit_non_blocking_call(builder, llvm_mod, call_conv, converted_params, func_ptr, func_t, frame)
            end
            builder.call(link_external_function(llvm_mod, 'ffi_llvm_jit_save_errno')) unless Gem.win_platform?
            if Gem.win_platform?
              if blocking
                exc_gep = builder.gep2(BLOCKING_CALL_T, call_data, [LLVM::Int(0), LLVM::Int(2)], '')
                builder.call(link_external_function(llvm_mod, 'ffi_llvm_jit_raise_exception'), builder.load2(VALUE, exc_gep))
              end
            else
              exc = builder.load2(VALUE, builder.gep2(FRAME_T, frame, [LLVM::Int(0), LLVM::Int(FRAME_EXC_INDEX)], ''))
              builder.call(link_external_function(llvm_mod, 'ffi_llvm_jit_raise_exception'), exc)
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

        if Gem.win_platform?
          # Add uwtable(async) to JIT-generated functions so LLVM emits full Windows SEH
          # .pdata/.xdata entries.  clang-cl adds this automatically; IR built here does not
          # inherit it.  Value 1 = async (covers longjmp/RtlUnwindEx); value 0 = sync only.
          _uwtable_name = 'uwtable'
          _uwtable_ptr = FFI::MemoryPointer.from_string(_uwtable_name)
          _uwtable_kind = LLVM::C.get_enum_attribute_kind_for_name(_uwtable_ptr, _uwtable_name.length)
          _uwtable_attr = LLVM::C.create_enum_attribute(LLVM::Context.global, _uwtable_kind, 2)
          LLVM::C.add_attribute_at_index(rb_func, -1, _uwtable_attr)
          LLVM::C.add_attribute_at_index(call_blocking_func, -1, _uwtable_attr) if blocking
        end

        # Capture names as Ruby strings before add_module/function_address consume the
        # LLVM IR (after JIT compilation the underlying C++ Module may be freed and
        # LLVMGetValueName would return "" on the dangling pointer).
        _rb_func_name   = rb_func.name
        _body_func_name = blocking ? call_blocking_func.name : nil

        rb_func_addr = LLVM_MUTEX.synchronize do
          $stderr.puts "JIT: compile #{_rb_func_name} blocking=#{blocking}"; $stderr.flush
          call_blocking_func&.verify!
          rb_func.verify!
          llvm_mod.verify!
          $stderr.puts "JIT: verify ok"; $stderr.flush
          $stderr.puts llvm_mod.to_s if Gem.win_platform? && blocking
          if Gem.win_platform?
            LLVM_ENG.add_module(llvm_mod)
            $stderr.puts "JIT: add_module ok"; $stderr.flush
          else
            LLVM_ENG.modules.add(llvm_mod)
          end
          $stderr.puts "JIT: function_address(#{_rb_func_name})"; $stderr.flush
          addr = LLVM_ENG.function_address(_rb_func_name)
          $stderr.puts "JIT: function_address=0x#{addr.to_s(16)}"; $stderr.flush
          if Gem.win_platform?
            # Register .pdata for this JIT function so RtlUnwindEx can unwind through
            # it.  JITLink does not register .pdata itself (LLVM issue #163503); without
            # it any rb_raise() or longjmp() with a JIT frame on the stack causes
            # STATUS_BAD_FUNCTION_TABLE — including type-conversion exceptions in
            # non-blocking calls (e.g. passing a Symbol where a String is expected).
            FFI::LLVMJIT.jit_register_pdata(addr)
            $stderr.flush
            # Verify registration via RtlLookupFunctionEntry
            ib = FFI::MemoryPointer.new(:uint64)
            rf = NtDll.lookup_function_entry(addr, ib, nil)
            if rf.null?
              $stderr.puts "JIT: .pdata still NONE after registration (unexpected!)"
            else
              image_base   = ib.read_uint64
              begin_rva    = rf.get_uint32(0)
              end_rva      = rf.get_uint32(4)
              unwind_rva   = rf.get_uint32(8)
              begin_actual = image_base + begin_rva
              end_actual   = image_base + end_rva
              xdata_actual = image_base + unwind_rva
              ok = addr >= begin_actual && addr < end_actual
              $stderr.puts "JIT: .pdata OK base=0x#{image_base.to_s(16)} " \
                           "begin_rva=0x#{begin_rva.to_s(16)} end_rva=0x#{end_rva.to_s(16)} " \
                           "unwind_rva=0x#{unwind_rva.to_s(16)} addr_in_range=#{ok}"
            end
            # Also register .pdata for the inner blocking body.  It is on the call
            # stack inside rb_thread_call_without_gvl; if an APC/UBF fires while
            # it runs and longjmp unwinds through it, the frame must have .pdata.
            if blocking
              body_addr = LLVM_ENG.function_address(_body_func_name)
              $stderr.puts "JIT: body_function_address=0x#{body_addr.to_s(16)}"; $stderr.flush
              FFI::LLVMJIT.jit_register_pdata(body_addr)
              ib2 = FFI::MemoryPointer.new(:uint64)
              rf2 = NtDll.lookup_function_entry(body_addr, ib2, nil)
              $stderr.puts rf2.null? ? "JIT: body .pdata NONE (unexpected!)" :
                "JIT: body .pdata OK addr=0x#{body_addr.to_s(16)}"
              $stderr.flush
            end
            # One-time: register .pdata for every defined function in the base bitcode
            # module.  Helper functions (ffi_llvm_jit_value_to_*, _raise_exception, etc.)
            # are JIT-compiled as a side effect of the first function_address() call.
            # They appear on the call stack between the outer JIT wrapper and rb_raise,
            # so they also need .pdata.  Addresses outside the JIT callback range are
            # silently skipped by jit_register_pdata (native DLL helpers are already OK).
            unless JIT_HELPER_PDATA_DONE[0]
              JIT_HELPER_PDATA_DONE[0] = true
              LLVM_MOD.functions.each do |f|
                next if f.declaration?.nonzero? || f.name.start_with?('llvm.')
                begin
                  helper_addr = LLVM_ENG.function_address(f.name)
                  next if helper_addr == 0
                  FFI::LLVMJIT.jit_register_pdata(helper_addr)
                  $stderr.puts "JIT: helper .pdata #{f.name}=0x#{helper_addr.to_s(16)}"
                rescue => e
                  $stderr.puts "JIT: helper .pdata skip #{f.name}: #{e.message}"
                end
                $stderr.flush
              end
            end
          end
          addr
        end
        [rb_func_addr, LLVM_FUNC_SEQ[0]]
      end

      # rubocop:disable Metrics/ParameterLists
      def emit_blocking_call(
        builder, llvm_mod, params_store_t, frame, converted_params, call_blocking_func,
        params_store, call_data
      )
        converted_params.each_with_index do |p, i|
          builder.store(p, builder.gep2(params_store_t, params_store, [LLVM::Int(0), LLVM::Int(i)], ''))
        end
        builder.store(call_blocking_func, builder.gep2(BLOCKING_CALL_T, call_data, [LLVM::Int(0), LLVM::Int(0)], ''))
        builder.store(
          params_store || VOID_PTR_T.null,
          builder.gep2(BLOCKING_CALL_T, call_data, [LLVM::Int(0), LLVM::Int(1)], ''),
        )
        if Gem.win_platform?
          # rb_rescue2 is called from C (ffi_llvm_jit_blocking_call_win) rather than
          # JIT code: on MSVC x64, longjmp inside rb_rescue2 calls RtlUnwindEx which
          # requires .pdata unwind tables for every frame; JIT frames may not have them.
          # ffi_llvm_jit_blocking_call_win is native (ffi_llvm_jit.c), not in LLVM_MOD,
          # so we can't use link_external_function — borrow the type from
          # ffi_llvm_jit_blocking_call which has the same VALUE(VALUE) signature.
          unless llvm_mod.functions['ffi_llvm_jit_blocking_call_win']
            f = llvm_mod.functions.add('ffi_llvm_jit_blocking_call_win',
                                       LLVM_MOD.functions['ffi_llvm_jit_blocking_call'].function_type)
            f.linkage = :external
          end
          builder.call(
            llvm_mod.functions['ffi_llvm_jit_blocking_call_win'],
            builder.ptr2int(call_data, VALUE),
          )
        else
          builder.call(link_external_function(llvm_mod, 'ffi_llvm_jit_frame_push'), frame)
          builder.call(
            link_external_function(llvm_mod, 'rb_rescue2'),
            link_external_function(llvm_mod, 'ffi_llvm_jit_blocking_call'),
            builder.ptr2int(call_data, VALUE),
            link_external_function(llvm_mod, 'ffi_llvm_jit_save_frame_exception'),
            builder.ptr2int(frame, VALUE),
            builder.load2(VALUE, link_external_global(llvm_mod, 'rb_eException')),
            VALUE.from_i(0),
          )
          builder.call(link_external_function(llvm_mod, 'ffi_llvm_jit_frame_pop'), frame)
        end
      end

      def emit_non_blocking_call(builder, llvm_mod, call_conv, converted_params, func_ptr, func_t, frame)
        unless Gem.win_platform?
          builder.call(link_external_function(llvm_mod, 'ffi_llvm_jit_frame_push'), frame)
        end
        ret = emit_cfunc_call(builder, call_conv, converted_params, func_ptr, func_t)
        unless Gem.win_platform?
          builder.call(link_external_function(llvm_mod, 'ffi_llvm_jit_frame_pop'), frame)
        end
        ret
      end

      def emit_cfunc_call(builder, call_conv, converted_params, func_ptr, func_t)
        func_ptr_val = builder.load(func_ptr)
        # See value.rb (Function) and builder.rb (Builder#call2)
        # func_ptr_val is actually an Instruction, can't set call_conv
        res = builder.call2(func_t, func_ptr_val, *converted_params)
        res.call_conv = call_conv if call_conv
        res
      end
      # rubocop:enable Metrics/ParameterLists

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
