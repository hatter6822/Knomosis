/-
LegalKernel — umbrella module.

Re-exports the trusted core (`Kernel.lean`), the §8.3 RBMap proof
library (`RBMapLemmas.lean`, also TCB), and the law set the
deployment chooses to admit.  Phase 0 shipped exactly one law (the
canonical `transfer` of §4.11); Phase 1 adds the §4.3 balance
lemmas, the §4.9 multi-step / law-set reachability extensions, and
the §8.3 fold lemmas.  Phase 2 will add `mint`, `burn`, and
`freeze`; Phase 3 will layer an authority module above this point.

Importing `LegalKernel` is the recommended entry point for downstream
modules and tests; do *not* import `LegalKernel.Kernel` or
`LegalKernel.RBMapLemmas` directly except when you specifically need
the trusted-core surface in isolation (e.g. the `tcb_audit` tool of
WU 1.11).

This file may carry **non-TCB** convenience definitions (build tags,
deployment-wide constants).  Anything *trusted* belongs in
`LegalKernel.Kernel` or `LegalKernel.RBMapLemmas`.
-/

import LegalKernel.Kernel
import LegalKernel.RBMapLemmas
import LegalKernel.Laws.Transfer

namespace LegalKernel

/-- A non-TCB build identification string.  Lets non-kernel callers
    (the `canon` placeholder runtime, the test driver) confirm at link
    time that the kernel module compiled, without exercising any
    actual transition.  Bumped by hand whenever the §4.12 surface
    changes; mirror in §13.8 release-cutting runbook.

    Lives outside `LegalKernel.Kernel` so that the trusted-core file
    contains only the §4.12 listing — the WU-1.11 TCB audit tool can
    therefore enumerate `Kernel.lean` without seeing convenience
    constants. -/
def kernelBuildTag : String := "canon-phase-1-kernel-completion"

end LegalKernel
