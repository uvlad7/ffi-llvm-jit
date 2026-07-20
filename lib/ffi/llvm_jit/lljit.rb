# frozen_string_literal: true

# Standalone LLJIT (OrcJIT v2) bindings.
# Works with any ruby-llvm major version without patching the gem.
# Fixes a bug in ruby-llvm's lljit.rb where create_thread_safe_module
# was mapped to the wrong C function (LLVMOrcCreateNewThreadSafeContext).
#
# Usage:
#   require 'llvm/core'
#   require 'ffi/llvm_jit/lljit'
#   jit = LLVM::LLJit.new
#   jit.add_module(mod)         # transfers ownership of mod
#   addr = jit.function_address("my_func")
#   jit.dispose

require 'llvm/core'

module LLVM
  class LLJit
    def initialize
      out = FFI::MemoryPointer.new(:pointer)
      builder = C.create_lljit_builder

      # On MSVC Ruby (mswin) the system LLVM (from UCRT64/MSYS2) has default triple
      # x86_64-w64-windows-gnu.  MSVC's longjmp calls RtlUnwindEx, which requires
      # .pdata unwind tables in Windows MSVC format for every frame on the stack.
      # JITLink generates the right .pdata only when the target triple is the MSVC
      # variant; override before building LLJIT.
      if RbConfig::CONFIG['host_os'] =~ /mswin/i
        jtmb_out = FFI::MemoryPointer.new(:pointer)
        err = C.jtmb_detect_host(jtmb_out)
        raise_if_error(err)
        jtmb = jtmb_out.read_pointer
        $stderr.puts "LLJIT: detected triple=#{C.jtmb_get_target_triple(jtmb)}"
        C.jtmb_set_target_triple(jtmb, 'x86_64-pc-windows-msvc')
        $stderr.puts "LLJIT: override triple=#{C.jtmb_get_target_triple(jtmb)}"
        C.lljit_builder_set_jtmb(builder, jtmb)
      end

      err = C.create_lljit(out, builder)
      raise_if_error(err)
      @ptr = out.read_pointer

      # Install the native C error reporter. Pass LLVM function pointers from the
      # already-loaded DLL so the C extension needs no build-time LLVM dependency.
      es = C.get_execution_session(@ptr)
      fns = C.attached_functions
      FFI::Function.new(:void, [:pointer, :pointer, :pointer, :pointer],
                        FFI::LLVMJIT.jit_init_error_reporter_ptr).call(
        es,
        fns[:set_error_reporter],
        fns[:get_error_message],
        fns[:dispose_error_message],
      )

      dylib = C.get_main_jit_dylib(@ptr)
      gen_out = FFI::MemoryPointer.new(:pointer)
      # global_prefix is '\0' on ELF Linux; null filter = accept all process symbols
      err = C.create_process_generator(gen_out, C.get_global_prefix(@ptr), nil, nil)
      raise_if_error(err)
      C.dylib_add_generator(dylib, gen_out.read_pointer)
    end

    # Add an LLVM::Module for JIT compilation. Transfers ownership — do not use mod after this.
    def add_module(mod)
      ts_ctx = C.create_thread_safe_context
      ts_mod = C.create_thread_safe_module(mod, ts_ctx)
      C.dispose_thread_safe_context(ts_ctx)
      err = C.add_ir_module(@ptr, C.get_main_jit_dylib(@ptr), ts_mod)
      if err && !err.null?
        C.dispose_thread_safe_module(ts_mod)
        raise_if_error(err)
      end
    end

    # Look up a compiled symbol by name. Returns an Integer address.
    # LLVMOrcExecutorAddress is uint64_t; on 32-bit targets the upper 32 bits are zero.
    def function_address(name)
      out = FFI::MemoryPointer.new(:uint64)
      err = C.lookup(@ptr, out, name)
      raise_if_error(err)
      out.read_uint64
    end

    def dispose
      return unless @ptr
      C.dispose_lljit(@ptr)
      @ptr = nil
    end

    # Add a symbol generator that searches a specific DLL by file path.
    def add_dll_generator(path)
      gen_out = FFI::MemoryPointer.new(:pointer)
      err = C.create_dll_generator_for_path(gen_out, path, C.get_global_prefix(@ptr), nil, nil)
      raise_if_error(err)
      C.dylib_add_generator(C.get_main_jit_dylib(@ptr), gen_out.read_pointer)
    end

    # Define one symbol as an absolute address in the main JITDylib.
    # LLVMOrcCSymbolMapPair layout (64-bit): 8 (ptr Name) + 8 (uint64 Address) +
    #   1 (uint8 GenericFlags) + 1 (uint8 TargetFlags) + 6 pad = 24 bytes.
    # LLVMOrcAbsoluteSymbols consumes the interned name ref; do not release it.
    def add_absolute_symbol(name, address, exported: true)
      pair = FFI::MemoryPointer.new(24)
      pair.put_pointer(0, C.mangle_and_intern(@ptr, name))
      pair.put_uint64(8, address)
      pair.put_uint8(16, exported ? 1 : 0)
      pair.put_uint8(17, 0)
      mu = C.absolute_symbols_mu(pair, 1)
      err = C.jitdylib_define(C.get_main_jit_dylib(@ptr), mu)
      raise_if_error(err)
    end

    private

    def raise_if_error(err)
      return if err.nil? || err.null?
      raise "LLJIT error: #{C.get_error_message(err)}"
    end

    module C
      extend FFI::Library

      ffi_lib_flags(:lazy, :global)
      _ver = LLVM::LLVM_VERSION
      ffi_lib ["LLVM-#{_ver}", "libLLVM-#{_ver}.so.1", "libLLVM.so.#{_ver}",
               "libLLVM.so.#{_ver}.1", "libLLVM-#{_ver}.dll", "LLVM-C"]

      attach_function :create_lljit_builder, :LLVMOrcCreateLLJITBuilder, [], :pointer
      # JIT Target Machine Builder — used to override the default host triple on mswin.
      attach_function :jtmb_detect_host, :LLVMOrcJITTargetMachineBuilderDetectHost,
                      [:pointer], :pointer
      attach_function :jtmb_get_target_triple, :LLVMOrcJITTargetMachineBuilderGetTargetTriple,
                      [:pointer], :string
      attach_function :jtmb_set_target_triple, :LLVMOrcJITTargetMachineBuilderSetTargetTriple,
                      [:pointer, :string], :void
      attach_function :lljit_builder_set_jtmb, :LLVMOrcLLJITBuilderSetJITTargetMachineBuilder,
                      [:pointer, :pointer], :void
      attach_function :create_lljit, :LLVMOrcCreateLLJIT, [:pointer, :pointer], :pointer
      attach_function :dispose_lljit,        :LLVMOrcDisposeLLJIT,         [:pointer], :pointer
      attach_function :get_main_jit_dylib,   :LLVMOrcLLJITGetMainJITDylib, [:pointer], :pointer
      attach_function :get_global_prefix,    :LLVMOrcLLJITGetGlobalPrefix,  [:pointer], :char

      attach_function :create_thread_safe_context,  :LLVMOrcCreateNewThreadSafeContext, [], :pointer
      attach_function :dispose_thread_safe_context, :LLVMOrcDisposeThreadSafeContext,   [:pointer], :void
      attach_function :create_thread_safe_module,   :LLVMOrcCreateNewThreadSafeModule,  [:pointer, :pointer], :pointer
      attach_function :dispose_thread_safe_module,  :LLVMOrcDisposeThreadSafeModule,    [:pointer], :void

      attach_function :add_ir_module, :LLVMOrcLLJITAddLLVMIRModule, [:pointer, :pointer, :pointer], :pointer

      # LLVMErrorRef LLVMOrcLLJITLookup(LLVMOrcLLJITRef, LLVMOrcExecutorAddress *Result, const char *Name)
      attach_function :lookup, :LLVMOrcLLJITLookup, [:pointer, :pointer, :string], :pointer

      # LLVMErrorRef LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(
      #   LLVMOrcDefinitionGeneratorRef *Result, char GlobalPrefix,
      #   LLVMOrcSymbolPredicate Filter, void *FilterCtx)
      attach_function :create_process_generator,
                      :LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess,
                      [:pointer, :char, :pointer, :pointer], :pointer

      attach_function :dylib_add_generator, :LLVMOrcJITDylibAddGenerator, [:pointer, :pointer], :void

      # LLVMErrorRef LLVMOrcCreateDynamicLibrarySearchGeneratorForPath(
      #   LLVMOrcDefinitionGeneratorRef *Result, const char *Path,
      #   char GlobalPrefix, LLVMOrcSymbolPredicate Filter, void *FilterCtx)
      attach_function :create_dll_generator_for_path,
                      :LLVMOrcCreateDynamicLibrarySearchGeneratorForPath,
                      [:pointer, :string, :char, :pointer, :pointer], :pointer

      # Intern a symbol name through the LLJIT's mangler (applies global prefix).
      # Returns LLVMOrcSymbolStringPoolEntryRef — caller owns one ref.
      # LLVMOrcAbsoluteSymbols consumes the ref, so don't release after passing.
      attach_function :mangle_and_intern, :LLVMOrcLLJITMangleAndIntern, [:pointer, :string], :pointer

      # LLVMOrcMaterializationUnitRef LLVMOrcAbsoluteSymbols(
      #   LLVMOrcCSymbolMapPairs Syms, size_t NumPairs)
      # Syms is an array of { LLVMOrcSymbolStringPoolEntryRef Name (ptr),
      #                        LLVMJITEvaluatedSymbol { uint64 Address, uint8 GenericFlags, uint8 TargetFlags } }
      # struct size: 8 (ptr) + 8 (addr) + 1 + 1 + 6 pad = 24 bytes per pair (64-bit).
      attach_function :absolute_symbols_mu, :LLVMOrcAbsoluteSymbols, [:pointer, :size_t], :pointer

      # LLVMErrorRef LLVMOrcJITDylibDefine(LLVMOrcJITDylibRef JD, LLVMOrcMaterializationUnitRef MU)
      attach_function :jitdylib_define, :LLVMOrcJITDylibDefine, [:pointer, :pointer], :pointer

      attach_function :get_error_message,     :LLVMGetErrorMessage,     [:pointer], :string
      attach_function :dispose_error_message, :LLVMDisposeErrorMessage, [:string],  :void

      attach_function :get_execution_session, :LLVMOrcLLJITGetExecutionSession, [:pointer], :pointer
      # void LLVMOrcExecutionSessionSetErrorReporter(
      #   LLVMOrcExecutionSessionRef ES,
      #   void (*ReportError)(void *Ctx, LLVMErrorRef Err),
      #   void *Ctx)
      attach_function :set_error_reporter,
                      :LLVMOrcExecutionSessionSetErrorReporter,
                      [:pointer, :pointer, :pointer], :void
    end
  end
end
