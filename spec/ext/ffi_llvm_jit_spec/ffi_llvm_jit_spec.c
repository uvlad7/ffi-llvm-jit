
#include <stdbool.h>

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
