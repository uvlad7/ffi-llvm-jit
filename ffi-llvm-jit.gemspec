# frozen_string_literal: true

require_relative 'lib/ffi/llvm_jit/version'

# Project structure inspired by
# https://github.com/postmodern/ffi-libc
Gem::Specification.new do |spec|
  spec.name = 'ffi-llvm-jit'
  spec.version = FFI::LLVMJIT::VERSION
  spec.authors = ['uvlad7']
  spec.email = ['uvlad7@gmail.com']

  spec.summary = 'Ruby FFI JIT using LLVM'
  spec.description = 'Extends Ruby FFI and uses LLVM to generate JIT wrappers for attached native functions. ' \
                     'Works only on MRI'
  spec.homepage = 'https://github.com/uvlad7/ffi-llvm-jit'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 2.3.8'
  spec.required_rubygems_version = '>= 3.2.3'

  # spec.metadata['allowed_push_host'] = "https://rubygems.org"

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/v#{spec.version}"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['documentation_uri'] = "https://rubydoc.info/gems/#{spec.name}/#{spec.version}"

  spec.files = [
    # .rb - to exclude .so
    *Dir['ext/**/*'], *Dir['lib/**/*.rb'], *Dir['sig/**/*'],
    'LICENSE.txt', 'README.md',
  ].reject { |f| File.directory?(f) }

  # spec.bindir = 'exe'
  # spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ['lib']
  spec.extensions = ['ext/llvm_bitcode/extconf.rb', 'ext/ffi_llvm_jit/extconf.rb']

  spec.add_dependency 'ffi', '~> 1.15'
  spec.add_dependency 'ruby-llvm', '>= 14'

  spec.add_development_dependency 'pry', '0.14.2'
  spec.add_development_dependency 'pry-byebug', '3.10.1'

  spec.add_development_dependency 'benchmark-ips', '~> 2.14'
  spec.add_development_dependency 'strlen', '~> 1.0'
  # Only because its major version matches required llvm version and I have llvm-17 installed
  spec.add_development_dependency 'ruby-llvm', '~> 17'

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html

  spec.add_development_dependency 'rake', '~> 13.0'

  spec.add_development_dependency 'rake-compiler'

  spec.add_development_dependency 'rspec', '~> 3.0'

  spec.add_development_dependency 'rubocop', '~> 1.21'
end
