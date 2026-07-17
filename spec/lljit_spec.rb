# frozen_string_literal: true

RSpec.describe LLVM::LLJit do
  def capture_stderr
    r, w = IO.pipe
    original = $stderr.dup
    $stderr.reopen(w)
    w.close
    begin
      yield
    ensure
      $stderr.reopen(original)
      original.close
    end
    output = r.read
    r.close
    output
  end

  it 'reports JITLink errors' do
    jit = LLVM::LLJit.new
    mod = LLVM::Module.new('spec_undef_ext')
    undef_fn = mod.functions.add('__ffi_llvm_jit_spec_undef_xyz',
                                  LLVM::Type.function([], LLVM::Int32))
    wrapper = mod.functions.add('spec_wrapper', LLVM::Type.function([], LLVM::Int32))
    wrapper.basic_blocks.append('entry').build { |b| b.ret b.call(undef_fn) }
    jit.add_module(mod)

    stderr = capture_stderr do
      expect { jit.function_address('spec_wrapper') }
        .to raise_error(RuntimeError, 'LLJIT error: Failed to materialize symbols: { (main, { spec_wrapper }) }')
    end
    expect(stderr).to eq("JITLink error: Symbols not found: [ __ffi_llvm_jit_spec_undef_xyz ]\n")
  ensure
    jit&.dispose
  end
end
