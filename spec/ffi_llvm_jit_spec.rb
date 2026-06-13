# frozen_string_literal: true

require 'io/nonblock'

RSpec.describe FFI::LLVMJIT do # rubocop:disable Metrics/BlockLength
  let(:jitlib) do
    Module.new.tap do |mod|
      mod.extend described_class::Library
      mod.ffi_lib FFI::Library::LIBC, FFI::Compiler::Loader.find('ffi_llvm_jit_spec', './ext/ffi_llvm_jit_spec'), 'm'

      mod.attach_llvm_jit_function :strlen, [:string], :size_t
    end
  end

  let(:stdcall_jitlib) do
    Module.new.tap do |mod|
      mod.extend described_class::Library
      mod.ffi_convention :stdcall
      mod.ffi_lib FFI::Library::LIBC, FFI::Compiler::Loader.find('ffi_llvm_jit_spec', './ext/ffi_llvm_jit_spec'), 'm'
    end
  end

  it 'has a version number' do
    expect(FFI::LLVMJIT::VERSION).not_to be nil
  end

  it 'calculates strlen' do
    expect(jitlib.strlen('Hello from FFI LLVM JIT!')).to eq 24
  end

  it 'raises an error when function is not found' do
    expect do
      jitlib.attach_llvm_jit_function :unknown, [:string], :size_t
    end.to raise_error(FFI::NotFoundError)
  end

  it "doesn't invalidate old function pointers" do
    jitlib.attach_llvm_jit_function :strlen2, :strlen, [:string], :size_t
    jitlib.attach_llvm_jit_function :strlen3, :strlen, [:string], :size_t
    expect(jitlib.strlen2('ok')).to eq 2
  end

  it 'passes unsupported functions to FFI::Library' do
    ret = jitlib.attach_function :printf, %i[string varargs], :int
    expect(ret).to be_a(FFI::VariadicInvoker)

    cb = FFI::CallbackInfo.new(FFI.find_type(:int), [FFI.find_type(:pointer), FFI.find_type(:pointer)])
    expect do
      jitlib.attach_llvm_jit_function :qsort, [:pointer, :size_t, :size_t, cb], :void
    end.to raise_error(
      FFI::LLVMJIT::UnsupportedError,
      'Unsupported argument type: #<FFI::Type::Builtin::POINTER size=8 alignment=8>',
    )
    jitlib.attach_function :qsort, [:pointer, :size_t, :size_t, cb], :void

    cb2 = FFI::CallbackInfo.new(FFI.find_type(:int), [FFI.find_type(:bool)])
    expect do
      jitlib.attach_llvm_jit_function :spec_bool_param_ptr, [], cb2
    end.to raise_error(
      FFI::LLVMJIT::UnsupportedError,
      "Unsupported return type: #{cb2.inspect}",
    )
    jitlib.attach_function :spec_bool_param_ptr, [], cb2
    expect(jitlib.spec_bool_param_ptr.call(true)).to eq(42)
    expect(jitlib.spec_bool_param_ptr.call(false)).to eq(24)
  end

  it 'returns a FFI::Function object for compatibility' do
    fn = jitlib.attach_function(:strlen4, :strlen, [:string], :size_t)
    expect(fn).to be_a(FFI::Function)
    expect(jitlib.attached_functions[:strlen4]).to be(fn)
  end

  it 'allows typedefs' do
    expect(jitlib.attach_llvm_jit_function(:strlen5, :strlen, [:string], :size_t)).to be_nil
    jitlib.typedef :size_t, :length
    expect(jitlib.attach_llvm_jit_function(:strlen6, :strlen, [:string], :size_t)).to be_nil
    expect(jitlib.attach_llvm_jit_function(:strlen7, :strlen, [:string], :length)).to be_nil
  end

  it 'ignores explicit type_map option' do
    expect(jitlib.attach_llvm_jit_function(:strlen_tm, :strlen, [:string], :size_t, type_map: {})).to be_nil
    expect do
      jitlib.attach_llvm_jit_function(
        :strlen_tm, :strlen, [:string], :length,
        type_map: { length: FFI::TypeDefs[:size_t] },
      )
    end.to raise_error(TypeError, "unable to resolve type 'length'")
  end

  it 'supports enums' do
    # partial support - not as typedefs, for that dataconverter support is needed
    jitlib.enum [:a, :b, 2]
    jitlib.attach_llvm_jit_function(:spec_enum, %i[int string], :int)
    expect(jitlib.spec_enum(:a, nil)).to eq(0)
    expect(jitlib.spec_enum(:b, nil)).to eq(2)
    expect(jitlib.spec_enum(1, nil)).to eq(1)
    expect do
      # Test non-enum type stays, not converted to nil
      jitlib.spec_enum(1, :c)
    end.to raise_error(TypeError, 'no implicit conversion of Symbol into String')
    expect do
      jitlib.spec_enum(:c, nil)
    end.to raise_error(TypeError, 'no implicit conversion from nil to integer')
    jitlib.enum [:c, 42]
    # test it uses the same object and is affected by further changes
    expect(jitlib.spec_enum(:c, nil)).to eq(42)

    enums = FFI::Enums.new
    enums << FFI::Enum.new([:v, 42])
    expect(jitlib.attach_llvm_jit_function(:spec_enum_cust, :spec_enum, %i[int string], :int, enums: enums)).to be_nil
    expect do
      jitlib.spec_enum_cust(:c, nil)
    end.to raise_error(TypeError, 'no implicit conversion from nil to integer')
    expect(jitlib.spec_enum_cust(:v, nil)).to eq(42)

    includer = Class.new.tap { |cls| cls.include(jitlib) }.new
    expect do
      includer.spec_enum_cust(:c, nil)
    end.to raise_error(TypeError, 'no implicit conversion from nil to integer')
    expect(includer.spec_enum_cust(:v, nil)).to eq(42)
  end

  it 'supports multiple args' do
    expect(jitlib.attach_llvm_jit_function(:strcmp, %i[string string], :int)).to be_nil
    expect(jitlib.attach_llvm_jit_function(:strcasecmp, %i[string string], :int)).to be_nil
    expect(jitlib.strcmp('a', 'b')).to be < 1
    expect(jitlib.strcmp('ABBA', 'abBA')).to be < 1
    expect(jitlib.strcasecmp('ABBA', 'abBA')).to be 0
  end

  it 'handles name clashes' do
    jitlib.attach_llvm_jit_function(:strcmp, %i[string string], :int)
    jitlib.attach_llvm_jit_function(:strcmp, :strcasecmp, %i[string string], :int)
    expect(jitlib.strcmp('ABBA', 'abBA')).to be 0
  end

  it 'handles unsigned values well' do
    # LONG_MIN: -9223372036854775808, LONG_MAX: 9223372036854775807, ULONG_MAX: 18446744073709551615
    # the second argument is actually a char **, but as pointer isn't
    # supported, we use :string and abuse the fact that null pointer
    # is supported both by the function and by the converter.
    # Don't use it in real life code!
    jitlib.attach_llvm_jit_function :strtoul, %i[string string int], :ulong
    jitlib.attach_llvm_jit_function :strtol, %i[string string int], :long
    ulong_max = (2**(FFI.find_type(:ulong).size * 8)) - 1
    expect(jitlib.strtoul(ulong_max.to_s, nil, 0)).to eq ulong_max
    expect(jitlib.strtol('-1', nil, 0)).to eq(-1)
  end

  it 'supports string return values' do
    jitlib.attach_llvm_jit_function :getenv, [:string], :string
    ENV['JIT_ANSWER'] = '42'
    expect(jitlib.getenv('JIT_ANSWER')).to eq('42')
    ENV.delete('JIT_ANSWER')
    expect(jitlib.getenv('JIT_ANSWER')).to be_nil
  end

  it 'supports void return values' do
    # Again, only for testing purposes, don't use it in real life code,
    # first arg should be pointer instead
    # (UPD: this is fine, FFI supports strings and nils where pointer is expected and converts them
    # almost the same way string arg is converted (StringValuePtr, which is less strict than StringValueCStr)
    # so essentially string is a subset of pointer for argument type)
    # and you probably shouldn't modify Ruby strings in C func!
    jitlib.attach_llvm_jit_function :memset, %i[string int size_t], :void
    buf = 42.chr * 42
    expect(jitlib.memset(buf, 34, 34)).to be_nil
    expect(buf).to eq('""""""""""""""""""""""""""""""""""********')
  end

  it "doesn't accept void parameters" do
    expect do
      jitlib.attach_llvm_jit_function :memset, %i[string void size_t], :void
    end.to raise_error(
      FFI::LLVMJIT::UnsupportedError,
      'Unsupported argument type: #<FFI::Type::Builtin::VOID size=1 alignment=1>',
    )
    # Surprisignly, FFI allows that, but
    #   jitlib.memset("", nil, 0)
    # would raise
    #   ArgumentError: Invalid parameter type: 0
  end

  it 'works across forks' do
    read, write = IO.pipe
    lib = jitlib
    pid = Process.fork do
      read.close
      write.write(lib.strlen('Hello from FFI LLVM JIT!'))
      exit!(0)
    end
    write.close
    result = read.read
    Process.wait(pid)
    expect(result).to eq('24')
  end

  it "doesn't allow attaching new functions after fork" do
    read, write = IO.pipe
    pid = Process.fork do
      read.close
      begin
        jitlib.attach_llvm_jit_function :strlen8, :strlen, [:string], :size_t
        write.write('no error raised')
      rescue described_class::UnsupportedError => e
        write.write(e.inspect)
      end
      exit!(0)
    end
    write.close
    result = read.read
    Process.wait(pid)
    expect(result).to eq("#<FFI::LLVMJIT::UnsupportedError: Can't use LLVM after fork>")
  end

  it 'saves errno' do
    jitlib.attach_llvm_jit_function :strtol, %i[string string int], :long
    FFI.errno = 0
    long_max = (2**((FFI.type_size(:long) * 8) - 1)) - 1
    expect(jitlib.strtol('42' * 10, nil, 10)).to eq(long_max)
    expect(FFI.errno).to eq(Errno::ERANGE::Errno)
    FFI.errno = 0
    expect(jitlib.strtol('42', nil, 10)).to eq(42)
    expect(FFI.errno).to eq(0)
  end

  it 'saves errno in blocking calls' do
    jitlib.attach_llvm_jit_function :strtoul, %i[string string int], :ulong
    FFI.errno = 0
    ulong_max = (2**(FFI.type_size(:long) * 8)) - 1
    expect(jitlib.strtoul('42' * 10, nil, 10)).to eq(ulong_max)
    expect(FFI.errno).to eq(Errno::ERANGE::Errno)
    FFI.errno = 0
    expect(jitlib.strtoul('42', nil, 10)).to eq(42)
    expect(FFI.errno).to eq(0)
  end

  it 'saves errno in interrupted blocking call (sleep)' do
    jitlib.attach_llvm_jit_function :sleep_jit, :sleep, %i[uint], :uint, blocking: true

    thread = Thread.new do
      FFI.errno = 0
      begin
        jitlib.sleep_jit(3600)
      rescue RuntimeError
        { errno: FFI.errno }
      end
    end
    sleep(0.1) until thread.stop?
    thread.raise('Wake up')
    expect(thread.value).to eq({ errno: Errno::EINTR::Errno })
  end

  it 'saves errno in interrupted blocking call (read)' do
    jitlib.attach_llvm_jit_function :read_jit, :read, %i[int string size_t], :ssize_t, blocking: true

    read_io, = IO.pipe
    read_io.nonblock = false
    buf = ' ' * 6
    thread = Thread.new do
      FFI.errno = 0
      begin
        # Strings shouldn't be used as buffers, but for spec purposes it's fine
        # (and nothing is actually going to be written to it)
        jitlib.read_jit(read_io.fileno, buf, 4)
      rescue RuntimeError
        { errno: FFI.errno }
      end
    end
    sleep(0.1) until thread.stop?
    thread.raise('Wake up')
    expect(thread.value).to eq({ errno: Errno::EINTR::Errno })
  end

  it 'supports long long' do
    jitlib.attach_llvm_jit_function :strtoull, %i[string string int], :ulong_long
    jitlib.attach_llvm_jit_function :strtoll, %i[string string int], :long_long
    ulong_max = (2**64) - 1
    expect(jitlib.strtoull(ulong_max.to_s, nil, 0)).to eq ulong_max
    expect(jitlib.strtoll('-1', nil, 0)).to eq(-1)
  end

  it 'supports float and double' do
    jitlib.attach_llvm_jit_function :powf, %i[float float], :float
    jitlib.attach_llvm_jit_function :pow, %i[double double], :double

    jitlib.attach_llvm_jit_function :strtof, %i[string string], :float
    jitlib.attach_llvm_jit_function :strtod, %i[string string], :double
    max_float = '340282346638528859811704183484516925440.0000000000000000'
    expect(jitlib.strtof(max_float, nil)).to eq(3.4028234663852886e+38)
    max_double = '179769313486231570814527423731704356798070567525844996598917476803157260780028538' \
                 '760589558632766878171540458953514382464234321326889464182768467546703537516986049' \
                 '910576551282076245490090389328944075868508455133942304583236903222948165808559332' \
                 '123348274797826204144723168738177180919299881250404026184124858368.0000000000000000'
    expect(jitlib.strtof(max_double, nil)).to eq(Float::INFINITY)
    expect(jitlib.strtod(max_double, nil)).to eq(1.7976931348623157e+308)

    expect(jitlib.powf(2.0, 2.0)).to eq 4.0
    expect(jitlib.powf(1.7, 308)).to eq(Float::INFINITY)
    expect(jitlib.pow(2.0, 2.0)).to eq 4.0
    expect(jitlib.pow(1.7, 308)).to eq(1.7**308)
  end

  it 'supports bool' do
    jitlib.attach_llvm_jit_function :spec_bool_param, [:bool], :int
    jitlib.attach_llvm_jit_function :spec_bool_ret, [:int], :bool
    expect(jitlib.spec_bool_param(true)).to eq 42
    expect(jitlib.spec_bool_param(false)).to eq 24
    expect do
      jitlib.spec_bool_param(nil)
    end.to raise_error(TypeError, 'wrong argument type  (expected a boolean parameter)')
    expect(jitlib.spec_bool_ret(42)).to be true
    expect(jitlib.spec_bool_ret(24)).to be false
    expect(jitlib.spec_bool_ret(42.24)).to be true
  end

  it 'supports char' do
    jitlib.attach_llvm_jit_function :spec_char_to_downcase, [:char], :char
    jitlib.attach_llvm_jit_function :spec_uchar_to_downcase, [:uchar], :uchar
    expect(jitlib.spec_char_to_downcase('A'.ord).chr).to eq('a')
    expect(jitlib.spec_uchar_to_downcase('A'.ord).chr).to eq('a')
    expect(jitlib.spec_char_to_downcase('A'.ord - 256).chr).to eq('a')
    expect(jitlib.spec_uchar_to_downcase('A'.ord - 256).chr).to eq('a')
    expect(jitlib.spec_char_to_downcase(127)).to eq(-97)
    expect(jitlib.spec_uchar_to_downcase(127)).to eq(159)
  end

  it 'supports mapped values' do
    mapper = Class.new do
      extend FFI::DataConverter

      native_type FFI::Type::INT

      def self.to_native(value, _context)
        value**2
      end

      def self.from_native(value, _context)
        value * 2
      end
    end

    jitlib.attach_llvm_jit_function :spec_converter, [mapper], mapper
    expect(jitlib.spec_converter(10)).to eq(-200)
  end

  it 'supports stacked mapped values' do
    mapper1 = Class.new do
      extend FFI::DataConverter

      native_type FFI::Type::INT

      def self.to_native(value, _context)
        value**2
      end

      def self.from_native(value, _context)
        value * 2
      end
    end

    mapper2 = Class.new do
      extend FFI::DataConverter

      native_type mapper1

      def self.to_native(value, _context)
        value.to_i
      end

      def self.from_native(value, _context)
        :"#{value}"
      end
    end

    jitlib.attach_llvm_jit_function :spec_converter, [mapper2], mapper2
    expect(jitlib.spec_converter('10')).to eq(:'-200')
  end

  it 'supports blocking calls (sleep)' do
    # sleep(seconds) takes a uint, returns uint (seconds remaining); safe to use as a long-running blocker
    jitlib.attach_llvm_jit_function :sleep_jit, :sleep, [:uint], :uint, blocking: true
    expect(jitlib.sleep_jit(0)).to eq(0)

    thread = Thread.new { jitlib.sleep_jit(3600) } # 1 hour — guaranteed to block
    sleep(0.1) until thread.stop?
    # Without blocking it's just stuck here
    thread.kill
    expect(thread.value).to be_nil

    thread = Thread.new { jitlib.sleep_jit(3600) }
    thread.report_on_exception = false
    sleep(0.1) until thread.stop?
    thread.raise('Ooops')
    expect { thread.value }.to raise_error(RuntimeError, 'Ooops')
  end

  it 'supports blocking calls (read)' do
    jitlib.attach_llvm_jit_function :read_jit, :read, %i[int string size_t], :ssize_t, blocking: true
    read_io, write_io = IO.pipe
    read_io.nonblock = false
    write_io.write('abc')
    buf = ' ' * 6
    expect(jitlib.read_jit(read_io.fileno, buf, 3)).to eq(3)

    thread = Thread.new { jitlib.read_jit(read_io.fileno, buf, 4) }
    sleep(0.1) until thread.stop?
    # Without blocking it's just stuck here
    thread.kill
    expect(thread.value).to be_nil

    thread = Thread.new { jitlib.read_jit(read_io.fileno, buf, 4) }
    thread.report_on_exception = false
    sleep(0.1) until thread.stop?
    thread.raise('Ooops')
    expect { thread.value }.to raise_error(RuntimeError, 'Ooops')
  end

  it 'supports blocking calls with void ret and params' do
    jitlib.attach_llvm_jit_function :spec_blocking_void_ret, [:uint], :void, blocking: true
    jitlib.attach_llvm_jit_function :spec_blocking_void_param, [], :uint, blocking: true
    jitlib.attach_llvm_jit_function :spec_blocking_void_ret_void_param, [], :void, blocking: true

    expect(jitlib.spec_blocking_void_ret(1)).to be_nil
    expect(jitlib.spec_blocking_void_param).to eq(42)
    expect(jitlib.spec_blocking_void_ret_void_param).to be_nil
  end

  it 'supports stdcall' do
    if FFI::Platform::OS =~ /windows|cygwin/ && FFI::Platform::ARCH == 'i386'
      expect(described_class::Library.const_get(:LLVM_STDCALL)).to be_a(Symbol)
    else
      expect(described_class::Library.const_get(:LLVM_STDCALL)).to be_nil
      skip "stdcall isn't supported on #{FFI::Platform::OS}-#{FFI::Platform::ARCH}"
    end
    stdcall_jitlib.attach_llvm_jit_function(
      :test_stdcall, %i[int8 int16 int32 int64 float double], :long,
    )
    expect(stdcall_jitlib.test_stdcall(1, 2, 3, 4, 1.0, 2.0)).to eq(42)

    skip "structures and pointers aren't supported yet"

    struct_ucdp = Class.new(FFI::Struct) do
      layout :a1, :uchar,
             :a2, :double,
             :a3, :pointer
    end
    stdcall_jitlib.attach_llvm_jit_function(
      :test_stdcall_many_params, [
        :pointer, :int8, :int16, :int32, :int64, struct_ucdp.by_value, struct_ucdp.by_ref, :float, :double,
      ], :void,
    )
    s = struct_ucdp.new
    po = FFI::MemoryPointer.new :long
    stdcall_jitlib.test_stdcall_many_params po, 1, 2, 3, 4, s, s, 1.0, 2.0
    expect(po.read_long).to eq 42
  end
end
