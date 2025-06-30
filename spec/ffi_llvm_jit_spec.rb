# frozen_string_literal: true

RSpec.describe FFI::LLVMJIT do # rubocop:disable Metrics/BlockLength
  let(:ffi_llvm_jit_lib) do
    Module.new.tap do |mod|
      mod.extend described_class::Library
      mod.ffi_lib FFI::Library::LIBC

      mod.attach_function :strlen, [:string], :size_t
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
      ffi_llvm_jit_lib.attach_function :unknown, [:string], :size_t
    end.to raise_error(FFI::NotFoundError)
  end

  it "doesn't invalidate old function pointers" do
    ffi_llvm_jit_lib.attach_function :strlen2, :strlen, [:string], :size_t
    ffi_llvm_jit_lib.attach_function :strlen3, :strlen, [:string], :size_t
    expect(ffi_llvm_jit_lib.strlen2('ok')).to eq 2
  end

  it 'passes unsupported functions to FFI::Library' do
    ret = ffi_llvm_jit_lib.attach_function :printf, %i[string varargs], :int
    expect(ret).to be_a(FFI::VariadicInvoker)
    expect(defined?(ffi_llvm_jit_lib.printf)).to be_truthy
    expect(defined?(ffi_llvm_jit_lib.llvm_jit_printf)).to be_nil

    res = ffi_llvm_jit_lib.attach_function :free, [:pointer], :void
    expect(res).to be_a(FFI::Function)
    expect(defined?(ffi_llvm_jit_lib.free)).to be_truthy
    expect(defined?(ffi_llvm_jit_lib.llvm_jit_free)).to be_nil

    res = ffi_llvm_jit_lib.attach_function :strlen4, :strlen, [:string], :size_t, blocking: true
    expect(res).to be_a(FFI::Function)

    expect(ffi_llvm_jit_lib.attach_function(:strlen5, :strlen, [:string], :size_t)).to be_nil
    ffi_llvm_jit_lib.typedef :size_t, :length
    expect(ffi_llvm_jit_lib.attach_function(:strlen6, :strlen, [:string], :size_t)).to be_a(FFI::Function)
  end

  it 'supports multiple args' do
    expect(ffi_llvm_jit_lib.attach_function(:strcmp, %i[string string], :int)).to be_nil
    expect(ffi_llvm_jit_lib.attach_function(:strcasecmp, %i[string string], :int)).to be_nil
    expect(ffi_llvm_jit_lib.llvm_jit_strcmp('a', 'b')).to be < 1
    expect(ffi_llvm_jit_lib.llvm_jit_strcmp('ABBA', 'abBA')).to be < 1
    expect(ffi_llvm_jit_lib.llvm_jit_strcasecmp('ABBA', 'abBA')).to be 0
  end
end
