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
  # because of ruby-llvm that requires ruby 2.7 since version 13.0.0
  spec.required_ruby_version = '>= 2.7'
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

  # sed -i 's/ffi (~> 1.16)/ffi (~> 1.16, >= 1.16.3)/' gemfiles/Gemfile-*.lock
  spec.add_dependency 'ffi', '~> 1.16', '>= 1.16.3'
  spec.add_dependency 'ruby-llvm', '>= 17.0.0', '<= 21.1.0'

  spec.requirements.push('llvm-17-dev or newer')
  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html

  # Development dependencies are in Gemfile, versioned via BUNDLE_GEMFILE symlinks in gemfiles/
end
