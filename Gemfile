# frozen_string_literal: true

source 'https://rubygems.org'

basename = File.basename(__FILE__)

llvm_version = basename[/llvm_([\d_]+)/, 1]&.gsub('_', '.')
# Only because its major version matches required llvm version and I have llvm-17 installed
llvm_version ||= (Gem.win_platform? ? '~> 20' : '~> 17')

ffi_version = basename[/ffi_([\d_]+)/, 1]&.gsub('_', '.')

gemspec path: File.basename(__dir__) == 'gemfiles' ? '..' : '.'

gem 'ffi', ffi_version if ffi_version
gem 'ruby-llvm', llvm_version

gem 'pry', '0.14.2'
gem 'pry-byebug', '3.10.1'

gem 'benchmark-ips', '~> 2.14'
gem 'strlen', '~> 1.0'

gem 'ffi-compiler', '~> 1.3'

gem 'rake', '~> 13.0'
gem 'rake-compiler'
gem 'rspec', '~> 3.0'
gem 'rubocop', '~> 1.21'
gem 'yard', '~> 0.9.37'
