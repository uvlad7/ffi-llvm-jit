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

# Similar to https://gist.github.com/tenderworks/f4cbb60f2c0dc3ab334eb73fec36f702
task bench: :compile do
  require 'ffi'
  require 'benchmark/ips'
  require 'strlen'
  require 'ffi_llvm_jit'

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
#           strlen-ffi   565.948k i/100ms
#          strlen-ruby     1.303M i/100ms
#          strlen-cext     1.248M i/100ms
#          ruby-direct     1.720M i/100ms
#  strlen-ffi-llvm-jit     1.238M i/100ms
# Calculating -------------------------------------
#           strlen-ffi      5.676M (± 2.6%) i/s  (176.17 ns/i) -     28.863M in   5.088461s
#          strlen-ruby     13.128M (± 2.3%) i/s   (76.18 ns/i) -     66.453M in   5.064791s
#          strlen-cext     11.899M (± 4.9%) i/s   (84.04 ns/i) -     59.881M in   5.047425s
#          ruby-direct     16.699M (± 6.4%) i/s   (59.89 ns/i) -     84.277M in   5.076964s
#  strlen-ffi-llvm-jit     11.947M (± 2.4%) i/s   (83.70 ns/i) -     60.654M in   5.079950s

# Comparison:
#          ruby-direct: 16698670.4 i/s
#          strlen-ruby: 13127528.3 i/s - 1.27x  slower
#  strlen-ffi-llvm-jit: 11947139.9 i/s - 1.40x  slower
#          strlen-cext: 11898508.3 i/s - 1.40x  slower
#           strlen-ffi:  5676267.8 i/s - 2.94x  slower
