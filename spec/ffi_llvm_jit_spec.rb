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

  it 'raises an error when function is not found' do
    expect do
      ffi_llvm_jit_lib.attach_function :strlen, [:string], :size_t
    end.to raise_error(FFI::NotFoundError)
  end

  it "doesn't invalidate old function pointers" do
    ffi_llvm_jit_lib.attach_function :strlen2, :strlen, [:string], :size_t
    ffi_llvm_jit_lib.attach_function :strlen3, :strlen, [:string], :size_t
    expect(ffi_llvm_jit_lib.strlen2('ok')).to eq 2
  end
end
