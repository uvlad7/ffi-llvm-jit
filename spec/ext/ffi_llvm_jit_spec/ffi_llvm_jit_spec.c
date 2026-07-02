
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

signed int spec_bool_param(bool val)
{
    return val ? 42 : 24;
}

typedef signed int (*bool_param_ptr)(bool);
bool_param_ptr spec_bool_param_ptr() {
    return spec_bool_param;
}

bool spec_bool_ret(signed int val)
{
    return val == 42;
}

int spec_enum(int val, char* str) {
    return val;
}

signed int spec_converter(signed int val)
{
    return -val;
}

signed char spec_char_to_downcase(signed char val) {
    return val + 32;
}

unsigned char spec_uchar_to_downcase(unsigned char val) {
    return val + 32;
}

void spec_blocking_void_ret(unsigned int seconds) {
}

unsigned int spec_blocking_void_param(void) {
    return 42;
}

void spec_blocking_void_ret_void_param(void) {
}

#if defined(_WIN32) && !defined(_WIN64)
struct StructUCDP {
  unsigned char a1;
  double a2;
  void *a3;
};

long __stdcall test_stdcall(char a2, short int a3, int a4, __int64 a5,
            float a8, double a9) {
                return 42L;
}

void __stdcall test_stdcall_many_params(long *a1, char a2, short int a3, int a4, __int64 a5,
            struct StructUCDP a6, struct StructUCDP *a7, float a8, double a9) {
                *a1 = 42L;
}
#endif

unsigned long int factorial(unsigned int n) {
    if (n <= 1) {
        return 1;
    }
    else {
        return n * factorial(n - 1);
    }
}

// When called as a JIT blocking call (blocking: true), this runs inside
// rb_thread_call_without_gvl. Calling an FFI::Function callback from there
// triggers FFI's trampoline → rb_thread_call_with_gvl → blocking_region_end
// → rb_thread_check_ints, which processes any pending thread.raise interrupt.
// Used by spec/gvl_reentry_repro.rb to reproduce the exception-propagation
// bug cross-platform (no APC / Windows-specific code required).
void spec_spin_callback(uint64_t cb_addr, uint64_t data_addr, uint32_t iterations) {
    void (*cb)(uint64_t) = (void (*)(uint64_t)) (uintptr_t) cb_addr;
    for (uint32_t i = 0; i < iterations; i++) {
        cb(data_addr);
    }
}

// Calls cb(data) exactly once, synchronously, and returns the callback's result.
// Used to test whether an exception raised inside a callback propagates back to
// the caller (vs. the async thread.raise path tested by spec_spin_callback).
uint64_t spec_invoke_callback(uint64_t cb_addr, uint64_t data_addr) {
    uint64_t (*cb)(uint64_t) = (uint64_t (*)(uint64_t)) (uintptr_t) cb_addr;
    return cb(data_addr);
}
