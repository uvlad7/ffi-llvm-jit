# frozen_string_literal: true

source 'https://rubygems.org'

basename = File.basename(__FILE__)

llvm_version = basename[/llvm_([\d_]+)/, 1]&.gsub('_', '.')
# win matched only after a delimiter so 'cygwin' does not accidentally match
llvm_version ||= if basename =~ /(?:^|[-_])cygwin(?:[-_]|$)/
                   '~> 20' # Cygwin ships LLVM 20.x
                 elsif basename =~ /(?:^|[-_])mswin(?:[-_]|$)/
                   '~> 22' # MSYS2 UCRT64 libLLVM-22.dll (same install as x64 Ruby, ridk-resolved path)
                 elsif basename =~ /(?:^|[-_])win32(?:[-_]|$)/
                   '~> 21' # MSYS2 i686 archive tops out at LLVM 21.x (dropped from active repo)
                 elsif basename =~ /(?:^|[-_])win(?:[-_]|$)/
                   '~> 22' # MSYS2 UCRT64 ships LLVM 22.x
                 else
                   '~> 18'
                 end

ffi_version = basename[/ffi_([\d_]+)/, 1]&.gsub('_', '.')

gemspec path: File.basename(__dir__) == 'gemfiles' ? '..' : '.'

gem 'ffi', ffi_version if ffi_version
gem 'ruby-llvm', llvm_version

gem 'ffi-compiler', '~> 1.3'

gem 'rake', '~> 13.0'
gem 'rake-compiler'
gem 'rspec', '~> 3.0'

group :development do
  gem 'pry', '0.14.2'
  gem 'pry-byebug', '3.10.1'

  gem 'benchmark-ips', '~> 2.14'
  gem 'strlen', '~> 1.0'

  gem 'rubocop', '~> 1.21'
  gem 'yard', '~> 0.9.37'
end

gem "fiddle", ">= 1.1"

gem "irb", ">= 1.18"
