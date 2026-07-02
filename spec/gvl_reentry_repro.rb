# frozen_string_literal: true

# Cross-platform repro: does a JIT blocking call correctly propagate thread.raise
# when an FFI::Function callback fires from within the blocking region?
#
# Build the spec extension first:
#   bundle exec rake spec_compile:default
#
# Then run:
#   bundle exec ruby spec/gvl_reentry_repro.rb
#
# When spec_spin_callback (marked blocking: true) is called, it runs inside
# rb_thread_call_without_gvl.  Each call to the FFI::Function pointer from C:
#   cb(data)
# goes through FFI's trampoline, which detects the missing GVL and calls
#   rb_thread_call_with_gvl(callback_with_gvl, ...)
# which in turn calls blocking_region_end → rb_thread_check_ints.  Once
# thread.raise('Ooops') is set, the next check_ints call longjmps to the JIT's
# rb_rescue2 — the exception should be stored and re-raised afterwards.
#
# Expected output (if both work):
#   FFI  + spin_callback: OK   — raised RuntimeError("Ooops")
#   JIT  + spin_callback: OK   — raised RuntimeError("Ooops")

require 'bundler/setup'
require 'ffi/llvm_jit'
require 'ffi-compiler/loader'

spec_ext = File.absolute_path(
  FFI::Compiler::Loader.find('ffi_llvm_jit_spec', './spec/ext/ffi_llvm_jit_spec'),
)

ffi_libs = if Gem.win_platform?
             [FFI::Library::LIBC, spec_ext, 'msvcrt', 'kernel32']
           else
             [FFI::Library::LIBC, spec_ext, 'm']
           end

ITERATIONS = 1_000_000
RAISE_DELAY = 0.05 # seconds before raising

# ---------------------------------------------------------------------------
# Regular FFI module
# ---------------------------------------------------------------------------
ffi_mod = Module.new do
  extend FFI::Library
  ffi_lib(*ffi_libs)
  # void spec_spin_callback(void (*cb)(void *), void *data, uint32_t iterations)
  attach_function :spec_spin_callback, %i[pointer pointer uint], :void, blocking: true
end

# ---------------------------------------------------------------------------
# JIT module
# ---------------------------------------------------------------------------
jit_mod = Module.new do
  extend FFI::LLVMJIT::Library
  ffi_lib(*ffi_libs)
  yolo!
  attach_llvm_jit_function :spec_spin_callback, %i[pointer pointer uint], :void, blocking: true
end

# ---------------------------------------------------------------------------
# Test helper
# ---------------------------------------------------------------------------
test = ->(label, mod) do
  print "#{label}: "
  cb = FFI::Function.new(:void, [:pointer]) {}
  t = Thread.new { mod.spec_spin_callback(cb, nil, ITERATIONS) }
  t.report_on_exception = false
  sleep(RAISE_DELAY)
  t.raise('Ooops')
  begin
    t.value
    puts 'FAIL — thread.value returned nil or value (exception lost)'
  rescue RuntimeError => e
    puts "OK   — raised RuntimeError(#{e.message.inspect})"
  rescue => e
    puts "UNEXPECTED — #{e.class}: #{e.message}"
  end
end

test.('FFI  + spin_callback', ffi_mod)
test.('JIT  + spin_callback', jit_mod)
