# frozen_string_literal: true

RSpec.describe FFI::LLVMJIT do
  let(:ffi_llvm_jit_lib) do
    Module.new.tap do |mod|
      mod.extend described_class::Library
      mod.ffi_lib FFI::Library::LIBC

      mod.attach_function :strlen, :strlen, [:string], :size_t
    end
  end

  it 'has a version number' do
    expect(FFI::LLVMJIT::VERSION).not_to be nil
  end

  it 'calculates strlen' do
    expect(ffi_llvm_jit_lib.llvm_jit_strlen('Hello from FFI LLVM JIT!')).to eq 24
  end
end
