# frozen_string_literal: true

# Cross-platform repro for two exception-propagation scenarios:
#
# 1. spec_spin_callback (blocking: true) + thread.raise from another thread
#    The raise interrupt is queued and processed by blocking_region_end the
#    next time the callback re-acquires the GVL.
#
# 2. spec_invoke_callback (blocking: true or not) + callback that raises directly
#    FFI wraps each callback in rb_rescue2 (callback_with_gvl in Function.c),
#    saves the exception in the current rbffi_frame_t, returns normally through
#    all C frames, then re-raises in rbffi_CallFunction after rbffi_frame_pop.
#    JIT has no equivalent frame mechanism: save_callback_exception is called
#    with cb->frame == NULL (no frame pushed), so the exception is silently dropped.
#
# Build the spec extension first:
#   bundle exec rake spec_compile:default
#
# Then run:
#   bundle exec ruby spec/gvl_reentry_repro.rb

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
  attach_function :spec_spin_callback,   %i[uint64 uint64 uint], :void,   blocking: true
  attach_function :spec_invoke_callback, %i[uint64 uint64],      :uint64, blocking: true
  attach_function :spec_invoke_callback_nonblocking,
                  :spec_invoke_callback, %i[uint64 uint64],      :uint64
end

# ---------------------------------------------------------------------------
# JIT module
# ---------------------------------------------------------------------------
jit_mod = Module.new do
  extend FFI::LLVMJIT::Library
  ffi_lib(*ffi_libs)
  yolo!
  attach_llvm_jit_function :spec_spin_callback,   %i[uint64 uint64 uint], :void,   blocking: true
  attach_llvm_jit_function :spec_invoke_callback, %i[uint64 uint64],      :uint64, blocking: true
  attach_llvm_jit_function :spec_invoke_callback_nonblocking,
                            :spec_invoke_callback, %i[uint64 uint64],      :uint64
end

# ---------------------------------------------------------------------------
# Test 1: spin_callback + thread.raise from another thread
# ---------------------------------------------------------------------------
spin_test = ->(label, mod) do
  print "#{label}: "
  cb = FFI::Function.new(:void, [:uint64]) {}
  t = Thread.new { mod.spec_spin_callback(cb.to_i, 0, ITERATIONS) }
  t.report_on_exception = false
  sleep(RAISE_DELAY)
  t.raise('Ooops')
  begin
    t.value
    puts 'FAIL — exception lost (thread.value did not raise)'
  rescue RuntimeError => e
    puts "OK   — raised RuntimeError(#{e.message.inspect})"
  rescue => e
    puts "UNEXPECTED — #{e.class}: #{e.message}"
  end
end

# ---------------------------------------------------------------------------
# Test 2: invoke_callback + callback that raises directly
# ---------------------------------------------------------------------------
invoke_test = ->(label, invoke_method, mod) do
  print "#{label}: "
  cb = FFI::Function.new(:uint64, [:uint64]) do |_|
    $stderr.puts "[callback] tid=#{Thread.current.native_thread_id}"
    raise 'Ooops'
    0
  end
  t = Thread.new do
    $stderr.puts "[thread]   tid=#{Thread.current.native_thread_id}"
    mod.public_send(invoke_method, cb.to_i, 0)
  end
  t.report_on_exception = false
  begin
    t.value
    puts 'FAIL — exception lost (thread.value did not raise)'
  rescue RuntimeError => e
    puts "OK   — raised RuntimeError(#{e.message.inspect})"
  rescue => e
    puts "UNEXPECTED — #{e.class}: #{e.message}"
  end
end

puts '--- spin_callback + thread.raise ---'
spin_test.('FFI + spin_callback', ffi_mod)
spin_test.('JIT + spin_callback', jit_mod)

puts "\n--- invoke_callback (blocking: true) + callback raises ---"
invoke_test.('FFI + invoke_callback (blocking)',     :spec_invoke_callback,             ffi_mod)
invoke_test.('JIT + invoke_callback (blocking)',     :spec_invoke_callback,             jit_mod)

puts "\n--- invoke_callback (non-blocking) + callback raises ---"
invoke_test.('FFI + invoke_callback (non-blocking)', :spec_invoke_callback_nonblocking, ffi_mod)
invoke_test.('JIT + invoke_callback (non-blocking)', :spec_invoke_callback_nonblocking, jit_mod)
