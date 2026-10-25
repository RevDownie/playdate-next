#ifdef __arm__
// newlib expects <stddef.h> to provide wint_t via __need_wint_t, which translate-c's stddef.h does not
typedef unsigned int wint_t;
#endif

#include "pd_api.h"
