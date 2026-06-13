# frozen_string_literal: true

require 'mkmf'

llvm_config = ENV['LLVM_CONFIG'] || 'llvm-config'
llvm_bindir = `#{llvm_config} --bindir`.strip
clang = with_config('clang-path', File.join(llvm_bindir, 'clang'))
clangxx = with_config('clangxx-path', File.join(llvm_bindir, 'clang++'))
RbConfig::MAKEFILE_CONFIG['CC'] = RbConfig::CONFIG['CC'] = clang
RbConfig::MAKEFILE_CONFIG['CXX'] = RbConfig::CONFIG['CXX'] = clangxx
RbConfig::MAKEFILE_CONFIG['LDSHARED'] =
  RbConfig::CONFIG['LDSHARED'] = "ruby -rfileutils -e 'FileUtils.cp(ARGV[2], ARGV[1])' -- "
# RbConfig::MAKEFILE_CONFIG['MKMF_VERBOSE'] = RbConfig::CONFIG['MKMF_VERBOSE'] = '1'
# cp into lib dir won't work; just use MAKEFILE_CONFIG later to find the extname
# RbConfig::MAKEFILE_CONFIG['DLEXT'] = RbConfig::CONFIG['DLEXT'] = 'bc'

# required to push flags without checking
$CFLAGS << ' -emit-llvm -c -Werror=implicit-function-declaration ' # rubocop:disable Style/GlobalVars

# MakeMakefile::COMPILE_C = config_string('COMPILE_C') ||
#   '$(CC) $(INCFLAGS) $(CPPFLAGS) $(CFLAGS) $(COUTFLAG) -c $(CSRCFLAG)$<'

create_makefile('llvm_jit/llvm_bitcode')
