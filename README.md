# FFI::LLVMJIT

Extends Ruby FFI and uses LLVM to generate JIT wrappers for attached native functions. Works only on MRI.

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

This gem provides `FFI::LLVMJIT::Library` module that intends to be fully compatible with (`FFI::Library`)[https://www.rubydoc.info/gems/ffi/1.17.2/FFI/Library#attach_function-instance_method]. It defines its own `attach_function` method to create a faster JIT fuction instead of a FFI wrapper. The only difference for the caller is that `attach_function` returns `nil` instead of `FFI::Function`/`FFI::VariadicInvoker` when JIT function is created.

Only basic types and none configuration options are supported; in case of unsupported parameters `ffi-llvm-jit` simply calls `ffi`. It also provides `attach_llvm_jit_function` method that raises an exception instead in that case.

Example:

```ruby
require 'ffi/llvm_jit'

module LibCFFI
  extend FFI::LLVMJIT::Library
  ffi_lib FFI::Library::LIBC
end

begin
  LibCFFI.attach_llvm_jit_function :printf, [:string, :varargs], :int
rescue NotImplementedError => e
  e
end
# => #<NotImplementedError: Cannot create JIT function printf>

LibCFFI.attach_function :printf, [:string, :varargs], :int
# => #<FFI::VariadicInvoker:0x0000766a3ac4a200 @fixed=[#<FFI::Type::Builtin::STRING size=8 alignment=8>], @type_map=nil>

begin
  LibCFFI.attach_llvm_jit_function :strcasecmp, [:string, :string], :int, blocking: true
rescue NotImplementedError => e
  e
end
# => #<NotImplementedError: Cannot create JIT function strcasecmp>

LibCFFI.attach_llvm_jit_function :strcasecmp, [:string, :string], :int
# => nil

LibCFFI.strcasecmp('aBBa', 'AbbA')
# => 0
```

## Benchmarks

`FFI::LLVMJIT` can be up to 2x faster when used with fast native functions, where FFI overhead is especially significant.

Below is a benchmark that compares Ruby's `bytesize` method called directly and indirectly with C `strlen` method called via LLVMJIT, C extension and FFI respectively

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

LLVM 17 is used for development, install it via `apt install llvm17-dev` or change `ruby-llvm` version in [ffi-llvm-jit.gemspec](./ffi-llvm-jit.gemspec) if you want to use another version of LLVM.

Then, run `bundle exec rake spec` to run the tests. You can also run `bin/console` for an interactive prompt that will allow you to experiment.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version, update the version number in `version.rb`, and then run `bundle exec rake release`, which will create a git tag for the version, push git commits and the created tag, and push the `.gem` file to [rubygems.org](https://rubygems.org).

## Contributing

Bug reports and pull requests are welcome [on GitHub](https://github.com/uvlad7/ffi-llvm-jit).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
