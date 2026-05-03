# Canon - A Legal Kernel

A formally grounded, implementation-oriented constitutional kernel built in
Lean 4. The Legal Kernel is a **proof-carrying state transition system** in
which legality is a type, every state change is accompanied by a
machine-checkable proof of admissibility, and global system properties are
guaranteed by inductive invariants rather than by trust in operators.

The full architectural and mathematical blueprint, including the formal
kernel, mathematical guarantees, threat model, and phased implementation
roadmap, lives in:

- [docs/GENESIS_PLAN.md](docs/GENESIS_PLAN.md)

That document is the canonical source of truth for the project's design
philosophy, formal model, and implementation strategy. Start there.

## Status

| Phase | Title              | Status      |
|-------|--------------------|-------------|
| 0     | Foundations        | Complete    |
| 1     | Kernel completion  | Complete    |
| 2+    | (see Genesis Plan) | Not started |

Phase 0 shipped the trusted-core kernel module (`LegalKernel/Kernel.lean`,
the literal §4.12 listing), the canonical `transfer` law
(`LegalKernel/Laws/Transfer.lean`, §4.11 with the self-transfer
sequencing fix), a Lake build, a `lake test` driver, and a GitHub
Actions CI workflow (with SHA-pinned third-party actions) that blocks
on build or test failure.

Phase 1 adds:

- **§8.3 RBMap proof library** in `LegalKernel/RBMapLemmas.lean` —
  pointwise insert lemmas (WU 1.1) and `Nat`-summing fold lemmas
  (WU 1.2 – 1.4), now part of the TCB.
- **§4.3 balance lemmas** in `LegalKernel/Kernel.lean` —
  `getBalance_setBalance_same` and `getBalance_setBalance_other`
  (WU 1.5), proved via the new RBMap library.
- **§4.9 multi-step / law-set reachability extensions** in
  `LegalKernel/Kernel.lean` — `Reachable.refl`, `Reachable.trans`,
  `ReachableViaLaws`, `reachable_of_reachable_via_laws`, and
  `invariant_preservation_via_laws` (WU 1.7 – 1.9).
- **WU 1.6 decidability discipline** documented in
  `docs/decidability_discipline.md`.
- **WU 1.11 TCB-audit tool** (`lake exe tcb_audit`) gated against
  `tcb_allowlist.txt`.
- **WU 1.12 sorry-counting tool** (`lake exe count_sorries`) that
  enforces zero `sorry` in the kernel TCB.
- **WU 1.13 Std-dependency audit** in `docs/std_dependencies.md`,
  enumerating every `Std` lemma the TCB invokes.
- **43 unit tests** across four suites (kernel: 22, rbmap: 8,
  umbrella: 2, transfer: 11) — up from 24 in Phase 0.  Coverage
  includes term-level API-stability checks for every Phase-1
  theorem (`Reachable.refl`, `Reachable.trans`, `ReachableViaLaws`,
  `reachable_of_reachable_via_laws`, `invariant_preservation_via_laws`,
  `sumValues_eq_values_sum`, `sumValues_insert_absent`,
  `sumValues_insert_present`).
- **Extended CI** that runs `lake exe count_sorries` and
  `lake exe tcb_audit` on every PR after `lake build` / `lake test`.

## Quickstart

Canon depends only on a pinned Lean 4 toolchain — no Mathlib, no
external Lake packages.  The toolchain version is read from
`lean-toolchain`.

```bash
# 1. Install elan (Lean's toolchain manager) once per machine.
curl -sSfL https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
  | sh -s -- -y --default-toolchain none

# 2. Pre-fetch the pinned toolchain.
elan toolchain install "$(cat lean-toolchain)"

# 3. Build the project (downloads nothing further).
lake build

# 4. Run the test driver.
lake test
```

A scripted version of the above lives in `scripts/setup.sh`; running
that script makes a fresh checkout buildable without any manual steps.

The CI workflow in `.github/workflows/ci.yml` executes the same `lake
build` and `lake test` on every pull request, so a green CI is the
authoritative signal that Phase-0 acceptance criteria still hold.

## Repository layout

```
canon/
├── lakefile.lean                  -- Lake package config (default target,
│                                     test driver, audit executables).
├── lean-toolchain                 -- pinned Lean version (Section 13.4).
├── tcb_allowlist.txt              -- WU 1.11 TCB import allowlist.
├── Main.lean                      -- placeholder runtime; replaced in Phase 5.
├── Tests.lean                     -- @[test_driver]; runs every test module.
├── LegalKernel.lean               -- umbrella import (kernel + RBMap + laws).
├── LegalKernel/
│   ├── Kernel.lean                -- §4.12; trusted core (TCB).
│   ├── RBMapLemmas.lean           -- §8.3 RBMap proof library (TCB).
│   ├── Laws/
│   │   └── Transfer.lean          -- §4.11; canonical transfer law.
│   └── Test/
│       ├── Framework.lean         -- minimal IO-based test harness +
│       │                             shared `emptyState` helper.
│       ├── KernelTests.lean       -- value-level kernel tests (22).
│       ├── RBMapLemmasTests.lean  -- §8.3 fold-lemma value tests (8).
│       ├── Umbrella.lean          -- umbrella-module smoke tests (2).
│       └── Laws/
│           └── Transfer.lean      -- transfer-law tests (11).
├── Tools/
│   ├── Common.lean                -- shared TCB constants + readFileSafe.
│   ├── TcbAudit.lean              -- WU 1.11 — enforces tcb_allowlist.txt.
│   └── CountSorries.lean          -- WU 1.12 — kernel sorry gate.
├── scripts/
│   └── setup.sh                   -- one-shot toolchain + build script.
├── .github/workflows/
│   └── ci.yml                     -- lake build + lake test +
│                                     count_sorries + tcb_audit.
├── CLAUDE.md                      -- guidance for Claude / coding agents.
└── docs/
    ├── GENESIS_PLAN.md            -- canonical design document.
    ├── decidability_discipline.md -- WU 1.6 — `decPre` discipline.
    └── std_dependencies.md        -- WU 1.13 — Std lemma audit.
```

## Design invariants enforced in Phases 0 – 1

The build mechanically guarantees:

1. **Determinism** — `step_impl` is a Lean function, so its output is
   uniquely determined by its inputs (§5.1).
2. **No silent illegality** — `impl_noop_if_not_pre` proves a failed
   precondition leaves state untouched (§4.6).
3. **Refinement** — `impl_refines_spec` proves every executed step
   satisfies the relational specification (§4.6).
4. **Invariant preservation theorem** — `invariant_preservation` and
   `invariants_compose` are proved at the abstract `Transition` level
   (§4.10), so future laws inherit the global guarantee for free.
5. **Per-law-set invariant preservation** — `invariant_preservation_via_laws`
   restricts the global theorem to a deployed law set `L : List Transition`,
   enabling the §5.3 `total_supply_global` argument once Phase 2 lands.
6. **Multi-step reachability** — `Reachable.refl` and `Reachable.trans`
   establish that the inductive reachability relation is the
   reflexive-transitive closure of single-step legality (§4.9).
7. **Pointwise balance lemmas** — `getBalance_setBalance_same` and
   `getBalance_setBalance_other` discharge the §4.3 obligations that
   every higher-level invariant depends on.

Phase 0's "zero `sorry` in kernel-adjacent code" rule extends in Phase
1 to cover `LegalKernel/RBMapLemmas.lean` (also TCB).  Both
`lake exe count_sorries` and a manual
`grep -rn 'sorry' LegalKernel/` confirm the property.

## Contributing

Read `docs/GENESIS_PLAN.md` end-to-end first — every change beyond the
trivial must reference a work unit (`WU x.y`) and follow the runbooks of
§13.6–§13.9.  Kernel-touching work units require two reviewers.  See
`CLAUDE.md` for the conventions any AI coding agent must follow when
working in this repository.

## License

See [LICENSE](LICENSE).
