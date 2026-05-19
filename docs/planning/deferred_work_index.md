<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Deferred Work — Master Index

This document is the navigator for the nine deferred-work
planning documents authored after the 2026-05-14 comprehensive
audit of deferred work.  It captures the dependency graph
between the workstreams, the recommended landing order, the
total effort estimate, and the connection points to the open-
questions registry.

## Workstream catalogue

Effort numbers are post-expansion (revised after each plan
decomposed complex sub-units into sub-sub-units).  Sub-sub-unit
counts in parentheses give the total granular landing surface.

| Plan | Workstream | Sub-units (sub-sub-units) | Effort | Status | Dependencies |
|------|-----------|----------------------------|--------|--------|--------------|
| `encoder_injectivity_plan.md` | EI — map-backed sub-state encoder injectivity | 8 (~22) | ~10–14 days | **Complete.**  EI.0 – EI.8 all shipped; retires CLAUDE.md footnote 1; lifts `commitExtendedState_subcommits` from bytes-eq to extensional-eq. | independent (Lean-only) |
| `rust_host_runtime_plan.md` | RH — Phase 5 + E-A + E-B + H.10.5 Rust | 8 sub-streams (~40) | ~14–18 wks | the largest workstream; interop deliverables | independent (Rust-only) |
| `smt_cell_proofs_plan.md` | SC — cross-stack soundness for cell proofs | 3 (~15) | ~5–7 wks | closes the only documented soundness gap | independent of EI (uses same `CollisionFree hashBytes`) |
| `ethereum_workstream_g_plan.md` | WG — E-G documentation amendment | 5 (~17) | ~13 days | the only "Not started" workstream | independent (documentation) |
| `chain_level_accounting_plan.md` | CA — §7.6.4 / §7.6.5 inductive promotion | 3 (~13) | ~9 days | retires m-16, the only AR "Defer / n/a" finding | independent (Lean-only) |
| `parameterized_laws_landing_plan.md` | PA — land the drafted parameter substrate | 12 (~52) | ~5 wks | drafted in `parameterized_laws_plan.md` | benefits from EI; not strictly blocking |
| `phase_7_plan.md` | P7 — advanced-capability portfolio | 7 sub-workstreams (~40) | 25+ wks (open-ended) | menu workstream; pick sub-workstreams per release | varies per sub-workstream; see plan §4 |
| `lex_v2_v3_roadmap_plan.md` | LX2 / LX3 — Lex v2 + v3 evolution | 13 (~40) | ~22 wks total | forward-roadmap; demand-driven | LX3.3 triggers kernel amendment |
| `cleanup_and_consolidation_plan.md` | CL — documentation + visibility tidy-up | 5 (~21 with CL.2 itemization) | ~5 days | the project's "tidy-up" PR sequence | CL.4 depends on EI.8 |
| `step_vm_coherence_plan.md` | SVC — L1 step-VM cross-stack coherence + observer terminate wiring | 5 (~25) | ~9 wks (~5–6 wks with 2 engineers) | gates `HonestMove::TerminateOnSingleStep` wiring in the off-chain fault-proof observer; retires `SubmitError::TerminateNotImplemented` | builds on SC (SMT cell proofs); RH-G's observer is the consumer |
| `open_questions.md` | (registry) | 30+ open questions | n/a | living design-decision document | referenced by every plan |
| `deferred_work_index.md` | (this index) | n/a | n/a | navigator | none |

**Total granular surface:** ~260 sub-sub-units across all
workstreams.  Each sub-sub-unit is sized for single-PR review
(≤ ~1 engineer-day at the median, ≤ ~3 days at the largest).
The granular decomposition is the load-bearing property of
these plans: bisection cleanliness, parallel-developer
landing, and rollback safety all depend on it.

## Dependency graph

```
            EI (encoder injectivity)
              │
              │ EI.8 closes footnote 1 + lifts
              │ AR.23 to "Complete" status
              ▼
            CL.4 (AR.23 lift; awaits EI.8)
              ▲
            CL.1, CL.2, CL.3, CL.5 (parallel; no EI dependency)


            CA (chain-level accounting)            independent


            SC (SMT cell proofs)                   independent


            WG (E-G documentation)                 independent


            PA (parameterized laws landing)        independent
              │
              │ PA encoder injectivity follows EI's template
              │ (parameter substrate encoder); not blocking
              ▼

            LX2 / LX3 (Lex roadmap)
              │
              │ LX3.3 (Action.revokeKey) is a kernel touch;
              │ §13.6 two-reviewer rule + Genesis-Plan amendment
              ▼
            kernel TCB delta (only if LX3.3 lands)


            RH (Rust host runtime)
              │
              │ Closes Phase 5 WUs 5.4 / 5.7 / 5.8 / 5.11;
              │ closes E-A / E-B Rust crates;
              │ closes Workstream H WU H.10.5 (observer);
              │ RH-A.1 / RH-A.2 swap-points work alongside SC
              │ (both validated by the same cross-stack corpus
              │ extension)
              ▼

            P7 (Phase 7 portfolio)
              │
              ├── P7.A Capabilities          (depends on Phase 3)
              ├── P7.B Threshold sigs        (depends on Phase 3.4 + PA)
              ├── P7.C ZK proofs             (depends on Phase 5.1)
              ├── P7.D Intent solver         (depends on Phase 3.7)
              ├── P7.E Cross-shard           (depends on Phase 5.5)
              ├── P7.F Schema migration      (depends on Phase 5.12)
              └── P7.G Multi-region          (depends on Phase 5.12)
```

## Recommended landing order (cost-prioritised)

The following ordering minimises blocked work and front-loads
the headline deliverables:

```
Tier 0 (small, parallel, immediate):
  CL.1 documentation drift                              (0.5 day)
  CL.5 LP open-questions registry                       (0.5 day)
  WG.2 README + CLAUDE.md status                        (1 day, can wait for WG.1)

Tier 1 (medium, parallel, weeks):
  CA chain-level accounting                             (5–8 days; closes m-16)
  WG Workstream G documentation                         (8–14 days; closes "Not started")
  CL.2 stale comments                                   (2 days; parallel to others)
  CL.3 AR.18 visibility                                 (1 day)

Tier 2 (substantive, parallel-after-precursors, weeks):
  EI encoder injectivity                                (~9–16 days; retires footnote 1)
  SC SMT cell proofs                                    (~6–9 weeks; closes soundness gap)

Tier 3 (large, post-EI, parallel-when-resources-allow):
  PA parameterized laws landing                         (~6–10 weeks)
  CL.4 AR.23 lift to "Complete"                         (0.5 day; gated on EI.8)
  RH Rust host runtime                                  (~14–22 weeks)

Tier 4 (forward-roadmap, demand-driven):
  LX2 Lex v2                                            (~8 weeks)
  LX3 Lex v3                                            (~18 weeks)
  P7 Phase 7 (pick sub-workstreams)                     (20+ weeks)
```

Total minimum effort (Tier 0 + Tier 1 + Tier 2 + CL.4): ~14–22
calendar weeks for one full-time engineer.  Tier 3 (PA + RH)
adds ~20–32 weeks.  Tier 4 is open-ended.

## What this index does *not* track

  * **Detailed acceptance criteria.**  Each plan owns its
    acceptance criteria; this index is navigation only.
  * **Reviewer assignments.**  Per-workstream.
  * **Open questions resolutions.**  Owned by
    `open_questions.md`; resolved questions move to its §9.
  * **PR-by-PR status.**  Live in PR labels and the
    `audit_remediation_plan.md` §15C.2-style status tables of
    the relevant plan.

## Status-tracking rule

Each plan's "Status" section is the single source of truth for
that workstream.  When a sub-unit lands:
  1. Update the plan's status (mark sub-unit "Complete").
  2. If the sub-unit is the last in the workstream, update
    this index's "Status" column.
  3. If the workstream closes a CLAUDE.md or GENESIS_PLAN
    deferral note, retire that note in the same PR.

## Connection to CLAUDE.md / GENESIS_PLAN.md status tables

| Plan completes | Updates in CLAUDE.md | Updates in GENESIS_PLAN.md |
|----------------|----------------------|----------------------------|
| EI | footnote 1 retired; headline-theorem row added | §15B.1 / §15C.7 |
| RH | "Phase 5 ... Rust-host WUs ... deferred" note retired; "Rust off-chain observer deferred" note retired; E-A / E-B Rust adaptor notes retired | §12 Phase 5 table; §15B (observer) |
| SC | "Rust off-chain observer deferred" note partially retired (operator-mitigation portion); cell-proof headline row added | §15B (deferral note) |
| WG | "E-G | Not started" → "Complete" | new §15 chapter |
| CA | "Workstream E-C ... chain-level §7.6.4 / §7.6.5 follow-up" note retired; new headline rows | §7.6.4 / §7.6.5 / m-16 |
| PA | new "PA | Complete" row in phase table | new §14 or §15.X chapter for parameter substrate |
| LX2 | "Lex roadmap" v2 entry "Complete" | none direct |
| LX3 | "Lex roadmap" v3 entry "Complete" | kernel amendment for LX3.3 |
| CL | various comment / docstring cleanup | minor §15C.6 retirement (post-CL.3) |
| P7 | per-sub-workstream rows | §12 / new chapters |

## References

  * `docs/planning/encoder_injectivity_plan.md`
  * `docs/planning/rust_host_runtime_plan.md`
  * `docs/planning/smt_cell_proofs_plan.md`
  * `docs/planning/ethereum_workstream_g_plan.md`
  * `docs/planning/chain_level_accounting_plan.md`
  * `docs/planning/parameterized_laws_landing_plan.md`
  * `docs/planning/phase_7_plan.md`
  * `docs/planning/lex_v2_v3_roadmap_plan.md`
  * `docs/planning/cleanup_and_consolidation_plan.md`
  * `docs/planning/open_questions.md`
  * `CLAUDE.md` — canonical status tables.
  * `docs/GENESIS_PLAN.md` — canonical design + roadmap.

---

**End of index.**  Each workstream plan stands alone; this
document weaves them into a single landing strategy.
