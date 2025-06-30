# frozen_string_literal: true

RSpec.describe FfiLlvmJit do
  let(:ffi_llvm_jit_lib) do
    Module.new.tap do |mod|
      mod.extend described_class::Library
      mod.ffi_lib FFI::Library::LIBC

      mod.attach_function :strlen, :strlen, [:string], :size_t
    end
  end

  it 'has a version number' do
    expect(FfiLlvmJit::VERSION).not_to be nil
  end

  it 'calculates strlen' do
    expect(ffi_llvm_jit_lib.strlen('Hello from FFI LLVM JIT!')).to eq 24
  end
end
