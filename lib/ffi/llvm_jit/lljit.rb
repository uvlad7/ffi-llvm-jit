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
      builder = C.create_lljit_builder
      out = FFI::MemoryPointer.new(:pointer)
      err = C.create_lljit(out, builder)
      raise_if_error(err)
      @ptr = out.read_pointer

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
               "libLLVM.so.#{_ver}.1", "libLLVM-#{_ver}.dll"]

      attach_function :create_lljit_builder, :LLVMOrcCreateLLJITBuilder, [], :pointer
      attach_function :create_lljit,         :LLVMOrcCreateLLJIT,          [:pointer, :pointer], :pointer
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

      attach_function :get_error_message,     :LLVMGetErrorMessage,     [:pointer], :string
      attach_function :dispose_error_message, :LLVMDisposeErrorMessage, [:string],  :void
    end
  end
end
