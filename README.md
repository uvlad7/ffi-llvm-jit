# FFI::LLVMJIT

Extends Ruby FFI and uses LLVM to generate JIT wrappers for attached native functions. Works only on MRI, doesn't support Windows yet.

## Requirements

The gem depends on `ruby-llvm` gem, which requires `llvm` development package to be installed.

On Debian/Ubuntu you can install it with `apt install llvmXX-dev`, where `XX` is a major version of `ruby-llvm` gem.
For other systems, refer to `ruby-llvm` [README](https://github.com/ruby-llvm/ruby-llvm/blob/master/README.md).

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add ffi-llvm-jit
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install ffi-llvm-jit
```

## Usage

This gem provides the `FFI::LLVMJIT::Library` module that intends to be fully compatible with [FFI::Library](https://www.rubydoc.info/gems/ffi/1.17.2/FFI/Library#attach_function-instance_method). It defines its own `attach_function` method to create a faster JIT function instead of a FFI wrapper. When a JIT function is created, `attach_function` still returns an `FFI::Function` for API compatibility (though the method uses the JIT implementation). Use `attach_llvm_jit_function` if you want `nil` on success or an explicit error on failure.

Supported features include basic scalar types, typedefs, enums, `FFI::DataConverter` mapped types (including stacked converters, note that it differs slightly from how FFI [behaves](https://github.com/ffi/ffi/pull/1185)), blocking calls, and errno saving. Unsupported parameters (varargs, callbacks, `:pointer` arguments) cause `attach_function` to fall back to FFI, or raise `FFI::LLVMJIT::UnsupportedError` when using `attach_llvm_jit_function`.

Example:

```ruby
require 'ffi/llvm_jit'

module LibCFFI
  extend FFI::LLVMJIT::Library
  ffi_lib FFI::Library::LIBC
end

# Varargs are unsupported — attach_function falls back to FFI and returns a VariadicInvoker
LibCFFI.attach_function :printf, [:string, :varargs], :int
# => #<FFI::VariadicInvoker:0x0000766a3ac4a200 ...>

# For supported types, attach_function returns FFI::Function (JIT is still used for the actual call)
LibCFFI.attach_function :strlen, [:string], :size_t
# => #<FFI::Function address=0x000070e75099d8a0>

# attach_llvm_jit_function raises FFI::LLVMJIT::UnsupportedError for unsupported types
begin
  LibCFFI.attach_llvm_jit_function :printf, [:string, :varargs], :int
rescue FFI::LLVMJIT::UnsupportedError => e
  e.message
end
# => "Unsupported argument type: #<FFI::Type::Builtin::VARARGS ...>"

# Basic function — JIT compiled, returns nil
LibCFFI.attach_llvm_jit_function :strcasecmp, [:string, :string], :int
# => nil

LibCFFI.strcasecmp('aBBa', 'AbbA')
# => 0
```

### Blocking calls

Pass `blocking: true` to release the GVL while the native function runs, allowing other Ruby threads to execute concurrently. Exceptions raised in other threads during the call are propagated correctly.

```ruby
LibCFFI.attach_llvm_jit_function :sleep, [:uint], :uint, blocking: true

thread = Thread.new { LibCFFI.sleep(3600) }
sleep(0.1) until thread.stop?
thread.kill  # works — GVL is released during the blocking call
```

### Enums

Enum symbols from `enum` declarations are resolved automatically before JIT calls. You can also pass a custom `FFI::Enums` object via the `enums:` option.

```ruby
module LibC
  extend FFI::LLVMJIT::Library
  ffi_lib FFI::Library::LIBC
  enum :open_flags, [:rdonly, 0, :wronly, 1, :rdwr, 2]
  attach_llvm_jit_function :open, [:string, :open_flags], :int
end
LibC.open('/dev/null', :rdonly)  # symbol :rdonly resolved to 0
# => 5

# Custom enums object:
enums = FFI::Enums.new
enums << FFI::Enum.new([:rdonly, 0])
LibC.attach_llvm_jit_function :open2, :open, [:string, :int], :int, enums: enums
```

### DataConverter

Types implementing `FFI::DataConverter` (mapped types) work for both arguments and return values. Stacked converters (where one converter's `native_type` is another `FFI::DataConverter`) are also supported.

> [!WARNING]
> Stacked converters currently [don't work](https://github.com/ffi/ffi/pull/1185) on MRI with the regular FFI gem.

```ruby
Squared = Class.new do
  extend FFI::DataConverter
  native_type FFI::Type::INT
  def self.to_native(value, _ctx) = value**2
  def self.from_native(value, _ctx) = value * 2
end

module Lib
  extend FFI::LLVMJIT::Library
  # ...
  attach_llvm_jit_function :abs, [Squared], Squared
end
Lib.abs(3)  # to_native(3) => 9; C returns abs(9) = 9; from_native(9) => 18
```

### Errno

`FFI.errno` is saved after every JIT call, matching standard FFI behavior.

```ruby
FFI.errno = 0
LibCFFI.strtol('9' * 30, nil, 10)  # overflows
FFI.errno  # => Errno::ERANGE::Errno
```

### Typedefs

Type aliases defined with `typedef` are resolved transparently by the JIT.

```ruby
module Lib
  extend FFI::LLVMJIT::Library
  ffi_lib FFI::Library::LIBC
  typedef :size_t, :length
  attach_llvm_jit_function :strlen, [:string], :length  # :length resolves to :size_t
end
```

> [!NOTE]
> The `type_map:` option is ignored by `ffi-llvm-jit` (as it is by FFI for non-variadic functions). Use `typedef` on the module instead.

### Fork safety

Functions attached before a fork work correctly in the child process. Because `ffi-llvm-jit` uses eager (non-lazy) LLVM compilation, the native wrapper code is fully compiled at attach time and requires no further interaction with the JIT engine in the child.

Attaching new functions after a fork is not supported — LLVM's JIT engine is not fork-safe; `attach_llvm_jit_function` raises `FFI::LLVMJIT::UnsupportedError`, and `attach_function` falls back to FFI silently.

Forking servers (Unicorn, Puma in cluster mode, etc.) work fine in practice because `attach_function` is normally called at require time, and the server forks workers only after the application is fully loaded.

## Benchmarks

`FFI::LLVMJIT` can be up to 2x faster when used with fast native functions, where FFI overhead is especially significant.

Below is a benchmark that compares Ruby's `bytesize` method called directly and indirectly with the C `strlen` method called via LLVMJIT, a C extension, and FFI respectively.

```
Comparison:
         ruby-direct: 15089241.4 i/s
         strlen-ruby: 11353201.8 i/s - 1.33x  slower
 strlen-ffi-llvm-jit: 10839778.2 i/s - 1.39x  slower
         strlen-cext: 10822451.7 i/s - 1.39x  slower
          strlen-ffi:  5058105.5 i/s - 2.98x  slower
```

## Development

After checking out the repo, run `bin/setup` to install dependencies.

LLVM 18 is used for development. Install it via `apt install llvm18-dev`, or change the `ruby-llvm` version in [ffi-llvm-jit.gemspec](./ffi-llvm-jit.gemspec) to use a different version of LLVM.

Then, run `bundle exec rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome [on GitHub](https://github.com/uvlad7/ffi-llvm-jit).

## AI assistance disclosure

The core idea behind this gem — using LLVM's JIT compiler to eliminate FFI call overhead by generating native Ruby-to-C bridge functions at runtime — as well as the entire implementation, architecture, and design decisions are the author's original work.

Claude (Anthropic) was used in an assistive capacity for:

- **Documentation** — drafting and editing README sections, including usage examples and feature descriptions.
- **Specs** — helping write RSpec test cases for newly added features.
- **API discovery** — searching LLVM C API and ruby-llvm documentation to find relevant functions and capabilities. For example, `LLVM::C.add_symbol` — which registers native symbols with the JIT engine's global symbol table before compilation — was found this way, as was `LLVM::C.search_for_address_of_symbol` used to validate that all external declarations are resolved.

All code, including the LLVM IR generation, the blocking call mechanism, the DataConverter pipeline, and the FFI compatibility layer, was written by the author without AI code generation.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
