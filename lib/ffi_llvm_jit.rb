# frozen_string_literal: true

require_relative 'ffi_llvm_jit/version'

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

  @ffi_llvm_jit = LLVM::Module.parse_bitcode(File.expand_path("ffi_llvm_jit/ffi_llvm_jit.#{RbConfig::MAKEFILE_CONFIG['DLEXT']}", __dir__))
  # @ffi_llvm_jit.functions['ffi_llvm_jit_convert_string']

  # Your code goes here...
end
