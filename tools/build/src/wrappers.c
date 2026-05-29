/* Tiny C shims around libguile macros whose expansions don't survive
   zig translate-c (volatile casts in SCM_BOOL_F / SCM_BYTEVECTOR_CONTENTS
   trip it).  These compile cleanly under gcc and present Zig with plain
   function calls. */

#include <libguile.h>
#include <string.h>

SCM canary_scm_false(void) { return SCM_BOOL_F; }

SCM canary_scm_make_bv(size_t len) {
    return scm_c_make_bytevector(len);
}

void canary_scm_bv_write(SCM bv, const unsigned char *src, size_t len) {
    memcpy(SCM_BYTEVECTOR_CONTENTS(bv), src, len);
}
