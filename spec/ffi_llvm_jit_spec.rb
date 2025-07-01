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

  it 'handles unsigned values well' do
    # LONG_MIN: -9223372036854775808, LONG_MAX: 9223372036854775807, ULONG_MAX: 18446744073709551615
    # the second argument is actually a char **, but as pointer isn't
    # supported, we use :string and abuse the fact that null pointer
    # is supported both by the function and by the converter.
    # Don't use it in real life code!
    ffi_llvm_jit_lib.attach_function :strtoul, %i[string string int], :ulong
    ffi_llvm_jit_lib.attach_function :strtol, %i[string string int], :long
    ulong_max = (2**(FFI.find_type(:ulong).size * 8)) - 1
    expect(ffi_llvm_jit_lib.llvm_jit_strtoul(ulong_max.to_s, nil, 0)).to eq ulong_max
    expect(ffi_llvm_jit_lib.llvm_jit_strtol('-1', nil, 0)).to eq(-1)
  end

  it 'supports string return values' do
    ffi_llvm_jit_lib.attach_function :getenv, [:string], :string
    ENV['JIT_ANSWER'] = '42'
    expect(ffi_llvm_jit_lib.llvm_jit_getenv('JIT_ANSWER')).to eq('42')
    ENV.delete('JIT_ANSWER')
    expect(ffi_llvm_jit_lib.llvm_jit_getenv('JIT_ANSWER')).to be_nil
  end

  it 'supports void return values' do
    # Again, only for testing purposes, don't use it in real life code,
    # first arg should be pointer instead and you shouldn't modify Ruby strings in C func!
    ffi_llvm_jit_lib.attach_function :memset, %i[string int size_t], :void
    buf = 42.chr * 42
    expect(ffi_llvm_jit_lib.llvm_jit_memset(buf, 34, 34)).to be_nil
    expect(buf).to eq('""""""""""""""""""""""""""""""""""********')
  end

  it "doesn't accept void parameters" do
    res = ffi_llvm_jit_lib.attach_function :memset, %i[string void size_t], :void
    expect(res).to be_a(FFI::Function)
    # Surprisignly, they allow that, but
    #   ffi_llvm_jit_lib.memset("", nil, 0)
    # would raise
    #   ArgumentError: Invalid parameter type: 0
  end
end
