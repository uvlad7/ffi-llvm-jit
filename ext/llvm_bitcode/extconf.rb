# frozen_string_literal: true

require 'mkmf'

require 'llvm'

llvm_bindir = [
  with_config('llvm-config-path', ENV.fetch('LLVM_CONFIG', nil)),
  "llvm-config-#{LLVM::LLVM_VERSION}",
  'llvm-config',
].find do |llvm_config|
  next unless llvm_config

  begin
    break `#{llvm_config} --bindir`.strip
  rescue Errno::ENOENT
    next
  end
end
clang = with_config('clang-path', ENV.fetch('CLANG', File.join(*llvm_bindir, 'clang')))
clangxx = with_config('clangxx-path', ENV.fetch('CLANGXX', File.join(*llvm_bindir, 'clang++')))
RbConfig::MAKEFILE_CONFIG['CC'] = RbConfig::CONFIG['CC'] = clang
RbConfig::MAKEFILE_CONFIG['CXX'] = RbConfig::CONFIG['CXX'] = clangxx
RbConfig::MAKEFILE_CONFIG['LDSHARED'] =
  RbConfig::CONFIG['LDSHARED'] = "#{RbConfig.ruby} -rfileutils -e 'FileUtils.cp(ARGV[2], ARGV[1])' -- "
# RbConfig::MAKEFILE_CONFIG['MKMF_VERBOSE'] = RbConfig::CONFIG['MKMF_VERBOSE'] = '1'
# cp into lib dir won't work; just use MAKEFILE_CONFIG later to find the extname
# RbConfig::MAKEFILE_CONFIG['DLEXT'] = RbConfig::CONFIG['DLEXT'] = 'bc'

# required to push flags without checking
$CFLAGS << ' -emit-llvm -c -Werror=implicit-function-declaration ' # rubocop:disable Style/GlobalVars
# TODO: check which win_platform? guards are applicable on cygwin
if Gem.win_platform? # rubocop:disable Style/GlobalVars
  $CFLAGS << ' -DFFI_LLVM_JIT_WIN_PLATFORM '
  # SYMBOL_PREFIX="_" (cdecl) but EXPORT_PREFIX="" (Ruby .def file exports without it):
  # the LLVM JIT would look for _rb_eException but Ruby only exports rb_eException.
  # -fno-leading-underscore sets m:e (ELF mangling) in the module data layout so
  # JIT-compiled code references symbols by their exact DLL export name.
  if RbConfig::CONFIG['SYMBOL_PREFIX'] == '_' && RbConfig::CONFIG['EXPORT_PREFIX'].strip.empty?
    $CFLAGS << ' -fno-leading-underscore'
  end
end

# MakeMakefile::COMPILE_C = config_string('COMPILE_C') ||
#   '$(CC) $(INCFLAGS) $(CPPFLAGS) $(CFLAGS) $(COUTFLAG) -c $(CSRCFLAG)$<'

create_makefile('llvm_jit/llvm_bitcode')
