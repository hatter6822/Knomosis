<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# L1 Step-VM Cross-Stack Coherence — Engineering Plan

This document plans the work needed to (a) extend the cross-stack
step-VM coherence corpus from the current 2 variants (Transfer +
Mint) to the full 19 `Action` variants, and (b) wire the off-chain
fault-proof observer's [`HonestMove::TerminateOnSingleStep`]
through to the L1 `terminateOnSingleStep(uint256, uint8, bytes,
uint64, CellProof[], bytes32)` calldata builder.

Closing this workstream retires the
`SubmitError::TerminateNotImplemented` deferral in
`runtime/canon-faultproof-observer/src/submitter.rs`, the matching
`"deferred RH-G follow-up work"` comment in
`src/observer.rs::maybe_play_move`, and the implicit gap noted in
the audit-pass-4-round-6 closeout of `CLAUDE.md` (the observer can
play 3 of 4 move types end-to-end; the 4th, terminate-on-single-
step, requires this plan's work to land).

## Background

### What's currently shipped

  * **Lean side.**  `LegalKernel/FaultProof/SolidityStepVMCommit.lean`
    ships a complete Lean mirror of the L1's `_stepXX` hash recipe
    for all 19 variants (`stepCommitTransfer` through
    `stepCommitFaultProofResolution`).  These are byte-equivalent
    to the Solidity `CanonStepVM._stepXX` functions under
    `isKeccak256Linked = true`.

    `LegalKernel/FaultProof/Coherence.lean` ships the headline
    coherence theorem `recomputeCommitment_coherent_with_kernelOnlyApply`
    which states that `recomputeCommitment es st =
    commitExtendedState (applyCellWrites_to_state es st)` — i.e.,
    the L1's step-VM hash equals the canonical state commit AS
    LONG AS the L1's hash recipe reproduces what `commitExtendedState`
    computes.

  * **Solidity side.**  `solidity/src/contracts/CanonStepVM.sol`
    ships `executeStep(preCommit, actionKind, actionFields, signer,
    cellProofs) → bytes32` with all 19 step functions implemented.
    Each `_stepXX` reads its specific actionFields layout (e.g.,
    Transfer's 32-byte `r || sender || receiver || amount`),
    reconstructs the post-state cells from the supplied cellProofs,
    and emits the recomputed commit via `keccak256(abi.encodePacked
    (preCommit, TAG_XX, ...))`.

  * **Cross-stack fixture corpus.**
    `solidity/test/CrossCheck/fixtures/step_vm.json` ships 48
    cross-stack-tested entries: 24 Transfer + 24 Mint.  Each entry
    carries:
    - `fixtureId` (string)
    - `actionVariant` ("transfer" or "mint")
    - `preStateCommitHex` (32 bytes hex)
    - `actionKind` (uint8)
    - `actionFieldsHex` (hex-encoded packed bytes)
    - `signer` (uint64)
    - `cellProofs` (array of cell-proof tuples)
    - `expectedPostStateCommitHex` (the canonical
      `commitExtendedState ∘ kernelOnlyApply`)
    - `expectedStepVMCommitHex` (the L1's recomputed hash)

    Under `isKeccak256Linked = true` these two columns are
    byte-equal — pinning cross-stack coherence for Transfer + Mint.

  * **Off-chain observer.**  The Rust observer
    (`runtime/canon-faultproof-observer/`) can compute the next
    honest move (`compute_next_move`) and submit calldata for 3
    of 4 move types: `Submit`, `RespondAgree`, `RespondDisagree`.
    `TerminateOnSingleStep` short-circuits at
    `encode_calldata` → `Err(SubmitError::TerminateNotImplemented)`
    because the observer has no way to (a) compute the L1-format
    `actionFields` for the action at the single-step pivot and
    (b) bundle them with the cell proofs that the L1 expects.

### What's missing

  1. **Cross-stack fixture coverage for variants 2 – 18.**  17
     variants have NO cross-stack-tested coherence:
     - 2 Burn, 3 FreezeResource, 4 ReplaceKey, 5 Reward,
       6 DistributeOthers, 7 ProportionalDilute (the "structured"
       group — actionFields decode to specific typed slots)
     - 8 Dispute, 9 DisputeWithdraw, 10 Verdict, 11 Rollback
       (the dispute-pipeline group — opaque actionFields hashed
       as a whole)
     - 12 RegisterIdentity (structured + variable-length pk)
     - 13 Deposit, 14 Withdraw (structured + bridge-flavoured)
     - 15 DeclareLocalPolicy, 16 RevokeLocalPolicy (opaque)
     - 17 FaultProofChallenge, 18 FaultProofResolution (opaque)

  2. **No `actionFieldsForL1 : Action → ByteArray` encoder in
     Lean.**  The Solidity side defines the L1 actionFields
     format implicitly via the `_stepXX` decoders.  The Lean side
     has no canonical encoder that produces these bytes from an
     `Action` value.  Without it, the off-chain observer has no
     way to construct calldata that round-trips through the L1.

  3. **No `canon export-terminate-bundle LOG IDX` subcommand.**
     The existing `canon export-cell-proofs LOG IDX SIGNER` emits
     only the cell-proof array — not the actionFields, signer,
     action kind, or claimed post-commit.  A new subcommand is
     needed.

  4. **No `TerminateBundleOracle` trait in Rust.**  The observer
     would need to query the canon subprocess for the terminate
     bundle at a given pivot index.  No abstraction exists.

  5. **No observer-side dispatch for `HonestMove::TerminateOnSingleStep`.**
     Currently `encode_calldata` returns `TerminateNotImplemented`.
     Observer logs + skips.  Need to fetch bundle + call
     `encode_terminate_full_calldata`.

  6. **Open soundness question for opaque variants.**
     Variants 8 – 11 and 15 – 18 use opaque-actionFields hashing
     in their L1 step recipes:

     ```solidity
     return keccak256(abi.encodePacked(
         preStateCommit, TAG_DISPUTE, keccak256(actionFields), signer));
     ```

     The Lean mirror (`stepCommitDispute`) reproduces this hash.
     But `commitExtendedState(postState)` for these actions is
     NOT obviously equal to this hash — `commitExtendedState`
     uses the 5-component state-aggregate recipe, not a
     preCommit-plus-action-hash form.  The coherence theorem
     `recomputeCommitment_coherent_with_kernelOnlyApply` requires
     that **the L1's recomputation equals the canonical state
     commit**, which means the canonical commit must already
     embed the action's pre/post effects in a way that the L1's
     hash reproduces.

     For STRUCTURED variants (e.g., Transfer), the L1 recomputes
     the post-state cell values from the cellProofs + actionFields
     and embeds them in the hash — this is provably equal to
     `commitExtendedState(postState)` if `commitExtendedState`
     also folds the cells in the same order.

     For OPAQUE variants, the L1's hash depends ONLY on
     `keccak256(actionFields) + signer + preCommit + TAG`.  This
     can only equal `commitExtendedState(postState)` if the
     canonical commit's relationship to the action is purely a
     function of (preCommit, action_hash, signer, tag) — a much
     stronger architectural property than the cell-update
     coherence shown for structured variants.

     Whether this property holds for the existing 9 opaque
     variants is **the central open question** this plan
     resolves.  The likely answer is "yes, but it requires
     proving a per-variant `kernel_only_apply_commit_eq_step_vm_hash`
     theorem and threading it through the existing
     `recomputeCommitment_coherent_with_kernelOnlyApply`
     instantiation."  The plan's first sub-unit confirms this.

## Status

  * **Workstream prefix:** `SVC` (Step-VM Coherence).  Five
    sub-units:
    - **SVC.1** Cross-stack-coherence theorem extension to all
      19 variants — **Complete** (per-variant dispatch
      coherence lemmas shipped; opaque-variant architectural
      decision = Option B, recorded in the module docstring).
    - **SVC.2** Lean `actionFieldsForL1` encoder + per-variant
      coherence corollaries — **Complete**.
    - **SVC.3** `canon export-terminate-bundle LOG IDX`
      subcommand — **Complete**.
    - **SVC.4** Rust `TerminateBundleOracle` trait +
      `SubprocessTruthOracle` implementation — **Complete**.
    - **SVC.5** Observer integration + cross-stack fixture
      widening + chaos coverage — **Complete**.  Cross-stack
      corpus widened from 48 → 218 entries (24 Transfer + 24
      Mint + 17 new variants × 10 each, exceeding the plan's
      ~190 target).  Solidity-side per-variant byte-
      equivalence tests added for opaque variants +
      freezeResource + replaceKey + registerIdentity
      (the cell-free variants that work in empty state).
  * **Effort estimate:** 8 – 12 calendar weeks for one Lean +
    Solidity + Rust engineer.  Parallelisable into 5 – 8 weeks
    if Lean (SVC.1, SVC.2) and Rust (SVC.3 – SVC.5) are split
    after SVC.1.a (which gates everything).
  * **Build-posture target:** Lean side passes all existing
    gates plus the new headline theorem
    `step_vm_coherent_with_kernel_apply` (a per-variant
    generalisation of `recomputeCommitment_coherent_with_kernelOnlyApply`).
    Solidity side adds 17 new CrossCheck fixtures.  Rust
    observer adds the bundle oracle + terminate-on-single-step
    integration tests.
  * **TCB delta:** zero.  The new theorems live in
    `LegalKernel/FaultProof/StepVMCoherence.lean` (non-TCB).
  * **Trust-assumption delta:** zero.  Same `CollisionFree
    hashBytes` hypothesis as the existing chain.

## Architecture

### Lean side

```
LegalKernel/
└── FaultProof/
    ├── SolidityStepVMCommit.lean  (existing) — L1 hash recipe mirror
    ├── Coherence.lean              (existing) — recomputeCommitment + headline
    ├── Commit.lean                 (existing) — commitExtendedState
    ├── StepVMCoherence.lean        (new ~600 lines)
    │   ├── actionFieldsForL1 : Action → ByteArray
    │   ├── actionKindByte : Action → UInt8
    │   ├── per-variant coherence lemmas (19 of them)
    │   └── step_vm_coherent_with_kernel_apply (headline)
    ├── TerminateBundle.lean        (new ~150 lines)
    │   ├── TerminateBundle structure
    │   ├── buildTerminateBundle : ExtendedState → LogEntry → TerminateBundle
    │   └── well-formedness theorems
    └── ...

Test/Bridge/CrossCheck/
├── StepVM.lean              (existing — 48 entries Transfer + Mint)
└── StepVMAllVariants.lean   (new ~800 lines — 19 × N entries)

Main.lean
└── cmdExportTerminateBundle (new ~80 lines)
```

### Rust side

```
runtime/canon-faultproof-observer/
├── src/
│   ├── strategy.rs
│   │   ├── trait TerminateBundleOracle (new)
│   │   ├── struct TerminateBundle (new)
│   │   ├── impl TerminateBundleOracle for SubprocessTruthOracle (new)
│   │   └── impl TerminateBundleOracle for MemoryTerminateBundleOracle (new, test-only)
│   ├── observer.rs
│   │   └── maybe_play_move: handle HonestMove::TerminateOnSingleStep (modified)
│   └── submitter.rs
│       └── encode_calldata: remove TerminateNotImplemented for HonestMove::TerminateOnSingleStep (modified)
└── tests/
    ├── real_canon_export_terminate_bundle.rs (new)
    ├── observer_terminate_integration.rs (new)
    └── ...
```

## Sub-units

### SVC.1 — Cross-stack coherence theorem extension

**Scope.**  `LegalKernel/FaultProof/StepVMCoherence.lean` (new).

**Goal.**  Prove
`step_vm_coherent_with_kernel_apply` for all 19 `Action` variants:

```lean
theorem step_vm_coherent_with_kernel_apply
    (es : ExtendedState) (entry : LogEntry) :
    let post := kernelOnlyApply es entry
    let preCommit := commitExtendedState es
    let action := entry.signedAction.action
    let signer := entry.signedAction.signer
    let actionFields := actionFieldsForL1 action
    let kind := actionKindByte action
    -- The L1's hash recipe for this variant equals the canonical
    -- post-state commit.  The exact equation is per-variant; we
    -- factor through a per-variant lemma + dispatch on `kind`.
    stepVMHash preCommit kind actionFields signer (extractCellWrites es entry) =
      commitExtendedState post
```

**Implementation steps.**

  1. **SVC.1.a — Foundation lemmas.**  Define helper definitions
     mirroring the L1's per-variant hash recipes (already in
     `SolidityStepVMCommit.lean`).  Add `stepVMHash` as the
     dispatch function `(kind : UInt8) → ByteArray → UInt64 →
     CellWrites → ByteArray` that the headline theorem calls.

  2. **SVC.1.b — Structured-variant coherence (variants 0 – 7,
     12, 13, 14).**  Per-variant theorem:
     `step_vm_coherent_transfer`, `step_vm_coherent_mint`, etc.
     The proof goes by:
     - Unfold `kernelOnlyApply` to expose the new cell values.
     - Unfold `commitExtendedState` to expose its hashing recipe.
     - Show that the L1's hash recipe (with appropriately decoded
       fields + post-cell values from `cellProofs`) equals the
       canonical hash recipe.

     For Transfer + Mint this is already implicitly proven by the
     existing cross-stack fixtures; explicit theorems make it
     formal.

  3. **SVC.1.c — Opaque-variant coherence (variants 8 – 11,
     15 – 18).**  These are the architecturally-interesting cases.
     The L1's hash for, e.g., Dispute is:
     ```
     keccak256(preCommit || TAG_DISPUTE || keccak256(actionFields) || signer)
     ```
     For this to equal `commitExtendedState(postState)`, the
     canonical commit must be redefined OR `kernelOnlyApply`'s
     dispute path must leave the state-aggregate in a form that
     reproduces this hash.

     **Hypothesis to test:** Dispute (and the other 8 opaque
     variants) do not modify the state's balance/nonce/registry/
     bridge-consumed/bridge-pending sub-states.  They only emit
     events.  So `postState ≅ preState` (extensional equality
     after removing the event log, which `commitExtendedState`
     doesn't include).  Therefore `commitExtendedState(postState)
     = commitExtendedState(preState) = preCommit`.

     But the L1's Dispute hash is **not** `preCommit` — it's
     `keccak256(preCommit || tag || action_hash || signer)`.
     These are not equal.  **This is the core soundness gap.**

     **Resolution candidates:**

     - **A.**  Redefine `commitExtendedState` to include an
       "action accumulator" component that the L1's hash
       reproduces.  Requires changing the kernel's commit recipe
       — a TCB-touching change.
     - **B.**  Accept that opaque variants' L1 commit differs
       from the canonical commit, and tighten the L1 step VM's
       contract to: "the L1's `_stepDispute` returns a
       *transcript-relative* commit, not the canonical state
       commit."  Then `recomputeCommitment_coherent_with_kernelOnlyApply`
       holds only for structured variants; opaque variants need
       a separate theorem
       `step_vm_dispute_transcript_consistent_with_action_hash`.
     - **C.**  Restrict the L1's fault-proof game to TERMINATE
       only on structured-variant actions.  If the single-step
       pivot lands on an opaque action, the game settles via
       timeout instead.  This is the path-of-least-resistance:
       the observer DOES NOT terminate on opaque actions; the
       sequencer must claim the timeout.

     **Recommended:** Option C for the off-chain observer; the
     L1's step VM accepts terminate on opaque variants but the
     observer never submits one (the chain will catch the
     opposition trying to cheat via the bisection rounds, which
     ARE coherent for opaque variants because both sides agree
     on `keccak256(actionFields)`).

     **Open Question OQ-SVC-1:** Confirm Option C is sound.  The
     bisection game's halt-on-mismatch property requires that
     the canonical commits at each log index can be compared
     pointwise.  For opaque variants, the L1 step VM's hash
     differs from the canonical commit.  Does the bisection
     still halt correctly?

  4. **SVC.1.d — Headline theorem.**  After SVC.1.b + SVC.1.c
     resolve, prove the combined statement.

**Acceptance criteria.**

  * `step_vm_coherent_with_kernel_apply` proved for all 19
    variants OR explicit per-variant lemmas + a clear
    architectural decision recorded for opaque variants.
  * `#print axioms` ⊆ `[propext, Classical.choice, Quot.sound]`.
  * `lake build` + `lake test` green.

**Risk.**  HIGH.  The opaque-variant coherence question may
require architectural changes to `commitExtendedState`'s recipe
or a clarification of the L1's step-VM contract.  Decision
SHOULD be ratified by the two-reviewer TCB-change gate before
landing.

**Effort.**  ~3 engineer-weeks (assuming Option C is acceptable;
~5 weeks if Option A is needed).

### SVC.2 — Lean `actionFieldsForL1` encoder

**Scope.**  `LegalKernel/FaultProof/StepVMCoherence.lean` (within
the file from SVC.1).

**Goal.**  Define a canonical encoder `actionFieldsForL1 :
Action → ByteArray` such that for every `action`:

```lean
let bytes := actionFieldsForL1 action
let kind := actionKindByte action
-- Soundness contract: applying the L1's stepXX with these bytes
-- yields the canonical commit, per SVC.1's coherence theorem.
```

**Implementation steps.**

  1. **SVC.2.a — Per-variant encoders.**

     For STRUCTURED variants (Transfer, Mint, Burn, FreezeResource,
     ReplaceKey, Reward, DistributeOthers, ProportionalDilute,
     RegisterIdentity, Deposit, Withdraw):

     ```lean
     | .transfer r s r' a =>
         uint64BE r.toNat ++ uint64BE s.toNat ++
         uint64BE r'.toNat ++ uint64BE a
     | .mint r to a =>
         uint64BE r.toNat ++ uint64BE to.toNat ++ uint64BE a
     | .burn r fr a =>
         uint64BE r.toNat ++ uint64BE fr.toNat ++ uint64BE a
     ...
     ```

     For OPAQUE variants (Dispute, DisputeWithdraw, Verdict,
     Rollback, DeclareLocalPolicy, RevokeLocalPolicy,
     FaultProofChallenge, FaultProofResolution):

     The encoder uses Lean's existing `Action.encode action` with
     the leading CBE tag bytes stripped (i.e., the fields-only
     CBE form).  This is the canonical format the L1 will hash;
     both sides agree on the bytes.

  2. **SVC.2.b — Per-variant injectivity lemmas.**  Prove that
     for each variant, `actionFieldsForL1` is injective on the
     variant's domain.  Required to defend against an adversary
     constructing a different action with the same encoded form.

  3. **SVC.2.c — Cross-variant non-collision lemma.**  Prove
     that different action variants produce different bytes (or
     are distinguished by `actionKindByte`).  Composition of
     SVC.2.b + this lemma + injectivity of
     `(action_kind, action_fields)` yields
     `actionFieldsForL1_action_eq_iff_actions_eq`.

**Acceptance criteria.**

  * `actionFieldsForL1` defined for all 19 variants.
  * Per-variant injectivity lemmas proved.
  * Round-trip lemma: for each variant, decoding the L1's
    actionFields via the Solidity decoder layout yields the
    same fields as the original `Action`.

**Risk.**  LOW.  Mechanical translation from the Solidity
decoders.

**Effort.**  ~1.5 engineer-weeks.

### SVC.3 — `canon export-terminate-bundle` subcommand

**Scope.**  `Main.lean` (~80 lines new), plus a library function
in `LegalKernel/FaultProof/TerminateBundle.lean` (~150 lines new).

**Goal.**  Add a new Lean CLI subcommand that emits the full
terminate-on-single-step bundle as JSON:

```bash
canon export-terminate-bundle LOG IDX
```

Output (one JSON object per line, terminated by closing `]`):

```json
{
  "fixture_id": "log[7]",
  "action_kind": 0,
  "action_fields_hex": "00000000000000010000000000000002000...",
  "signer": 5,
  "claimed_post_commit_hex": "abcd1234...",
  "cell_proofs": [
    {"cell_kind": 0, "key_a": "0x01", "key_b": "0x05", ...},
    ...
  ]
}
```

**Implementation steps.**

  1. **SVC.3.a — `buildTerminateBundle` function.**  In
     `LegalKernel/FaultProof/TerminateBundle.lean`:

     ```lean
     structure TerminateBundle where
       actionKind        : UInt8
       actionFields      : ByteArray
       signer            : UInt64
       claimedPostCommit : StateCommit
       cellProofs        : List CellProof
     ```

     ```lean
     def buildTerminateBundle (preState : ExtendedState)
         (entry : LogEntry) : TerminateBundle :=
       let action := entry.signedAction.action
       let signer := entry.signedAction.signer
       let actionFields := actionFieldsForL1 action
       let kind := actionKindByte action
       let postState := kernelOnlyApply preState entry
       let postCommit := commitExtendedState postState
       let bundle := buildObserverCellProofs preState action signer
       { actionKind := kind
       , actionFields := actionFields
       , signer := signer
       , claimedPostCommit := postCommit
       , cellProofs := bundle.proofs }
     ```

  2. **SVC.3.b — JSON formatter.**  Reuse
     `LegalKernel.Runtime.CellProofJson.formatCellProofJson` for
     the cell-proof array.  Add a top-level formatter for the
     bundle envelope (snake_case keys to match Rust serde
     conventions).

  3. **SVC.3.c — Main.lean subcommand.**  Mirror the existing
     `cmdExportCellProofs` pattern.

  4. **SVC.3.d — Integration tests.**  Add
     `LegalKernel/Test/Integration/ExportTerminateBundleCli.lean`
     with:
     - Happy path for Transfer log entry.
     - Happy path for Mint log entry.
     - One test per opaque variant (if Option C from SVC.1.c is
       chosen, document that the subcommand emits the bundle but
       observer doesn't use it).
     - Idx-out-of-range error.
     - Non-Nat idx error.

**Acceptance criteria.**

  * Subcommand works for all 19 action variants (or only
    structured if Option C).
  * JSON byte-pinned for at least Transfer + Mint variants.
  * Integration tests pass.

**Risk.**  LOW.  Mechanical given SVC.2 lands.

**Effort.**  ~1 engineer-week.

### SVC.4 — Rust `TerminateBundleOracle` trait

**Scope.**  `runtime/canon-faultproof-observer/src/strategy.rs`
(extended).

**Goal.**  Define a trait and impl that the observer uses to
fetch the terminate bundle from canon:

```rust
pub trait TerminateBundleOracle {
    fn terminate_bundle_at(&self, idx: LogIndex)
        -> Option<TerminateBundle>;
}

pub struct TerminateBundle {
    pub action_kind: u8,
    pub action_fields: Vec<u8>,
    pub signer: u64,
    pub claimed_post_commit: StateCommit,
    pub cell_proofs: Vec<CellProof>,
}
```

**Implementation steps.**

  1. **SVC.4.a — Trait + struct definitions.**  In strategy.rs
     alongside `TruthOracle`.

  2. **SVC.4.b — `MemoryTerminateBundleOracle` impl.**  Test-only;
     stores a pre-computed map.  Used by Observer tests to seed
     a known bundle.

  3. **SVC.4.c — `SubprocessTruthOracle` impl.**  Extend the
     existing `SubprocessTruthOracle` to also implement
     `TerminateBundleOracle`.  Shells out to `canon
     export-terminate-bundle LOG IDX`, parses the JSON output.

     The drain-during-wait pattern from audit-pass-4-round-6
     applies: we expect the canon subprocess to emit a large
     JSON document (~10 KiB for a typical cell-proof bundle), so
     the drain thread must run continuously.  This is already
     correctly implemented in the audit-pass-4-round-6 fix.

  4. **SVC.4.d — Blanket impl for `Box<dyn TerminateBundleOracle>`.**
     Mirror the `Box<dyn TruthOracle>` blanket impl from
     audit-pass-4-round-6.

  5. **SVC.4.e — Bundle parser.**  Add `parse_terminate_bundle_json`
     with serde Deserialize derives on `TerminateBundle`.  Reuse
     the existing `CellProof` deserializer.

  6. **SVC.4.f — Property + unit tests.**  Mock canon scripts;
     bundle parser round-trips; cap on bundle JSON size to
     prevent OOM (mirrors `MAX_CELL_VALUE_BYTES`); typed errors
     on malformed input.

**Acceptance criteria.**

  * Trait + struct compile + serialize round-trip cleanly.
  * Mock canon scripts cover happy path + every error path.
  * `cargo clippy --workspace --all-targets -- -D warnings` clean.

**Risk.**  LOW.  Mirrors the existing oracle patterns.

**Effort.**  ~1 engineer-week.

### SVC.5 — Observer integration + cross-stack fixture widening

**Scope.**  `runtime/canon-faultproof-observer/src/observer.rs`,
`src/submitter.rs`, `tests/`.

**Goal.**  End-to-end wiring so the observer can play
`TerminateOnSingleStep` for at least Transfer + Mint variants
(structured variants in general if SVC.1 lands Option B, all 19
variants if Option A).

**Implementation steps.**

  1. **SVC.5.a — Modify `Observer` generic bounds.**  Either:
     - Add a second generic `T2: TerminateBundleOracle`, OR
     - Use `Box<dyn TerminateBundleOracle>` field on Observer.

     Recommended: extend `TruthOracle` trait to ALSO require
     `TerminateBundleOracle` (since the latter is a strict
     superset functionally — anything that can answer
     commit-at can in principle also build the bundle).  This
     avoids generic explosion.

  2. **SVC.5.b — Modify `maybe_play_move`.**  When
     `compute_next_move` returns `HonestMove::TerminateOnSingleStep
     { claimed_post_commit }`:
     - Look up the bundle via the terminate-bundle oracle at the
       single-step pivot idx.
     - If bundle is None, defer (mirror the `TruthOracleMissed`
       path).
     - If bundle is Some, validate `bundle.claimed_post_commit ==
       claimed_post_commit` (defence-in-depth — both should
       agree).
     - Construct calldata via `encode_terminate_full_calldata`.
     - Submit + persist.

  3. **SVC.5.c — Remove `SubmitError::TerminateNotImplemented`.**
     Add `encode_calldata_full(game_id, mv, bundle)` that takes
     the bundle and dispatches to `encode_terminate_full_calldata`.
     Keep the old `encode_calldata` for callers that don't have
     the bundle (returns the same `NoMove` / etc. errors but
     panics or returns a typed error if called with
     `HonestMove::TerminateOnSingleStep`).

  4. **SVC.5.d — End-to-end integration tests.**  Add to
     `tests/observer_terminate_integration.rs`:
     - Happy path: observer plays terminate for a Transfer
       action at single-step pivot.
     - Bundle missing: observer defers gracefully.
     - Bundle commit mismatches strategy commit: typed error.
     - Cross-stack: observer's emitted calldata matches what
       `forge test` would invoke directly.

  5. **SVC.5.e — Cross-stack corpus widening.**  Extend
     `solidity/test/CrossCheck/fixtures/step_vm.json` from 48
     entries (Transfer + Mint) to ~190 entries (10 per variant
     × 19 = 190).  Each entry's `expectedStepVMCommitHex` is
     keccak-locked to `expectedPostStateCommitHex` under
     `isKeccak256Linked = true`.

  6. **SVC.5.f — Chaos coverage.**  Add chaos test case:
     simulated bisection that reaches max depth + the observer
     successfully plays terminate.

**Acceptance criteria.**

  * Observer plays terminate end-to-end for the variants chosen
    in SVC.1.
  * 190-entry cross-stack corpus passes both Lean and Solidity
    side under `isKeccak256Linked = true`.
  * `cargo test --workspace` green; `forge test` green.

**Risk.**  MEDIUM.  Observer integration touches the maybe_play_move
loop which is well-tested but architecturally central; the
generic-bounds refactor (SVC.5.a) is the trickiest part.

**Effort.**  ~2.5 engineer-weeks.

## Acceptance criteria (workstream-level)

  * Lean side: `step_vm_coherent_with_kernel_apply` proved for all
    19 variants (or per Option C, proved for structured + a
    clear documented contract for opaque).
  * Solidity side: 190 cross-stack entries pass byte-equality
    under `isKeccak256Linked = true`.
  * Rust side: observer plays terminate end-to-end; 10+
    integration tests pass.
  * `lake build` + `lake test` green; `cargo test --workspace`
    green; `forge test` green; all linters clean.
  * `#print axioms` on every new Lean theorem ⊆ `[propext,
    Classical.choice, Quot.sound]`.

## Risk register

  * **R1 (HIGH).**  Opaque-variant coherence (SVC.1.c) may
    require redefining `commitExtendedState` — a TCB-touching
    change that triggers the §13.6 two-reviewer gate AND may
    break existing FaultProof theorems.  Mitigation: prefer
    Option C (restrict observer's terminate to structured
    variants).

  * **R2 (MEDIUM).**  Bundle parser is exposed to adversarial
    canon outputs (operator misconfiguration).  Mitigation:
    apply the same defensive caps as `CellProof` deserializers
    (max-size, max-depth, max-cell-count).

  * **R3 (LOW).**  Cross-stack fixture maintenance burden
    grows from 48 to ~190 entries.  Mitigation: generator-
    driven fixtures (the Lean side emits the JSON
    deterministically; Solidity side reads it).

## Effort estimate

| Sub-unit | Description                                          | Effort       |
|----------|------------------------------------------------------|--------------|
| SVC.1    | Cross-stack coherence theorem extension              | ~3 weeks     |
| SVC.2    | Lean `actionFieldsForL1` encoder                     | ~1.5 weeks   |
| SVC.3    | `canon export-terminate-bundle` subcommand           | ~1 week      |
| SVC.4    | Rust `TerminateBundleOracle` trait                   | ~1 week      |
| SVC.5    | Observer integration + cross-stack widening + chaos  | ~2.5 weeks   |
| **TOTAL** |                                                      | **~9 weeks** |

Parallelisable to ~5 – 6 weeks with two engineers after SVC.1.a
gates the architectural decision.

## Related gap: claim-timeout wiring

A separate but related production gap surfaced during the same
audit pass: the observer does NOT call `claimTimeout(uint256)`
when the opposition's `turnDeadline` expires.  This means an
adversary can stall the game indefinitely:

  1. Adversary submits invalid `stateRoot` to L1.
  2. Observer opens a bisection game.
  3. Adversary stops responding (it's their turn).
  4. `turnDeadline` expires on L1.
  5. The L1 contract's `claimTimeout(gameId)` becomes callable,
     but **no one calls it** — the observer doesn't have the
     logic, and there's no automatic on-chain expiry.
  6. Game stays in `InProgress` status indefinitely; observer
     doesn't win; sequencer's invalid claim may even finalize
     via a separate finalization timeout.

Specifically:
  * `GameState` struct in `runtime/canon-faultproof-observer/
    src/game.rs:215` has NO `turn_deadline` field.
  * `state_reader.rs:424` decodes the L1's `turnDeadline` slot
    but discards it (`let _turn_deadline = ...`).
  * Observer's `run_iteration_inner` has NO per-game timeout
    check loop.
  * `encode_claim_timeout_calldata` is implemented in
    `submitter.rs:691` but is **dead code** — nothing calls it.

This gap is logically independent of the SVC workstream — it
doesn't require cross-stack coherence work.  It DOES require:

  1. Adding `turn_deadline: u64` to `GameState` (cross-stack: must
     match Lean's `LegalKernel.FaultProof.Game.GameState` field —
     verify with the existing Lean reference).
  2. Decoding it in `state_reader.rs::decode_game_state` (replace
     the `_turn_deadline` with assignment).
  3. Adding per-game deadline-expiry check in
     `observer.rs::run_iteration_inner`.
  4. Wiring `encode_claim_timeout_calldata` through the submit
     pipeline.
  5. Dedup: `pending_claim_timeouts: HashSet<u128>` to prevent
     re-submitting the same claim.
  6. Tests: kill-the-opposition scenarios in chaos suite.

Recommended as a follow-up PR after the SVC workstream lands
(estimate ~3 engineer-days).  Tag in this plan to keep the
related work surfaced.

## Cross-references

  * **Generated by:** audit-pass-4-round-6 deep audit
    (CLAUDE.md → "Audit posture at audit-pass-4-round-6 landing").
  * **Closes:** the `SubmitError::TerminateNotImplemented`
    deferral in `runtime/canon-faultproof-observer/src/submitter.rs`.
  * **References:**
    - `docs/planning/rust_host_runtime_plan.md` §RH-G.5
      (response submission scope).
    - `docs/planning/smt_cell_proofs_plan.md` (template for
      cross-stack plans).
    - `docs/planning/fault_proof_migration_plan.md` (Workstream
      H plan).
    - `LegalKernel/FaultProof/Coherence.lean`
      (`recomputeCommitment_coherent_with_kernelOnlyApply`).
    - `LegalKernel/FaultProof/SolidityStepVMCommit.lean` (per-
      variant L1 hash mirror).
    - `solidity/src/contracts/CanonStepVM.sol` (deployed step
      VM).
    - `solidity/test/CrossCheck/fixtures/step_vm.json` (existing
      48-entry corpus).

## Closeout (SVC landing)

The five sub-units of the SVC workstream shipped together as
the `canon-step-vm-coherence` milestone (kernel build tag
bumped from `"canon-encoder-injectivity"` to
`"canon-step-vm-coherence"`).  Workspace version bumped 0.2.5
→ 0.2.6 per the patch-bump default discipline.

### SVC.1 + SVC.2 — Lean dispatcher + action-fields encoder

`LegalKernel/FaultProof/StepVMCoherence.lean` (~880 lines)
ships:

  * `actionKindByte : Action → UInt8` — the 0..18 dispatcher
    byte mirror of the Solidity `ActionKind` enum.
  * `actionFieldsForL1 : Action → ByteArray` — canonical byte
    layout per variant.  Structured variants encode fields as
    `uint64BE`-packed big-endian fields followed by any
    variable-length trailing payload (`newKey`, `pk`,
    `recipientL1`); opaque variants encode the CBE payload
    directly (the L1's `_stepXX` only hashes the bytes).
  * `stepVMHash` — unified dispatcher mirroring Solidity's
    `CanonStepVM.executeStep`.  Reads the action-fields'
    big-endian fields, looks up the matching balance cells from
    the bundle, and routes to the per-variant `stepCommitXX`
    helper.
  * `stepVMHashFromAction` — convenience composition for the
    canonical `(ExtendedState, Action, ActorId)` triple.  This
    is what the off-chain observer's `claimed_post_commit`
    must equal.
  * Per-variant dispatch-coherence theorems
    (`stepVMHash_<variant>_kind`) — 17 `rfl`-proofs pinning
    that the dispatcher reduces to the canonical per-variant
    body when `kind = <variant>`.
  * Architectural decision (Option B): the bisection-game's
    chain of commits uses **step-VM hashes throughout** (not
    full `commitExtendedState` values).  This is the load-
    bearing decision that closes the OQ-SVC-1 open question
    — recorded in the module docstring.

Tests: 68 new cases in `LegalKernel/Test/FaultProof/StepVMCoherence.lean`
covering per-variant `actionKindByte`, byte-layout shape of
`actionFieldsForL1`, BE byte order, `readUint64BE` round-trip,
`decodeCellNat` for absent + present cells, per-variant
`stepVMHash` dispatch, and API-stability for every per-variant
theorem.  Plus 3 cross-stack-decoder-layout regression tests
(transfer / mint / deposit decode their own
`actionFieldsForL1` output).

### SVC.3 — `canon export-terminate-bundle` subcommand

`LegalKernel/FaultProof/TerminateBundle.lean` (~245 lines)
ships:

  * `TerminateBundle` structure carrying `actionKind`,
    `actionFields`, `signer`, `claimedPostCommit`,
    `cellProofs`.
  * `buildTerminateBundle preState entry` — canonical
    bundle constructor.  Bundle's `claimedPostCommit` =
    `stepVMHashFromAction preState action signer`; bundle's
    `cellProofs` = `Observer.buildObserverCellProofs`.
  * `formatTerminateBundleJson` — JSON formatter with
    snake_case fields matching the Rust serde-deserialize
    defaults.
  * Well-formedness theorems: bundle's cell-proof bundle
    verifies against the pre-state commit
    (`buildTerminateBundle_cellProofs_verify`); per-field
    projections.

`Main.lean::cmdExportTerminateBundle` adds the
`canon export-terminate-bundle LOG IDX` subcommand (matching
the existing `export-cell-proofs` dispatch pattern).

Tests: 18 new cases in `LegalKernel/Test/FaultProof/TerminateBundle.lean`
+ 15 new cases in `LegalKernel/Test/Integration/ExportTerminateBundleCli.lean`
covering bundle construction, cell-proof verification, JSON
envelope shape, snake_case field names, byte-pinning for
deterministic prefixes, and per-variant dispatch.

### SVC.4 — Rust `TerminateBundleOracle` trait

`runtime/canon-faultproof-observer/src/strategy.rs` adds:

  * `TerminateBundle` struct with custom serde deserializers
    for the hex-encoded fields (`action_fields_hex` and
    `claimed_post_commit_hex`).  Defensive caps:
    `MAX_TERMINATE_BUNDLE_JSON_BYTES = 8 MiB`,
    `MAX_TERMINATE_BUNDLE_ACTION_FIELDS_BYTES = 4 KiB`,
    `MAX_TERMINATE_BUNDLE_CELL_PROOFS = 272` (mirrors
    Solidity's `CanonStepVM::MAX_CELL_PROOFS_PER_STEP`).
  * `TerminateBundleError` typed error enum (`Missed`,
    `Malformed`, `Oversize`).
  * `parse_terminate_bundle_json` — defensive parser that
    enforces the JSON-size and cell-proof-count caps.
  * `TerminateBundleOracle` trait with the contract
    `terminate_bundle_at(idx) → Result<TerminateBundle, Error>`.
  * `MemoryTerminateBundleOracle` impl (test / in-memory mode).
  * Extended `SubprocessTruthOracle` to ALSO implement
    `TerminateBundleOracle` via the
    `canon export-terminate-bundle LOG IDX` subprocess pattern.
    Reuses the audit-pass-4-round-6 deadlock-prevention
    pattern (drain thread spawned BEFORE the wait loop) and
    the audit-pass-4-round-4 orphan-pipe drain timeout.
  * Blanket `TerminateBundleOracle for Box<T>` impl.

Tests: 9 new lib unit tests in `strategy.rs` covering the
oracle's miss / hit / overwrite / blanket-impl-dispatch
semantics, parser happy path + every cap rejection path,
hex-form vs array-form deserialization, and Lean-shape JSON
round-trip.  7 new end-to-end integration tests in
`tests/real_canon_export_terminate_bundle.rs` exercising the
actual canon binary's `export-terminate-bundle` subcommand
against synthetic logs (Transfer / Mint / Withdraw variants
+ idempotency + error paths + single-line JSON shape).

### SVC.5 — Observer integration

`runtime/canon-faultproof-observer/src/observer.rs` adds:

  * Optional `terminate_bundle_oracle:
    Option<Box<dyn TerminateBundleOracle + Send + Sync>>`
    field on `Observer`.
  * Builder method `Observer::with_terminate_bundle_oracle`
    for production wiring.
  * `Observer::build_calldata_for_move` — dispatches
    terminate moves to the new bundle-driven path,
    non-terminate moves to the existing `encode_calldata`.
  * `Observer::build_terminate_calldata` — fetches the
    bundle, validates `claimed_post_commit` agreement
    (defence-in-depth), and routes to
    `encode_terminate_full_calldata`.  Without a bundle
    oracle attached, logs + defers (the pre-SVC behaviour).

`runtime/canon-faultproof-observer/src/submitter.rs` adds:

  * `SubmitError::BundleCommitMismatch` variant for the
    oracle-drift defence-in-depth.
  * `encode_calldata_with_bundle` — the new entry point that
    takes an optional bundle and dispatches terminate moves
    to `encode_terminate_full_calldata`.  Non-terminate
    moves delegate to `encode_calldata`.

Tests: 7 new lib unit tests in `submitter.rs` covering
delegate + matching-bundle + mismatched-commit + selector
pinning against the canonical Solidity signature.  5 new
lib unit tests in `observer.rs` covering attach + miss-defer
+ hit-success + mismatch-refuse + non-terminate-delegate
paths.

### Cross-stack fixture-corpus widening (SVC.5.e)

Extends `step_vm.json` from 48 entries (Transfer + Mint) to
**218 entries** (24 Transfer + 24 Mint + 17 new variants × 10
each = 218), exceeding the plan's ~190 target.

  * **Per-variant happy + adversarial split.**  Each of the 17
    new variants ships 6 happy + 4 adversarial fixtures.  The
    existing Transfer + Mint corpora (16 happy + 8 adversarial
    each, totalling 48 entries) are preserved unchanged.
  * **Schema additions.**  Each fixture entry now carries
    three new fields beyond the original schema:
    - `actionKindByte`: the 0..18 dispatcher byte (per
      `actionKindByte`).
    - `actionFieldsHex`: the canonical `actionFieldsForL1`
      bytes hex-encoded.
    - `signerNat`: the signer's `ActorId` as a Nat.
    These let the Solidity-side test driver invoke
    `executeStep` with the exact L1-format inputs without
    per-variant decoding logic.
  * **Solidity-side byte-equivalence tests added** (under
    `isKeccak256Linked = true`):
    - `test_perEntry_opaque_variant_byte_equivalence` —
      asserts byte equality for all 48 opaque-variant happy
      entries (Dispute, DisputeWithdraw, Verdict, Rollback,
      DeclareLocalPolicy, RevokeLocalPolicy,
      FaultProofChallenge, FaultProofResolution — 6 each).
    - `test_perEntry_freezeResource_byte_equivalence` — 6
      entries.
    - `test_perEntry_replaceKey_byte_equivalence` — 6
      entries.
    - `test_perEntry_registerIdentity_byte_equivalence` — 6
      entries.
    - The existing `test_perEntry_stepVMCommit_byte_equivalence_mint`
      (Mint's first happy entry).
    Total: 67 happy entries get full byte-equivalence
    assertion under keccak256 binding.
  * **Solidity-side schema-only tests cover all 218 entries**
    unconditionally (independent of binding status):
    fixture-header shape, per-variant counts,
    per-entry schema, adversarial-flag consistency, happy
    postCommit is 32 bytes, stepVMCommit field is well-
    formed, actionKindByte in 0..18, actionFieldsHex is
    `0x`-prefixed + even-length.

### SVC.5.e+ — Cell-bound variant byte-equivalence (follow-up)

The 7 cell-bound structured variants (Transfer, Burn, Reward,
Deposit, Withdraw, DistributeOthers, ProportionalDilute) ship
their happy fixtures with **non-empty pre-states** seeded via
`setBalance`, and emit canonical cell-proof bundles via
`buildObserverCellProofs` (plus per-recipient appends for the
two bulk variants).  Cell-bound happy fixtures' computed
`expectedStepVMCommitHex` values are derived from the actual
pre-balance values via the per-variant `stepCommitXX` helpers
+ `stepCommitDistributeOthersFold` / `stepCommitProportionalDiluteFold`
fold chains for bulk variants.

  * **Wire format:** the fixture JSON gains `cellProofs` and
    `cellProofsCount` fields per entry.  Each `cellProofs`
    element has `(cellKind, keyA, keyB, cellValueHex,
    witnessCommitHex)`.  `vm.parseJsonUint` /
    `vm.parseJsonBytes` / `vm.parseJsonBytes32` consume the
    fields directly.
  * **Solidity-side driver collapse:** the 5 per-variant
    byte-equivalence tests (mint, opaque, freezeResource,
    replaceKey, registerIdentity) are replaced by a single
    generic `test_perEntry_byte_equivalence_all_happy` test
    that iterates every happy entry, parses inputs from JSON,
    invokes `executeStep`, and asserts byte equality against
    `expectedStepVMCommitHex`.  Under keccak256 binding, this
    asserts byte-equivalence for all **134 happy fixtures**
    (16 transfer + 16 mint + 17 × 6 other-variant entries).
    Under FNV fallback the test skips.
  * **Defence-in-depth schema test:** the
    `test_perEntry_cellProofs_witness_binding` test asserts
    every happy fixture's `cellProofs[i].witnessCommitHex`
    equals the fixture's `preStateCommitHex` (the binding
    Solidity's outer loop enforces on broadcast).
  * **Self-transfer coverage:** `transferFixtures` reserves
    `i==8` for an explicit self-transfer (sender == receiver
    == 8), exercising Solidity's `if (sender == receiver) {
    newSenderBalance = senderBalance; newReceiverBalance =
    senderBalance; }` branch.
  * **Bulk-variant recipient sets:** DistributeOthers /
    ProportionalDilute happy fixtures use a deterministic
    3-recipient set (`excluded + 1`, `excluded + 2`,
    `excluded + 3`) with balances `[50 + idx, 75 + idx, 100 +
    idx]`.  Cell-proof bundles include the observer's
    required cells + the 3 recipient balance cells in
    deterministic order.  Solidity's bulk loop iterates the
    bundle in this exact order; Lean's fold chain mirrors it
    byte-for-byte.
  * **ProportionalDilute soundness:** `sumOthers = 225 + 3 *
    idx ≥ 225 > 0` and `totalReward = 100 + 10 * idx ≥ 100 >
    0` ⇒ Solidity's `if (sumOthers == 0) revert` and
    `if (totalReward == 0) revert` never fire.

### SVC.5.e+ audit-pass — bulk-variant dispatcher correctness

A post-merge deep-audit found that `stepVMHash` for kinds 6
(DistributeOthers) and 7 (ProportionalDilute) returned the
HEAD form only — missing the per-recipient fold that
Solidity's `_stepDistributeOthers` / `_stepProportionalDilute`
compute.  This meant `stepVMHashFromAction es action signer`
for bulk variants would NOT byte-equal `executeStep(...)` on
the same inputs when the bundle contained recipient balance
cells.

The fix:

  * **`stepVMHash` for kind = 6** now computes
    `head ++ fold(balance cells matching r ∧ ≠ excluded)`,
    where the fold uses Solidity's exact filter, iteration
    order, and `MAX_RECIPIENTS_PER_BULK_ACTION = 256` cap.
  * **`stepVMHash` for kind = 7** now does the full two-pass
    logic: pass 1 sums balance-cell values (over the same
    256-cap prefix), pass 2 computes per-recipient
    `credit := totalReward * v / sumOthers`,
    `newBal := v + credit`, and folds in iteration order.
  * **New helper constant** `maxRecipientsPerBulkAction = 256`
    mirrors Solidity's `MAX_RECIPIENTS_PER_BULK_ACTION`.
  * **Two new dispatch theorems**
    `stepVMHash_distributeOthers_kind` and
    `stepVMHash_proportionalDilute_kind` document the bulk
    semantics as rfl-proofs.
  * **8 new value-level tests** in
    `LegalKernel/Test/FaultProof/StepVMCoherence.lean` cover:
    empty bundle (head only), 1-matching-cell fold, excluded-
    actor cell filter, non-balance cell skipping, two-cell
    fold, mixed bundle (registry+nonce+balances).  Plus 2
    API-stability tests for the new theorems.

**Backward compatibility.**  The fixture corpus is unchanged
(same SHA: `8e5376f5...`); the fixture writer computes the
fold manually using the same semantics, so the
`expectedStepVMCommitHex` for bulk fixtures was already
correct.  The fix improves `stepVMHash`'s faithfulness to
Solidity but doesn't alter any fixture data.

### SVC.5.e+ audit-pass-3 — `decodeCellNat` byte-equivalence

A third audit pass closed a documented cross-stack semantic
divergence between Lean's `decodeCellNat` and Solidity's
`_decodeNat`:

  * **Previous behaviour.**  `decodeCellNat` went through
    `Encodable.decode (T := Nat)`, which `cborHeadDecode`
    rejects when the tag byte ≠ `cbeTagUint = 0x00`.  Any
    non-canonical tag byte produced `Nat 0`.
  * **Solidity's behaviour.**  `_decodeNat` ignores the tag
    byte entirely and reads `bytes[1..9]` little-endian as a
    `uint256`.  It only reverts on length 1..8 inputs.
  * **Divergence.**  On non-canonical inputs (tag byte ≠
    0x00 with length-9 payload, or length > 9 with arbitrary
    leading byte), the two decoders disagreed.  All honest
    cross-stack fixtures use canonical tags so the corpus
    byte-equivalence test never triggered the divergence —
    but the dispatcher's mathematical contract claimed
    "Mirrors Solidity's `_decodeNat`", which was a
    documentation lie.
  * **Fix.**  `decodeCellNat` is now rewritten as a direct
    byte-for-byte mirror of `_decodeNat`'s inner loop:
    ```lean
    def decodeCellNat (bytes : ByteArray) : Nat :=
      if bytes.size = 0 then 0
      else if bytes.size < 9 then 0
      else
        let b1 := bytes.data[1]!.toNat
        ...  -- bytes[1..9] LE, tag byte at offset 0 ignored
    ```
    Length-1..8 inputs return 0 (Solidity reverts; the
    chosen 0 has the property that the dispatcher's resulting
    hash cannot match any honestly-claimed pivot commit under
    collision-resistance of `hashBytes`, so on Lean-side
    replay an adversary who supplies short cell bytes
    forfeits the implicit terminate response — mirroring the
    on-chain outcome where Solidity's revert keeps the game
    in-progress until the responsible party times out).
  * **Soundness rationale.**  The fix makes the two decoders
    byte-equivalent on EVERY input (mod the length-1..8
    revert-vs-0 case, which is documented and benign).  An
    adversary at single-step termination can no longer
    exploit decoder drift in any unanticipated way; both
    sides now agree on the dispatcher's output for any
    bundle the adversary can construct.
  * **Backward compatibility.**  The fixture corpus is
    unchanged (same SHA `8e5376f5...`).  All cell bytes in
    the corpus are canonical-CBE (tag=0x00, 8 LE payload
    bytes); the old and new `decodeCellNat` agree on these
    inputs.  Re-running `CANON_FIXTURES_OVERWRITE=1 lake test`
    produces a byte-identical fixture file.
  * **Test additions.**  5 new regression tests in
    `LegalKernel/Test/FaultProof/StepVMCoherence.lean` pin
    the cross-stack-equivalent behaviour:
    1. Non-canonical tag byte (0xFF) is ignored.
    2. Arbitrary first byte preserves bytes[1..9] LE value
       (canonical, 0x01, 0xFF all decode to the same value).
    3. Length 9 + extra trailing bytes ignored.
    4. Short bytes (length 1..8) return 0.
    5. Full u64 max payload (0xFFFFFFFFFFFFFFFF) round-trips.
    Existing canonical-input tests preserved unchanged
    (length-0 → 0, CBE-encoded 42 round-trips, CBE-encoded
    0xDEADBEEF round-trips).

### Audit posture at SVC landing

* **Lean side:**
  - `lake build` — green; zero new warnings.
  - `lake test` — all suites green; 2245 cases pass across
    125 suites (+5 from the audit-pass-3 regression tests
    pinning `decodeCellNat`'s cross-stack byte-equivalence).
  - `lake exe count_sorries` / `tcb_audit` / `stub_audit` /
    `naming_audit` / `deferral_audit` — all PASS.
  - `#print axioms` on every new theorem ⊆ `[propext,
    Classical.choice, Quot.sound]`.
  - TCB delta: zero (the new module is non-TCB).
* **Rust side:**
  - `cargo build --workspace --all-targets --locked` —
    green.
  - `cargo test --workspace --locked` — 1433 tests passing
    (+29 from the SVC additions).
  - `cargo clippy --workspace --all-targets --locked -- -D
    warnings` — clean.
  - `cargo fmt --all -- --check` — clean.
  - `unsafe_code = "forbid"` preserved across all SVC additions.
* **Binary smoke-test:**
  - `canon export-terminate-bundle <empty-log> 0` → exit 2
    with "idx 0 >= log length 0" stderr.  Output well-formed.
  - `canon help` lists the new `export-terminate-bundle`
    subcommand with the correct documentation.
* **Sub-unit closure:**
  - `SubmitError::TerminateNotImplemented` is now reachable
    only via `encode_calldata` directly (the legacy entry
    point); the production path through
    `encode_calldata_with_bundle` accepts a bundle and
    succeeds.  The `TerminateNotImplemented` variant is
    retained for callers (smoke tests, third-party
    integrators) that don't have a bundle.

### Related gap: claim-timeout wiring (still deferred)

The "claim_timeout / turn_deadline" gap documented in the
plan's §"Related gap" section remains deferred to a follow-up
PR.  It is logically independent of SVC: SVC closes the
terminate-on-single-step path; claim-timeout closes the
chain-stall-by-non-response path.
