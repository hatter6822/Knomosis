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

| Phase | Title                       | Status      |
|-------|-----------------------------|-------------|
| 0     | Foundations                 | Complete    |
| 1     | Kernel completion           | Complete    |
| 2     | Economic invariants         | Complete    |
| 3     | Authority layer             | Complete    |
| 4+    | (see Genesis Plan)          | Not started |

Phase 0 shipped the trusted-core kernel module (`LegalKernel/Kernel.lean`,
the literal §4.12 listing), the canonical `transfer` law
(`LegalKernel/Laws/Transfer.lean`, §4.11 with the self-transfer
sequencing fix), a Lake build, a `lake test` driver, and a GitHub
Actions CI workflow (with SHA-pinned third-party actions) that blocks
on build or test failure.

Phase 1 added:

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

Phase 2 (Economic Invariants) adds:

- **§8.1 `TotalSupply` quantity functional and §5.3 framework** in
  `LegalKernel/Conservation.lean` — the per-resource sum-over-actors
  function, the master accounting lemma `totalSupply_setBalance`, the
  `IsConservative` typeclass, the `ConservativeLawSet` structure, and
  the `total_supply_global` theorem (with its typeclass-driven
  corollary `total_supply_global_via_law_set`).
- **§4.11.1 `transfer_conserves`** (WU 2.2 + 2.3) in
  `LegalKernel/Laws/Transfer.lean` — the conservation theorem for the
  `transfer` law, uniform over the distinct-actor and self-transfer
  cases.  The same module ships `transfer_does_not_touch_other_resources`
  (§4.11.2 pointwise), `transfer_other_resource_untouched` (state-level),
  `transfer_conserves_other_resource`, and the
  `transfer_isConservative` typeclass instance.
- **`mint` and `burn` laws** in `LegalKernel/Laws/Mint.lean` and
  `LegalKernel/Laws/Burn.lean` (WU 2.5) — non-conservative balance
  mutators with `decPre := fun _ => inferInstance`, explicit
  `mint_not_conservative` / `burn_not_conservative` non-conservation
  witnesses (WU 2.6), and a per-law cross-resource locality triple
  (state-level `*_other_resource_untouched`, pointwise
  `*_does_not_touch_other_resources`, and the per-resource
  `*_conserves_other_resource`) mirroring the Phase-2 additions to
  `Laws/Transfer.lean`.
- **`freezeResource` / `FrozenForResource`** in
  `LegalKernel/Laws/Freeze.lean` (WU 2.9) — a no-op marker law (with
  the resource id parameter `_r` deliberately ignored at the kernel
  level) plus the per-resource immutability invariant, with
  preservation lemmas for transfer/mint/burn at *different* resources
  (each conditional on a disjointness hypothesis).
- **95 unit tests** across eight suites (kernel: 22, rbmap: 8,
  umbrella: 2, conservation: 15, transfer: 16, mint: 10, burn: 12,
  freeze: 10) — up from 43 in Phase 1.  Coverage includes term-level
  API-stability checks for every Phase-2 theorem and three negative
  regression tests demonstrating that mutations at the *frozen*
  resource genuinely break the snapshot.
- **Extended CI** continues to run `lake exe count_sorries` and
  `lake exe tcb_audit` on every PR; both pass with zero changes to
  `tcb_allowlist.txt` because the Phase-2 modules are non-TCB.

Phase 3 (Authority Layer) adds:

- **§4.13 Action layer with structural injectivity** in
  `LegalKernel/Authority/Action.lean` — the `Action` inductive
  enumerating five deployed action shapes (`transfer`, `mint`,
  `burn`, `freezeResource`, `replaceKey`); the `CompiledAction`
  wrapper carrying both the source `Action` and the kernel
  `Transition`; and `Action.compile_injective` proved as a one-line
  `congrArg` on `CompiledAction.source`.  The wrapper-based design
  sidesteps the genuine non-injectivity at the bare-`Transition`
  level (Phase-2's `freezeResource` ignores its parameter) without
  growing the kernel TCB.
- **§8.2 cryptographic interface** in
  `LegalKernel/Authority/Crypto.lean` — opaque `PublicKey`,
  `Signature`, `Verify`, and `signingInput`.  The `opaque`
  declaration form keeps the kernel's axiom audit at exactly the
  three Lean built-ins; the EUF-CMA security assumption surfaces
  as a *trust assumption* on the deployment-supplied runtime
  adaptor.
- **§8.2 AuthorityPolicy and KeyRegistry** in
  `LegalKernel/Authority/Identity.lean` — the
  `AuthorityPolicy` structure (with `empty`, `unrestricted`,
  `union`, `intersect`, `singleton` combinators) and the
  `KeyRegistry` with `register` / `revoke` / `mergeLeftBiased`
  combinators.  The dynamic registry lives in `ExtendedState`
  rather than `AuthorityPolicy` so that `replaceKey` (WU 3.10) can
  mutate it through `apply_admissible`.
- **§8.5 NonceState and ExtendedState** in
  `LegalKernel/Authority/Nonce.lean` — the per-actor
  next-expected-nonce ledger, the runtime's
  `ExtendedState` (kernel state + nonces + key registry), and the
  headline `expectsNonce_strict_mono` lemma proved in three lines
  via the §8.3 RBMap library.
- **§8.2 + §8.5 admissibility and replay protection** in
  `LegalKernel/Authority/SignedAction.lean` — the `SignedAction`
  structure, the five-condition `Admissible` predicate, the single
  guarded `apply_admissible` entry point, and the headline §8.5.2
  theorems `nonce_uniqueness` (no two distinct admissible actions by
  the same signer share a nonce) and `replay_impossible` (a
  successfully applied signed action cannot be admissible at the
  post-state).
- **WU 3.10 key rotation** — `Action.replaceKey` plus the three
  registry-mutation theorems (`replaceKey_updates_registry`,
  `replaceKey_other_actor_untouched`,
  `non_replaceKey_preserves_registry`) and an end-to-end test chain
  exercising "register K1, rotate to K2, rotate back to K1, verify
  cross-actor isolation".
- **156 unit tests** across twelve suites (kernel: 22, rbmap: 8,
  umbrella: 2, conservation: 15, transfer: 16, mint: 10, burn: 12,
  freeze: 10, authority-action: 19, authority-identity: 14,
  authority-nonce: 11, authority-signed: 17) — up from 95 in
  Phase 2.  Coverage includes term-level API-stability checks for
  every Phase-3 theorem and value-level checks for the algebraic
  cores of `nonce_uniqueness` and `replay_impossible`.
- **CI continues to pass** `lake exe count_sorries` and
  `lake exe tcb_audit` with zero changes to `tcb_allowlist.txt`
  because the Phase-3 modules are non-TCB.

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
authoritative signal that Phase-0/1/2/3 acceptance criteria still hold.

## Repository layout

```
canon/
├── lakefile.lean                  -- Lake package config (default target,
│                                     test driver, audit executables).
├── lean-toolchain                 -- pinned Lean version (Section 13.4).
├── tcb_allowlist.txt              -- WU 1.11 TCB import allowlist.
├── Main.lean                      -- placeholder runtime; replaced in Phase 5.
├── Tests.lean                     -- @[test_driver]; runs every test module.
├── LegalKernel.lean               -- umbrella import (kernel + RBMap + Conservation + laws + authority).
├── LegalKernel/
│   ├── Kernel.lean                -- §4.12; trusted core (TCB).
│   ├── RBMapLemmas.lean           -- §8.3 RBMap proof library (TCB).
│   ├── Conservation.lean          -- §8.1 / §5.3 economic-invariants
│   │                                 framework (Phase 2, non-TCB).
│   ├── Laws/
│   │   ├── Transfer.lean          -- §4.11 transfer + Phase-2 conservation.
│   │   ├── Mint.lean              -- Phase-2 mint law + non-conservation.
│   │   ├── Burn.lean              -- Phase-2 burn law + non-conservation.
│   │   └── Freeze.lean            -- Phase-2 freezeResource + invariant.
│   ├── Authority/
│   │   ├── Crypto.lean            -- Phase-3 PublicKey, Signature,
│   │   │                             opaque Verify (WU 3.4).
│   │   ├── Action.lean            -- Phase-3 Action inductive,
│   │   │                             CompiledAction wrapper, structural
│   │   │                             compile_injective (WU 3.1 + 3.2).
│   │   ├── Identity.lean          -- Phase-3 KeyRegistry +
│   │   │                             AuthorityPolicy + combinators (WU 3.3).
│   │   ├── Nonce.lean             -- Phase-3 NonceState, ExtendedState,
│   │   │                             expectsNonce_strict_mono (WU 3.5).
│   │   └── SignedAction.lean      -- Phase-3 SignedAction, Admissible,
│   │                                 apply_admissible, nonce_uniqueness,
│   │                                 replay_impossible, replaceKey
│   │                                 (WU 3.6 / 3.7 / 3.8 / 3.10).
│   └── Test/
│       ├── Framework.lean         -- minimal IO-based test harness +
│       │                             shared `emptyState` helper.
│       ├── KernelTests.lean       -- value-level kernel tests (22).
│       ├── RBMapLemmasTests.lean  -- §8.3 fold-lemma value tests (8).
│       ├── Umbrella.lean          -- umbrella-module smoke tests (2).
│       ├── ConservationTests.lean -- Phase-2 conservation tests (15).
│       ├── Laws/
│       │   ├── Transfer.lean      -- transfer-law tests (16, incl. Phase 2).
│       │   ├── Mint.lean          -- Phase-2 mint tests (10).
│       │   ├── Burn.lean          -- Phase-2 burn tests (12).
│       │   └── Freeze.lean        -- Phase-2 freeze tests (10).
│       └── Authority/
│           ├── Action.lean        -- Phase-3 Action layer tests (19).
│           ├── Identity.lean      -- Phase-3 KeyRegistry / AuthorityPolicy
│           │                         tests (14).
│           ├── Nonce.lean         -- Phase-3 nonce ledger tests (11).
│           └── SignedAction.lean  -- Phase-3 admissibility / replay /
│                                     key-rotation tests (17).
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

## Design invariants enforced in Phases 0 – 3

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
5. **Per-law-set invariant preservation** —
   `invariant_preservation_via_laws` restricts the global theorem to
   a deployed law set `L : List Transition`, enabling the §5.3
   `total_supply_global` argument that lands in Phase 2.
6. **Multi-step reachability** — `Reachable.refl` and `Reachable.trans`
   establish that the inductive reachability relation is the
   reflexive-transitive closure of single-step legality (§4.9).
7. **Pointwise balance lemmas** — `getBalance_setBalance_same` and
   `getBalance_setBalance_other` discharge the §4.3 obligations that
   every higher-level invariant depends on.
8. **Per-resource conservation** — `transfer_conserves` (§4.11.1)
   proves that `transfer` preserves total supply at the transferred
   resource; `transfer_isConservative` lifts this to the typeclass
   level so deployments can compose conservative laws automatically.
9. **Global supply preservation** — `total_supply_global` (§5.3) and
   its typeclass-driven corollary `total_supply_global_via_law_set`
   conclude per-resource supply conservation across every state
   reachable through a `ConservativeLawSet`.
10. **Explicit non-conservation** — `mint_not_conservative` and
    `burn_not_conservative` formally prove that the supply-changing
    laws cannot be `IsConservative`, so the type-level firewall in
    `ConservativeLawSet` is sound.
11. **Per-resource immutability** — `FrozenForResource` plus the four
    `*_preserves_freeze` lemmas establish that a deployment can
    commit to leaving a resource untouched after freezing it, as long
    as subsequent mutating laws operate on different resources.
12. **Action-layer structural injectivity** — `Action.compile_injective`
    proves that distinct `Action` values necessarily produce distinct
    `CompiledAction` values (§4.13).  The proof is a one-line
    `congrArg` on `CompiledAction.source`, made possible by the
    Phase-3 wrapper design.
13. **Per-actor nonce monotonicity** — `expectsNonce_strict_mono`
    proves that `advanceNonce` strictly increases the actor's
    expected nonce by 1 (§8.5.2), the algebraic core of replay
    protection.
14. **Nonce uniqueness for admissible actions** — `nonce_uniqueness`
    proves that two distinct admissible signed actions by the same
    signer cannot share a nonce (§8.5.2).
15. **Replay impossibility** — `replay_impossible` proves that a
    successfully applied signed action cannot be admissible at the
    post-state (§8.5.2).  This is the kernel's headline replay-
    protection guarantee.
16. **Key rotation correctness** — `replaceKey_updates_registry`,
    `replaceKey_other_actor_untouched`, and
    `non_replaceKey_preserves_registry` together prove that
    `replaceKey actor newKey` mutates exactly the entry for `actor`
    and that no other action mutates the registry at all (WU 3.10).

Phase 0's "zero `sorry` in kernel-adjacent code" rule extends in
Phase 1 to cover `LegalKernel/RBMapLemmas.lean` (also TCB).  Phases 2
and 3 add non-TCB modules under `LegalKernel/`; both
`lake exe count_sorries` (which walks all of `LegalKernel/`) and a
manual `grep -rn 'sorry' LegalKernel/` confirm the zero-sorry
property continues to hold across the entire library.

The Phase-3 authority layer additionally depends on `Verify`, an
opaque uninterpreted function modelling the deployment-supplied
signature scheme.  `Verify` is declared `opaque` rather than `axiom`,
so the kernel's `#print axioms` audit continues to return exactly
the three Lean built-in axioms (`propext`, `Classical.choice`,
`Quot.sound`) for every Phase-3 theorem.  The EUF-CMA security
assumption is a *trust assumption* on the runtime adaptor (Phase 5),
not a Lean axiom.

## Contributing

Read `docs/GENESIS_PLAN.md` end-to-end first — every change beyond the
trivial must reference a work unit (`WU x.y`) and follow the runbooks of
§13.6–§13.9.  Kernel-touching work units require two reviewers; Phase-2+
deployment-infrastructure work units (Conservation, mint/burn/freeze
laws, Authority/*) require one.  See `CLAUDE.md` for the conventions any
AI coding agent must follow when working in this repository.

## License

See [LICENSE](LICENSE).
