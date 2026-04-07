
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct {
    int32_t x;
    int32_t y;
} spec_point_t;

spec_point_t* spec_make_point(int32_t x, int32_t y) {
    spec_point_t *p = malloc(sizeof(spec_point_t));
    p->x = x;
    p->y = y;
    return p;
}


int32_t spec_point_sum(spec_point_t *p) {
    return p->x + p->y;
}

signed int spec_bool_param(bool val)
{
    return val ? 42 : 24;
}

bool spec_bool_ret(signed int val)
{
    return val == 42;
}

signed char spec_char_to_downcase(signed char val) {
    return val + 32;
}

unsigned char spec_uchar_to_downcase(unsigned char val) {
    return val + 32;
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
