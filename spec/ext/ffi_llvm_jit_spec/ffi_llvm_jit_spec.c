
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

// Stored-callback variant: the callback address is saved globally by spec_store_callback
// (called via regular FFI) and invoked by spec_invoke_stored_callback (called via JIT).
// Tests JIT exception propagation when the callback is not passed as a parameter
// (JIT does not support pointer types yet).
// Note: if the callback raises, save_callback_exception zeroes cb->retval, so
// spec_invoke_stored_callback returns 0 before the exception is re-raised.
static uint64_t (*spec_global_callback)(uint64_t) = NULL;

void spec_store_callback(uint64_t cb_addr) {
    spec_global_callback = (uint64_t (*)(uint64_t)) (uintptr_t) cb_addr;
}

uint64_t spec_invoke_stored_callback(uint64_t data_addr) {
    return spec_global_callback(data_addr);
}
