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
  
if RbConfig::CONFIG['host_os'] =~ /mswin/i
  # On mswin, use clang-cl (MSVC-compat clang from VS env) rather than UCRT64 GCC-mode clang.
  # GCC-mode clang ignores nmake's -Fo<output> flag and writes to a different filename,
  # so the .obj file is never created and nmake fails to resolve subsequent dependencies.
  # clang-cl understands -Fo, -Zi, and all other MSVC-style CFLAGS, and supports -emit-llvm.
  clang   = with_config('clang-path',   ENV.fetch('CLANG',   File.join(llvm_bindir, 'clang-cl').tr('/', '\\')))
  clangxx = with_config('clangxx-path', ENV.fetch('CLANGXX', File.join(llvm_bindir, 'clang-cl').tr('/', '\\')))
  # clang-cl with /clang:-emit-llvm ignores -Fo and writes bitcode to <stem>.bc.
  # MakeMakefile::COUTFLAG is a constant captured at mkmf load time, so RbConfig alone
  # is not enough; remove and redefine the constant so the clang driver gets the output path.
  # Also, -Fo is passed to cl in a wrong way - -Follvm_bitcode.obj is interpreted as ["-Follvm_bitcode", ".obj"]
  # and then cl : Command line warning D9027 : source file '.obj' ignored
  coutflag = '/clang:-o /clang:'
  RbConfig::MAKEFILE_CONFIG['COUTFLAG'] = RbConfig::CONFIG['COUTFLAG'] = coutflag
  MakeMakefile.send(:remove_const, :COUTFLAG)
  MakeMakefile::COUTFLAG = coutflag
else
  clang   = with_config('clang-path',   ENV.fetch('CLANG',   File.join(*llvm_bindir, 'clang')))
  clangxx = with_config('clangxx-path', ENV.fetch('CLANGXX', File.join(*llvm_bindir, 'clang++')))
  # GNU make link format: -o <output> <inputs>...  (ARGV[1]=output, ARGV[2]=first input)
  RbConfig::MAKEFILE_CONFIG['LDSHARED'] =
    RbConfig::CONFIG['LDSHARED'] = "#{RbConfig.ruby} -rfileutils -e 'FileUtils.cp(ARGV[2], ARGV[1])' -- "
end
RbConfig::MAKEFILE_CONFIG['CC']  = RbConfig::CONFIG['CC']  = clang
RbConfig::MAKEFILE_CONFIG['CXX'] = RbConfig::CONFIG['CXX'] = clangxx
# RbConfig::MAKEFILE_CONFIG['MKMF_VERBOSE'] = RbConfig::CONFIG['MKMF_VERBOSE'] = '1'
# cp into lib dir won't work; just use MAKEFILE_CONFIG later to find the extname
# RbConfig::MAKEFILE_CONFIG['DLEXT'] = RbConfig::CONFIG['DLEXT'] = 'bc'

# required to push flags without checking
# /clang: prefix passes a flag through to the clang driver; bare -emit-llvm is silently ignored by clang-cl
$CFLAGS << (RbConfig::CONFIG['host_os'] =~ /mswin/i ? ' /clang:-emit-llvm' : ' -emit-llvm') # rubocop:disable Style/GlobalVars
$CFLAGS << ' -c -Werror=implicit-function-declaration '
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

if RbConfig::CONFIG['host_os'] =~ /mswin/i
  # Inline Ruby in nmake's LDSHARED recipe silently does nothing (cmd.exe quoting + nmake's
  # space-before-command means the script runs but IO/FileUtils writes go nowhere visible).
  # Replace the link recipe with native Windows `copy`: bitcode is already in $(OBJS),
  # just copy it to the $(@) target — no linking needed for LLVM bitcode.
  mf = File.read('Makefile')
  mf.sub!(/^\t\$\(Q\) \$\(LDSHARED\).*$/, "\tcopy $(OBJS) $(@) >NUL")
  File.write('Makefile', mf)
end
