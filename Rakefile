# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

require 'rubocop/rake_task'

RuboCop::RakeTask.new

require 'rake/extensiontask'

task build: :compile

GEMSPEC = Gem::Specification.load('ffi_llvm_jit.gemspec')

GEMSPEC.extensions.each do |extension|
  name = extension[%r{ext/(.*)/extconf.rb}, 1]
  Rake::ExtensionTask.new(name, GEMSPEC) do |ext|
    ext.lib_dir = 'lib/ffi_llvm_jit'
  end
end

task default: %i[clobber compile spec rubocop]

require 'ffi'
require 'benchmark/ips'
require 'strlen'
require 'ffi_llvm_jit'

# Similar to https://gist.github.com/tenderworks/f4cbb60f2c0dc3ab334eb73fec36f702
task bench: :compile do
  module A
    extend FFI::Library
    ffi_lib 'c'
    attach_function :strlen, [:string], :int
  end

  module B
    def self.strlen(x)
      x.bytesize
    end
  end

  module C
    extend FfiLlvmJit::Library

    ffi_lib ::FFI::Library::LIBC

    attach_function :strlen, :strlen, [:string], :size_t
  end

  str = 'foo'

  Benchmark.ips do |x|
    x.report('strlen-ffi') { A.strlen(str) }
    x.report('strlen-ruby') { B.strlen(str) }
    x.report('strlen-cext') { Strlen.strlen(str) }
    x.report('ruby-direct') { str.bytesize }
    x.report('strlen-ffi-llvm-jit') { C.strlen(str) }
    x.compare!
  end
end

# ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [x86_64-linux]
# Warming up --------------------------------------
#           strlen-ffi   556.941k i/100ms
#          strlen-ruby     1.325M i/100ms
#          strlen-cext     1.219M i/100ms
#          ruby-direct     1.729M i/100ms
#  strlen-ffi-llvm-jit     1.242M i/100ms
# Calculating -------------------------------------
#           strlen-ffi      5.668M (± 4.6%) i/s  (176.42 ns/i) -     28.404M in   5.023478s
#          strlen-ruby     12.340M (±12.0%) i/s   (81.04 ns/i) -     60.956M in   5.034906s
#          strlen-cext     11.948M (± 4.8%) i/s   (83.70 ns/i) -     59.730M in   5.012220s
#          ruby-direct     16.552M (± 6.7%) i/s   (60.42 ns/i) -     82.994M in   5.041789s
#  strlen-ffi-llvm-jit     11.267M (± 9.7%) i/s   (88.76 ns/i) -     57.113M in   5.123262s

# Comparison:
#          ruby-direct: 16551738.5 i/s
#          strlen-ruby: 12340198.6 i/s - 1.34x  slower
#          strlen-cext: 11947514.4 i/s - 1.39x  slower
#  strlen-ffi-llvm-jit: 11266645.8 i/s - 1.47x  slower
#           strlen-ffi:  5668356.2 i/s - 2.92x  slower
