# frozen_string_literal: true

require 'mkmf'

# Makes all symbols private by default to avoid unintended conflict
# with other gems. To explicitly export symbols you can use RUBY_FUNC_EXPORTED
# selectively, or entirely remove this flag.
append_cflags('-fvisibility=hidden')
append_cflags('-Werror=implicit-function-declaration')

if RbConfig::CONFIG['host_os'] =~ /mswin/i
  # bufferoverflowU.lib provides __security_check_cookie and __security_cookie.
  # We export them from this DLL so LLVM's JIT can resolve them via load_library_permanently.
  $LOCAL_LIBS << ' bufferoverflowU.lib'
elsif RbConfig::CONFIG['host_os'] =~ /mingw/i
  # libssp_nonshared provides __stack_chk_guard (randomized at DLL load) and __stack_chk_fail.
  # Static link so there is no libssp-0.dll runtime dependency; export both via
  # .def file (MinGW equivalent of MSVC's /EXPORT:name,DATA) so LLVM's JIT can
  # resolve them via load_library_permanently.
  $LOCAL_LIBS << ' -lssp_nonshared'
  File.write('ssp_exports.def', "EXPORTS\n  __stack_chk_guard DATA\n  __stack_chk_fail\n")
  $DLDFLAGS << ' -Wl,ssp_exports.def'
end

create_makefile('llvm_jit/ffi_llvm_jit')
