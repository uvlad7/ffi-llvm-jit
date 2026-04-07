# frozen_string_literal: true

source 'https://rubygems.org'

# Specify your gem's dependencies in ffi-llvm-jit.gemspec
gemspec

gem 'ffi', github: 'uvlad7/ffi', branch: 'ffi_llvm_gem_integration', submodules: true
# Has needs to be here to be installed after ffi
gem 'ruby-llvm', (Gem.win_platform? ? '~> 20' : '~> 17')
