# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)

require 'rubocop/rake_task'

RuboCop::RakeTask.new

require 'yard'

YARD::Rake::YardocTask.new do |t|
  # use .yardopts file instead
  # t.options = gemspec.rdoc_options
  t.options += ['--output-dir', ENV['DOCS_DIR']] if ENV['DOCS_DIR']
end

require 'rake/extensiontask'

task build: :compile

GEMSPEC = Gem::Specification.load('ffi-llvm-jit.gemspec')

GEMSPEC.extensions.each do |extension|
  name = extension[%r{ext/(.*)/extconf.rb}, 1]
  Rake::ExtensionTask.new(name, GEMSPEC) do |ext|
    ext.lib_dir = 'lib/ffi/llvm_jit'
  end
end

namespace 'spec_compile' do
  require 'ffi-compiler/compile_task'
  FFI::Compiler::CompileTask.new('spec/ext/ffi_llvm_jit_spec/ffi_llvm_jit_spec')
end
task spec: 'spec_compile:default'

task spec: :compile

task default: %i[clobber compile spec rubocop yard]

# Similar to https://gist.github.com/tenderworks/f4cbb60f2c0dc3ab334eb73fec36f702
# rubocop:disable Metrics/BlockLength, Style/Documentation, Lint/ConstantDefinitionInBlock, Naming/MethodParameterName
task bench: [:compile, 'spec_compile:default'] do
  require 'ffi'
  require 'benchmark/ips'
  require 'strlen'
  require 'ffi/llvm_jit'
  require 'ffi-compiler/loader'

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
    extend FFI::LLVMJIT::Library

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

  module D
    extend FFI::Library
    ffi_lib FFI::Compiler::Loader.find('ffi_llvm_jit_spec', './spec/ext/ffi_llvm_jit_spec')

    attach_function :factorial, [:uint], :ulong
  end

  module E
    extend FFI::LLVMJIT::Library
    ffi_lib FFI::Compiler::Loader.find('ffi_llvm_jit_spec', './spec/ext/ffi_llvm_jit_spec')

    attach_llvm_jit_function :factorial, [:uint], :ulong
  end

  Benchmark.ips do |x|
    x.report('factorial(100) ffi') { D.factorial(100) }
    x.report('factorial(100) ffi-llvm-jit') { E.factorial(100) }
    x.compare!
  end
  Benchmark.ips do |x|
    x.report('factorial(42000) ffi') { D.factorial(42000) }
    x.report('factorial(42000) ffi-llvm-jit') { E.factorial(42000) }
    x.compare!
  end
end
# rubocop:enable Metrics/BlockLength, Style/Documentation, Lint/ConstantDefinitionInBlock, Naming/MethodParameterName

# ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [x86_64-linux]
# Warming up --------------------------------------
#           strlen-ffi   574.246k i/100ms
#          strlen-ruby     1.299M i/100ms
#          strlen-cext     1.204M i/100ms
#          ruby-direct     1.696M i/100ms
#  strlen-ffi-llvm-jit     1.107M i/100ms
# Calculating -------------------------------------
#           strlen-ffi      5.633M (± 6.1%) i/s  (177.53 ns/i) -     28.138M in   5.020541s
#          strlen-ruby     13.203M (± 2.7%) i/s   (75.74 ns/i) -     66.262M in   5.022705s
#          strlen-cext     11.672M (± 4.6%) i/s   (85.68 ns/i) -     58.979M in   5.064773s
#          ruby-direct     17.050M (± 1.3%) i/s   (58.65 ns/i) -     86.520M in   5.075277s
#  strlen-ffi-llvm-jit     12.064M (± 1.2%) i/s   (82.89 ns/i) -     60.911M in   5.049621s

# Comparison:
#          ruby-direct: 17050160.9 i/s
#          strlen-ruby: 13202524.9 i/s - 1.29x  slower
#  strlen-ffi-llvm-jit: 12064294.8 i/s - 1.41x  slower
#          strlen-cext: 11671739.9 i/s - 1.46x  slower
#           strlen-ffi:  5632971.7 i/s - 3.03x  slower

# ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [x86_64-linux]
# Warming up --------------------------------------
#   factorial(100) ffi   219.370k i/100ms
# factorial(100) ffi-llvm-jit
#                        281.576k i/100ms
# Calculating -------------------------------------
#   factorial(100) ffi      2.178M (± 2.9%) i/s  (459.19 ns/i) -     10.968M in   5.041112s
# factorial(100) ffi-llvm-jit
#                           2.846M (± 1.6%) i/s  (351.40 ns/i) -     14.360M in   5.047532s

# Comparison:
# factorial(100) ffi-llvm-jit:  2845732.7 i/s
#   factorial(100) ffi:  2177744.0 i/s - 1.31x  slower

# ruby 3.3.6 (2024-11-05 revision 75015d4c1f) [x86_64-linux]
# Warming up --------------------------------------
# factorial(42000) ffi   729.000 i/100ms
# factorial(42000) ffi-llvm-jit
#                        778.000 i/100ms
# Calculating -------------------------------------
# factorial(42000) ffi      7.263k (± 2.0%) i/s  (137.68 μs/i) -     36.450k in   5.020507s
# factorial(42000) ffi-llvm-jit
#                           7.590k (± 2.4%) i/s  (131.75 μs/i) -     38.122k in   5.025649s

# Comparison:
# factorial(42000) ffi-llvm-jit:     7589.9 i/s
# factorial(42000) ffi:     7263.2 i/s - 1.04x  slower
