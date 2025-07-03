
#include <stdbool.h>

int spec_bool_param(bool val)
{
    return val ? 42 : 24;
}

bool spec_bool_ret(int val)
{
    return val == 42;
}
