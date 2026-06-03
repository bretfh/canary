/* C shims around libguile macros whose expansions don't survive
   zig translate-c.  Same pattern as guile-webui/src/wrappers.c and
   canary tools/build/src/wrappers.c.  These compile under gcc and
   present Zig with plain function calls. */

#include <libguile.h>

SCM cn_scm_undefined(void)    { return SCM_UNDEFINED; }
SCM cn_scm_unspecified(void)  { return SCM_UNSPECIFIED; }
int cn_scm_is_undefined(SCM x) { return SCM_UNBNDP(x); }
