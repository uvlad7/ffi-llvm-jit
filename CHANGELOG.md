# Changelog

## [Unreleased] - 0.2.1

### Added

- Platform validation — `attach_llvm_jit_function` raises `UnsupportedError` on unsupported OS or architecture; `attach_function` falls back to FFI silently
- Support for FreeBSD (x86\_64 and aarch64): inline ASM parser initialized at startup (`LLVMInitializeX86AsmParser` / `LLVMInitializeAArch64AsmParser`), required for MCJIT
- Support for i386/i686 Linux
- CI matrix now covers FreeBSD 14.4 (x86\_64 and aarch64 via vmactions), i386/Debian 12 (Docker), and Alpine/musl (Docker)

### Changed

- `UnsupportedError` is now a subclass of `NotImplementedError`

### Fixed

- `INTPTR.from_i` now uses unsigned interpretation for function addresses, fixing a crash on i386 where library addresses can exceed signed 32-bit range
- `extconf.rb` uses `RbConfig.ruby` instead of bare `ruby`, fixing the build on FreeBSD where the Ruby binary is named `ruby33`
- `extconf.rb` auto-detects clang/clang++ via `llvm-config --bindir` instead of hardcoding the binary name; supports `--with-clang-path` / `--with-clangxx-path` / `CLANG` / `CLANGXX` env overrides
- `BLOCKING_CALL_T` falls back to a synthetic struct when the named struct is absent (LLVM 21+ no longer persists named struct types across modules)

## [0.2.0] - 2026-06-08

### Added

- Support for `FFI::DataConverter` mapped types (including stacked converters)
- Support for blocking calls (`blocking: true`) via `rb_rescue2` / `rb_thread_call_without_gvl`
- Support for enum types in `attach_function` / `attach_llvm_jit_function`
- Unresolved JIT symbol check at load time — raises immediately if an external declaration has no address
- `stdcall` call convention is now supported, matching standard FFI behavior
- `UnsupportedError` introduced for unsupported argument/return types in `attach_llvm_jit_function`, replacing `NotImplementedError`
- CI matrix now covers macOS and Ubuntu, with LLVM installed per-platform

### Fixed

- `errno` is now saved after every JIT call, matching standard FFI behavior
- `attach_function` now returns an `FFI::Function` for API compatibility (and stores it in `attached_functions`)
- Fix `bool` type size; now uses `i1` (`LLVM::Int1`)
- Mutex (`LLVM_MUTEX`) guards JIT compilation to prevent concurrent module modification
- Fork safety: attaching new functions after `Process.fork` raises `UnsupportedError` instead of potentially corrupting JIT state

### Changed

- Refactored `attach_function` to delegate unsupported types cleanly to `FFI::Library` instead of conditional branching

## [0.1.0] - 2025-07-04

Initial release. Supports basic scalar types (integers, floats, bool, string, void) and typedefs on Linux x86\_64 and macOS. CI runs on Ubuntu with a single Ruby version.
