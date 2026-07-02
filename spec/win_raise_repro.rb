# frozen_string_literal: true

# Minimal repro: compare exception propagation after thread.raise + QueueUserAPC
# for regular FFI vs ffi_llvm_jit's JIT-compiled blocking calls.
#
# Run on Windows:
#   ruby spec/win_raise_repro.rb
#
# Expected: FFI raises RuntimeError('Ooops'), JIT also raises (if not, JIT is swallowing it).

require 'bundler/setup'
require 'ffi/llvm_jit'

abort 'Windows only' unless Gem.win_platform?

# ---------------------------------------------------------------------------
# Kernel32 helpers (shared)
# ---------------------------------------------------------------------------
K32Helper = Module.new do
  extend FFI::Library
  ffi_lib 'kernel32'
  attach_function :OpenThread,      %i[uint int uint],         :pointer
  attach_function :QueueUserAPC,    %i[pointer pointer uint64], :uint
  attach_function :CloseHandle,     [:pointer],                 :int
  attach_function :GetCurrentThreadId, [],                      :uint
end

ffi_libs = [FFI::Library::LIBC, 'msvcrt', 'kernel32']

# ---------------------------------------------------------------------------
# Two APC callback styles to test
# ---------------------------------------------------------------------------
# 1. Ruby FFI::Function — calls rb_thread_call_with_gvl, may consume interrupt
ruby_apc = FFI::Function.new(:void, [:uint64]) {}

# 2. Native kernel32 — no Ruby re-entry, interrupt stays queued
k32 = FFI::DynamicLibrary.open('kernel32', FFI::DynamicLibrary::RTLD_LAZY)
native_apc = k32.find_function('GetCurrentThreadId')

wake = ->(t, apc_fn) do
  h = K32Helper.OpenThread(0x0010, 0, t.native_thread_id)
  K32Helper.QueueUserAPC(apc_fn, h, 0)
  K32Helper.CloseHandle(h)
end

test = ->(label, mod, apc_fn) do
  print "#{label}: "
  t = Thread.new { mod.sleep_ex(3_600_000, 1) }
  t.report_on_exception = false
  sleep(0.05) until t.stop?
  t.raise('Ooops')
  wake.(t, apc_fn)
  begin
    t.value
    puts 'FAIL — thread.value returned nil (exception lost)'
  rescue RuntimeError => e
    puts "OK   — raised RuntimeError(#{e.message.inspect})"
  rescue => e
    puts "UNEXPECTED — #{e.class}: #{e.message}"
  end
end

# ---------------------------------------------------------------------------
# Regular FFI module
# ---------------------------------------------------------------------------
ffi_mod = Module.new do
  extend FFI::Library
  ffi_lib FFI::Library::LIBC, 'msvcrt', 'kernel32'
  attach_function :sleep_ex, :SleepEx, %i[uint int], :uint, blocking: true
end

# ---------------------------------------------------------------------------
# JIT module
# ---------------------------------------------------------------------------
jit_mod = Module.new do
  extend FFI::LLVMJIT::Library
  ffi_lib FFI::Library::LIBC, 'msvcrt', 'kernel32'
  attach_llvm_jit_function :sleep_ex, :SleepEx, %i[uint int], :uint, blocking: true
end

# ---------------------------------------------------------------------------
# Run the matrix
# ---------------------------------------------------------------------------
test.('FFI  + ruby_apc  ', ffi_mod, ruby_apc)
test.('FFI  + native_apc', ffi_mod, native_apc)
test.('JIT  + ruby_apc  ', jit_mod, ruby_apc)
test.('JIT  + native_apc', jit_mod, native_apc)
