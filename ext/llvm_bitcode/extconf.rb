# frozen_string_literal: true

require 'mkmf'

RbConfig::MAKEFILE_CONFIG['CC'] = RbConfig::CONFIG['CC'] = 'clang'
RbConfig::MAKEFILE_CONFIG['CXX'] = RbConfig::CONFIG['CXX'] = 'clang++'
RbConfig::MAKEFILE_CONFIG['LDSHARED'] =
  RbConfig::CONFIG['LDSHARED'] = "ruby -rfileutils -e 'FileUtils.cp(ARGV[2], ARGV[1])' -- "
# RbConfig::MAKEFILE_CONFIG['MKMF_VERBOSE'] = RbConfig::CONFIG['MKMF_VERBOSE'] = '1'
# cp into lib dir won't work; just use MAKEFILE_CONFIG later to find the extname
# RbConfig::MAKEFILE_CONFIG['DLEXT'] = RbConfig::CONFIG['DLEXT'] = 'bc'

# required to push flags without checking
$CFLAGS << ' -emit-llvm -c ' # rubocop:disable Style/GlobalVars

# MakeMakefile::COMPILE_C = config_string('COMPILE_C') ||
#   '$(CC) $(INCFLAGS) $(CPPFLAGS) $(CFLAGS) $(COUTFLAG) -c $(CSRCFLAG)$<'

create_makefile('ffi_llvm_jit/llvm_bitcode')
