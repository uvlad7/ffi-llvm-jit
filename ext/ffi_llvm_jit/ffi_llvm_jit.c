#include "ffi_llvm_jit.h"

#ifdef _MSC_VER
/* Re-export __security_check_cookie from bufferoverflowU.lib so LLVM's JIT can
 * resolve it via load_library_permanently on this DLL. */
#pragma comment(linker, "/EXPORT:__security_check_cookie")
#pragma comment(linker, "/EXPORT:__security_cookie,DATA")
#pragma comment(linker, "/EXPORT:__security_cookie_complement,DATA")
#endif

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "ruby/thread.h"
#include <stdlib.h>
#include <stdio.h>

/* ORC JIT generates __orc_init_func for every COFF module and calls __main from it to
 * run global constructors.  Our bitcode has no global ctors so a no-op suffices.
 * Must be a native C function — ORC may call it from a JIT worker thread, so a Ruby
 * FFI callback would be unsafe here. */
RUBY_FUNC_EXPORTED void __main(void) {}

/* Must match ffi_llvm_jit_blocking_call_t in llvm_bitcode.c (same field order and types). */
typedef struct {
    void *(*call_blocking_function_fn)(void *);
    void *params_store;
    VALUE exc_store;
} ffi_llvm_jit_blocking_call_win_t;

static VALUE
ffi_llvm_jit_win_blocking_inner(VALUE data)
{
    ffi_llvm_jit_blocking_call_win_t *call_data = (ffi_llvm_jit_blocking_call_win_t *)data;
    rb_thread_call_without_gvl(call_data->call_blocking_function_fn, call_data->params_store,
                                (rb_unblock_function_t *)-1, NULL);
    return Qnil;
}

static VALUE
ffi_llvm_jit_win_save_exc(VALUE data, VALUE exc)
{
    VALUE *store = (VALUE *)data;
    *store = exc;
    return Qnil;
}

/* Called from the JIT wrapper instead of rb_rescue2 directly.
 * On MSVC x64, longjmp calls RtlUnwindEx which requires .pdata unwind tables
 * for every frame on the stack (LLVM issue #163503 — JITLink does not register
 * them).  Keeping rb_rescue2 and the blocking call here in native C ensures the
 * rescue path only unwinds through frames that already have .pdata.
 * The JIT outer frame (rb_func) still needs .pdata for non-blocking exceptions
 * (e.g. rb_raise from type-conversion helpers): see jit_register_pdata below. */
RUBY_FUNC_EXPORTED VALUE
ffi_llvm_jit_blocking_call_win(VALUE data)
{
    ffi_llvm_jit_blocking_call_win_t *call_data = (ffi_llvm_jit_blocking_call_win_t *)data;
    call_data->exc_store = 0;
    rb_rescue2(
        ffi_llvm_jit_win_blocking_inner, data,
        ffi_llvm_jit_win_save_exc, (VALUE)&call_data->exc_store,
        rb_eException, (VALUE)0
    );
    return Qnil;
}

#if defined(_WIN64) && defined(_MSC_VER)
#pragma comment(lib, "ntdll.lib")  /* RtlInstallFunctionTableCallback */
/* -----------------------------------------------------------------------
 * Manual .pdata / UNWIND_INFO registration for JIT-compiled functions.
 *
 * JITLink (without ORC runtime) does not call RtlAddFunctionTable for JIT
 * functions (LLVM issue #163503).  Without registered .pdata:
 *   • rb_raise() → longjmp() → RtlUnwindEx() treats the JIT frame as a
 *     leaf (RSP += 8), corrupting the stack pointer.
 *   • The next native frame's .pdata is then read with a wrong RSP, causing
 *     STATUS_BAD_FUNCTION_TABLE and immediate process termination.
 * This affects ALL exceptions raised while a JIT frame is on the stack —
 * not only blocking calls but also type-conversion errors (e.g. passing a
 * Symbol where a string is expected causes rb_raise inside the JIT frame).
 *
 * Fix: after each function_address() call, parse the JIT function's x64
 * prolog, synthesise a minimal UNWIND_INFO, and register it via
 * RtlInstallFunctionTableCallback so RtlUnwindEx can correctly reconstruct
 * RSP when unwinding through the JIT frame.
 *
 * LLJIT may allocate different modules in separate VirtualAlloc regions that
 * are far apart in address space.  A single callback with a fixed 128 MB
 * range cannot cover all of them.  We therefore maintain an array of regions;
 * each new region gets its own RtlInstallFunctionTableCallback and xdata pool.
 * ----------------------------------------------------------------------- */

#define JIT_MAX_REGIONS  16
#define JIT_MAX_FUNCS    1024
#define JIT_REGION_COV   0x08000000ULL  /* 128 MB per callback */
#define JIT_XDATA_REGION (16 * 1024)   /* 16 KB xdata per region (~400 funcs) */
#define JIT_FUNC_EST_SZ  4096

typedef struct {
    DWORD64  base;
    BYTE    *xdata;
    SIZE_T   xdata_used;
} jit_region_t;

typedef struct {
    DWORD64          begin;
    DWORD64          end;
    RUNTIME_FUNCTION rf;   /* BeginAddress/EndAddress/UnwindData: RVAs from region base */
} jit_func_entry_t;

static jit_region_t      g_regions[JIT_MAX_REGIONS];
static volatile LONG     g_region_count = 0;
static jit_func_entry_t  g_jit_funcs[JIT_MAX_FUNCS];
static volatile LONG     g_jit_func_count = 0;

/* Try to allocate size bytes within ~1.75 GB of hint so that all RVAs from
 * the region base to the xdata pool fit in 32 bits.  Scans upward first. */
static PVOID
alloc_near(DWORD64 hint, SIZE_T size)
{
    const DWORD64 RANGE = 0x70000000ULL; /* ±1.75 GB */
    SYSTEM_INFO si;
    GetSystemInfo(&si);
    DWORD64 hi = hint + RANGE;
    if (hi > (DWORD64)(ULONG_PTR)si.lpMaximumApplicationAddress)
        hi = (DWORD64)(ULONG_PTR)si.lpMaximumApplicationAddress;
    DWORD64 lo = (hint > RANGE) ? (hint - RANGE) : 0x10000ULL;

    DWORD64 addr = (hint + 0xFFFF) & ~(DWORD64)0xFFFF;
    while (addr + (DWORD64)size <= hi) {
        PVOID p = VirtualAlloc((PVOID)(ULONG_PTR)addr, size,
                               MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (p) return p;
        MEMORY_BASIC_INFORMATION mbi;
        if (!VirtualQuery((PVOID)(ULONG_PTR)addr, &mbi, sizeof(mbi))) break;
        addr = ((DWORD64)(ULONG_PTR)mbi.BaseAddress + mbi.RegionSize + 0xFFFF)
               & ~(DWORD64)0xFFFF;
    }
    /* Fall back to scanning downward. */
    addr = hint & ~(DWORD64)0xFFFF;
    while (addr > lo + (DWORD64)size) {
        addr -= 0x10000;
        PVOID p = VirtualAlloc((PVOID)(ULONG_PTR)addr, size,
                               MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
        if (p) return p;
    }
    return NULL;
}

/* Called by Windows during RtlUnwindEx / RtlLookupFunctionEntry for any
 * address within a registered region's [base, base + JIT_REGION_COV).
 * The RUNTIME_FUNCTION fields are RVAs from the SAME base that was passed
 * to RtlInstallFunctionTableCallback for that region, so addresses stored
 * at registration time must use the correct per-region base. */
static PRUNTIME_FUNCTION CALLBACK
jit_pdata_cb(DWORD64 ControlPc, PVOID Context)
{
    (void)Context;
    /* Snapshot count before the loop: entries before this index are fully written. */
    LONG count = g_jit_func_count;
    for (LONG i = 0; i < count; i++) {
        if (ControlPc >= g_jit_funcs[i].begin && ControlPc < g_jit_funcs[i].end)
            return &g_jit_funcs[i].rf;
    }
    return NULL;
}

/* Find an existing region covering func_addr, or install a new one.
 * Returns NULL on failure.  Only the Ruby main thread calls this. */
static jit_region_t *
get_or_install_region(DWORD64 func_addr)
{
    LONG count = g_region_count;
    for (LONG r = 0; r < count; r++) {
        if (func_addr >= g_regions[r].base &&
            func_addr <  g_regions[r].base + JIT_REGION_COV)
            return &g_regions[r];
    }

    if (count >= JIT_MAX_REGIONS) {
        fprintf(stderr, "ffi_llvm_jit: too many JIT regions -- .pdata skipped\n");
        fflush(stderr);
        return NULL;
    }

    MEMORY_BASIC_INFORMATION mbi;
    if (!VirtualQuery((PVOID)(ULONG_PTR)func_addr, &mbi, sizeof(mbi))) {
        fprintf(stderr, "ffi_llvm_jit: VirtualQuery failed for 0x%llx\n",
                (unsigned long long)func_addr);
        fflush(stderr);
        return NULL;
    }
    DWORD64 base = (DWORD64)(ULONG_PTR)mbi.AllocationBase;

    jit_region_t *nr = &g_regions[count];
    nr->base       = base;
    nr->xdata      = (BYTE *)alloc_near(func_addr, JIT_XDATA_REGION);
    nr->xdata_used = 0;
    if (!nr->xdata) {
        fprintf(stderr, "ffi_llvm_jit: alloc_near failed for base=0x%llx\n",
                (unsigned long long)base);
        fflush(stderr);
        return NULL;
    }

    /* TableIdentifier low 2 bits must be set (dynamic-table marker per WDK docs).
     * Each region has a unique base so the identifiers are distinct. */
    BOOL ok = RtlInstallFunctionTableCallback(
        base | 3, base, (DWORD)JIT_REGION_COV, jit_pdata_cb, NULL, NULL);
    if (!ok) {
        VirtualFree(nr->xdata, 0, MEM_RELEASE);
        nr->xdata = NULL;
        fprintf(stderr,
                "ffi_llvm_jit: RtlInstallFunctionTableCallback failed base=0x%llx\n",
                (unsigned long long)base);
        fflush(stderr);
        return NULL;
    }
    fprintf(stderr,
            "ffi_llvm_jit: pdata callback installed region=%ld base=0x%llx xdata=0x%llx\n",
            (long)count, (unsigned long long)base,
            (unsigned long long)(ULONG_PTR)nr->xdata);
    fflush(stderr);
    MemoryBarrier();
    InterlockedIncrement(&g_region_count);
    return nr;
}

/* Parse the x64 prolog at func_addr, build a synthetic UNWIND_INFO in the
 * region's xdata pool, and publish the entry so jit_pdata_cb can return it. */
static void
jit_register_pdata(DWORD64 func_addr)
{
    if (g_jit_func_count >= JIT_MAX_FUNCS) return;

    jit_region_t *region = get_or_install_region(func_addr);
    if (!region) return;

    DWORD64 rva_begin = func_addr - region->base;

    /* ---------- Parse the x64 function prolog ----------
     * Handles the patterns LLVM/clang-cl emits for MSVC x64 ABI:
     *   push r8–r15    (REX.B 0x41 + 0x50–0x5F)
     *   push rbx/rbp/rsi/rdi  (0x53/0x55/0x56/0x57)
     *   sub rsp, imm8  (48 83 EC xx)   — covers 8..128 byte frames
     *   sub rsp, imm32 (48 81 EC xx..) — covers larger frames
     */
    const BYTE *c = (const BYTE *)(ULONG_PTR)func_addr;
    int off = 0, prolog_sz = 0;
    BYTE uw[28] = {0};  /* up to 14 two-byte UNWIND_CODE slots */
    int nuw = 0;

    while (off < 28 && nuw + 2 < 14) {
        BYTE b0 = c[off], b1 = c[off+1], b2 = c[off+2];

        /* push r8–r15: REX.B (0x41) + PUSH (0x50–0x5F) */
        if (b0 == 0x41 && b1 >= 0x50 && b1 <= 0x5F) {
            off += 2;
            uw[nuw*2]   = (BYTE)off;
            uw[nuw*2+1] = (BYTE)(0x00 | ((8 + (b1 & 7)) << 4)); /* UWOP_PUSH_NONVOL */
            nuw++;
            continue;
        }
        /* push rbx(53) rbp(55) rsi(56) rdi(57): plain 1-byte PUSH */
        if (b0 >= 0x50 && b0 <= 0x57) {
            off += 1;
            uw[nuw*2]   = (BYTE)off;
            uw[nuw*2+1] = (BYTE)(0x00 | ((b0 & 7) << 4));
            nuw++;
            continue;
        }
        /* sub rsp, imm8: 48 83 EC xx */
        if (b0 == 0x48 && b1 == 0x83 && b2 == 0xEC) {
            int alloc = (int)c[off+3];
            off += 4; prolog_sz = off;
            if (alloc >= 8 && alloc <= 128 && (alloc % 8) == 0) {
                uw[nuw*2]   = (BYTE)off;
                uw[nuw*2+1] = (BYTE)(0x02 | (((alloc / 8) - 1) << 4)); /* UWOP_ALLOC_SMALL */
                nuw++;
            }
            break;
        }
        /* sub rsp, imm32: 48 81 EC xx xx xx xx */
        if (b0 == 0x48 && b1 == 0x81 && b2 == 0xEC) {
            unsigned int alloc =
                (unsigned int)c[off+3]         |
                ((unsigned int)c[off+4] << 8)  |
                ((unsigned int)c[off+5] << 16) |
                ((unsigned int)c[off+6] << 24);
            off += 7; prolog_sz = off;
            unsigned int s8 = alloc / 8;
            if (s8 > 0 && s8 <= 0xFFFFU && (alloc % 8) == 0) {
                /* UWOP_ALLOC_LARGE OpInfo=0: one extra slot holds alloc/8 as uint16 */
                uw[nuw*2]   = (BYTE)off; uw[nuw*2+1] = 0x01; nuw++;
                uw[nuw*2]   = (BYTE)(s8 & 0xFFU); uw[nuw*2+1] = (BYTE)(s8 >> 8); nuw++;
            }
            break;
        }
        break; /* unrecognised instruction — stop */
    }

    /* UNWIND_CODEs must appear in reverse-prolog order (last instruction first). */
    for (int i = 0, j = nuw - 1; i < j; i++, j--) {
        BYTE t0 = uw[i*2], t1 = uw[i*2+1];
        uw[i*2]   = uw[j*2];   uw[i*2+1] = uw[j*2+1];
        uw[j*2]   = t0;         uw[j*2+1] = t1;
    }

    /* ---------- Write UNWIND_INFO into the region's xdata pool ---------- */
    SIZE_T xdata_sz = ((SIZE_T)(4 + nuw * 2) + 3) & ~(SIZE_T)3; /* DWORD-align */
    if (region->xdata_used + xdata_sz > (SIZE_T)JIT_XDATA_REGION) {
        fprintf(stderr, "ffi_llvm_jit: xdata pool full for base=0x%llx\n",
                (unsigned long long)region->base);
        fflush(stderr);
        return;
    }

    BYTE *xdata = region->xdata + region->xdata_used;
    memset(xdata, 0, xdata_sz);
    xdata[0] = 0x01;               /* Version=1, Flags=0 (no exception handler) */
    xdata[1] = (BYTE)prolog_sz;
    xdata[2] = (BYTE)nuw;
    xdata[3] = 0x00;               /* FrameRegister=0, FrameOffset=0 */
    if (nuw > 0) memcpy(xdata + 4, uw, (size_t)nuw * 2);
    region->xdata_used += xdata_sz;

    /* ---------- Fill RUNTIME_FUNCTION with RVAs from region base ---------- */
    DWORD64 xdata_rva = (DWORD64)(ULONG_PTR)xdata - region->base;
    if (xdata_rva >= 0x100000000ULL) {
        fprintf(stderr, "ffi_llvm_jit: xdata RVA overflow for base=0x%llx\n",
                (unsigned long long)region->base);
        fflush(stderr);
        return;
    }

    /* Diagnostic: dump prolog bytes and synthesized UNWIND_INFO to confirm correctness. */
    fprintf(stderr, "ffi_llvm_jit: code[0..15]:");
    for (int b = 0; b < 16; b++) fprintf(stderr, " %02x", c[b]);
    fprintf(stderr, "\nffi_llvm_jit: xdata[0..%zu]:", xdata_sz - 1);
    for (SIZE_T b = 0; b < xdata_sz; b++) fprintf(stderr, " %02x", xdata[b]);
    fprintf(stderr, "\n");
    fflush(stderr);

    LONG idx = g_jit_func_count; /* only this (Ruby main) thread writes; increment last */
    g_jit_funcs[idx].begin           = func_addr;
    g_jit_funcs[idx].end             = func_addr + JIT_FUNC_EST_SZ;
    g_jit_funcs[idx].rf.BeginAddress = (DWORD)rva_begin;
    g_jit_funcs[idx].rf.EndAddress   = (DWORD)(rva_begin + JIT_FUNC_EST_SZ);
    g_jit_funcs[idx].rf.UnwindData   = (DWORD)xdata_rva;

    /* Publish the entry after all fields are written. */
    MemoryBarrier();
    InterlockedIncrement(&g_jit_func_count);

    fprintf(stderr,
            "ffi_llvm_jit: pdata registered func=0x%llx prolog_sz=%d nuw=%d\n",
            (unsigned long long)func_addr, prolog_sz, nuw);
    fflush(stderr);
}

static VALUE
rb_jit_register_pdata(VALUE self, VALUE addr_v)
{
    (void)self;
    jit_register_pdata((DWORD64)NUM2ULL(addr_v));
    return Qnil;
}
#else /* !(_WIN64 && _MSC_VER) */
/* No-op on MinGW/32-bit: longjmp doesn't call RtlUnwindEx there so .pdata
 * registration is not needed.  Method still exists so Ruby can call it
 * unconditionally on win_platform?. */
static VALUE
rb_jit_register_pdata(VALUE self, VALUE addr_v)
{
    (void)self; (void)addr_v;
    return Qnil;
}
#endif /* _WIN64 && _MSC_VER */

#endif /* _WIN32 */

VALUE rb_mFFI;
VALUE rb_mFFILLVMJIT;
VALUE rb_mFFILLVMJITLibrary;

// from https://github.com/ffi/ffi/blob/master/ext/ffi_c/Function.c
static VALUE
attach_rb_wrap_function(VALUE module, VALUE name_val, VALUE func_val, VALUE argc_val, VALUE private)
{
  const char * name = StringValueCStr(name_val);
  VALUE (*func)(ANYARGS);
  int argc;
  func = (VALUE (*)(ANYARGS))NUM2PTR(func_val);
  if (func == NULL)
  {
    rb_raise(rb_eRuntimeError, "trying to attach NULL function");
    return Qnil;
  }
  argc = NUM2INT(argc_val);
  // rb_define_module_function uses rb_define_private_method instead of rb_define_method
  if (RTEST(private)) {
    rb_define_private_method(rb_singleton_class(module), name, func, argc);
    rb_define_private_method(module, name, func, argc);
  } else {
    rb_define_singleton_method(module, name, func, argc);
    rb_define_method(module, name, func, argc);
  }

  return module;
}

RUBY_FUNC_EXPORTED void
Init_ffi_llvm_jit(void)
{
  rb_mFFI = rb_define_module("FFI");
  rb_mFFILLVMJIT = rb_define_module_under(rb_mFFI, "LLVMJIT");
  rb_mFFILLVMJITLibrary = rb_define_module_under(rb_mFFILLVMJIT, "Library");
  rb_define_const(rb_mFFILLVMJITLibrary, "LLVM_STDCALL",
  // That's how FFI hadles it, see https://github.com/ffi/ffi/blob/5b44581847bf167b83db51ac64aa409ccc9cabee/ext/ffi_c/FunctionInfo.c#L233
  // the only supported calling convention other than default is stdcall on x86 windows
#if defined(X86_WIN32)
  rb_intern("x86_stdcall")
#else
  Qnil
#endif
  );
  rb_define_private_method(rb_mFFILLVMJITLibrary, "attach_rb_wrap_function", attach_rb_wrap_function, 4);
#ifdef _WIN32
  rb_define_module_function(rb_mFFILLVMJIT, "jit_register_pdata", rb_jit_register_pdata, 1);
#endif
}
