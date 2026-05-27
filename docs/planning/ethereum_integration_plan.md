<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Knomosis-on-Ethereum: Minimum Viable Integration — Workstream Plan

This document plans the engineering effort needed to deploy Knomosis as
a proof-carrying optimistic rollup anchored to Ethereum L1.  It is a
roadmap, not a specification; the formal design lives in the Genesis
Plan amendment that workstream G.1 is charged with drafting.

The plan deliberately constrains itself to a *minimum viable*
integration: the smallest set of changes that lets a real Ethereum
user deposit ETH (or an ERC-20), execute a Knomosis transaction, and
withdraw the result back to L1, with on-chain dispute resolution
backed by the existing Phase-6 fraud-proof pipeline.

## Status

  * **Drafted on branch:** `claude/ethereum-kernel-integration-HMexY`.
  * **Phase prefix:** `E` (Ethereum) — workstreams labelled `A.1`,
    `B.2`, …, `G.5` to disambiguate from the Genesis-Plan
    `Phase 1`/`Phase 2`/… numbering.  This phase is parallel to,
    not a successor of, the Genesis-Plan Phase 7.
  * **Build-posture target:** `lake build`, `lake test`,
    `lake exe count_sorries`, `lake exe tcb_audit`, and
    `lake exe stub_audit` all green throughout; no new sorries; no
    new axioms; no expansion of the kernel TCB.
  * **Workstream A (cryptographic adaptors) status:** **Complete**
    on the Lean side as of branch
    `claude/implement-crypto-adaptors-fo76C`.  WU A.1
    (`LegalKernel/Bridge/VerifyAdaptor.lean`), WU A.2
    (`LegalKernel/Bridge/HashAdaptor.lean`), and WU A.3
    (`LegalKernel/Bridge/Eip712.lean`) all land with full Lean-side
    contracts, stability theorems, and value-level test coverage.
    The Rust-side adaptor crates
    (`runtime/knomosis-verify-secp256k1`, `runtime/knomosis-hash-keccak256`)
    are deferred to a follow-up PR with its own CI infrastructure;
    the Lean-side `Bridge/*` modules ship the canonical type
    declarations, reference test vectors, and stability theorems
    that the Rust crates' tests will consume via FFI.  All three
    headline §12.6 theorems (`eip712Wrap_injective`,
    `eip712DomainSeparator_distinguishes`,
    `eip712Wrap_distinguishes`) ship without `sorry` and depend
    only on the standard Lean built-in axioms (`propext` and
    `Quot.sound` only — `Classical.choice` not used).  Test
    count grew from 665 to 758 (+93 tests across the three new
    bridge suites, including the Workstream-A audit-1
    additions); `kernelBuildTag` bumped to
    `"knomosis-ethereum-workstream-a-crypto-adaptors"`.

    **Workstream-A audit-1 hardening (post-landing).**  A first
    audit pass identified a **critical interop bug** —
    `eip712StructHash` encoded only `actionHash` while the type
    string declared four fields, meaning a spec-compliant
    MetaMask wallet would produce a struct hash differing from
    Lean's, so the §5.3 acceptance criterion ("MetaMask-produced
    EIP-712 signature on a Knomosis `signInput` verifies via the
    A.1 binding") would have failed at runtime.  Closed by:
    (a) extending `eip712StructHash` to encode all four
    declared fields via the new `structPreHash` helper (5-field
    160-byte preimage); (b) re-proving `eip712Wrap_injective`
    for the new struct hash (four byte-level boundary
    extractions plus two collision-free applications);
    (c) updating the type strings to declare `bytes` (not
    `bytes32` / `address`) for the hashed `deploymentId` /
    `verifyingContract` fields, restoring exact EIP-712
    spec-compliance for the declared field types.  Plus six
    new regression tests (`structPreHashSize`,
    `structPreHashContainsSigner`, byte-layout LSB checks,
    and four type-string sanity tests) that would have caught
    the original bug, and four other defensive
    additions (`orderBytesDecodesToOrder`,
    `halfOrderMatchesEip2`, conditional KAT tests for
    `kat_abc` / `kat_helloWorld`, `katVectorsLeadingBytesDistinct`).
    Three unused imports also removed.

  * **Workstream B (identity and authority) status:** **Complete**
    on the Lean side as of branch
    `claude/implement-identity-authority-Bi2bB`.  WU B.1
    (`LegalKernel/Bridge/AddressBook.lean`), WU B.2
    (`LegalKernel/Bridge/Ingest.lean`), and WU B.3
    (`LegalKernel/Bridge/BridgeActor.lean`) all land with full
    Lean-side data structures, theorems, and value-level test
    coverage.  The Rust-side ingestor binary that consumes a
    `web3.eth.Filter` stream and feeds the resulting `L1Event`
    list to the Lean side via FFI is deferred to a follow-up PR
    with its own CI infrastructure.

    The implementation also pulls forward one Workstream-C.4
    deliverable: the `Action.registerIdentity (actor : ActorId)
    (pk : PublicKey)` constructor, which Workstream B.2's
    `ingest` and B.3's `bridgePolicy` cannot be type-checked
    without.  The constructor is appended at frozen index 12
    (per the append-only discipline); when Workstream C lands
    `Action.deposit` and `Action.withdraw`, those will use
    indices 13 and 14, in that order.  This deviation from the
    plan's original index allocation (`deposit` = 12,
    `withdraw` = 13, `registerIdentity` = 14) is documented in
    CLAUDE.md and reflects the fact that Workstream B is
    implemented before Workstream C.

    Workstream-B headline §12 theorems, all without `sorry` and
    depending only on the standard Lean built-in axioms:

      * §12.7: `addressBook_invariant`, `assign_fresh_actorId`,
        `assign_idempotent_for_known`.  The plan-sketch's
        unconditional form of `addressBook_invariant` is recovered
        as conditional on a `Consistent` hypothesis (the bookkeeping
        invariant separating forward / reverse-map agreement); the
        runtime adaptor maintains `Consistent` by construction
        (via `empty_consistent` + `assign_preserves_consistent`
        under a freshness hypothesis).

      * §12.8: `ingest_emits_bridge_actor` (every emitted unsigned
        action's signer is `bridgeActor` — type-level pinning of
        the bridge's authority boundary);
        `ingest_preserves_lookup_for_other_addresses` (the per-
        address locality lemma); and
        `ingest_lookup_equivalent_for_distinct_addresses` (cross-
        address commutativity at addresses not touching either
        event).  The plan-sketch's `isSome` form is also exposed
        as `ingest_isSome_equivalent_for_distinct_addresses`.

      * §12.9: `bridgePolicy_rejects_transfer` (#32),
        `bridgePolicy_authorizes_replaceKey` (#35),
        `bridgePolicy_authorizes_registerIdentity` (#36), plus a
        wider rejection family for every other Action constructor
        and `bridgePolicy_rejects_non_bridge_signer`.  Theorems
        §12.9 #33 (`bridgePolicy_rejects_withdraw`) and #34
        (`bridgePolicy_authorizes_deposit`) are reserved for
        Workstream C when those constructors land.  The §12.9 #37
        type-level theorem `registerIdentity_first_time_only` is
        also reserved for C.4 (it requires extending `Admissible`
        to include action-specific authority-layer preconditions);
        for now, the bridge runtime enforces first-time-only at
        the `AddressBook` level.

    Test count grew from 758 to 816 in the initial commit, then to
    835 after the audit-1 pass (+77 over baseline; audit-1 added 19
    tests across `bridge-address-book` (+3), `bridge-actor` (+3),
    `bridge-ingest` (+9), `encoding-action` (+2 for the
    `Action.registerIdentity` round-trip + cross-constructor
    distinguishability));  `kernelBuildTag` bumped to
    `"knomosis-ethereum-workstream-b-identity-authority"`.

    **Workstream-B audit-1 hardening summary.**  A first audit pass
    identified one critical-but-correctable spec deviation
    (`ingest_isSome_equivalent_for_distinct_addresses` was
    restricted to addresses NOT touching either event, not the
    plan's full §12.8 #30 form covering ALL addresses) plus
    several smaller documentation-vs-code drift items.  All closed:

      * Strengthened `ingest_isSome_equivalent_for_distinct_addresses`
        to the full per-address form.  Used a new
        `ingest_lookup_isSome_pre_invariant` work-horse lemma
        (applying the same event to two books that agree on
        `addr.isSome` produces post-states that agree on
        `addr.isSome`).
      * Added `assign_fresh_actorId_le` Nat-projected `≤` form
        matching the plan §12.7 #28 spec under a no-overflow
        hypothesis (`b.nextActorId.toNat + 1 < 2^64`).
      * Added `ingest_preserves_consistent` lemma making the
        runtime adaptor's invariant (the `AddressBook` is
        `Consistent` after every `ingest`) a type-level guarantee.
      * Added `EthAddress.toBytes_size` lemma (always 20 bytes).
      * Added `L1Event.DecidableEq` instance, matching the plan's
        `deriving Repr, DecidableEq`.
      * Renamed `non_replaceKey_preserves_registry` to
        `non_registry_mutating_preserves_registry` for content-
        accurate naming (now that `registerIdentity` also mutates
        the registry).  The old name is kept as a definitional
        alias for backward compatibility.
      * Fixed a `Repr EthAddress` bug (decimal value was rendered
        with a misleading `0x` prefix).
      * Added missing `Action.registerIdentity` encoding round-trip
        tests in the `encoding-action` suite.
      * Documentation fix: BridgeActor.lean's coverage-map
        docstring incorrectly listed `(#32, #34, #35, #36)` —
        corrected to `(#32, #35, #36)` since #33 / #34 are
        deferred to C.4.

    All audit-1 additions ship without `sorry` and depend only on
    the standard Lean built-in axioms ([propext, Classical.choice,
    Quot.sound] for the harder theorems; just [propext] for
    several `bridgePolicy` theorems).

  * **Workstream C (bridge laws) status:** **Complete** on the
    Lean side as of branch `claude/implement-bridge-laws-eYwV0`.
    All six work units (C.0 – C.6) ship without `sorry` and pass
    every audit gate (`count_sorries`, `tcb_audit`,
    `stub_audit`, strict-warnings).  Test count grew from 835 to
    921 (+86 tests).  `kernelBuildTag` bumped to
    `"knomosis-ethereum-workstream-c-bridge-laws"`.

    **Amendment (2026-05-22, RB — runtime bridge wiring):**
    Workstream C originally shipped `BridgeAdmissibleWith`,
    `apply_bridge_admissible_with`, and the supporting
    pass-through theorems, but the *runtime* entry points
    (`processSignedActionWith`, `processPure`, `replayStepWith`)
    continued to dispatch on the weaker `AdmissibleWith` and apply
    via `apply_admissible_with{,_budget}` — leaving the
    `ExtendedState.bridge` field unchanged after admitted
    `deposit` / `withdraw` actions.  This let deposit-id replay,
    identity re-registration, and bridge-only impersonation slip
    past the runtime even though the predicates that catch them
    (`BridgeAdmissibleWith` conjuncts 6 – 8) already existed.
    Three follow-up pieces close the gap:

      * `LegalKernel/Bridge/Admissible.lean` —
        `apply_bridge_admissible_with_budget` combines the GP.3.2
        budget gate (`EpochBudgetState.consume`) with
        `apply_bridge_admissible_with` so admission, budget
        consumption, kernel state advance, and bridge state advance
        happen atomically through a single Lean-level entry.
      * `LegalKernel/Runtime/Replay.lean` —
        `BridgeAdmissibleWith.dec_depositIdFresh`,
        `BridgeAdmissibleWith.dec_registrationFresh`, and the
        umbrella `BridgeAdmissibleWith.decidable` instance lift the
        `forall-implication` shape of conjuncts 6 / 7 onto a
        `cases`-based decision procedure: each conjunct collapses
        to a concrete decidable Bool / Option check on the matching
        `Action` constructor, and to `Decidable True` (via the
        structurally-impossible equation hypothesis) on every other
        constructor.
      * `LegalKernel/Runtime/{Loop,Replay}.lean` — the three
        runtime entry points (`processSignedActionWith`,
        `processPure`, `replayStepWith`) now dispatch on
        `BridgeAdmissibleWith` and apply via
        `apply_bridge_admissible_with_budget`, threading the
        runtime's `logIndex` (or the replay entry's `idx`) through
        as the bridge-state `l2LogIndex`.

    Acceptance: 10 new value-level tests in
    `LegalKernel/Test/Runtime/BridgeAdmission.lean` exercise
    deposit-marks-consumed (with `DepositRecord` shape check),
    deposit-replay-rejected, withdraw-appends-pending (with
    `PendingWithdrawal` l2LogIndex check), deposit-by-non-bridge-
    signer rejected, registration re-attempt rejected, the
    non-bridge regression (transfer / mint unaffected), a multi-
    step bridge-state-threading chain, and term-level API
    stability for the two new public surfaces.
    `#print axioms` on every new declaration returns the canonical
    `[propext, Classical.choice, Quot.sound]` (no custom axioms).
    No theorems from §7.1.3 are deleted; the legacy
    `apply_admissible_with_preserves_bridge` and
    `apply_admissible_preserves_bridge` keep their `rfl` shapes
    (they describe a function the runtime no longer reaches by
    default, but the API contract still holds and downstream
    callers that bypass the bridge layer can rely on it).

    Modules landed:

      * `LegalKernel/Bridge/State.lean` (WU C.1.1) — `DepositId`
        (`Nat`; documented deviation from plan's `ByteArray`),
        `WithdrawalId`, `DepositRecord` (audit-2 amendment),
        `PendingWithdrawal`, `BridgeState`, `BridgeState.empty`,
        `markConsumed`, `appendWithdrawal`, `isConsumed`,
        `hasConsumed`.
      * Extension to `LegalKernel/Authority/Nonce.lean` (WU C.1.2)
        — `ExtendedState.bridge : Bridge.BridgeState :=
        Bridge.BridgeState.empty` field embedding (default-valued
        for backwards-compat with pre-Workstream-C constructions).
      * Extension to `LegalKernel/Encoding/State.lean` (WU C.1.4)
        — `BridgeState.encode/decode`, `DepositRecord.encode/decode`,
        `PendingWithdrawal.encode/decode`; extended
        `ExtendedState.encode/decode` to include the bridge
        segment at the end.
      * `LegalKernel/Bridge/Admissible.lean` (WU C.0) —
        `BridgeAdmissibleWith` (5+3 conjuncts),
        `applyActionToBridgeState` helper,
        `apply_bridge_admissible_with` entry point,
        `BridgeAdmissibleWith.toAdmissibleWith` projection,
        per-field agreement theorems
        (`apply_bridge_admissible_with_{base,nonces,registry}_agrees`),
        `apply_admissible_with_preserves_bridge` (rfl pass-through;
        WU C.1.3), `apply_admissible_preserves_bridge`,
        `apply_bridge_admissible_with_preserves_bridge_for_non_bridge`,
        `applyActionToBridgeState_non_bridge` identity lemma,
        `bridge_replay_impossible` lift via projection.
      * `LegalKernel/Laws/Deposit.lean` (WU C.2) — `deposit r
        recipient amount depositId` law with
        `totalSupply_after_deposit`,
        `deposit_other_resource_untouched`,
        `deposit_other_actor_untouched`,
        `deposit_does_not_touch_other_resources`,
        `deposit_conserves_other_resource`,
        `deposit_isMonotonic` instance,
        `deposit_not_conservative`.
      * `LegalKernel/Laws/Withdraw.lean` (WU C.3) — `withdraw r
        sender amount recipientL1` law with
        `totalSupply_after_withdraw` (additive form),
        `withdraw_other_resource_untouched`,
        `withdraw_other_actor_untouched`,
        `withdraw_does_not_touch_other_resources`,
        `withdraw_conserves_other_resource`,
        `withdraw_not_monotonic`,
        `withdraw_not_conservative`.
      * Extensions to `LegalKernel/Authority/Action.lean` (WU C.4)
        — `Action.deposit` (frozen index 13) and `Action.withdraw`
        (frozen index 14) constructors with their
        `compileTransition` branches; structural compile-injectivity
        extends to the new constructors via `CompiledAction.source`.
      * Extensions to `LegalKernel/Encoding/Action.lean` (WU C.4)
        — `fieldsBounded`, `encode`, `decode`, `action_roundtrip`
        / `action_encode_injective` extended for the new constructors.
      * Extension to `LegalKernel/Authority/SignedAction.lean` (WU
        C.4) — `non_registry_mutating_preserves_registry` extended
        with `rfl` cases for `deposit` / `withdraw` (neither
        mutates the registry).
      * Extension to `LegalKernel/Bridge/BridgeActor.lean` (WU C.4)
        — `bridgeAuthorizedAction` and `bridgePolicy` extended to
        admit `deposit` / `withdraw` for the bridge actor;
        `bridgePolicy_authorizes_deposit` (§12.9 #34) and
        `bridgePolicy_authorizes_withdraw` theorems.
      * Extensions to `LegalKernel/Events/Types.lean` and
        `LegalKernel/Events/Extract.lean` (WU C.5) — two new
        `Event` constructors (`withdrawalRequested` at frozen
        index 9, `depositCredited` at index 10), updated
        `actor` / `resource` / new `isBridgeEvent` projections,
        delta-filtered `actionEvents` for `deposit`/`withdraw`,
        unconditional bridge semantic events emitted in
        `extractEvents`, two new headline theorems
        (`extractEvents_deposit_emits_credited`,
        `extractEvents_withdraw_emits_requested`).
      * `LegalKernel/Bridge/Accounting.lean` (WU C.6) —
        `totalDeposited` / `totalWithdrawn` quantity functionals,
        genesis sanity lemmas, `amountAt` projections,
        `_unchanged_when_bridge_eq` field-equality lemmas,
        per-action accounting deltas
        (`accounting_delta_non_bridge` parameterised, plus
        specialisations to `transfer`, `freeze`, `replaceKey`,
        `registerIdentity`), `applyActionToBridgeState_deposit/_withdraw`
        shape lemmas.

    Documented deviations from the integration plan:

      1. `DepositId : Nat` rather than `ByteArray` (avoids the
         `byteArrayCompare` `TransCmp/LawfulEqCmp` re-derivation
         cost; runtime adaptor performs 32-byte BE → Nat
         conversion at the bridge boundary; injective on
         fixed-length 32-byte inputs).
      2. `bridge` field has default value `BridgeState.empty`
         (additive backwards-compatible extension; existing
         `ExtendedState` literal constructions in test fixtures
         keep elaborating).
      3. The chain-level `bridge_supply_account_general` (§7.6.4)
         and `bridge_supply_account` (§7.6.5) theorems are scoped
         as deferred follow-ups: the per-action accounting (the
         non-trivial content of the chain-level theorem) is
         fully proved at the WU C.6.2 / C.6.3 level; closing
         the chain requires defining a custom `BridgeReachable`
         predicate over `ExtendedState`, which is a structural
         lift over what is already shipped.

    **Workstream-C audit-1 hardening summary.**  A first post-
    landing audit identified three issues; all are now closed.

      * **Critical: `Action.isBridgeOnly` flagged `withdraw`
        (security bug).**  The pre-audit listing forced ALL
        withdrawals to be bridge-actor-signed via conjunct 8 of
        `BridgeAdmissibleWith`, contradicting the design where
        users sign their own withdrawals.  Audit-1 removes
        `withdraw` from `isBridgeOnly`; only the L1-attested
        actions (`registerIdentity`, `deposit`) remain.

      * **`bridgePolicy_authorizes_withdraw` →
        `bridgePolicy_rejects_withdraw`.**  Aligns with §12.9 #33.
        The bridge actor is forbidden from signing withdrawals,
        closing a coordinated-attack vector.
        `bridgeAuthorizedAction` updated to exclude `withdraw`.

      * **Added post-application bridge-state invariants.**
        `deposit_marks_consumed` (the depositId IS in `consumed`
        after admissibility), `deposit_replay_blocked_by_consumed`
        (the same depositId cannot be admissibly applied twice),
        `withdraw_bumps_nextWdId` (distinct withdrawals get
        distinct ids).  These close the L1-deposit-replay and
        L2-withdraw-replay attacks at the type level.

      * **Added BridgeState encoding theorems.**
        `bridgeState_encode_deterministic`,
        `depositRecord_encode_deterministic`,
        `pendingWithdrawal_encode_deterministic`,
        `depositRecord_roundtrip`.  Closes the §7.1.4
        deliverable.

      * **Documented `DepositId` 64-bit projection requirement.**
        The CBE round-trip bound `< 2^64` means production 32-byte
        L1 hashes need a deployment-canonical projection
        (`keccak256(blockHash ‖ logIdx)[0:8]`, or sequential
        `uint64` numbering); the projection's injectivity is the
        deployment's correctness obligation.

    Audit-1 raised the test count from 921 to 934 (+13).  All
    additions ship without `sorry` and depend only on the standard
    Lean built-in axioms.

    **Workstream-C audit-2 hardening summary.**  A second post-
    landing audit identified one further critical issue and closed
    it.

      * **Critical: 64-bit truncation of `recipientL1` enabled
        signature replay (`Action.withdraw` and
        `PendingWithdrawal`).**  The pre-audit-2 encoders
        serialised `recipient.val` as a CBE Nat (`< 2^64` bound),
        but `EthAddress = Fin (2^160)` can be 160 bits.  Two
        EthAddresses sharing low 64 bits encoded to identical
        bytes — same `signingInput`, same valid signature.  An
        attacker could replay a user's signed withdrawal against
        any attacker-controlled L1 address sharing the low 64
        bits.

      * **Fix: lossless 20-byte ByteArray encoding.**  Audit-2
        switches the recipient encoding to
        `Encodable.encode (T := ByteArray)
        (Bridge.EthAddress.toBytes rcp)` — a 29-byte CBE byte
        string carrying all 20 bytes of the BE-encoded address.
        Lossless on every `Fin (2^160)` value.  Closed via the
        new `EthAddress.ofBytes_toBytes` round-trip lemma in
        `Bridge/AddressBook.lean` (proved sorry-free using three
        helper lemmas about the BE encoder).

      * **`Action.fieldsBounded` simplified for `.withdraw`.**  The
        pre-audit clause `rcp.val < 2^64` is removed — the
        20-byte ByteArray encoding has size `= 20 < 2^64`
        unconditionally.

      * **Audit-2 security regressions added.**  Two new tests in
        `encoding-action` and four new tests in
        `bridge-address-book` verify that distinct EthAddresses
        sharing low 64 bits encode to *distinct* bytes, and that
        160-bit-max EthAddresses round-trip losslessly.

    Audit-2 raised the test count from 934 to 940 (+6).  All
    additions ship without `sorry` and depend only on the standard
    Lean built-in axioms.

    **Audit-2 on-disk log format break.**  Pre-audit-2 logs with
    `Action.withdraw` records are NOT compatible with the post-
    audit decoder.  Acceptable break since Workstream C is shipping
    for the first time; future audits will preserve on-disk
    compatibility within a phase.

  * **Workstream D (withdrawal proofs) status:** **Complete** on
    the Lean side as of branch
    `claude/implement-withdrawal-proofs-LSo4T`.  All three work
    units (D.1 with five sub-WUs, D.2, D.3) ship without `sorry`
    and pass every audit gate (`count_sorries`, `tcb_audit`,
    `stub_audit`, strict-warnings).  Test count grew from 940 to
    1024 (+84 tests, including audit-1 + audit-2 additions).
    `kernelBuildTag` bumped to
    `"knomosis-ethereum-workstream-d-withdrawal-proofs"`.

    Modules landed:

      * `LegalKernel/Bridge/WithdrawalRoot.lean` — the SMT data
        structures (D.1.1: `smtHeight`, `defaultHash`,
        `pathBitAtLevel`, `hashUp`, `leafBytes`, `rangeRoot`
        with empty short-circuit, `withdrawalRoot`); the verifier
        and constructor (D.1.2: `WithdrawalProof` structure,
        `verifyProofRec`, `verifyProof`, `constructProofAux`
        with empty short-circuit, `constructProof`,
        `emptyProofSiblings`); the unconditional completeness
        theorem (D.1.3: `verifyProof_complete` plus
        `verifyProofRec_eq_rangeRoot`); the hash-conditional
        soundness theorem (D.1.4: `verifyProof_sound` plus
        `verifyProofRec_inj`, `hashUp_inj_of_collisionFree`,
        `byteArray_append_inj`).
      * `LegalKernel/Bridge/WithdrawalProof.lean` (WU D.2) —
        `Snapshot.bridgeWithdrawalRoot` (function on
        `Runtime.Snapshot` for the on-L1 redemption root);
        `extractProof` (snapshot + WithdrawalId →
        `Option WithdrawalProof`);
        `extractProof_consistent_with_root` (extracted proofs
        verify against the snapshot's bridge root).
      * `LegalKernel/Bridge/Finalisation.lean` (WU D.3) —
        `FinalisableSnapshot` wrapper (snapshot + L1 confirmation
        metadata + log range); `hasUpheldInRange` (forward-walk
        upheld-dispute scan over `disputeStatus`); `isFinalised`
        predicate; `isFinalised_monotonic_in_currentBlock` and
        `isFinalised_implies_no_upheld_against` headline
        theorems.
      * Extension to `Main.lean` — `knomosis withdrawal-proof
        SNAP_PATH ID` subcommand (D.2 user-facing CLI).  Loads
        the snapshot, extracts the proof, and emits a
        hex-encoded leaf + sibling path to stdout.
      * `LegalKernel/Test/Bridge/WithdrawalRoot.lean` — 30
        cases covering D.1.1 / D.1.2 / D.1.3 / D.1.4.
      * `LegalKernel/Test/Bridge/WithdrawalProof.lean` — 12
        cases covering D.2.
      * `LegalKernel/Test/Bridge/Finalisation.lean` — 14 cases
        covering D.3.
      * `LegalKernel/Test/Bridge/WithdrawalRootGoldens.lean` —
        5 cases covering D.1.5 (16-leaf golden fixture
        generator and verifier).

    **Workstream-D performance fix.**  `rangeRoot` and
    `constructProofAux` ship with empty-entries short-circuits
    that the integration plan §8.1.1 / §8.1.2 pseudocode does
    not specify.  Without these short-circuits, computing
    `rangeRoot 64 []` (and by extension `withdrawalRoot
    BridgeState.empty`) would be O(2^64) — every level forks
    into two recursive calls on the empty list.  With the
    short-circuit, the work is O(N * smtHeight) for a sparse
    tree with N populated entries.  Both definitions are
    operationally equivalent to the spec's pseudocode (the
    `rangeRoot_nil_eq_defaultHash` and `constructProofAux_nil`
    lemmas establish the equivalence at the value level).

    **Workstream-D Solidity-side deferral.**  The §8.1.5
    cross-stack golden file (`solidity/test/fixtures/withdrawal_proof_smt.json`)
    is generated by the Lean test driver
    (`Test/Bridge/WithdrawalRootGoldens.lean`) but the Solidity-
    side verifier (`solidity/test/SMT.t.sol`) is deferred to
    Workstream E.1.3 (where `KnomosisBridge.sol`'s SMT verifier
    consumes the same fixture bytes).  The Lean side ships the
    canonical computation and the test fixtures it produces;
    when Workstream E lands, it will assert byte-for-byte
    matching against this Lean output via the `@[extern]`-linked
    keccak256 binding.

    **Workstream-D audit-1 hardening (post-implementation).**
    A comprehensive audit raised six items, all closed:

      1. **`extractFinalisedProof` added** to match §8.2's
         "returns `none` if not finalised" spec form.  The
         pre-audit `extractProof` only checked pending
         membership; the new wrapper combines it with the §8.3
         `isFinalised` predicate.  Plus
         `extractFinalisedProof_consistent_with_root`,
         `extractFinalisedProof_deterministic`, and
         `extractFinalisedProof_unfinalised`.

      2. **Dead code in `constructProofAux`** at level=0
         non-empty branch removed.  The inner
         `match entries with | [] => ... | _ :: _ => ...` had
         an unreachable `[]` case (since the outer pattern
         already matched `_ :: _`).

      3. **`verifyProof_complete_any_index`** added as the
         strengthened headline (no `b.pending[idx]? = some wd`
         hypothesis required); `verifyProof_complete` is a
         direct corollary that retains the integration plan's
         exact signature.

      4. **Auxiliary lemmas for spec-form soundness:**
         `constructProofAux_leaf_singleton` and
         `mem_filter_pathBitAtLevel_self` (both private).
         These are work-horses for proving the spec's
         existential conclusion `∃ wd, mapped ∧ proof.leaf =
         encode wd`; the full membership corollary is scoped
         as a structural follow-up over the TreeMap-backed
         filter chain.

      5. **`WithdrawalId ≥ 2^64` aliasing documented** as a
         deployment-correctness obligation.  The SMT consults
         only `smtHeight = 64` bits of each id.  In practice,
         the runtime adaptor's `nextWdId` counter is a UInt64
         so this aliasing doesn't occur; the Lean type uses
         `Nat` for arithmetic flexibility.

      6. **15 new tests added:** `bridge-withdrawal-root` +3
         (tampered-index rejection, tampered leaf-adjacent
         sibling, non-membership proof verifies for unmapped
         idx); `bridge-finalisation` +6 (extractFinalisedProof
         API + value-level cases); `bridge-withdrawal-proof-cli`
         +6 (new suite for D.2 CLI integration: save / load /
         extract / verify, byte-stability, absent / corrupt
         snapshot handling).

    Audit-1 raised the test count from 1001 to 1016.  TCB
    unchanged; no new axioms; all theorems use only the
    canonical 3.

    **Workstream-D audit-2 hardening (this branch).**  A second
    audit found that the audit-1 `verifyProof_sound` theorem's
    `h_canonical_sibs_size : ∀ s, s.size = 32` hypothesis was
    *unsatisfiable for the realistic deployment case*.
    Sequentially-assigned WithdrawalIds (the `nextWdId`
    increment-by-1 flow) place ids 0 and 1 in the same deepest
    pair: the canonical leaf-adjacent sibling for id 0 in this
    case is `leafBytes wd_1` (~56 bytes for a `PendingWithdrawal`),
    not 32 bytes.  The audit-1 soundness theorem was therefore
    inapplicable to common production scenarios.

    Audit-2 generalises the soundness theorem:

      1. **`siblingsHaveMatchingSizes` predicate added** —
         element-wise size match between proof and canonical
         siblings (`∀ p ∈ List.zip sibs₁ sibs₂, p.1.size =
         p.2.size`).  Dischargeable in production by the
         runtime adaptor's size-check at the proof-validation
         boundary.

      2. **`verifyProofRec_inj` refactored** to use
         `siblingsHaveMatchingSizes` as its sibling-size
         hypothesis instead of "all 32 bytes".  Plus
         `siblingsHaveMatchingSizes_of_all_32` corollary
         showing the old form is a special case.

      3. **`verifyProof_sound` generalised** to take the
         element-wise size match.  The audit-1 form is
         preserved as `verifyProof_sound_all_32` corollary
         (applies under the SMT-with-leaf-hashing convention,
         which deviates from the spec's `proof.leaf = encode wd`
         semantics).

      4. **8 new edge-case tests added** covering: dense-pair
         (id 0 + id 1 both mapped — canonical proofs verify
         and leaf-adjacent sibling is 56 bytes confirming the
         variable-size path), max-Nat WithdrawalId
         (no crash; treated as `idx mod 2^smtHeight`), unmapped
         id (non-membership proof verifies), and the new
         theorem's term-level API stability.

    Audit-2 raised the test count from 1016 to 1024.  TCB
    unchanged; no new axioms.  Verified end-to-end via the
    `knomosis` binary on a dense-pair snapshot fixture.

  * **Workstream F (cross-stack verification) status:**
    **Complete** as of branch
    `claude/cross-stack-verification-8uwUJ`.  All four
    sub-workstreams (F.1 fixture corpus across 7 sub-WUs, F.2
    goldens, F.3 testnet acceptance script, F.4 property-based
    bridge tests) land with full Lean + Solidity coverage.

    Cumulative fixture-input count: **656** across the six F.1
    fixtures (ECDSA-128 + keccak-104 + deposit-receipt-128 +
    withdrawal-proof-96 + dispute-evidence-168 + migration-32);
    plus 96 mainnet-shaped goldens records + 9 cross-check
    test contracts on the Solidity side.

    The implementation covers every cross-stack invariant
    flagged by the §21 audit:

      * Audit-1 invariants: `signerHint` API, `verdictDigest`
        derivation (no caller-supplied free parameter),
        `MAX_VERDICT_SIGNERS = 64` boundary, `MAX_EVIDENCE_BLOB
        _BYTES = 100_000` boundary, quorum dedup discipline.
      * Audit-2 invariants: variable-size leaf and siblings
        (dense-pair coverage in F.1.5), `resourceId` in
        receiptHash (F.1.4), Bridge `revertToPriorRoot`
        floor+ceiling pair (mirrored in §21.8 / F.3 acceptance).
      * Audit-3 invariants: doubleApply concat shape (`count
        == 2`, `assertFullyConsumed`), predecessor pre-
        commitment direction (F.1.7), CREATE3 cycle-breaking
        + post-deploy `assertConsistent()` discipline (F.3).

    Hash-binding-conditional behaviour: the Lean side's
    `Bridge.HashAdaptor.isKeccak256Linked` flag gates per-entry
    byte-equivalence assertions in the cross-check fixtures —
    when the production keccak256 binding is not linked, the
    Lean fixture content is FNV-derived and the Solidity-side
    cross-check skips with an explicit log line.  CI gates the
    `cross-stack-equivalence` job on the production binding
    being linked.  Without the binding, **8 Solidity cross-
    stack tests skip; with the binding, all 197 Solidity tests
    pass**.

    Workstream-F adds **3 property-based bridge tests** (F.4)
    over the §12.13 `bridgeLawSet : MonotonicLawSet`:
    `prop_deposit_then_withdraw_roundtrip`,
    `prop_bridge_account_invariant_holds`, and
    `prop_withdrawal_proof_verifies` (the latter discharged
    unconditionally by `verifyProof_complete`).
    `Laws.withdraw` is deliberately excluded from the law set
    via the typeclass-level forward-protection
    (`withdraw_not_monotonic` — adding `withdraw` to the law
    list produces a `failed to synthesize IsMonotonic` error
    at elaboration time).

    Test count grew from 1024 to **1100** (+76 tests across 9
    new suites: 8 framework + 7 ECDSA + 9 keccak + 11 deposit-
    receipt + 8 withdrawal-proof + 10 dispute-evidence + 10
    migration-attestation + 10 goldens + 3 property-bridge).
    Solidity test count grew from 166 to **189 + 8
    conditionally-skipped** (+23 / +8: 9 new cross-check
    contracts).  No new theorem obligations (F is a cross-
    stack equivalence corpus, not a kernel-level proof
    obligation, per §21.11).  TCB unchanged; no new axioms.

    `kernelBuildTag` bumped to
    `"knomosis-ethereum-workstream-f-cross-stack-verification"`.

    **Toolchain bootstrap.**  `scripts/setup.sh` extended to
    install Foundry v1.7.0 (SHA-256 pinned for x86_64 +
    aarch64) and solc v0.8.20 (SHA-256 pinned for x86_64;
    upstream v0.8.20 doesn't ship an ARM static binary).  New
    flags `--skip-solidity` and `--solidity-only`.  A
    `.claude/hooks/session-start.sh` SessionStart hook invokes
    `setup.sh --quiet` so subsequent `lake build` / `forge
    test` calls don't race against an in-flight install.

## Executive summary

The MVP makes Knomosis usable by any Ethereum wallet against any
EVM chain.  Concretely:

  * **Seven workstreams**, forty-eight leaf work units (after
    Audit-2 decomposed the six most complex parents — C.1, C.6,
    D.1, E.1, E.2, F.1 — into atomic sub-WUs).  ≈ 9 wall-clock
    weeks with two engineers; ≈ 5 weeks with four (decomposition
    enabled additional intra-parent parallelism).
  * **Three new `Action` constructors** at frozen indices 12, 13,
    14: `registerIdentity` (12, landed in Workstream B —
    pulled forward from the plan's original C.4 attribution because
    B.2's `ingest` and B.3's `bridgePolicy` cannot type-check
    without it), `deposit` (13, Workstream C), `withdraw`
    (14, Workstream C).  Plus two new `Event` constructors at
    indices 9, 10 (`withdrawalRequested`, `depositCredited`).
    Constructor indices are append-only; once landed they are
    immutable.
  * **One new `ExtendedState` field** (`bridge : BridgeState`),
    holding the consumed-deposit set and pending withdrawals.
    `ExtendedState` is non-TCB; the field addition does not
    expand the kernel.
  * **Two extern-linked Rust adaptors**: ECDSA secp256k1
    (`knomosis_verify`) and keccak256 (`knomosis_hash_bytes`), wiring
    Knomosis's existing `Verify` opaque and `hashBytes` swap-point
    to production-grade implementations.
  * **Five Solidity contracts**: `KnomosisBridge.sol`,
    `KnomosisDisputeVerifier.sol`, `KnomosisIdentityRegistry.sol`,
    `KnomosisSequencerStake.sol`, and `KnomosisMigration.sol`.
    All five are **deployed immutably** — no proxies, no
    `initialize`, no upgrade authority, no `Pausable`, no
    mutable role grants.  Recovery from sequencer or attestor
    misbehaviour uses the dispute pipeline (Phase-6
    `applyVerdict` rolls back state at the contract level via
    `revertToPriorRoot`); recovery from genuinely buggy
    contract code uses an attested one-shot handoff to a
    successor deployment via `KnomosisMigration.sol`.  The
    immutability discipline mirrors the kernel TCB: just as
    `Kernel.lean` / `RBMapLemmas.lean` are not field-mutable,
    the on-chain rules are not field-mutable.  See §4.8.
  * **Sixty-eight proof obligations** enumerated in §12, every
    one a full Lean proof under the canonical three-axiom set.
    A handful (the EIP-712 wrap and the Merkle-soundness theorem
    `verifyProof_sound`) are stated under a `CollisionFree`
    hypothesis (a `Prop` parameter, not an axiom); the rest are
    unconditional.  The Audit-2 decomposition replaced two
    monolithic theorems (`bridge_supply_account_general` and
    `verifyProof_complete`/`_sound`) with thirteen smaller named
    lemmas each, none individually exceeding ≈ 30 lines of
    tactics.
  * **One headline composition theorem**, `bridge_deployment_safety`
    (§12.13), bundling per-resource bridge accounting, per-actor
    nonce monotonicity, once-registered-always-registered, and
    first-time-registration discipline into a single
    four-conjunct `And` proposition the L1 contracts rely on.

The architecture deliberately avoids any kernel TCB change: the
two-reviewer §14.4 gate applies only to G.1 (the Genesis Plan
amendment).  Every other WU lands under the standard one-reviewer
discipline.

## Table of contents

  1. [Purpose and scope](#1-purpose-and-scope)
  2. [Goals and non-goals](#2-goals-and-non-goals)
  3. [Architecture overview](#3-architecture-overview)
  4. [Design principles](#4-design-principles)
  5. [Workstream A — cryptographic adaptors](#5-workstream-a--cryptographic-adaptors)
  6. [Workstream B — identity and authority](#6-workstream-b--identity-and-authority)
  7. [Workstream C — bridge laws](#7-workstream-c--bridge-laws)
  8. [Workstream D — withdrawal proofs](#8-workstream-d--withdrawal-proofs)
  9. [Workstream E — Solidity contracts](#9-workstream-e--solidity-contracts)
  10. [Workstream F — cross-stack verification](#10-workstream-f--cross-stack-verification)
  11. [Workstream G — documentation and amendment](#11-workstream-g--documentation-and-amendment)
  12. [Mathematical correctness obligations](#12-mathematical-correctness-obligations)
  13. [Sequencing and dependencies](#13-sequencing-and-dependencies)
  14. [Acceptance gates](#14-acceptance-gates)
  15. [Risks and mitigations](#15-risks-and-mitigations)
  16. [Out of scope (post-MVP)](#16-out-of-scope-post-mvp)
  17. [Glossary](#17-glossary)
  18. [Audit-1 changelog](#18-audit-1-changelog)
  19. [Audit-2 changelog](#19-audit-2-changelog)
  20. [Immutability amendment changelog](#20-immutability-amendment-changelog)
  21. [Workstream-F audit changelog](#21-workstream-f-audit-changelog)
  22. [Workstream-F implementation audit changelog](#22-workstream-f-implementation-audit-changelog)

---

## 1. Purpose and scope

Knomosis (Phases 0–6, complete as of the parent branch) is a
proof-carrying state-transition system specified for the security
model of a sequenced, signed, append-only log with a per-actor
nonce ledger and a four-stage dispute pipeline.  Ethereum L1
supplies a settlement layer with economic finality, a public
identity layer (ECDSA secp256k1 keys, optionally EIP-1271
smart-contract signers), and a permissionless dispute substrate
(a Solidity contract anyone can call).

The architectural fit between the two systems is unusually clean:
Knomosis's existing primitives map almost 1-to-1 onto rollup
primitives (see §3 for the alignment table).  The MVP is therefore
not a *reimplementation* but a *deployment*: the kernel and laws
stay untouched, and the bridge surface is a new non-TCB module set
that plugs into existing typeclass and opaque slots.

This document plans the engineering effort to land that deployment.
It enumerates the workstreams (§5–§11), the proof obligations each
workstream owes (§12), the dependency DAG (§13), and the acceptance
gates each work unit must clear before merging (§14).

## 2. Goals and non-goals

### 2.1 Goals (what shipping the MVP means)

  1. **A real ETH or ERC-20 token can be deposited** by an EOA via
     a single L1 transaction; the funds appear in the depositor's
     Knomosis balance within one settlement window.
  2. **A Knomosis transaction signed with a standard Ethereum wallet**
     (MetaMask, hardware wallet, etc.) is admissible without any
     custom signing software on the user's side.  This requires the
     signing-input round-tripping cleanly through EIP-712.
  3. **A Knomosis withdrawal can be redeemed on L1** by presenting a
     Merkle proof of inclusion in a finalised state root.
  4. **A misbehaving sequencer is provably challengeable on L1**
     using the existing Phase-6 dispute pipeline — at minimum, the
     `signatureInvalid`, `nonceMismatch`, and `doubleApply` claim
     variants must round-trip through the L1 dispute verifier.
  5. **All Phase-0–6 type-level guarantees survive verbatim.**
     `lake build`, `lake test`, `lake exe count_sorries`,
     `lake exe tcb_audit`, and `lake exe stub_audit` continue to
     pass.  `#print axioms` on every kernel theorem returns
     exactly `[propext, Classical.choice, Quot.sound]`.
  6. **The trust-assumption inventory is documented** in
     `docs/extraction_notes.md` §2 — every new opaque or
     `@[extern]` dependency lists its security assumption.

### 2.2 Non-goals (deferred to v2 or later)

  1. **Widening `ActorId` from `UInt64` to a 20-byte address type.**
     A registry indirection (workstream B.1) suffices for the MVP;
     widening is a kernel TCB change requiring two reviewers and
     a §14.4 Genesis-Plan amendment.
  2. **ZK proofs of `apply_admissible`.**  The MVP is optimistic
     only.  ZK extension is a candidate Phase 8 deliverable.
  3. **Bisection dispute games.**  The MVP uses one-shot fraud
     proofs over a bounded log prefix; bisection is the right
     answer for production-scale logs but is out of scope here.
  4. **Account abstraction (ERC-4337).**  EIP-1271 is in scope
     (workstream A.1); ERC-4337's UserOperation envelope is not.
  5. **Cross-rollup interop.**  `deploymentId` already gives
     cross-rollup replay rejection; bidirectional cross-rollup
     bridges are not in the MVP.
  6. **Native ETH gas accounting.**  The MVP's economic model is
     "the sequencer is paid out-of-band"; on-chain gas markets
     and fee burning are post-MVP.
  7. **Sequencer decentralisation.**  The MVP runs a single
     sequencer with a published attestation key; rotated /
     multi-attestor / leader-election schemes are post-MVP.

### 2.3 The minimum-viable acceptance test

The MVP is "done" when the following acceptance script passes
end-to-end on a public Ethereum testnet (Sepolia or Holesky):

  1. Alice deposits 1 ETH to `KnomosisBridge.sol`.
  2. The Knomosis sequencer ingests the deposit event and credits
     1 ETH to Alice's Knomosis address.
  3. Alice signs an `Action.transfer 1_eth Bob 0.5_eth` via
     MetaMask using the EIP-712 envelope.
  4. The sequencer applies the transfer; Bob's Knomosis balance shows
     0.5 ETH.
  5. Bob signs an `Action.withdraw 1_eth Bob 0.5_eth` via MetaMask.
  6. The sequencer applies the withdrawal; the post-state root is
     submitted to `KnomosisBridge.sol`.
  7. After the dispute window closes, Bob calls
     `KnomosisBridge.withdrawWithProof(...)` and receives 0.5 ETH at
     his L1 address.

Each of those seven steps maps onto a closed workstream below.

## 3. Architecture overview

### 3.1 Alignment table (Knomosis ↔ rollup primitives)

| Knomosis primitive                           | Defined in                              | Ethereum / rollup role                         |
|-------------------------------------------|-----------------------------------------|------------------------------------------------|
| `Verify` opaque                           | `Authority/Crypto.lean:138`             | ECDSA secp256k1 (with EIP-1271 dispatch)       |
| `Runtime.Hash.hashBytes` (FNV-1a-64)      | `Runtime/Hash.lean`                     | keccak256 (linked via `@[extern]`)             |
| `signingInput` with `deploymentId`        | `Encoding/SignInput.lean` + Audit-3.4   | EIP-712 envelope; cross-chain replay rejection |
| `KeyRegistry`                             | `Authority/Identity.lean`               | Mirror of `KnomosisIdentityRegistry.sol`          |
| `Snapshot` + `AttestedSnapshot`           | `Runtime/Snapshot.lean`, Audit-3.2      | Periodic state-root commit on L1               |
| `Disputes` pipeline (Phase 6)             | `LegalKernel/Disputes/`                 | One-shot fraud proofs in `KnomosisDisputeVerifier.sol` |
| `IsConservative` / `IsMonotonic`          | `Conservation.lean`                     | Bridge-safety invariants                       |
| `replay_impossible` / `nonce_uniqueness`  | `Authority/SignedAction.lean`           | Per-actor anti-replay; matches EOA tx-nonce    |
| CBE canonicality + `*_encode_deterministic` | `Encoding/State.lean`                 | Byte-stable Merkle leaves for state roots      |
| `apply_admissible_with_eq_kernelOnlyApply` | Audit-3.6                              | Off-chain ↔ on-chain coherence theorem         |
| `VerdictPassedStage3` witness             | Phase-6 Option-C / `Disputes/Verdict.lean` | Type-level Stage-3 enforcement on L1 finalisation |
| TCB immutability + frozen action indices  | `Kernel.lean`, §4.3 indices              | Immutable contract code + `immutable` Solidity addresses (no proxy / no `initialize`) |
| `AttestedSnapshot` (Audit-3.2)            | `Runtime/AttestedSnapshot.lean`         | Attested handoff payload for `KnomosisMigration.sol`  |

### 3.2 Layered diagram

```
┌────────────────────────────────── Ethereum L1 ──────────────────────────────────┐
│                                                                                 │
│   ┌───────────────────────┐     ┌───────────────────────────┐                   │
│   │  KnomosisBridge.sol      │     │  KnomosisIdentityRegistry    │                   │
│   │    deposit(token, a)  │     │    register(addr, pk)     │                   │
│   │    submitStateRoot()  │     │    revoke(addr)           │                   │
│   │    withdrawWithProof  │     │    emits events           │                   │
│   └───────────────────────┘     └───────────────────────────┘                   │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │  KnomosisDisputeVerifier.sol                                               │   │
│   │    fileDispute(claim, evidenceBlob)    — mirrors Phase-6 Stage 1        │   │
│   │    checkEvidence(...)                  — ports Stage 2 verifiers        │   │
│   │    finalizeUpheld(verdict, sigs)       — mirrors applyVerdict           │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
└────────────┬────────────────────────────────────────────────────┬───────────────┘
             │ deposit / register / revoke events                 │ state roots,
             │                                                    │ disputes
┌────────────┴────────────────────────────────────────────────────┴───────────────┐
│                       Knomosis Runtime (sequencer / replica)                       │
│                                                                                 │
│   ┌──────────────────────────────┐    ┌─────────────────────────────────────┐   │
│   │  L1 ingestor                 │    │  L1 publisher                       │   │
│   │  (L1 event log -> Action)    │    │  (snapshot -> state-root tx)        │   │
│   └──────────────────────────────┘    └─────────────────────────────────────┘   │
│                                                                                 │
│   ┌─────────────────────────── extern bindings ─────────────────────────────┐   │
│   │    Verify  := ECDSA secp256k1 (low-s canonical)        [WU A.1]         │   │
│   │    Hash    := keccak256                                [WU A.2]         │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│   ┌───────────────────── Phase-5 runtime (untouched) ───────────────────────┐   │
│   │   processSignedAction · bootstrap · replay · snapshot                   │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│   ┌──────────────── Phase-6 dispute pipeline (untouched) ───────────────────┐   │
│   │   fileDispute · checkEvidence · proposeAndApplyVerdict                  │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│   ┌───────────────── Phase-0–4 kernel + laws (TCB unchanged) ───────────────┐   │
│   │   apply_admissible_with · step_impl · IsConservative / IsMonotonic      │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│   ┌───────────────────────── new bridge layer ──────────────────────────────┐   │
│   │   Laws.deposit · Laws.withdraw · Bridge.AddressBook · Bridge.Ingest     │   │
│   │   Bridge.WithdrawalRoot · Bridge.Eip712 · Bridge.Conservation           │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### 3.3 Trust-boundary inventory

The MVP introduces the following new trust assumptions, all
cryptographic or economic, none Lean-axiomatic:

  1. **EUF-CMA on ECDSA secp256k1** (existing for Phase 3, made
     concrete by workstream A.1).
  2. **Collision resistance of keccak256** (existing for Audit-3.1
     in skeletal form, made concrete by workstream A.2).
  3. **Ethereum L1 finality** at the sequencer's chosen depth
     (configurable; default 64 blocks ≈ 12 minutes post-Casper).
  4. **Solidity contract correctness** for `KnomosisBridge.sol`,
     `KnomosisDisputeVerifier.sol`, `KnomosisIdentityRegistry.sol`,
     `KnomosisSequencerStake.sol`, and `KnomosisMigration.sol`
     (workstream E; mitigated by F.1 cross-stack equivalence).
     Because the contracts are immutable, the pre-deployment
     audit bar is higher than for upgradeable contracts: there
     is no post-deployment patch path for code defects.  The
     compensating control is that all behaviour-shaping code is
     proven correct on the Lean side first; the Solidity side
     is a port whose correctness is checked against the Lean
     reference by F.1 corpus.
  5. **EIP-1271 contract correctness** for any contract signers
     the deployment chooses to admit (workstream A.1; opt-in).
  6. **Migration attestor** (the same key as the §3.3 attestor
     for the predecessor deployment).  Compromise lets the
     attacker propose a malicious successor `KnomosisMigration.sol`
     deployment.  The 30-day grace window plus the immutable
     successor address (set at `KnomosisMigration` construction
     time, not later mutable) bound the blast radius: users
     have a deterministic deadline to redeem at the predecessor
     before the migration activates.  See §15.8.

Every new assumption is enumerated in `docs/extraction_notes.md`
§2 by workstream G.4.

## 4. Design principles

### 4.1 The TCB never grows

`Kernel.lean` and `RBMapLemmas.lean` stay untouched.  Every WU
that is tempted to import or modify either of them is
re-architected to live in a non-TCB module.  Two-reviewer reviews
under Genesis Plan §14.4 are explicitly out of scope for the MVP;
any WU that requires one is *by definition* deferred.

### 4.2 No new axioms

Every new opaque (e.g. `eip712Wrap`) is declared `opaque`, never
`axiom`, so `#print axioms` continues to yield only the three Lean
built-ins.  Cryptographic assumptions surface as opaque-extern
bindings, not as Lean axioms.

### 4.3 Append-only constructor indices

`Action`'s frozen indices 0..11 stay frozen.  New constructors
take indices 12 (`deposit`), 13 (`withdraw`), and 14
(`registerIdentity`; see §6.3 design note).  `Event`'s frozen
indices 0..8 stay frozen; new constructors take indices 9
(`withdrawalRequested`) and 10 (`depositCredited`).  Once landed,
these indices are immutable forever — re-grouping is forbidden
under the same rule that governs the Phase-3 / Phase-6 indices.

### 4.4 Type-level firewalls preserved

The new bridge laws ship explicit `IsMonotonic` instances or
explicit non-monotonicity witnesses.  `MonotonicLawSet`
constructions involving the bridge are gated by the witnesses, so
deployments that want strict supply-non-decrease can refuse the
`withdraw` law at the type level.

### 4.5 Determinism end-to-end

Every new function from `(L1 event) → (Knomosis SignedAction)` is a
pure function.  Where ECDSA is used to author bridge-emitted
actions (B.3), the runtime adaptor uses RFC 6979 deterministic
ECDSA to keep test vectors stable.

### 4.6 Mathematical correctness is non-negotiable

Every WU's exit criterion includes a list of theorems that *must*
be proved before merge — not as `sorry`-bearing scaffolds, not as
admitted axioms, not as `unsafe` declarations, but as full Lean
proofs whose `#print axioms` output is the canonical built-in set.
Workstream-level theorem inventories appear in §12.

### 4.7 No process markers in identifier names

Per the existing CLAUDE.md rule, new declaration names describe
content (`deposit_isMonotonic`, `bridge_supply_account`), never
provenance (no `eth_`, `mvp_`, `wu_`, `phase_e_` tokens in
identifier names).  Process markers may appear in docstrings and
commit messages.

### 4.8 L1 contract immutability mirrors kernel TCB immutability

Knomosis's central invariant is "behaviour is mutable through
proof-carrying state transitions; rules are immutable in the
kernel."  The L1 contracts mirror this exactly: state is mutable
(via proof-gated entry points such as `withdrawWithProof`,
`submitStateRoot`, `fileDispute`); code is immutable (no
proxies, no `initialize`, no `proposeUpgrade`, no mutable
admin role).  Concretely:

  1. **No proxies.**  Every contract is deployed via
     `CREATE2` with a deterministic salt straight to its final
     address.  `TransparentUpgradeableProxy`,
     `UUPSUpgradeable`, `BeaconProxy`, and equivalents are
     forbidden.  No contract has an `initialize` function;
     all state is set in the constructor.
  2. **No mutable admin role.**  `AccessControl`'s
     `grantRole` / `revokeRole` family is forbidden for
     deployment-lifetime authority transfer.  Each role
     (attestor, dispute verifier, sequencer) is encoded as
     an `address public immutable` set in the constructor.
     Rotation requires a new deployment + migration; there
     is no shorter path.
  3. **No human-triggered pause.**  `Pausable.pause()` is
     forbidden because it concentrates trust in whoever
     holds `PAUSER_ROLE`.  The dispute pipeline is the
     granular pause: bad transactions are rolled back
     individually via `applyVerdict`; good transactions
     continue.  Where a *whole-system* halt is genuinely
     needed (e.g. a divergence between Lean-side and
     Solidity-side hash bindings — see §15.13), it is
     triggered by automatic *circuit breakers* — `revert`
     guards that fire on observable, deterministic
     predicates over public state with no privileged caller.
  4. **No mutable parameters.**  Every safety-critical
     parameter (`disputeWindowBlocks`,
     `maxRedemptionWindowBlocks`, `slashRatio`,
     `quorumThreshold`, `tvlCap`, `cooldownBlocks`,
     `maxAttestationStaleBlocks`) is `immutable` and set
     in the constructor.  Tuning a parameter requires a
     new deployment.
  5. **Recovery via the dispute pipeline, not via
     code.**  When something goes wrong on-chain, the
     response is a dispute filing — never an upgrade.  The
     dispute pipeline is the *only* mechanism by which the
     contract's behaviour can change after deployment, and
     it does so by changing *state*, not *code*.
  6. **Migration via attested handoff, not via code
     upgrade.**  When a code defect is found that the
     dispute pipeline cannot remediate (genuinely buggy
     contract code, e.g., an arithmetic overflow in
     `slash`), recovery is by deploying a fresh immutable
     contract and using `KnomosisMigration.sol` to attest the
     handoff.  Migration is a *one-shot, immutable record*
     in a *separate* contract — never a capability of the
     bridge itself.  See §9.5.

The mathematical justification: every safety property the
contract is supposed to enforce is also enforced by the
Lean-side equivalent under the F.1 cross-stack equivalence
corpus.  If the Lean side is correct (Phase 0–6 + Workstream A–D
proofs) and the cross-stack equivalence holds (workstream F.1),
then the Solidity side is correct.  The pre-deployment audit
bar is therefore higher than for upgradeable contracts — but the
post-deployment trust assumption is *strictly weaker*: there is
no `UPGRADER_ROLE` whose compromise drains the bridge.  The
total trust-assumption inventory shrinks (§15.7), and a whole
risk class (§15.8 in the upgradeable design) disappears.

## 5. Workstream A — cryptographic adaptors

**Status: COMPLETE (Lean side) as of branch
`claude/implement-crypto-adaptors-fo76C`.**  Rust-side adaptor
crates deferred to a follow-up PR — see the §5 status notes per
sub-WU below for the per-deliverable picture.

This workstream replaces the two opaque/fallback primitives
(`Verify`, `hashBytes`) with production Ethereum-native
implementations linked via `@[extern]`.  Both are runtime-side
deliverables; the Lean side gains tests and stability theorems
but no new TCB.

### 5.1 WU A.1 — ECDSA secp256k1 verify with low-s canonicalisation

**Status:** Lean side complete (`LegalKernel/Bridge/VerifyAdaptor.lean`
+ `LegalKernel/Test/Bridge/VerifyAdaptor.lean`); Rust crate
`runtime/knomosis-verify-secp256k1` deferred to follow-up.

**Owner:** runtime (Rust); **Reviewer count:** 1; **Depends on:** none.

**Deliverable.**  A Rust crate `runtime/knomosis-verify-secp256k1`
exporting one C-ABI symbol matching the
`Authority/Crypto.lean:138` opaque signature:

```c
extern "C" bool knomosis_verify(
  const uint8_t* pk,  size_t pk_len,
  const uint8_t* msg, size_t msg_len,
  const uint8_t* sig, size_t sig_len);
```

The implementation:
  1. Parses `pk` as a 33-byte compressed or 65-byte uncompressed
     secp256k1 point; rejects malformed input with `false`.
  2. Parses `sig` as a 65-byte `(r ‖ s ‖ v)` Ethereum-style
     signature; rejects malformed input with `false`.
  3. **Rejects high-s signatures** (the canonical EIP-2 / BIP-62
     constraint `s ≤ n/2`).  This blocks the malleability vector
     where two different `(r, s)` pairs verify the same message
     under the same key.
  4. Runs `secp256k1_ecdsa_verify` (via the audited
     `libsecp256k1`).
  5. Returns the boolean result.

**Lean-side stability tests** (`Test/Bridge/VerifyAdaptor.lean`):

  * `verifyAdaptor_accepts_canonical : Verify pk msg sig = true`
    on a hardcoded `(pk, msg, sig)` triple lifted from a real
    Ethereum testnet transaction.
  * `verifyAdaptor_rejects_high_s : Verify pk msg sigHighS = false`
    using the same triple with `s' := n - s`.
  * `verifyAdaptor_rejects_corrupt : Verify pk msg' sig = false`
    when `msg'` differs from `msg` by one byte.

**Acceptance criteria.**

  * 100 / 100 passes on a property-based corpus of randomly
    generated `(seed, msg)` pairs (sign with seed-derived key,
    verify, expect `true`); seeds are reproducible via the
    `KNOMOSIS_PROPERTY_SEED` env var (`Audit-3.9`).
  * 0 / 100 false-accepts on a corpus of random `(pk, msg, sig)`
    triples (none are real signatures; all should reject).
  * Cross-check against `geth`'s `crypto.VerifySignature` on a
    100-signature golden file.

**Threat-model note.**  EUF-CMA on secp256k1 is the cryptographic
assumption that backs every signature-derived guarantee in Phase 3
(`replay_impossible`, `nonce_uniqueness`).  The Phase-3 proofs do
not depend on the assumption (they reason purely about nonces);
the assumption is what closes the gap between "the proofs hold
for any `Verify`" and "the proofs hold for the real signature
scheme".

### 5.2 WU A.2 — keccak256 hash adaptor

**Status:** Lean side complete (`LegalKernel/Bridge/HashAdaptor.lean`
+ `LegalKernel/Test/Bridge/HashAdaptor.lean`); Rust crate
`runtime/knomosis-hash-keccak256` deferred to follow-up.

**Owner:** runtime (Rust); **Reviewer count:** 1; **Depends on:** A.1
(shares Rust crate skeleton).

**Deliverable.**  A Rust crate `runtime/knomosis-hash-keccak256`
exporting the three C-ABI symbols already documented in
`docs/abi.md §11` (Audit-3.1):

```c
extern "C" void knomosis_hash_bytes (const uint8_t* in, size_t len,
                                  uint8_t out[32]);
extern "C" void knomosis_hash_stream(/* CBE stream input */);
extern "C" void knomosis_hash_identifier(uint8_t out[32]);
```

`knomosis_hash_identifier` returns the 32-byte ASCII identifier
`"keccak256/EVM-compatible/v1\0\0\0\0"` so deployments can
distinguish hash schemes at runtime.

**Lean-side stability tests** (`Test/Bridge/HashAdaptor.lean`):

  * `hashAdaptor_matches_l1_keccak : hashBytes input₀ =
    expected₀` for a 32-tuple golden file lifted from
    `keccak256.spec` test vectors and from real Ethereum block
    headers.
  * `hashAdaptor_deterministic` — already proved generically;
    re-asserted at the value level for the new binding.
  * `hashAdaptor_thirty_two_byte_output` — output length is 32
    for every input (the Audit-3.1 size invariant).

**Acceptance criteria.**

  * 32 / 32 goldens match.
  * `knomosis-replay --allow-fallback-hash` is *not* required to be
    set; the binary refuses to start without the keccak256
    binding.

**Threat-model note.**  Collision resistance of keccak256 is the
cryptographic assumption that backs every state-root guarantee
(`replicaFromSnapshot`'s seed-hash check, the dispute pipeline's
log-prefix-replay check).  No Lean theorem depends on the
*structure* of keccak256; the assumption only enters at the
deployment boundary.

### 5.3 WU A.3 — EIP-712 sign-input wrapping

**Status:** Complete (`LegalKernel/Bridge/Eip712.lean` +
`LegalKernel/Test/Bridge/Eip712.lean`).  All three §12.6
theorems (`eip712Wrap_injective`,
`eip712DomainSeparator_distinguishes`, `eip712Wrap_distinguishes`)
ship without `sorry` and `#print axioms`-clean.

**Spec compliance (post-audit-1).**  An initial implementation
shipped with two spec deviations: (a) the struct hash committed
only to `actionHash` while the type string declared four fields
(would have broken MetaMask interop); (b) ByteArray-typed fields
(`deploymentId`, `verifyingContract`) were declared with fixed
type names (`bytes32` / `address`) but encoded via hashing
(EIP-712's `bytes` rule).  Workstream-A audit-1 closed both:
the struct hash now encodes all four declared fields per
EIP-712 spec, and the type strings now declare `bytes` for the
hashed fields.  Under the corrected type strings, the Lean
encoder is **byte-for-byte EIP-712 spec-compliant** — a
spec-compliant wallet (MetaMask, Ledger, etc.) parsing the
declared types and signing produces a struct hash that exactly
equals `eip712StructHash m`.  The §5.3 acceptance criterion
("MetaMask-produced EIP-712 signature on a Knomosis `signInput`
verifies via the A.1 binding") is therefore satisfied at the
byte level, not just the security-property level.

**Owner:** Lean + runtime; **Reviewer count:** 1; **Depends on:**
A.1 (verify must understand wrapped form), A.2 (keccak256 used
inside the wrap).

**Deliverable.**  A new module `LegalKernel/Bridge/Eip712.lean`
exporting an EIP-712 envelope built from a *structured* type
(rather than an opaque blob, which would not conform to EIP-712's
typed-data spec):

```lean
namespace LegalKernel.Bridge

/-- EIP-712 domain separator for Knomosis-on-Ethereum.  Hashed once
    per deployment; cached in the runtime adaptor.  The four
    fields match EIP-712's standard `EIP712Domain` type:
    `name`, `version`, `chainId`, `verifyingContract`. -/
def eip712DomainSeparator
    (name : ByteArray) (version : ByteArray)
    (chainId : Nat) (rollupId : Nat)
    (verifyingContract : ByteArray) : ByteArray

/-- The Knomosis-action EIP-712 type.  Wallet UIs render this as
    structured fields rather than as an opaque blob, which is a
    UX win (the user sees what they're signing) and a security
    win (a malicious dApp cannot trick the user into signing an
    arbitrary byte sequence).

    The `actionHash` field is `keccak256 (knomosisSignInput action
    signer nonce deploymentId)` — a 32-byte commitment to the
    full Knomosis CBE-encoded sign-input.  The wallet recomputes
    this hash from the ABI-encoded action params it displays,
    closing the loop with the L1 dispute verifier's recomputation. -/
def knomosisActionTypeHash : ByteArray :=
  /- = keccak256("KnomosisAction(bytes32 actionHash,uint64 signer,
                  uint64 nonce,bytes32 deploymentId)") -/

/-- Compute the EIP-712 struct hash for a Knomosis action.
    `structHash := keccak256(typeHash ‖ encodeStructFields(...))`
    where field encoding follows EIP-712 (32-byte right-padded
    bytes32 for hashes, 32-byte left-padded uint for ints). -/
def eip712StructHash
    (knomosisActionHash : ByteArray) (signer : ActorId)
    (nonce : Nonce) (deploymentId : ByteArray) : ByteArray

/-- Wrap a Knomosis `signInput` as an EIP-712 typed-structured-data
    message.  Returns the bytes the wallet signs:
    `0x19 ‖ 0x01 ‖ domainSep ‖ structHash`. -/
def eip712Wrap
    (action : Action) (signer : ActorId) (nonce : Nonce)
    (deploymentId : ByteArray) (domainSep : ByteArray)
    : ByteArray

end LegalKernel.Bridge
```

and the proof obligations:

```lean
/-- The wrap is injective in its message argument under a fixed
    domain separator. -/
theorem eip712Wrap_injective :
  ∀ d m₁ m₂, eip712Wrap m₁ d = eip712Wrap m₂ d → m₁ = m₂

/-- Domain separation: distinct chain / rollup / contract triples
    yield distinct domain separators. -/
theorem eip712DomainSeparator_distinguishes :
  ∀ c₁ r₁ v₁ c₂ r₂ v₂,
    (c₁, r₁, v₁) ≠ (c₂, r₂, v₂) →
    eip712DomainSeparator c₁ r₁ v₁ ≠ eip712DomainSeparator c₂ r₂ v₂

/-- The wrap is content-distinguishing across all (msg, domain)
    pairs. -/
theorem eip712Wrap_distinguishes :
  ∀ m₁ m₂ d₁ d₂, (m₁, d₁) ≠ (m₂, d₂) →
    eip712Wrap m₁ d₁ ≠ eip712Wrap m₂ d₂
```

The first two are direct corollaries of keccak256 collision
resistance plus injectivity of the prefix-concat envelope; the
third combines them.  Each gets a non-trivial Lean proof — the
keccak256 collision-resistance assumption is *not* introduced as
a Lean axiom; the theorems are stated with a hypothesis "assuming
hash_collision_resistant" and the test corpus exercises the
implication value-level.

**Acceptance criteria.**

  * The three theorems above ship without `sorry`.
  * Round-trip test: a MetaMask-produced EIP-712 signature on a
    Knomosis `signInput` verifies via the A.1 binding.
  * Cross-protocol distinguishability: an EIP-712-wrapped
    `signInput` produces bytes structurally distinct from
    a plain Knomosis `signedActionDomain`-prefixed `signInput`
    (already required by Audit-2; A.3 inherits the test).

## 6. Workstream B — identity and authority

This workstream wires Ethereum's address-based identity model into
Knomosis's `KeyRegistry` infrastructure without changing the kernel's
`ActorId : UInt64` abbreviation.

### 6.1 WU B.1 — `AddressBook` module

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** none.

**Deliverable.**  A new module `LegalKernel/Bridge/AddressBook.lean`:

```lean
/-- An Ethereum 20-byte address.  Represented as `Fin (2^160)`
    rather than `ByteArray` so that:

      1. The 20-byte width is enforced at the type level rather
         than by a runtime check (`Fin n` proves `i < n`
         constructively).
      2. The default `Ord (Fin n)` instance gives a numeric
         comparator that works directly with `Std.TreeMap`,
         avoiding the need for a custom `Ord ByteArray`
         instance (which Lean core does not ship).
      3. Decidable equality is automatic.

    `EthAddress.ofBytes : ByteArray → Option EthAddress`
    converts a 20-byte ByteArray to an `EthAddress`, returning
    `none` if the byte array is not exactly 20 bytes; the runtime
    adaptor performs this validation at the deployment boundary.

    Note: the existing `BoundedNat` structure in
    `Encoding/Encodable.lean` is hardcoded `< 2^64` and is
    therefore *not* suitable for a 160-bit address. -/
abbrev EthAddress : Type := Fin (2^160)

structure AddressBook where
  /-- Mapping from Ethereum 20-byte addresses to Knomosis ActorIds. -/
  forward  : Std.TreeMap EthAddress ActorId compare
  /-- Inverse mapping for log-extraction.  Maintained as the
      key-by-key inverse of `forward`; the `addressBook_invariant`
      below pins the relationship at the type level. -/
  reverse  : Std.TreeMap ActorId EthAddress compare
  /-- The next `ActorId` to assign on first-time registration.
      Strictly monotonic; never decreases. -/
  nextActorId : ActorId

namespace AddressBook
def empty : AddressBook
def lookup    (b : AddressBook) (addr : EthAddress)  : Option ActorId
def lookupRev (b : AddressBook) (id   : ActorId)     : Option EthAddress
def assign    (b : AddressBook) (addr : EthAddress)  : AddressBook × ActorId
end AddressBook
```

with theorems:

```lean
theorem addressBook_invariant (b : AddressBook) :
  ∀ addr id, b.lookup addr = some id ↔ b.lookupRev id = some addr

theorem assign_fresh_actorId :
  ∀ b addr, b.lookup addr = none →
    let (b', id) := b.assign addr
    b'.lookup addr = some id ∧ b.nextActorId ≤ b'.nextActorId

theorem assign_idempotent_for_known :
  ∀ b addr id, b.lookup addr = some id →
    let (b', id') := b.assign addr
    b' = b ∧ id' = id
```

**Acceptance criteria.**

  * The three theorems above ship without `sorry`.
  * `Test/Bridge/AddressBook.lean` covers: empty / single /
    duplicate / collision (never collide because IDs are
    monotonic) / serialisation round-trip.
  * The module imports only `Std.Data.TreeMap` and
    `LegalKernel.Kernel`; no kernel-TCB imports beyond those
    already on the allowlist.

### 6.2 WU B.2 — L1-event ingestor for identity events

**Owner:** Lean + runtime; **Reviewer count:** 1; **Depends on:** B.1.

**Deliverable.**  A new module `LegalKernel/Bridge/Ingest.lean`
defining an inductive of L1 events Knomosis ingests:

```lean
inductive L1Event
  | identityRegistered (addr : EthAddress) (pk : PublicKey)
                        (blockNum : Nat) (logIdx : Nat)
  | identityRevoked    (addr : EthAddress) (blockNum : Nat) (logIdx : Nat)
  | depositInitiated   (addr : EthAddress) (resource : ResourceId)
                        (amount : Amount)  (receiptHash : ByteArray)
                        (blockNum : Nat)   (logIdx : Nat)
  deriving Repr, DecidableEq
```

and a deterministic translator that returns *unsigned* data:

```lean
/-- The unsigned envelope that `ingest` produces.  The runtime
    adaptor packages this into a fully-formed `SignedAction` by
    computing the signature externally (the bridge actor's
    private key lives in the runtime, not in Lean). -/
structure UnsignedBridgeAction where
  action : Action
  signer : ActorId   -- always equal to bridgeActor; pinned by theorem below
  nonce  : Nonce     -- the bridge actor's next-expected nonce at ingest time

/-- Translate an L1 event to its Knomosis-side effect.  Every L1
    event becomes either:
      - `none` (event ignored: e.g. duplicate-receipt deposit),
      - `some ub` (one bridge-authored `UnsignedBridgeAction` for
                   the runtime adaptor to sign and feed into
                   `processSignedAction`).
    Identity events compile to `Action.registerIdentity`;
    rotation events to `Action.replaceKey`; deposits to
    `Action.deposit`. -/
def ingest (b : AddressBook) (currentNonce : Nonce) (e : L1Event)
    : AddressBook × Option UnsignedBridgeAction

/-- Project an L1 event to the Knomosis address it touches.  Used
    by the per-address-commutativity theorem below. -/
def L1Event.address : L1Event → EthAddress
```

The Lean function is pure (no `IO`), so determinism is automatic
— no theorem needed.  The non-trivial property is *bookkeeping
order-independence* across distinct addresses: the lookup-state
of the AddressBook is the same regardless of order, even though
the `nextActorId` counter and the specific ID assignments may
differ:

```lean
/-- Per-address lookup-equivalence.  Independent L1 events (those
    touching distinct Ethereum addresses) compose in either
    order to AddressBooks with the same `lookup` behaviour for
    every address.  Note: `nextActorId` and the specific
    address↔id assignments may differ between orderings (the
    address that arrived first gets the lower id), which is why
    the conclusion is `lookup`-equivalence rather than structural
    equality. -/
theorem ingest_lookup_equivalent_for_distinct_addresses :
  ∀ b n e₁ e₂, e₁.address ≠ e₂.address →
    let (b₁,  _) := ingest b  n     e₁
    let (b₂,  _) := ingest b₁ (n+1) e₂
    let (b₁', _) := ingest b  n     e₂
    let (b₂', _) := ingest b₁' (n+1) e₁
    ∀ addr, (b₂.lookup addr).isSome = (b₂'.lookup addr).isSome

/-- The emitted unsigned action's signer is always the bridge
    actor (workstream B.3).  This pins the bridge's authority
    boundary at the type level. -/
theorem ingest_emits_bridge_actor :
  ∀ b n e ub,
    (ingest b n e).snd = some ub →
    ub.signer = Bridge.bridgeActor
```

The runtime adaptor's pseudocode for end-to-end ingest:

```
loop:
    e := next finalised L1 event
    let (b', some ub) := Bridge.ingest current_addressbook current_nonce e
    let signing_bytes := signingInput ub.action ub.signer ub.nonce deploymentId
    let sig := knomosis_sign(bridge_private_key, signing_bytes)  -- in Rust
    let sa : SignedAction := { action := ub.action,
                                signer := ub.signer,
                                nonce  := ub.nonce,
                                sig    := sig }
    processSignedAction sa
    current_addressbook := b'
    current_nonce := current_nonce + 1
```

Note that the Lean side never sees the bridge's private key; the
key lives entirely in the runtime adaptor's Rust process and the
signing operation is opaque to Lean.  This preserves the
Phase-3 discipline of treating cryptographic operations as
opaque-extern functions.

**Acceptance criteria.**

  * Both theorems above ship without `sorry`.
  * `Test/Bridge/Ingest.lean` covers all three L1 event variants
    plus the per-address commutativity case at concrete fixtures.
  * The ingestor binary (Rust adaptor) consumes a `web3.eth.Filter`
    stream against a real Ethereum node, deduplicates by
    `(blockHash, logIndex)`, and feeds the resulting `L1Event`
    list to the Lean function via FFI.

### 6.3 WU B.3 — Bridge actor reservation

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** B.1, B.2,
C.4 (which lands the new `Action.registerIdentity` constructor at
index 14; see design note below).

**Deliverable.**  Reserves `ActorId 0` as the *bridge actor* — the
authority under which all L1-derived Knomosis actions are signed.
The bridge actor's public key is set at deployment time and is
*not* rotatable except via a dedicated governance event (out of
MVP scope).

```lean
namespace LegalKernel.Bridge
def bridgeActor : ActorId := 0

/-- The bridge actor's authority policy admits only the
    L1-derivable action variants: `registerIdentity` for first-
    time identity events (see design note), `replaceKey` for
    rotation events, and `deposit` for balance crediting.
    Everything else is rejected. -/
def bridgePolicy : AuthorityPolicy
end LegalKernel.Bridge
```

with theorems:

```lean
theorem bridgePolicy_rejects_transfer :
  ∀ a, ¬ bridgePolicy.authorized 0 (.transfer ..)
theorem bridgePolicy_rejects_withdraw :
  ¬ bridgePolicy.authorized 0 (.withdraw ..)
theorem bridgePolicy_authorizes_deposit :
  bridgePolicy.authorized 0 (.deposit ..)
theorem bridgePolicy_authorizes_registerIdentity :
  bridgePolicy.authorized 0 (.registerIdentity ..)
theorem bridgePolicy_authorizes_replaceKey :
  bridgePolicy.authorized 0 (.replaceKey ..)
```

All five theorems are direct decidable computations on the
`AuthorityPolicy.authorized` field and ship by `decide` /
`native_decide`.

**Design note: why `registerIdentity` is a separate constructor.**
The existing `Action.replaceKey actor newKey` is signed by the
*old* key (Phase-3 WU 3.10): the registry holds an existing
mapping for `actor`, and the new key replaces it.  But for an
EOA registering for the first time via L1, the Knomosis
`KeyRegistry` has no prior mapping — there is no old key to
sign with.

The MVP therefore introduces a new `Action.registerIdentity
(actor : ActorId) (pk : PublicKey)` constructor at frozen index 14
(workstream C.4).  Its admissibility precondition is
`KeyRegistry.lookup registry actor = none` (registration is
first-time only); its authority precondition is
`bridgePolicy.authorized bridgeActor (.registerIdentity ..)`
(only the bridge actor may register).  Subsequent rotations go
through the existing `replaceKey` machinery unchanged.

This keeps the two flows distinct at the type level, so a
deployment that wants to disable bridge-driven first-time
registration (e.g. a permissioned consortium) simply omits
`registerIdentity` from its law set.

**Acceptance criteria.**

  * The five theorems above + a `MonotonicLawSet`-compatibility
    note (the bridge actor's actions are classified per
    workstream C).
  * The bridge-actor `ActorId 0` reservation is documented in
    `docs/abi.md §12` (workstream G.3).

## 7. Workstream C — bridge laws

This workstream introduces two new `Action` constructors at frozen
indices 12 and 13, the `BridgeState` ledger that tracks consumed
deposit receipts and pending withdrawals, and the per-resource
*bridge accounting invariant* that grounds the deployment's
solvency claim.

### 7.0 Design rationale: why bridge actions need a dedicated admissibility extension

The existing kernel `Transition.pre` operates on `State` (the
balance maps), not on `ExtendedState` or `BridgeState`.  This
means three new bridge-specific preconditions have **nowhere to
live in the existing `Admissible` predicate**:

  1. *Deposit-id uniqueness* (`depositId` not already in
     `BridgeState.consumed`).
  2. *Registration first-time-only*
     (`KeyRegistry.lookup registry actor = none` for
     `registerIdentity actor _`).
  3. *Sufficient L1 backing* (this is enforced on the L1 side,
     not the L2 side; Knomosis trusts the bridge actor's deposit
     emission to be backed).

Three implementation strategies were considered:

  * **Strategy A: Extend `Transition.pre` to take `ExtendedState`.**
    Rejected — this is a kernel TCB change and would invalidate
    every existing `IsConservative` / `IsMonotonic` proof.
  * **Strategy B: Pre-flight check before `apply_admissible_with`.**
    A wrapper `processBridgeAction` checks bridge invariants,
    then calls `apply_admissible_with`.  Workable but bypasses
    the `Admissible` type-level discipline.
  * **Strategy C (chosen): Parameterised admissibility extension.**
    Define a new `BridgeAdmissible` predicate that conjuncts
    `AdmissibleWith` with the three bridge-specific conditions.
    Define a new `apply_bridge_admissible` entry point analogous
    to `apply_admissible_with` but consuming the stronger
    witness.  This keeps the type-level discipline intact and
    makes the bridge-specific obligations visible at every call
    site.

Strategy C is documented in detail below.  It introduces no new
TCB modules; the new predicate and entry point live alongside
the existing ones in (a new module) `LegalKernel/Bridge/Admissible.lean`.

```lean
namespace LegalKernel.Bridge

/-- The five existing `AdmissibleWith` conjuncts (authority,
    nonce, registration, signature, kernel-pre) plus the three
    bridge-specific conjuncts.  Every successful bridge action
    discharges this predicate. -/
def BridgeAdmissibleWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction) : Prop :=
  Authority.AdmissibleWith verify P deploymentId es st ∧
  -- (6) deposit-id uniqueness:
  (∀ r recipient amount depositId,
    st.action = .deposit r recipient amount depositId →
    ¬ es.bridge.consumed.contains depositId) ∧
  -- (7) registration first-time-only:
  (∀ actor pk,
    st.action = .registerIdentity actor pk →
    es.registry.lookup actor = none) ∧
  -- (8) bridge-actor authorisation for bridge-emitted actions:
  (st.action.isBridgeOnly → st.signer = bridgeActor)

/-- The chosen entry point for processing one signed action that
    *might* be a bridge action.  Equivalent to
    `apply_admissible_with` for non-bridge actions; for bridge
    actions, additionally updates `BridgeState` via
    `applyActionToBridgeState`. -/
def apply_bridge_admissible_with
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (deploymentId : ByteArray)
    (es : ExtendedState) (st : SignedAction)
    (h : BridgeAdmissibleWith verify P deploymentId es st) :
    ExtendedState

end LegalKernel.Bridge
```

The `applyActionToBridgeState` helper is analogous to the
existing `applyActionToRegistry`:

```lean
def applyActionToBridgeState (bs : BridgeState) : Action → BridgeState
  | .deposit  _ _ _ depositId  =>
      { bs with consumed := bs.consumed.insert depositId () }
  | .withdraw r sender amount recipientL1 =>
      let wd : PendingWithdrawal := { resource := r, recipient := recipientL1,
                                       amount := amount, l2Block := /* runtime field */ 0 }
      { bs with pending := bs.pending.insert bs.nextWdId wd
                nextWdId := bs.nextWdId + 1 }
  | _ => bs   -- non-bridge actions don't touch BridgeState
```

The new predicate carries every Phase-3 admissibility guarantee
(by inheriting `AdmissibleWith` as its first conjunct), so the
existing replay-impossible / nonce-uniqueness theorems lift
directly to the bridge layer via `BridgeAdmissibleWith.toAdmissibleWith`
projection.

### 7.0a WU C.0 — `BridgeAdmissibleWith` predicate and entry point

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** Phase-3
Authority layer (no MVP-side prerequisites).

**Deliverable.**  A new module `LegalKernel/Bridge/Admissible.lean`
defining `BridgeAdmissibleWith`, `apply_bridge_admissible_with`,
and `applyActionToBridgeState` per the §7.0 design rationale.
The module also exports the projection
`BridgeAdmissibleWith.toAdmissibleWith` so existing Phase-3
theorems lift transparently.

**Theorems.**

```lean
/-- Bridge admissibility implies kernel admissibility (the
    underlying Phase-3 predicate is the first conjunct). -/
theorem BridgeAdmissibleWith.toAdmissibleWith :
  ∀ verify P d es st,
    BridgeAdmissibleWith verify P d es st →
    Authority.AdmissibleWith verify P d es st

/-- The bridge-aware entry point agrees with the Phase-3 entry
    point on the `base`, `nonces`, and `registry` fields.  Only
    the new `bridge` field is touched. -/
theorem apply_bridge_admissible_with_kernel_agreement :
  ∀ verify P d es st h,
    let h' := h.toAdmissibleWith
    let es₁ := apply_bridge_admissible_with verify P d es st h
    let es₂ := apply_admissible_with verify P d es st h'
    es₁.base = es₂.base ∧
    es₁.nonces = es₂.nonces ∧
    es₁.registry = es₂.registry

/-- The Phase-3 replay-impossible theorem lifts to bridge
    admissibility via the projection. -/
theorem bridge_replay_impossible :
  ∀ verify P d es st h,
    ¬ BridgeAdmissibleWith verify P d
        (apply_bridge_admissible_with verify P d es st h) st
```

The first two theorems are `rfl`-class (the new entry point
shares its body with the Phase-3 one for non-bridge fields).
The third theorem follows from the Phase-3
`replay_impossible_with` via the projection.

**Acceptance criteria.**

  * All three theorems ship without `sorry`.
  * `Test/Bridge/Admissible.lean` covers each new conjunct's
    rejection path: a deposit with a consumed `depositId` is
    not bridge-admissible; a `registerIdentity` against a
    registered actor is not bridge-admissible; a non-bridge-
    actor signing a bridge-only action is not bridge-admissible.

### 7.1 WU C.1 — `BridgeState` and its embedding into `ExtendedState`

C.1 is split into four sub-WUs that land sequentially within
one engineering slot.  The split lets each correctness obligation
be reviewed in isolation rather than reading one large patch.

#### 7.1.1 WU C.1.1 — `BridgeState` data structures

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** B.1, C.0.

**Deliverable.**  A new module `LegalKernel/Bridge/State.lean`
defining the data structures only — no `ExtendedState` field
addition yet, so this lands without disturbing any existing
file.

```lean
namespace LegalKernel.Bridge

/-- A canonical 32-byte L1 deposit receipt hash. -/
abbrev DepositId : Type := ByteArray

/-- A monotonically-incrementing per-bridge withdrawal index. -/
abbrev WithdrawalId : Type := Nat

/-- One pending L2 withdrawal, awaiting L1 redemption. -/
structure PendingWithdrawal where
  resource    : ResourceId
  recipient   : EthAddress
  amount      : Amount
  l2LogIndex  : Nat        -- the LogIndex at which the
                            -- withdrawal was applied
  deriving Repr, DecidableEq

/-- The bridge ledger: consumed deposit-ids + pending withdrawals
    + the next withdrawal id to assign. -/
structure BridgeState where
  consumed : Std.TreeMap DepositId Unit  ByteArrayCompare.compare
  pending  : Std.TreeMap WithdrawalId PendingWithdrawal compare
  nextWdId : WithdrawalId
  deriving Repr

namespace BridgeState
def empty : BridgeState
end BridgeState

end LegalKernel.Bridge
```

Note: the `ByteArrayCompare.compare` in the `consumed` map's
type is a deployment-supplied lexicographic-byte comparator
(introduced in this sub-WU as a small helper definition;
`Std.Data.TreeMap` doesn't ship `Ord ByteArray` by default).
The comparator's correctness — stable, total, antisymmetric —
is proved in C.1.1 as a smoke-test theorem
`byteArrayCompare_total_order`.

**Theorems.**

  * `byteArrayCompare_total_order` — stability, totality,
    antisymmetry of the lexicographic comparator.
  * `BridgeState.empty_consumed_empty` — `BridgeState.empty.consumed`
    is the empty TreeMap.
  * `BridgeState.empty_pending_empty` — same for `pending`.
  * `BridgeState.empty_nextWdId_zero` — `nextWdId = 0`.

**Acceptance criteria.**

  * Four theorems ship without `sorry`.
  * `Test/Bridge/State.lean` covers BridgeState construction +
    field-level access at empty / single-element fixtures.

#### 7.1.2 WU C.1.2 — `ExtendedState` field embedding

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.1.1.

**Deliverable.**  The invasive change: extend `ExtendedState`
with a `bridge : BridgeState` field at the end.

```lean
structure ExtendedState where
  base     : State
  nonces   : NonceState
  registry : KeyRegistry
  bridge   : BridgeState        -- NEW field at the end
  deriving Repr
```

The discipline is to leave every existing file's `apply` /
`with`-syntax untouched: Lean's record-update syntax preserves
unmentioned fields by construction.  The non-trivial work is in
the deployment-time `genesisExtendedState` constructor and the
`ExtendedState.empty` initialiser, both of which gain a
`bridge := BridgeState.empty` clause.

**Sub-tasks.**

  1. Extend `LegalKernel/Authority/Nonce.lean`'s `ExtendedState`
     with the new field.
  2. Extend `ExtendedState.empty` with `bridge := BridgeState.empty`.
  3. Extend `LegalKernel/Encoding/State.lean`'s `ExtendedState`
     CBE encoder with a `BridgeState` segment at the end (frozen
     position; cannot be re-ordered later).
  4. Run the existing test suite; *every* test must pass without
     modification (the field addition is invisible to existing
     code by construction).

**Theorems.**

  * `extendedState_field_addition_preserves_existing` — every
    Phase-3+ `ExtendedState` operation that doesn't *explicitly
    reference* `bridge` produces the same result on the
    pre-extension and post-extension types.  Proved by a single
    `rfl`.

**Acceptance criteria.**

  * Theorem ships without `sorry`.
  * `lake test` runs to completion without modifying any
    pre-existing test module.
  * `lake exe count_sorries`, `tcb_audit`, `stub_audit` continue
    to pass.

#### 7.1.3 WU C.1.3 — Pass-through preservation theorem

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.1.2, C.0.

**Deliverable.**  The structural-pass-through theorem:

```lean
theorem apply_admissible_with_preserves_bridge
    (verify : PublicKey → ByteArray → Signature → Bool)
    (P : AuthorityPolicy) (d : ByteArray) (es : ExtendedState)
    (st : SignedAction)
    (h : Authority.AdmissibleWith verify P d es st) :
  (apply_admissible_with verify P d es st h).bridge = es.bridge
```

Proved by `rfl` after unfolding `apply_admissible_with`: the
existing definition uses `{ es with base := s' }` and `{ es''
with registry := ... }` syntax, which preserves unmentioned
fields by Lean's record-update semantics.

#### 7.1.4 WU C.1.4 — `BridgeState` CBE encoding

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.1.1.

**Deliverable.**  CBE `Encodable` instances for `DepositId`,
`PendingWithdrawal`, `BridgeState`, and the round-trip /
injectivity theorems:

```lean
instance instEncodableDepositId         : Encodable Bridge.DepositId
instance instEncodablePendingWithdrawal : Encodable Bridge.PendingWithdrawal
instance instEncodableBridgeState       : Encodable Bridge.BridgeState

theorem depositId_roundtrip
theorem depositId_encode_injective
theorem pendingWithdrawal_roundtrip
theorem pendingWithdrawal_encode_injective
theorem bridgeState_roundtrip
theorem bridgeState_encode_deterministic
```

`bridgeState_encode_deterministic` follows the same pattern as
the existing `state_encode_deterministic` (Audit-2 §8.8.6
canonicality enforcement on the underlying TreeMap-encoded
fields).

**Acceptance criteria.**

  * Six theorems ship without `sorry`.
  * `Test/Bridge/State.lean` covers each encodable type's
    round-trip at empty / single / multi-element fixtures.

### 7.2 WU C.2 — `deposit` law

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.1.

**Deliverable.**  A new module `LegalKernel/Laws/Deposit.lean`
defining a balance-crediting law gated by deposit-id uniqueness:

```lean
namespace LegalKernel.Laws

/-- Credit `amount` units of `r` to `recipient`, marking
    `depositId` as consumed.  Pre-condition: `depositId` is not
    already consumed.  Implementation: `setBalance` plus
    `BridgeState.consumed.insert depositId ()`. -/
def deposit (r : ResourceId) (recipient : ActorId)
            (amount : Amount) (depositId : Bridge.DepositId)
    : Transition where
  pre s := True   -- the kernel-level pre is trivial; the
                  -- bridge-level pre lives in the `Action`-layer
                  -- compile, where it has access to `BridgeState`
  apply_impl s := setBalance r recipient
                    (getBalance r recipient s + amount) s
  decPre := fun _ => inferInstance

end LegalKernel.Laws
```

Note that `Transition.pre` cannot reference `BridgeState`
directly (it operates on `State`, not `ExtendedState`).  The
deposit-id-uniqueness check therefore lives in the
`Action`-layer compile path, alongside the existing authority-
level `apply_admissible_with` machinery.  This is the same
pattern that already governs `replaceKey` (kernel pre is trivial;
the registry mutation lives in `applyActionToRegistry`).

**Theorems.**

```lean
/-- Locality (other resources untouched). -/
theorem deposit_other_resource_untouched :
  ∀ r r' recipient amount depositId s,
    r ≠ r' →
    (Laws.deposit r recipient amount depositId).apply_impl s
       |>.balances.find? r' = s.balances.find? r'

/-- Pointwise locality (other actors untouched at the same r). -/
theorem deposit_other_actor_untouched :
  ∀ r recipient recipient' amount depositId s,
    recipient ≠ recipient' →
    getBalance r recipient'
      ((Laws.deposit r recipient amount depositId).apply_impl s)
    = getBalance r recipient' s

/-- Per-resource accounting: total supply at `r` increases by
    exactly `amount`. -/
theorem totalSupply_after_deposit :
  ∀ r recipient amount depositId s,
    totalSupply r ((Laws.deposit r recipient amount depositId).apply_impl s)
    = totalSupply r s + amount

/-- Monotonicity instance. -/
instance deposit_isMonotonic
    (r : ResourceId) (recipient : ActorId)
    (amount : Amount) (depositId : Bridge.DepositId) :
  IsMonotonic (Laws.deposit r recipient amount depositId)

/-- Explicit non-conservation witness (deposits expand supply by
    construction, so this law is *not* `IsConservative`). -/
theorem deposit_not_conservative :
  ∀ r recipient amount depositId,
    amount > 0 →
    ¬ IsConservative (Laws.deposit r recipient amount depositId)
```

The first three theorems reduce to the §4.3 balance lemmas
(`getBalance_setBalance_*`) and the §8.1 master lemma
(`totalSupply_setBalance`); their proofs are short.  The
typeclass instance follows from the third theorem.  The
non-conservation witness is the existing `mint_not_conservative`
proof shape.

**Acceptance criteria.**

  * All five theorems ship without `sorry`.
  * `Test/Laws/Deposit.lean` mirrors `Test/Laws/Mint.lean`
    case-for-case (10–12 cases).
  * `lake exe count_sorries` zero kernel-TCB hits.

### 7.3 WU C.3 — `withdraw` law

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.1.

**Deliverable.**  A new module `LegalKernel/Laws/Withdraw.lean`
defining a balance-debiting law gated by sufficient balance:

```lean
namespace LegalKernel.Laws

/-- Burn `amount` units of `r` from `sender`, scheduling an L1
    redemption to `recipientL1`.  Pre-condition: sender's balance
    is at least `amount`.  Implementation: `setBalance` minus
    `amount`; the `Bridge.PendingWithdrawal` record is inserted at
    the Action-layer compile path (analogous to `deposit`). -/
def withdraw (r : ResourceId) (sender : ActorId) (amount : Amount)
             (recipientL1 : Bridge.EthAddress)
    : Transition where
  pre s := getBalance r sender s ≥ amount
  apply_impl s := setBalance r sender
                    (getBalance r sender s - amount) s
  decPre := fun _ => inferInstance

end LegalKernel.Laws
```

**Theorems.**

```lean
theorem withdraw_other_resource_untouched : /- as above -/
theorem withdraw_other_actor_untouched     : /- as above -/

theorem totalSupply_after_withdraw :
  ∀ r sender amount recipientL1 s,
    getBalance r sender s ≥ amount →
    totalSupply r ((Laws.withdraw r sender amount recipientL1).apply_impl s)
    = totalSupply r s - amount

/-- Explicit non-monotonicity witness (withdraw decreases supply
    by construction). -/
theorem withdraw_not_monotonic :
  ∀ r sender amount recipientL1, amount > 0 →
    ¬ IsMonotonic (Laws.withdraw r sender amount recipientL1)

/-- Explicit non-conservation witness. -/
theorem withdraw_not_conservative :
  ∀ r sender amount recipientL1, amount > 0 →
    ¬ IsConservative (Laws.withdraw r sender amount recipientL1)
```

The locality and accounting theorems mirror C.2.  The two
negative witnesses follow `burn_not_monotonic` /
`burn_not_conservative` in proof shape.

**Acceptance criteria.**

  * All five theorems ship without `sorry`.
  * `Test/Laws/Withdraw.lean` mirrors `Test/Laws/Burn.lean`
    case-for-case (12–13 cases) plus 2 extra cases for
    insufficient-balance precondition rejection.

### 7.4 WU C.4 — `Action` constructor extension

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.2, C.3.

**Deliverable.**  Three new `Action` constructors at frozen
indices 12, 13, and 14:

```lean
inductive Action
  /- ... existing 0..11 ... -/
  | deposit          (r : ResourceId) (recipient : ActorId)
                      (amount : Amount) (depositId : Bridge.DepositId)
  | withdraw         (r : ResourceId) (sender : ActorId)
                      (amount : Amount) (recipientL1 : Bridge.EthAddress)
  | registerIdentity (actor : ActorId) (pk : PublicKey)
```

`registerIdentity` compiles to a kernel-level no-op (like
`replaceKey`); the registry mutation lives in the Action-layer
compile path, gated by the *first-time-only* check
`KeyRegistry.lookup registry actor = none`:

```lean
def Action.compileTransition : Action → Transition
  | /- existing 0..11 ... -/
  | .deposit  r recipient amount depositId   =>
      Laws.deposit  r recipient amount depositId
  | .withdraw r sender    amount recipientL1 =>
      Laws.withdraw r sender    amount recipientL1
  | .registerIdentity _ _                    =>
      Laws.freezeResource 0   -- kernel-level no-op
```

The Phase-3 `applyActionToRegistry` is correspondingly extended:
on `registerIdentity actor pk`, the registry is updated via
`KeyRegistry.register registry actor pk` (provided
`KeyRegistry.lookup registry actor = none`).

**Theorems.**

```lean
/-- `Action.compile_injective` extends to the new constructors.
    Proof: `congrArg CompiledAction.source` is unchanged; only
    the inductive grew. -/
theorem Action.compile_injective_extends :
  ∀ a₁ a₂, Action.compile a₁ = Action.compile a₂ → a₁ = a₂

/-- The Phase-3 `non_replaceKey_preserves_registry` theorem must
    be *retired* and replaced.  The old form said "any non-
    `replaceKey` action preserves the registry pointwise" — but
    `registerIdentity` (introduced in C.4) is a non-`replaceKey`
    action that *does* mutate the registry, so the old form is
    falsified.

    The replacement is parameterised by an explicit predicate
    on which constructors are registry-mutating. -/
def Action.mutatesRegistry : Action → Bool
  | .replaceKey _ _       => true
  | .registerIdentity _ _ => true
  | _                     => false

/-- The successor theorem.  Retains the Phase-3 spirit (most
    actions don't touch the registry) but admits the new
    `registerIdentity` branch into the mutating set. -/
theorem registry_unchanged_when_action_does_not_mutate :
  ∀ vp p es sa h,
    sa.action.mutatesRegistry = false →
    (apply_admissible_with vp p es sa h).registry = es.registry

/-- The `deposit` and `withdraw` branches preserve the registry
    (corollary of the above; specialised). -/
theorem deposit_preserves_registry
theorem withdraw_preserves_registry
```

The deposit / withdraw branches close by `rfl` since their
`apply_impl` does not touch the registry; `registerIdentity`'s
branch is the new exception captured by `mutatesRegistry = true`.

The CBE encoder (`Encoding/Action.lean`) gains two new
constructor branches at indices 12 and 13:

```lean
def Action.encode : Action → Encoding.Stream
  | /- existing ... -/
  | .deposit r recipient amount depositId =>
      [12]  -- constructor tag
      ++ encode r ++ encode recipient ++ encode amount
      ++ encode depositId
  | .withdraw r sender amount recipientL1 =>
      [13]
      ++ encode r ++ encode sender ++ encode amount
      ++ encode recipientL1
```

with `action_roundtrip` and `action_encode_injective`
correspondingly extended.  Each new branch's roundtrip / injectivity
case closes by `simp` plus the per-field roundtrips
(`nat_roundtrip`, `byteArray_roundtrip`).

**Acceptance criteria.**

  * Both `compile`-extension theorems ship without `sorry`.
  * The CBE encoder roundtrip + injectivity theorems ship without
    `sorry`.
  * `Test/Authority/Action.lean` adds 8 new test cases (4 per new
    constructor: distinguishability + compile-shape).
  * `Test/Encoding/Action.lean` adds 2 new test cases
    (per-constructor round-trip).

### 7.5 WU C.5 — `Event` constructor extension

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.4.

**Deliverable.**  Two new `Event` constructors at frozen indices
9 and 10 in `LegalKernel/Events/Types.lean`:

```lean
inductive Event
  /- existing 0..8 ... -/
  | withdrawalRequested (r : ResourceId) (sender : ActorId)
                         (amount : Amount)
                         (recipientL1 : Bridge.EthAddress)
                         (withdrawalId : Bridge.WithdrawalId)
  | depositCredited     (r : ResourceId) (recipient : ActorId)
                         (amount : Amount)
                         (depositId : Bridge.DepositId)
```

with `extractEvents` branches in `LegalKernel/Events/Extract.lean`:

  * `Action.deposit` emits one `depositCredited`.
  * `Action.withdraw` emits one `withdrawalRequested` with
    `withdrawalId` derived from the post-state's `BridgeState.nextWdId`.
  * Both also emit the standard `nonceAdvanced` event.

**Theorems.**

```lean
theorem extractEvents_deposit_emits_credited :
  ∀ pre post sa, sa.action = .deposit r recipient amount depositId →
    Event.depositCredited r recipient amount depositId
      ∈ extractEvents pre post sa

theorem extractEvents_withdraw_emits_requested :
  ∀ pre post sa, sa.action = .withdraw r sender amount recipientL1 →
    ∃ wdId, Event.withdrawalRequested r sender amount recipientL1 wdId
              ∈ extractEvents pre post sa
```

**Acceptance criteria.**

  * Both theorems ship without `sorry`.
  * `Test/Events/Extract.lean` adds 4 new cases (deposit / withdraw
    × emission / determinism).

### 7.6 WU C.6 — Bridge accounting theorem

C.6 is the deepest proof obligation in the plan.  It is
decomposed into five sequential sub-WUs, each owning a tractable
piece of the inductive argument.  Sub-WU dependencies form a
chain: C.6.1 → C.6.2 → C.6.3 → C.6.4 → C.6.5.

#### 7.6.1 WU C.6.1 — `totalDeposited` / `totalWithdrawn` definitions

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.1.4, C.4, C.5.

**Deliverable.**  Pure definitions and structural-shape lemmas
(no induction yet):

```lean
namespace LegalKernel.Bridge

/-- The amount field of a `PendingWithdrawal`. -/
def PendingWithdrawal.amountAt (wd : PendingWithdrawal) (r : ResourceId)
    : Nat := if wd.resource = r then wd.amount else 0

/-- Total amount burned at resource `r` via pending withdrawals,
    summed over the bridge's `pending` map. -/
def totalWithdrawn (es : ExtendedState) (r : ResourceId) : Nat :=
  es.bridge.pending.foldl
    (fun acc _ wd => acc + wd.amountAt r) 0

/-- The amount field of a deposit-id record.  Requires the
    BridgeState to track per-deposit-id metadata; introduced as
    a sibling field `consumedDetails : TreeMap DepositId DepositRecord`
    in C.1.1's data definition (corrected at audit-2 time;
    pre-audit-2 the BridgeState only tracked the *set* of
    consumed depositIds, which was insufficient for accounting).
-/
structure DepositRecord where
  resource : ResourceId
  amount   : Amount
  deriving Repr, DecidableEq

def totalDeposited (es : ExtendedState) (r : ResourceId) : Nat :=
  es.bridge.consumedDetails.foldl
    (fun acc _ rec => acc + (if rec.resource = r then rec.amount else 0)) 0

/-- Pure lemmas: foldl-based sums respect insertion. -/
theorem totalDeposited_insert
theorem totalWithdrawn_insert
theorem totalDeposited_unchanged_on_other_action
theorem totalWithdrawn_unchanged_on_other_action

end LegalKernel.Bridge
```

The four lemmas reduce per-action accounting to a single
TreeMap-foldl-after-insert step, applying the §8.3 RBMap proof
library (`sumValues_insert_*` lemmas).

**Note (audit-2 amendment to C.1.1).**  C.6.1 surfaces a
correction to C.1.1's `BridgeState` definition: the `consumed`
field, originally `TreeMap DepositId Unit`, is widened to
`TreeMap DepositId DepositRecord` so that per-deposit `(resource,
amount)` metadata is available for the accounting fold.  This
correction is recorded in §19.

**Acceptance criteria.**

  * Four foldl-shape lemmas ship without `sorry`.
  * `Test/Bridge/Accounting.lean` covers single-element + multi-
    element fixtures for both `totalDeposited` and `totalWithdrawn`.

#### 7.6.2 WU C.6.2 — Per-action accounting deltas

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.6.1.

**Deliverable.**  One delta lemma per action variant.  These
isolate the inductive step's case-by-case work into named
sub-lemmas, avoiding a single 300-line monolithic proof.

```lean
namespace LegalKernel.Bridge

/-- After applying a `.transfer` admissibly, totalSupply,
    totalDeposited, totalWithdrawn are all preserved at every r. -/
theorem accounting_delta_transfer

/-- After applying a `.deposit r' a' amount _` admissibly:
    totalSupply r increases by amount iff r = r';
    totalDeposited r increases by amount iff r = r';
    totalWithdrawn r unchanged. -/
theorem accounting_delta_deposit

/-- After applying a `.withdraw r' a' amount _` admissibly:
    totalSupply r decreases by amount iff r = r';
    totalDeposited r unchanged;
    totalWithdrawn r increases by amount iff r = r'. -/
theorem accounting_delta_withdraw

/-- After applying a `.freezeResource _`, `.replaceKey _ _`, or
    `.registerIdentity _ _` admissibly:
    totalSupply, totalDeposited, totalWithdrawn all unchanged at
    every r. -/
theorem accounting_delta_balance_neutral

/-- After applying any of `.mint`, `.reward`, `.distributeOthers`,
    `.proportionalDilute` admissibly: totalSupply may increase;
    totalDeposited and totalWithdrawn unchanged.  This is the
    "fudge factor" delta that `totalRewarded` collects in
    C.6.4. -/
theorem accounting_delta_non_bridge_increasing

end LegalKernel.Bridge
```

Each lemma is a direct unfolding of `apply_bridge_admissible_with`
plus the per-action branch of `applyActionToBridgeState` plus the
§4.3 balance lemmas + the C.6.1 foldl-insert lemmas.  Per-lemma
length: ≤ 30 lines of tactics.

**Acceptance criteria.**

  * Five delta lemmas ship without `sorry`.
  * `Test/Bridge/Accounting.lean` exercises each delta at concrete
    pre/post fixtures.

#### 7.6.3 WU C.6.3 — `totalWithdrawn` boundedness lemma

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.6.1, C.6.2.

**Deliverable.**  The boundedness inductive invariant that
guarantees the `Nat`-subtraction inside `totalSupply r es.base
- totalWithdrawn es r` is exact (no truncation).

```lean
/-- For every state reachable from genesis under any
    `MonotonicLawSet` containing the bridge laws, the cumulative
    withdrawal amount at every resource is bounded by the
    cumulative deposit amount plus genesis supply.  Equivalent
    to: "you cannot withdraw what was never deposited." -/
theorem totalWithdrawn_bounded
    (L : MonotonicLawSet) (es₀ es : ExtendedState)
    (h : ReachableViaLaws L es₀ es) (r : ResourceId) :
  Bridge.totalWithdrawn es r
    ≤ totalSupply r es₀.base + Bridge.totalDeposited es r
```

Proof: induction on `h`.  Base case: empty bridge state, lhs =
0 ≤ rhs.  Step case: invoke C.6.2's per-action delta lemmas.
Only `.withdraw` increases lhs; on each `.withdraw`, the
admissibility precondition `getBalance r sender ≥ amount`
(workstream C.3) implies `amount ≤ totalSupply r es.base` (a
new helper lemma in C.6.3 itself: `getBalance_bounded_by_totalSupply`,
proved via §8.3 fold lemmas).  The §8.1
`totalSupply_setBalance` then gives the inductive step.

**Acceptance criteria.**

  * `totalWithdrawn_bounded` and the helper `getBalance_bounded_by_totalSupply`
    ship without `sorry`.
  * `Test/Bridge/Accounting.lean` exercises the boundedness at a
    fixture where total withdrawals approach total deposits +
    genesis.

#### 7.6.4 WU C.6.4 — `bridge_supply_account_general` master theorem

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.6.1, C.6.2, C.6.3.

**Deliverable.**  The general accounting equation.

```lean
/-- Total supply contributed by non-bridge balance-increasing
    actions, accumulated structurally over the reachability chain. -/
def totalRewarded (es : ExtendedState) (r : ResourceId) : Nat
  -- defined as a derived field on ExtendedState (cached),
  -- updated via applyActionToBridgeState for the non-bridge
  -- increasing actions.  See C.1.1 amendment.

/-- The general accounting equation. -/
theorem bridge_supply_account_general
    (L : MonotonicLawSet) (es₀ es : ExtendedState)
    (h : ReachableViaLaws L es₀ es) (r : ResourceId) :
  totalSupply r es.base + Bridge.totalWithdrawn es r
    = totalSupply r es₀.base + Bridge.totalDeposited es r
        + Bridge.totalRewarded es r
```

Proof: induction on `h`.  Base: `rfl` (lhs = rhs = `totalSupply
r es₀.base`).  Step: case-split on action via C.6.2's deltas;
each branch closes by `linarith` over the established equalities.

**Acceptance criteria.**

  * `bridge_supply_account_general` ships without `sorry`.
  * `Test/Bridge/Accounting.lean` covers a 4-step trace
    (deposit, transfer, withdraw, transfer) and verifies the
    general equation at each step.

#### 7.6.5 WU C.6.5 — `bridge_supply_account` strict-form corollary

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.6.4.

**Deliverable.**  The strict-form theorem under the canonical
bridge law set.

```lean
/-- The strict accounting equation: under the canonical bridge
    deployment law set (no mint / reward / distributeOthers /
    proportionalDilute), the totalRewarded term collapses to 0. -/
theorem bridge_supply_account
    (es₀ es : ExtendedState)
    (h : ReachableViaLaws bridgeLawSet es₀ es) (r : ResourceId) :
  totalSupply r es.base + Bridge.totalWithdrawn es r
    = totalSupply r es₀.base + Bridge.totalDeposited es r
```

Plus the supporting lemma:

```lean
/-- Under `bridgeLawSet`, `totalRewarded` is identically 0. -/
theorem totalRewarded_zero_under_bridgeLawSet
    (es₀ es : ExtendedState)
    (h : ReachableViaLaws bridgeLawSet es₀ es) (r : ResourceId) :
  Bridge.totalRewarded es r = 0
```

Proof of the corollary: invoke C.6.4 then rewrite by the
supporting lemma.  The supporting lemma is induction on `h`;
every action in `bridgeLawSet` either preserves `totalRewarded`
(`.transfer`, `.freezeResource`, `.replaceKey`, `.registerIdentity`,
`.deposit`, `.withdraw`) by C.6.2's deltas.

**Acceptance criteria.**

  * Both theorems ship without `sorry`.
  * `Test/Bridge/Accounting.lean` adds 3 cases asserting the
    strict form on `bridgeLawSet`-reachable fixtures.

## 8. Workstream D — withdrawal proofs

This workstream gives users a Merkle-proof object they can
present to `KnomosisBridge.sol` to redeem an L2 withdrawal on L1.
Every WU here is purely Lean + runtime; the Solidity-side
verification of these proofs lives in workstream E.1.

### 8.1 WU D.1 — sparse Merkle tree builder for `BridgeState.pending`

D.1 splits into five sub-WUs.  The split lets the data
structures + naive verifier land first (D.1.1, D.1.2), the
unconditional completeness proof land second (D.1.3), the
hash-collision-resistance-conditioned soundness proof land third
(D.1.4), and the cross-stack goldens land last (D.1.5).

#### 8.1.1 WU D.1.1 — SMT data structures and tree construction

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.1.4, A.2.

**Deliverable.**  A new module
`LegalKernel/Bridge/WithdrawalRoot.lean` with the data
definitions and the build function.  Hash function abstracted
behind a `H : ByteArray → ByteArray` argument so theorems can be
parameterised on the hash for testability.

```lean
namespace LegalKernel.Bridge

/-- Tree height: fixed at 64 to match `WithdrawalId : Nat ≤ 2^64`.
    A WithdrawalId is interpreted as a 64-bit big-endian path
    from root to leaf (bit i selects the right child at depth
    63-i). -/
def smtHeight : Nat := 64

/-- The sentinel byte sequence representing an empty leaf.  Used
    for SMT positions with no withdrawal mapped to them.  Per
    §8.8.4, the sentinel is `keccak256(0x00 repeated 32 times) =
    bytes32(0)` per the Audit-3.1 zero-hash convention. -/
def emptyLeafHash : ByteArray  -- 32 zero bytes

/-- The level-`i` empty-subtree hash, precomputed.
    `defaultHash 0 = emptyLeafHash`;
    `defaultHash (i+1) = H (defaultHash i ‖ defaultHash i)`. -/
def defaultHash (H : ByteArray → ByteArray) : Fin smtHeight.succ → ByteArray

/-- The 32-byte Merkle root over `pending`.  Uses
    `H = hashBytes` (the keccak256 binding); generic in `H` for
    testing. -/
def withdrawalRoot (H : ByteArray → ByteArray) (b : BridgeState) : ByteArray

end LegalKernel.Bridge
```

**Theorems.**

  * `defaultHash_well_defined` — `defaultHash` is total
    (`Fin.succ` recursion terminates on a finite domain).
  * `withdrawalRoot_empty_eq_defaultHash_top` — the root of an
    empty `BridgeState.pending` equals `defaultHash smtHeight`.
  * `withdrawalRoot_extensional` — `pending`-equivalent
    BridgeStates produce the same root under a deterministic
    `H`.

**Acceptance criteria.**

  * Three theorems ship without `sorry`.
  * `Test/Bridge/WithdrawalRoot.lean` covers empty / single /
    eight-leaf cases.

#### 8.1.2 WU D.1.2 — `verifyProof` and `constructProof` definitions

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** D.1.1.

**Deliverable.**  The verifier and constructor definitions.

```lean
/-- A Merkle inclusion proof for a single pending withdrawal:
    the leaf bytes, the index path, and exactly `smtHeight`
    sibling hashes (one per level, root-to-leaf). -/
structure WithdrawalProof where
  leaf     : ByteArray
  index    : WithdrawalId
  siblings : Vector ByteArray smtHeight   -- `Vector` (built-in
                                            -- Lean) for typed length

/-- Verify a proof against a root.  Walks the index bits
    leaf-to-root, hashing each level with the supplied sibling. -/
def verifyProof (H : ByteArray → ByteArray)
                 (proof : WithdrawalProof) (root : ByteArray) : Bool

/-- Construct the canonical proof for `idx` in `b.pending`.
    Walks the SMT bottom-up, collecting siblings.  If `idx ∉
    b.pending`, returns the proof for the empty-leaf sentinel
    (a valid proof, but the verify step will reject when called
    by the consumer). -/
def constructProof (H : ByteArray → ByteArray)
                    (b : BridgeState) (idx : WithdrawalId)
                    : WithdrawalProof
```

**Theorems.**

  * `constructProof_deterministic` — same input → same output
    (rfl).
  * `constructProof_siblings_length` — the siblings vector has
    length exactly `smtHeight` (statically guaranteed by `Vector
    n`; the theorem makes the property quotable in tests).
  * `verifyProof_total` — `verifyProof` always returns a `Bool`
    (no infinite loop or panic; total by structural recursion on
    `Fin smtHeight`).

**Acceptance criteria.**

  * Three theorems ship without `sorry`.
  * `Test/Bridge/WithdrawalRoot.lean` adds 4 cases for the
    constructor + verifier shape.

#### 8.1.3 WU D.1.3 — `verifyProof_complete` (unconditional)

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** D.1.2.

**Deliverable.**  The completeness theorem — unconditional, no
hash-collision-resistance hypothesis required.

```lean
/-- Completeness: for every pending withdrawal, the canonical
    constructor produces a proof that the verifier accepts.
    Independent of `H`'s collision properties: completeness is
    a structural recursion identity. -/
theorem verifyProof_complete
    (H : ByteArray → ByteArray) (b : BridgeState)
    (idx : WithdrawalId) (wd : PendingWithdrawal) :
  b.pending.find? idx = some wd →
    verifyProof H (constructProof H b idx) (withdrawalRoot H b) = true
```

Proof: induction on the index bits.  Each level the
`constructProof` collects the same sibling that `verifyProof`
expects to match, and the per-level hash is computed identically
on both sides.  No collision resistance needed — verify is the
inverse of construct.

**Acceptance criteria.**

  * `verifyProof_complete` ships without `sorry` and with no
    Lean axioms beyond the canonical three.
  * `Test/Bridge/WithdrawalRoot.lean` adds 4 cases verifying
    completeness on 4-, 8-, and 16-leaf fixtures.

#### 8.1.4 WU D.1.4 — `verifyProof_sound` (hash-conditional)

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** D.1.3.

**Deliverable.**  The soundness theorem under a hash-collision-
resistance hypothesis.

```lean
/-- The collision-resistance hypothesis as a `Prop` parameter.
    Note: this is *not* a Lean `axiom` and not a typeclass.  Its
    truth is a deployment assumption on `hashBytes` (the
    keccak256 binding).  Theorems in this section are proved
    *under* the hypothesis, so that an attacker who breaks
    keccak256 also breaks the hypothesis, not the Lean proof. -/
def CollisionFree (H : ByteArray → ByteArray) : Prop :=
  ∀ x y, x ≠ y → H x ≠ H y

/-- Soundness: a valid proof under a collision-free `H`
    guarantees the leaf is in the tree. -/
theorem verifyProof_sound
    {H : ByteArray → ByteArray} (hCF : CollisionFree H)
    (b : BridgeState) (proof : WithdrawalProof) :
  verifyProof H proof (withdrawalRoot H b) = true →
    ∃ wd, b.pending.find? proof.index = some wd ∧
          proof.leaf = Encodable.encode wd
```

Proof: contrapositive.  Suppose `b.pending.find? proof.index ≠
some wd_proof_leaf`.  Then either `idx` is unmapped (leaf is
the empty sentinel, but `proof.leaf` claims a non-sentinel
value) or `idx` is mapped to a different `wd'`.  Either way,
the leaf-level hashes differ.  The collision-free hypothesis
propagates the inequality up the tree level by level, so the
roots differ — but `verifyProof` only accepts when the
recomputed root equals the input root, contradiction.

**Acceptance criteria.**

  * `verifyProof_sound` ships without `sorry`.
  * `#print axioms verifyProof_sound` returns only the canonical
    three (the hypothesis appears as a function argument, not as
    an axiom).
  * `Test/Bridge/WithdrawalRoot.lean` adds 3 negative-case
    fixtures (proof-against-wrong-root, wrong-leaf,
    wrong-sibling).

#### 8.1.5 WU D.1.5 — Cross-stack SMT goldens

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:** D.1.4.

**Deliverable.**  A 16-leaf golden file built in Lean and
verified by an OpenZeppelin-style Solidity SMT verifier.  This
locks the byte-level shape of `WithdrawalProof` and the
recompute order against the most-tested available
implementation.

```
solidity/test/fixtures/withdrawal_proof_smt.json
  [ { idx, leaf_hex, siblings_hex[64], expected_root_hex }, … ]
```

The Lean-side test driver (`Test/Bridge/WithdrawalRootGoldens.lean`)
generates the file; the Solidity test (`solidity/test/SMT.t.sol`)
loads the file and asserts every fixture verifies.

**Acceptance criteria.**

  * 16 / 16 fixtures match between Lean and Solidity.
  * Reproducibility: re-running the Lean driver with the
    recorded seed produces a byte-identical fixture file.

### 8.2 WU D.2 — withdrawal proof extractor

**Owner:** Lean + runtime; **Reviewer count:** 1; **Depends on:** D.1.

**Deliverable.**  A user-facing API that, given a `WithdrawalId`
and a finalised snapshot, returns a `WithdrawalProof` ready to be
submitted to L1.

```lean
namespace LegalKernel.Bridge

/-- Extract a withdrawal proof from a finalised snapshot.
    Returns `none` if the withdrawal id is not in the snapshot
    or if the snapshot is not yet finalised. -/
def extractProof (snap : Snapshot) (idx : WithdrawalId)
    : Option WithdrawalProof

end LegalKernel.Bridge
```

**Theorems.**

```lean
theorem extractProof_consistent_with_root :
  ∀ snap idx proof,
    extractProof snap idx = some proof →
    verifyProof proof (snap.bridgeWithdrawalRoot) = true
```

The runtime side exposes a CLI subcommand:

```
knomosis withdrawal-proof <SNAPSHOT_FILE> <WITHDRAWAL_ID>
  -> stdout: hex-encoded WithdrawalProof
```

**Acceptance criteria.**

  * The consistency theorem ships without `sorry`.
  * CLI integration test in `Test/Bridge/WithdrawalProofCLI.lean`.
  * The output is byte-stable across runs (the proof is
    deterministic per D.1).

### 8.3 WU D.3 — snapshot-window finalisation policy

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** D.1, D.2.

**Deliverable.**  A finalisation predicate that determines when a
snapshot's withdrawal root is "redeemable" on L1:

```lean
namespace LegalKernel.Bridge

/-- A snapshot is finalised when both:
    1. Its `submitStateRoot` L1 transaction has at least
       `disputeWindowBlocks` confirmations on L1.
    2. No `Verdict.upheld` has been applied against the snapshot's
       log range.
    The predicate is decidable per Phase-6's `disputeStatus`
    walk-the-log machinery. -/
def isFinalised (snap : Snapshot) (currentL1Block : Nat)
                (disputeWindowBlocks : Nat)
                (log : List LogEntry) : Bool

end LegalKernel.Bridge
```

**Theorems.**

```lean
theorem isFinalised_monotonic_in_currentBlock :
  ∀ snap b₁ b₂ w log, b₁ ≤ b₂ →
    isFinalised snap b₁ w log = true →
    isFinalised snap b₂ w log = true

theorem isFinalised_implies_no_upheld_against :
  ∀ snap b w log, isFinalised snap b w log = true →
    ∀ idx, snap.logIndexLow ≤ idx ∧ idx < snap.logIndexHigh →
      disputeStatus log idx ≠ some (.decided .upheld)
```

The first theorem captures the L1-confirmation monotonicity
(once finalised, always finalised); the second captures the
no-upheld-disputes property (a `.upheld` verdict invalidates the
snapshot for redemption).

**Acceptance criteria.**

  * Both theorems ship without `sorry`.
  * `Test/Bridge/Finalisation.lean` covers the dispute-window
    boundary cases.

## 9. Workstream E — Solidity contracts

This workstream is the on-chain complement.  All contracts
target Solidity `^0.8.20` and use audited OpenZeppelin libraries
for primitives — no custom crypto.  Specifically:

  * `@openzeppelin/contracts/utils/ReentrancyGuard.sol`
  * `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`
    (handles non-conforming ERC-20s like USDT)
  * `@openzeppelin/contracts/token/ERC20/IERC20.sol`
  * `@openzeppelin/contracts/utils/Address.sol`
    (`sendValue` for ETH transfer; forwards all gas)
  * `@openzeppelin/contracts/utils/cryptography/ECDSA.sol`
  * `@openzeppelin/contracts/utils/cryptography/EIP712.sol`
  * `@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol`
  * `@openzeppelin/contracts/interfaces/IERC1271.sol`

The catalogue is deliberately *narrower* than a typical bridge
deployment.  Per §4.8 ("L1 contract immutability mirrors kernel
TCB immutability"), the following OpenZeppelin patterns are
**forbidden**:

  * `proxy/*` — every contract is deployed straight to its final
    address via `CREATE2`; no proxies, no `initialize`.
  * `Pausable` — the dispute pipeline is the granular pause
    (`applyVerdict (.upheld)` rolls back individual bad
    transactions); whole-system halt uses *automatic circuit
    breakers* on observable predicates (§9.1.4) with no
    privileged caller.
  * `Ownable` / `Ownable2Step` — no contract has an owner;
    administrative authority is encoded as `address public
    immutable` references set at construction.
  * `AccessControl` (the *mutable* role-grant family
    `grantRole` / `revokeRole`) — roles are `address public
    immutable` constants, not mutable mappings.  We retain
    `AccessControl` only for the well-known role-id constants
    (`bytes32` namespace hashes) used in event topic
    formatting; the `_grantRole` / `_revokeRole` family is
    not invoked.
  * `governance/TimelockController` — there is no governance
    surface to time-lock.

Roles are *immutable addresses* set in the constructor:

```solidity
address public immutable attestor;          // signs state roots
address public immutable disputeVerifier;   // KnomosisDisputeVerifier address
address public immutable sequencerStake;    // KnomosisSequencerStake address
address public immutable migration;         // KnomosisMigration address (may
                                            //   be address(0) until the
                                            //   migration contract is
                                            //   deployed; treated as a
                                            //   read-only handoff target,
                                            //   never a code-upgrade hook)
```

If the attestor's private key is compromised, the dispute
pipeline rolls back the bad attestations via `revertToPriorRoot`.
If a deployment-lifetime authority transfer is genuinely needed
(e.g. attestor key rotation that the dispute pipeline cannot
cover atomically), it requires a new deployment + `KnomosisMigration`
handoff.  This is the same discipline the kernel applies: the
TCB is *not* field-mutable; rotating means deploying again.

ETH transfers use `Address.sendValue` from OpenZeppelin (which
forwards all gas, unlike the deprecated `transfer(2300 gas)`),
guarded by `ReentrancyGuard.nonReentrant` to neutralise the
reentrancy risk this opens up.

**Five contracts** ship in this workstream:

| Contract                      | Sub-WUs           | Responsibility                                       |
|-------------------------------|-------------------|------------------------------------------------------|
| `KnomosisBridge.sol`             | E.1.1 – E.1.5     | Deposits, state roots, withdrawals, circuit breakers |
| `KnomosisDisputeVerifier.sol`    | E.2.1 – E.2.5     | Dispute filing, evidence verification, finalisation  |
| `KnomosisIdentityRegistry.sol`   | E.3               | Mirror of Lean `KeyRegistry`                         |
| `KnomosisSequencerStake.sol`     | E.4               | Sequencer stake escrow + slash handler               |
| `KnomosisMigration.sol`          | E.5               | One-shot attested handoff to a successor deployment  |

### 9.1 WU E.1 — `KnomosisBridge.sol`

E.1 splits into five sub-WUs, each owning one functional area
of the bridge contract.  All sub-WUs share the file
`solidity/contracts/KnomosisBridge.sol`, but the split lets each
functional area's tests, audit attention, and review focus on a
self-contained interface.

The contract has no proxy, no `initialize`, no owner, no
mutable role, and no `pause()` function.  Every parameter
listed in the constructor is `immutable`; rotation requires a
new deployment plus a `KnomosisMigration` handoff (§9.5).

```solidity
constructor(
    bytes32 _knomosisVersionTag,
    address _attestor,
    address _disputeVerifier,
    address _sequencerStake,
    address _migration,
    uint64  _disputeWindowBlocks,
    uint64  _maxRedemptionWindowBlocks,
    uint64  _maxAttestationStaleBlocks,
    uint64  _cooldownBlocks,
    uint256 _tvlCap
) {
    require(_disputeWindowBlocks >= _maxRedemptionWindowBlocks,
            "dispute < redemption");
    knomosisVersionTag           = _knomosisVersionTag;
    attestor                  = _attestor;
    disputeVerifier           = _disputeVerifier;
    sequencerStake            = _sequencerStake;
    migration                 = _migration;             // may be address(0)
    disputeWindowBlocks       = _disputeWindowBlocks;
    maxRedemptionWindowBlocks = _maxRedemptionWindowBlocks;
    maxAttestationStaleBlocks = _maxAttestationStaleBlocks;
    cooldownBlocks            = _cooldownBlocks;
    tvlCap                    = _tvlCap;

    deploymentId = keccak256(abi.encode(
        block.chainid,
        address(this),
        _knomosisVersionTag
    ));
}
```

The `deploymentId` is derived in the constructor exactly as on
the Lean side (§8.8.5) — `keccak256(chainId ‖ address(this) ‖
knomosisVersionTag)`.  It is `bytes32 immutable`, surfaced via a
public getter, and woven into every EIP-712 domain separator
the contract uses.  Cross-deployment replay rejection is
structural: a successor deployment derives a different
`deploymentId` (different `address(this)` from `CREATE2`), so
predecessor signatures cannot be replayed against it.

Two custom modifiers replace the OZ `whenNotPaused` family:

```solidity
modifier circuitOpen() {
    if (block.number > latestStateRootSubmittedAtBlock + maxAttestationStaleBlocks
        && latestStateRootSubmittedAtBlock != 0)
        revert AttestationStale();
    if (lastUpheldDisputeBlock != 0
        && block.number < lastUpheldDisputeBlock + cooldownBlocks)
        revert DisputeCooldown();
    if (totalLockedValue > tvlCap)
        revert TvlCapReached();
    if (migration != address(0)
        && IKnomosisMigration(migration).activated())
        revert MigrationActivated();
    _;
}

modifier withdrawalOpen() {
    // Withdrawals continue post-migration so users can drain;
    // they only stop when the dispute pipeline marks roots reverted.
    _;
}
```

Each breaker is a *property* — observable, deterministic, no
privileged caller.  `circuitOpen` rejects new state-shaping
operations (`depositETH`, `depositERC20`, `submitStateRoot`).
`withdrawalOpen` is intentionally permissive to preserve the
"users can always exit" property even after migration.  See
§9.1.4 for the precise breaker semantics and the per-breaker
mathematical justifications.

#### 9.1.1 WU E.1.1 — Deposit entry points

**Owner:** Solidity; **Reviewer count:** 1 Solidity + 1 Lean;
**Depends on:** A.2 (keccak256), B.2 (Lean ingestor for
DepositId byte-equivalence target).

**Deliverable.**  Two deposit functions plus their bookkeeping:

```solidity
function depositETH() external payable nonReentrant circuitOpen;
function depositERC20(IERC20 token, uint256 amount)
    external nonReentrant circuitOpen;

mapping(address => uint64) private depositNonce;  // per-depositor counter

event DepositInitiated(
    address indexed depositor,
    address token,            // address(0) for native ETH
    uint256 amount,
    uint64  depositorNonce,
    bytes32 receiptHash
);
```

**Critical correctness obligations.**

  1. **Reentrancy safety**: `nonReentrant` modifier on both
     functions.  ETH deposit's `msg.value` is transferred *to*
     the contract before any state update, so reentrancy is
     not directly exploitable, but a malicious ERC-20 token's
     `transferFrom` could re-enter; the modifier rejects.
  2. **`receiptHash`** is computed as
     ```
     receiptHash = keccak256(abi.encode(
         deploymentId,           // immutable, derived in ctor
         msg.sender,
         token,                  // address(0) for ETH
         amount,
         depositNonce[msg.sender]
     ));
     ```
     This must match the Lean side's `DepositId` derivation
     byte-for-byte (cross-stack fixture in F.1).
     `deploymentId` already binds `block.chainid` and
     `address(this)` per its construction recipe, so
     cross-deployment domain separation is structural.
  3. **Per-depositor counter**: `depositNonce[msg.sender]++`
     after `receiptHash` is computed.  Prevents a single
     depositor from accidentally producing identical receipt
     hashes within the same block.
  4. **SafeERC20**: ERC-20 deposits use
     `SafeERC20.safeTransferFrom`, which handles non-conforming
     tokens (USDT, etc.) that don't return a bool from
     `transfer`.
  5. **`totalLockedValue` accounting**: each successful deposit
     increments `totalLockedValue` by `amount` (using checked
     arithmetic — Solidity 0.8.20+ default).  This feeds the
     `tvlCap` circuit breaker; it also lets the off-chain
     watchdog reconcile against the Lean side's
     `totalDeposited - totalWithdrawn`.

**Acceptance criteria.**

  * 100% line coverage in `forge` test suite for the two
    functions.
  * Reentrancy fixture (malicious ERC-20 callback) rejected.
  * Cross-stack `receiptHash` byte-equivalence verified by F.1.
  * `tvlCap` circuit-breaker boundary fixture: deposit at
    `tvlCap` succeeds, deposit at `tvlCap + 1` reverts with
    `TvlCapReached`.

#### 9.1.2 WU E.1.2 — State-root submission

**Owner:** Solidity; **Reviewer count:** 1; **Depends on:** A.1
(ECDSA verify).

**Deliverable.**  Attestor-gated state-root submission.  The
attestor is the `address public immutable attestor` set in the
constructor; there is no `grantRole` / `revokeRole` path.
Rotating the attestor requires a new bridge deployment + a
`KnomosisMigration` handoff (§9.5).

```solidity
struct StateRootRecord {
    bytes32 root;
    uint64  logIndexHigh;
    uint64  submittedAtBlock;
    bool    finalised;        // dispute window elapsed (deterministic
                              //   function of submittedAtBlock and
                              //   block.number; cached on first read)
    bool    reverted;         // post-dispute rollback
}

mapping(uint64 => StateRootRecord) public stateRoots;  // logIndexHigh -> record
uint64 public latestSubmittedLogIndexHigh;
uint64 public latestStateRootSubmittedAtBlock;          // feeds circuitOpen()

function submitStateRoot(
    bytes32 root,
    uint64  logIndexHigh,
    bytes   calldata attestorSig
) external circuitOpen;

event StateRootSubmitted(
    bytes32 indexed root,
    uint64 indexed logIndexHigh,
    address indexed attestor,
    uint64 submittedAtBlock
);
```

**Critical correctness obligations.**

  1. **Strict monotonicity**: `require(logIndexHigh >
     latestSubmittedLogIndexHigh, NonMonotonic())`.  Concurrent
     attestor submissions at the same `logIndexHigh` are
     rejected (only the first to land on L1 succeeds).  This
     also ensures the L1 record matches the Lean
     `expectsNonce_strict_mono` discipline applied to
     log indices.
  2. **Attestor signature verification**: the function
     recovers the signer of the EIP-712 hash of
     `(root, logIndexHigh, deploymentId)` via `ECDSA.recover`
     (low-s canonicalised) and asserts
     `recovered == attestor`.  Inputs binding `deploymentId`
     give cross-deployment-replay rejection structurally
     (different deploymentId ⇒ different signing hash ⇒
     unrelated signature).  Implementation MUST use
     `MessageHashUtils.toTypedDataHash` to assemble the
     EIP-712 wrap (matching workstream A.3's Lean
     `eip712Wrap`).
  3. **Immutable-address gating** replaces `onlyRole`: a single
     `require(msg.sender == attestor, NotAttestor())` at
     function entry.  No mutable role mapping; no
     `AccessControlUnauthorizedAccount` revert path; no
     `grantRole` event in the contract's lifetime.
  4. **Circuit-breaker discipline**: the function carries
     `circuitOpen`, which (a) rejects submissions during the
     post-dispute cooldown window, (b) rejects submissions
     after the migration has activated, and (c) rejects
     submissions if the bridge has exceeded its TVL cap (a
     defensive measure against runaway sequencer behaviour).

**Acceptance criteria.**

  * Attestor-signature replay rejected (`logIndexHigh` strict
    monotonicity).
  * Cross-deployment-replay rejected: a signature produced
    against a deployment with a different `deploymentId`
    fails the `recover == attestor` check.
  * Immutable-address fixture: non-attestor caller is rejected
    with `NotAttestor` (typed custom error, no string-based
    revert).
  * Circuit-breaker fixture: a submission during cooldown
    reverts with `DisputeCooldown`; a submission post-
    migration-activation reverts with `MigrationActivated`.

#### 9.1.3 WU E.1.3 — Withdrawal redemption

**Owner:** Solidity; **Reviewer count:** 1 Solidity + 1 Lean;
**Depends on:** D.1 (proof verifier shape), E.1.2.

**Deliverable.**  Proof-gated withdrawal redemption with strict
check-effects-interactions ordering:

```solidity
mapping(bytes32 => bool) public withdrawalLeafRedeemed;
uint64 public immutable disputeWindowBlocks;
uint64 public immutable maxRedemptionWindowBlocks;

function withdrawWithProof(
    uint64           atLogIndexHigh,
    bytes calldata   proofBlob,    // CBE encode of WithdrawalProof
    bytes calldata   leafBlob      // CBE encode of PendingWithdrawal
) external nonReentrant withdrawalOpen returns (bool);

event WithdrawalRedeemed(
    bytes32 indexed leafHash,
    address indexed recipient,
    address token,
    uint256 amount,
    uint64  atLogIndexHigh
);
```

Note `withdrawalOpen` (not `circuitOpen`): per §9.1's
modifier table, withdrawals continue even after migration so
users can always exit.  The dispute pipeline still gates
withdrawal correctness via the `reverted` flag on the
state-root record.

**Critical correctness obligations (CEI ordering enforced).**

  1. **Check phase**:
     (a) Decode `leafBlob` into a structured
         `(resource, recipientL1, amount, l2LogIndex)` tuple
         using a CBE-decoder library shared with the dispute
         verifier (workstream E.2's CBE-decode helper).
     (b) Look up the state root at `atLogIndexHigh` from
         `stateRoots[atLogIndexHigh]`.  Reject if not present,
         not finalised, or reverted.  `finalised` is computed
         on-the-fly as
         `block.number >= record.submittedAtBlock + disputeWindowBlocks`
         (no separate setter; the property is a deterministic
         function of immutable state).
     (c) Compute `leafHash = keccak256(leafBlob)`.  Reject if
         `withdrawalLeafRedeemed[leafHash] == true`.
     (d) Decode `proofBlob` into a `WithdrawalProof` struct.
         Run `verifyProof(proof, stateRoots[atLogIndexHigh].root)`
         (the on-chain SMT verifier, same algorithm as Lean's
         §D.1.4).  Reject if false.
  2. **Effect phase**: set `withdrawalLeafRedeemed[leafHash] = true`
     *before* any external call.  Decrement `totalLockedValue`
     by `amount` (saturating subtraction guarded by `require`).
  3. **Interaction phase**: transfer to `recipientL1`.
     - Native ETH: `Address.sendValue(recipientL1, amount)`.
     - ERC-20: `SafeERC20.safeTransfer(token, recipientL1, amount)`.

  4. **Dispute-window-vs-redemption discipline**: the
     constructor require
     `_disputeWindowBlocks >= _maxRedemptionWindowBlocks`
     (§9.1 constructor sketch) is the *immutable* enforcement;
     re-enforced here as defence-in-depth via an inline
     `assert` in `_isFinalised`.  No state root is marked
     `finalised` until
     `block.number >= submittedAtBlock + disputeWindowBlocks`.

**Acceptance criteria.**

  * 100% line coverage on `withdrawWithProof`.
  * Reentrancy fixture (malicious recipient contract) rejected.
  * Double-spend fixture rejected.
  * Pre-finalisation fixture rejected.
  * Cross-stack equivalence: a Lean-built proof against a
    Lean-built state root verifies on-chain (F.1.5).
  * Post-migration redemption fixture: even after the migration
    activates, valid withdrawal proofs against pre-migration
    state roots continue to redeem (the user-exit guarantee).

#### 9.1.4 WU E.1.4 — Automatic circuit breakers

**Owner:** Solidity; **Reviewer count:** 1; **Depends on:** none
within E.1; depends on E.5 (`KnomosisMigration` interface
declaration only — the address may be `address(0)` at
deployment time).

**Deliverable.**  The four automatic, state-driven circuit
breakers that gate `circuitOpen`-marked entry points
(`depositETH`, `depositERC20`, `submitStateRoot`).
There are no human-triggered pause / unpause functions.
There is no admin role.  There is no upgrade authority.
Every breaker is a `revert` guard on a public, deterministic
predicate — anyone can verify off-chain whether the breaker
will fire on the next block.

```solidity
// All four parameters are `immutable`, set in the constructor.
uint64  public immutable maxAttestationStaleBlocks;
uint64  public immutable cooldownBlocks;
uint256 public immutable tvlCap;
address public immutable migration;       // KnomosisMigration; may be address(0)

// Cached state that the breakers inspect.
uint256 public totalLockedValue;          // sum(deposits) - sum(withdrawals)
uint64  public latestStateRootSubmittedAtBlock;
uint64  public lastUpheldDisputeBlock;    // set by revertToPriorRoot (E.1.5)

// Typed errors (no string reverts; gas-efficient + machine-parsable):
error AttestationStale();
error DisputeCooldown();
error TvlCapReached();
error MigrationActivated();
```

**The four breakers.**

  1. **`AttestationStale`** — `block.number >
     latestStateRootSubmittedAtBlock + maxAttestationStaleBlocks`
     when `latestStateRootSubmittedAtBlock != 0`.  Fires if the
     attestor has gone silent (typical default:
     `maxAttestationStaleBlocks = 7200` ≈ 24 hours).  Forces
     the watchdog / human operators to intervene by deploying
     a successor before the contract drifts further from the
     L2 state.  *Initial-state escape hatch*: when
     `latestStateRootSubmittedAtBlock == 0` (no state root
     submitted yet), the breaker does not fire — otherwise the
     bridge would be DOA at deployment.
  2. **`DisputeCooldown`** — `lastUpheldDisputeBlock != 0 &&
     block.number < lastUpheldDisputeBlock + cooldownBlocks`.
     Fires after a dispute upholds, halting new state-shaping
     ops for `cooldownBlocks` (typical default: 7200 ≈ 24
     hours).  Gives the human operators time to investigate
     before the sequencer can publish more state roots.
  3. **`TvlCapReached`** — `totalLockedValue > tvlCap` (typical
     default: `tvlCap = 100,000 ether`).  Hard cap on bridge
     value at risk.  Reset only by withdrawals draining
     `totalLockedValue` below the cap.  This is the per-
     contract-instance equivalent of "the kernel's
     `MonotonicLawSet` rejects new monotonic-violating laws
     at the type level": the bridge's TVL cannot grow without
     bound regardless of what the operator does.
  4. **`MigrationActivated`** — `migration != address(0) &&
     IKnomosisMigration(migration).activated() == true`.  Once
     the migration contract has activated its handoff to a
     successor, the predecessor stops accepting new
     deposits / new state roots.  Withdrawals continue
     (`withdrawalOpen` does not check this breaker), so users
     can drain the predecessor over the migration's grace
     window.  See §9.5.

**Critical correctness obligations.**

  1. **Determinism**.  Every breaker condition is a pure
     function of `block.number` plus public state.  No
     oracles, no signatures, no off-chain inputs.  This means
     anyone can compute, for any future block, whether the
     breaker would fire — there is no "surprise pause" path.
  2. **Monotonic predicates where possible.**  `AttestationStale`
     is monotonic in `block.number` between state-root
     submissions; `DisputeCooldown` is monotonic until the
     cooldown elapses; `MigrationActivated` is monotonic
     (once activated, never deactivates per §9.5).
     `TvlCapReached` is the only non-monotonic breaker, and
     it is rate-bounded by deposit / withdrawal flow.
  3. **No bypass path.**  Because there is no admin role,
     no `unpause()` function, and no upgrade hook, the
     breakers cannot be silenced by any single party.  An
     operator who wants to "unpause" must wait for the
     breaker's predicate to clear (e.g. `cooldownBlocks`
     elapses) or deploy a successor with different immutable
     parameters and migrate.
  4. **Mathematical soundness (no false safety claim).**
     Each breaker is a *necessary*, never *sufficient*, safety
     guard.  The actual safety properties (e.g. "no
     double-spend") are enforced by the per-function
     correctness obligations (E.1.1 – E.1.3), not by the
     breakers.  The breakers reduce *blast radius* — they do
     not provide *correctness*.  This is documented in the
     contract's NatSpec to prevent reviewers from misreading
     the breakers as primary safety mechanisms.

**Acceptance criteria.**

  * 100% line coverage on each breaker's revert path.
  * `AttestationStale` boundary fixture: deposit at exactly
    `latestStateRootSubmittedAtBlock + maxAttestationStaleBlocks`
    succeeds; deposit one block later reverts.
  * `DisputeCooldown` boundary fixture: deposit immediately
    after `revertToPriorRoot` reverts; deposit at
    `lastUpheldDisputeBlock + cooldownBlocks` succeeds.
  * `TvlCapReached` boundary fixture: deposit cumulating to
    exactly `tvlCap` succeeds; deposit pushing over the cap
    reverts.
  * `MigrationActivated` fixture: pre-migration deposits
    succeed; post-migration deposits revert; post-migration
    withdrawals succeed.
  * `Initial-state escape hatch` fixture: at the first block
    after deployment (when `latestStateRootSubmittedAtBlock
    == 0`), `AttestationStale` does not fire even when
    `block.number > maxAttestationStaleBlocks`.
  * No test exercises a "pause" or "unpause" function — they
    do not exist.  The forge test suite contains a
    compile-time assertion (`vm.expectRevert(NoSuchFunction)`)
    that calls to the deprecated names fail at the ABI level.

#### 9.1.5 WU E.1.5 — Rollback hook

**Owner:** Solidity; **Reviewer count:** 2 (Solidity + Lean);
**Depends on:** E.1.2, E.2 (dispute verifier calls into this).

**Deliverable.**  The rollback API that
`KnomosisDisputeVerifier.sol` calls on `.upheld` finalisation:

```solidity
function revertToPriorRoot(uint64 disputedLogIndexHigh) external;

event StateRootReverted(
    uint64 indexed disputedLogIndexHigh,
    bytes32 indexed revertedRoot
);
```

**Critical correctness obligations.**

  1. **Immutable-address gating** (replaces `onlyRole`): the
     function entry asserts
     `require(msg.sender == disputeVerifier, NotDisputeVerifier())`
     against the `address public immutable disputeVerifier`
     set in the constructor.  Only the well-known
     `KnomosisDisputeVerifier` contract can call this entry
     point; that contract's address is fixed for the lifetime
     of this `KnomosisBridge` deployment.  Rotating the dispute
     verifier requires a new `KnomosisBridge` deployment + a
     `KnomosisMigration` handoff (§9.5).
  2. **Mark all state roots from `disputedLogIndexHigh` onward
     as reverted.**  No further withdrawals can redeem against
     them; users with redemption-pending proofs at those roots
     must re-prove against a later finalised root (out of MVP
     scope: rollback restitution mechanism).
  3. **Idempotent**: calling `revertToPriorRoot` twice with the
     same argument is a no-op (no double-reversion).  Mirrors
     the Lean-side `applyWithdraw_idempotent`.
  4. **Cooldown-breaker sync**: on every successful call,
     update `lastUpheldDisputeBlock = block.number` so the
     `DisputeCooldown` circuit breaker (§9.1.4) trips for
     the next `cooldownBlocks` blocks.  This is the
     mechanical link between Stage 4 of the dispute pipeline
     and the bridge's automatic state-shaping freeze: the
     pipeline never asks an operator to flip a switch.

**Acceptance criteria.**

  * 100% line coverage on `revertToPriorRoot`.
  * Idempotency fixture passes.
  * Non-`disputeVerifier` caller rejected with
    `NotDisputeVerifier` (typed custom error; no string
    revert; no role-mapping lookup).
  * Cross-stack rollback fixture: an upheld dispute on Lean's
    side triggers a rollback on the Solidity side that matches
    the expected post-revert state.
  * Cooldown-sync fixture: after a successful
    `revertToPriorRoot`, the next `depositETH` call within
    `cooldownBlocks` reverts with `DisputeCooldown`.

### 9.2 WU E.2 — `KnomosisDisputeVerifier.sol`

E.2 is the most cross-stack-porting-risky workstream in the
MVP.  It splits into five sub-WUs that land sequentially.  The
shared file is `solidity/contracts/KnomosisDisputeVerifier.sol`;
the split lets each per-claim verifier be ported and audited in
isolation.

Like `KnomosisBridge.sol`, this contract is deployed immutably:
no proxy, no `initialize`, no admin role, no upgrade path.
The `bridge`, `identityRegistry`, `sequencerStake`, and
`migration` references are `address public immutable` set in
the constructor.  The dispute-verifier address recorded in
`KnomosisBridge` (`disputeVerifier` immutable) must match this
contract's address — the deployment script enforces this with
a constructor-time cross-check.

```solidity
constructor(
    bytes32 _knomosisVersionTag,
    address _bridge,
    address _identityRegistry,
    address _sequencerStake,
    address _migration,
    uint8   _quorumThreshold,
    address[] memory _approvedAdjudicators
) {
    require(_quorumThreshold > 0
        && _quorumThreshold <= _approvedAdjudicators.length,
        "quorum-threshold-out-of-range");
    require(IKnomosisBridge(_bridge).disputeVerifier() == address(this),
        "bridge-disputeVerifier-mismatch");
    knomosisVersionTag    = _knomosisVersionTag;
    bridge             = _bridge;
    identityRegistry   = _identityRegistry;
    sequencerStake     = _sequencerStake;
    migration          = _migration;
    quorumThreshold    = _quorumThreshold;
    deploymentId       = keccak256(abi.encode(
        block.chainid, address(this), _knomosisVersionTag));
    // Snapshot the approved adjudicator set into immutable storage
    // (handled by a fixed-size on-chain array; see §9.2.5 for the
    // mathematical justification of the immutable adjudicator set).
    _approvedAdjudicatorRoot = keccak256(abi.encode(_approvedAdjudicators));
    for (uint256 i = 0; i < _approvedAdjudicators.length; ++i) {
        _approvedAdjudicator[_approvedAdjudicators[i]] = true;
    }
}
```

The set of approved adjudicators is *snapshot* into the
contract at construction and never modified.  Rotating
adjudicators requires a new dispute-verifier deployment + a
`KnomosisMigration` handoff.  This is a deliberate design choice:
the §9.2.5 quorum-deduplication safety property requires the
approved set to be a fixed multiset; mid-flight membership
changes would invalidate cross-stack F.1.6 fixtures and
introduce a governance surface that this workstream
specifically rejects.

The MVP ports three of the five Phase-6 `Disputes.Evidence`
claim variants:

  * `signatureInvalid` — E.2.2.
  * `nonceMismatch`    — E.2.3.
  * `doubleApply`      — E.2.4.

Deferred to v2: `preconditionFalse` (requires full kernel
replay, expensive) and `oracleMisreported` (requires
deployment-specific oracle policy).  Adding either variant
requires a new dispute-verifier deployment + migration; there
is no in-place extension path.

#### 9.2.1 WU E.2.1 — Dispute filing and the CBE-decode helper

**Owner:** Solidity + Lean; **Reviewer count:** 1 Solidity + 1
Lean; **Depends on:** E.1.5, the Phase-6 `Disputes.Filing`
module.

**Deliverable.**  The dispute-filing entry point, the CBE-decode
library shared with the withdrawal-redemption path, and the
disputeId allocator.  The CBE-decode library is the
*hardest* piece — it must implement byte-for-byte CBE decoding
for all dispute-related types in Solidity, matching the Lean
`Encodable` instances exactly.

```solidity
struct DisputeRecord {
    uint64  impugnedLogIndex;
    address challenger;
    uint8   claimVariant;     // 0..4 per Disputes.Types.DisputeClaim
    bytes   evidenceBlob;     // CBE-encoded per-variant evidence
    uint8   status;           // 0=open, 1=upheld, 2=rejected,
                              // 3=inconclusive, 4=withdrawn
    uint64  filedAtBlock;
}

mapping(uint64 => DisputeRecord) public disputes;
uint64 public nextDisputeId;

function fileDispute(
    uint64         impugnedLogIndex,
    uint8          claimVariant,
    bytes calldata evidenceBlob
) external returns (uint64 disputeId);

event DisputeFiled(
    uint64 indexed disputeId,
    address indexed challenger,
    uint64 impugnedLogIndex,
    uint8 claimVariant
);
```

**The CBE-decode library** (`solidity/lib/CBEDecode.sol`)
provides:

```solidity
function readUint64(bytes calldata buf, uint256 off)
    internal pure returns (uint64 v, uint256 nextOff);
function readBytes32(bytes calldata buf, uint256 off)
    internal pure returns (bytes32 v, uint256 nextOff);
function readBytes(bytes calldata buf, uint256 off)
    internal pure returns (bytes memory v, uint256 nextOff);
function readActorId(bytes calldata buf, uint256 off)
    internal pure returns (uint64 actorId, uint256 nextOff);
```

Each function follows the CBE head encoding from
`LegalKernel/Encoding/CBOR.lean`: 1 type-tag byte + 8 LE value
bytes.  The library reverts with a typed error
(`CBEMalformed`) on any out-of-range read or wrong tag.

**Acceptance criteria.**

  * 100% line coverage on `fileDispute` and the CBE-decode
    library.
  * Cross-stack F.1.6 fixture: 32 Lean-encoded values round-trip
    through the Solidity decoder to the same logical values.
  * `CBEMalformed` revert fired on truncated / wrong-tag input.

#### 9.2.2 WU E.2.2 — `signatureInvalid` claim verifier

**Owner:** Solidity + Lean; **Reviewer count:** 1 Solidity + 1
Lean; **Depends on:** E.2.1, A.1, E.3 (`KnomosisIdentityRegistry`).

**Deliverable.**  The Solidity port of
`LegalKernel.Disputes.Evidence.checkSignatureInvalid`.

```solidity
function checkSignatureInvalid(
    uint64 impugnedLogIndex,
    bytes calldata logEntryBlob,    // CBE-encoded LogEntry
    bytes calldata recordedSig
) external view returns (uint8 verdict);   // 0=upheld, 1=rejected,
                                            //  2=inconclusive
```

The function:
  1. Decodes `logEntryBlob` into the structured
     `(action, signer, nonce, sig)` tuple.
  2. Looks up `signer`'s currently-registered key via
     `KnomosisIdentityRegistry.lookup(signer)`.  Returns `2`
     (inconclusive) if the signer is unregistered.
  3. Recomputes the EIP-712 signing hash of `(action, signer,
     nonce, deploymentId)`.
  4. Calls `ECDSA.recover(eip712Hash, sig)` and compares to the
     registered key's address.  Returns `0` (upheld — claim is
     true, signature is invalid) on mismatch; `1` (rejected —
     claim is false, signature is valid) on match.

**Critical correctness obligations.**

  * Byte-equivalent to `checkSignatureInvalid` in
    `LegalKernel/Disputes/Evidence.lean:171`.  Cross-stack
    fixture in F.1 covers 64 inputs (32 valid signatures, 32
    invalid).
  * Low-s canonicalisation: rejects high-s signatures (matches
    the A.1 binding).
  * Reverts on malformed `logEntryBlob` via `CBEMalformed`.

**Acceptance criteria.**

  * 100% line coverage.
  * 64 / 64 cross-stack matches.
  * High-s signature rejected.

#### 9.2.3 WU E.2.3 — `nonceMismatch` claim verifier

**Owner:** Solidity + Lean; **Reviewer count:** 1 Solidity + 1
Lean; **Depends on:** E.2.1.

**Deliverable.**  The Solidity port of
`LegalKernel.Disputes.Evidence.checkNonceMismatch`.

```solidity
struct LogPrefix {
    bytes[] entries;    // CBE-encoded LogEntries, ordered;
                        // the impugned entry is at the end
}

function checkNonceMismatch(
    uint64 impugnedLogIndex,
    LogPrefix calldata prefix
) external pure returns (uint8 verdict);

uint64 public constant MAX_PREFIX_LEN = 256;
```

The function:
  1. Reverts if `prefix.entries.length > MAX_PREFIX_LEN` (the
     MVP one-shot fraud-proof bound; bisection is post-MVP).
  2. Replays the prefix in order, maintaining a per-signer
     `expectsNonce` map.  Each replayed entry advances its
     signer's nonce.
  3. At the impugned entry: compares the recorded nonce against
     the recomputed `expectsNonce[signer]`.  Returns `0`
     (upheld) on mismatch; `1` (rejected) on match.

**Critical correctness obligations.**

  * Byte-equivalent to `checkNonceMismatch` (`Disputes/Evidence.lean:209`).
  * Replay does *not* check signatures or admissibility (it
    matches Lean's `kernelOnlyReplay` semantics — same
    nonce-only bookkeeping, no Verify calls).
  * Gas-cost bound: ≤ 256 entries × ~5k gas per entry =
    ~1.3M gas worst case.  Within mainnet block-gas budget for
    a one-off dispute.

**Acceptance criteria.**

  * 100% line coverage.
  * 32 / 32 cross-stack matches at varying prefix lengths.
  * `MAX_PREFIX_LEN+1` revert fixture rejected.

#### 9.2.4 WU E.2.4 — `doubleApply` claim verifier

**Owner:** Solidity + Lean; **Reviewer count:** 1 Solidity + 1
Lean; **Depends on:** E.2.1.

**Deliverable.**  The Solidity port of
`LegalKernel.Disputes.Evidence.checkDoubleApply`.

```solidity
function checkDoubleApply(
    uint64 impugnedLogIndex,
    uint64 secondaryLogIndex,
    bytes calldata impugnedBlob,
    bytes calldata secondaryBlob
) external pure returns (uint8 verdict);
```

The function:
  1. Reverts if `impugnedLogIndex == secondaryLogIndex` (claim
     is structurally invalid; matches Lean's
     `checkDoubleApply_rejects_self`).
  2. Decodes both blobs to extract `(signer, nonce)` pairs.
  3. Returns `0` (upheld) iff both signers and nonces match;
     `1` (rejected) otherwise.

**Critical correctness obligations.**

  * Byte-equivalent to `checkDoubleApply` (`Disputes/Evidence.lean:258`).
  * Self-claim (`idx₁ == idx₂`) reverts (`SelfClaimInvalid`),
    matching the Lean `rejected` outcome via revert convention
    documented in §9.2.1's CBE library.

**Acceptance criteria.**

  * 100% line coverage.
  * 32 / 32 cross-stack matches.
  * Self-claim revert fixture passes.

#### 9.2.5 WU E.2.5 — Verdict finalisation, slash, rollback trigger

**Owner:** Solidity + Lean; **Reviewer count:** 2 (Solidity +
Lean); **Depends on:** E.2.2, E.2.3, E.2.4, E.4 (staking).

**Deliverable.**  The verdict-finalisation logic + slash trigger
+ rollback trigger.  This is the apex of the dispute pipeline.

```solidity
function finalizeUpheld(
    uint64                       disputeId,
    bytes32                      verdictHash,
    address[] calldata           signers,
    bytes[]   calldata           sigs
) external;

// Set in the constructor; cannot be changed.
uint8 public immutable quorumThreshold;
```

The function:
  1. Loads `disputes[disputeId]`.  Reverts if not open.
  2. Counts distinct, approved, registered, valid-signature
     adjudicators in the `(signers, sigs)` arrays.  Uses the
     same per-signer deduplication discipline as the Phase-6
     `countVerifiedSignatures` post-Audit-1 fix
     (`Disputes/Verdict.lean`).  "Approved" is determined by
     the immutable `_approvedAdjudicator[addr]` mapping
     populated in the constructor — there is no governance
     setter.
  3. Reverts if count < `quorumThreshold`.
  4. Re-runs the appropriate per-claim verifier (E.2.2 / E.2.3
     / E.2.4) to confirm `.upheld`.  Reverts otherwise.
  5. Marks the dispute `upheld`.
  6. Calls `KnomosisSequencerStake.slash(disputeId, challenger)`
     (E.4).  The `sequencerStake` reference is `address public
     immutable`, so this call cannot be retargeted.
  7. Calls `KnomosisBridge.revertToPriorRoot(impugnedLogIndex)`
     (E.1.5).  The `bridge` reference is `address public
     immutable`, so this call cannot be retargeted.
  8. Emits `DisputeUpheld(disputeId)`.

A symmetric `finalizeRejected` path exists for adjudicator-
signed `.rejected` outcomes (no slash, no rollback).

**Critical correctness obligations.**

  1. **Quorum deduplication**: the Phase-6 Audit-1 fix —
     repeated approved signers contribute at most 1 to the
     count regardless of array padding.
  2. **Re-verification on finalisation**: the contract does *not*
     trust the filing-time verifier outcome.  It re-runs the
     per-claim verifier at finalisation time, since the
     impugned-log-prefix could have changed between filing and
     finalisation.  (Filing only locks the dispute; the
     evidence is re-evaluated at finalisation.)
  3. **Atomic slash + rollback**: both side-effects happen in
     the same transaction.  If either fails (e.g. the bridge's
     `revertToPriorRoot` reverts because the role is wrong),
     the entire `finalizeUpheld` reverts.

**Acceptance criteria.**

  * 100% line coverage on `finalizeUpheld` and
    `finalizeRejected`.
  * Quorum-padding attack fixture rejected.
  * Stale-evidence fixture: between filing and finalisation,
    the prefix changes such that the claim is no longer upheld;
    the contract correctly rejects.
  * Cross-stack equivalence: 100/100 random `(disputeId,
    verdict, sigs)` produce the same outcome on both
    implementations.

### 9.3 WU E.3 — `KnomosisIdentityRegistry.sol`

**Owner:** Solidity; **Reviewer count:** 1; **Depends on:** none.

**Deliverable.**  A pubkey-registration contract that
distinguishes ECDSA EOAs from EIP-1271 contract signers at the
type level (the two have different verification paths in
A.1's adaptor).  Like the other E.* contracts, this contract
is deployed immutably: no proxy, no `initialize`, no admin
role, no upgrade hook.  Each user's identity is theirs to
manage via `registerECDSA` / `registerEIP1271` / `revoke` —
there is no global key-rotation authority.  Re-deploying this
contract requires a new bridge deployment + a `KnomosisMigration`
handoff (§9.5).

```solidity
enum SignerKind { ECDSA_EOA, EIP1271_CONTRACT }

struct IdentityRecord {
    SignerKind kind;
    bytes      pubkey;        // 64 bytes uncompressed secp256k1 for
                              //   ECDSA_EOA; address-as-bytes20 for
                              //   EIP1271_CONTRACT
    uint64     registeredAt;  // block number
}

mapping(address => IdentityRecord) public identities;

function registerECDSA(bytes calldata uncompressedPubkey) external;
function registerEIP1271(address contractSigner) external;
function revoke() external;
function lookup(address actor) external view
    returns (IdentityRecord memory);

event RegisteredECDSA   (address indexed actor, bytes pubkey);
event RegisteredEIP1271 (address indexed actor, address contractSigner);
event Revoked           (address indexed actor);
```

**Critical correctness obligations.**

  1. **`registerECDSA`** verifies that the EOA actually
     possesses the private key for the supplied uncompressed
     pubkey:
     ```
     bytes32 pkHash = keccak256(uncompressedPubkey);
     address derived = address(uint160(uint256(pkHash)));
     require(derived == msg.sender, "pubkey-mismatch");
     require(uncompressedPubkey.length == 64, "wrong-pubkey-length");
     ```
     This blocks the front-running where Eve registers Alice's
     pubkey for her own address (the derived-vs-msg.sender check
     binds the registration to the caller's address).
  2. **`registerEIP1271`** verifies that `contractSigner`
     implements EIP-1271:
     ```
     // Probe with a dummy hash + signature to test
     // isValidSignature returns the EIP-1271 magic value.
     try IERC1271(contractSigner).isValidSignature(bytes32(0), "")
       returns (bytes4 v) {
         require(v == 0x00000000 || v == 0x1626ba7e,
                 "not-eip1271-or-bad-test");
     } catch { revert("not-eip1271"); }
     ```
     The probe distinguishes "contract implements EIP-1271 and
     correctly rejects invalid sig" from "contract throws or has
     no EIP-1271 interface".
  3. **`revoke`** sets `identities[msg.sender]` to the zero
     record.  Subsequent `Verify`-adaptor calls with the
     signer's address fail (since `lookup` returns zero pubkey,
     which fails ECDSA recover).  Re-registration is permitted
     (same as rotation).
  4. **No re-registration without revocation**:
     `registerECDSA` and `registerEIP1271` revert if the caller
     already has a non-zero record.  This prevents a contract
     signer from silently becoming an ECDSA signer (or vice
     versa) without an explicit revocation event in the audit
     log.

**Acceptance criteria.**

  * 100% line coverage in `forge` test suite.
  * Front-running fixture rejected (`registerECDSA` for a key
    not owned by `msg.sender`).
  * EIP-1271 probe rejects non-conforming contract.
  * Re-registration without revocation rejected.
  * Revoke-then-re-register passes.

### 9.4 WU E.4 — Sequencer staking and slashing

**Owner:** Solidity; **Reviewer count:** 1; **Depends on:** E.1, E.2.

**Deliverable.**  `solidity/contracts/KnomosisSequencerStake.sol`
holds the sequencer's stake in escrow.  On `DisputeUpheld`, the
stake is slashed: a `slashRatio` portion is paid to the
challenger as the reward documented in Phase-6's incentive
amendment (`DisputeRewardPolicy`); the remainder is burned
(sent to `address(0)`).

Like the other E.* contracts, this contract is deployed
immutably: no proxy, no admin role, no upgrade hook.  The
`sequencer`, `disputeVerifier`, and `bridge` references plus
`slashRatio` and `disputeWindowBlocks` are all `immutable`,
set in the constructor:

```solidity
constructor(
    bytes32 _knomosisVersionTag,
    address _sequencer,
    address _disputeVerifier,
    address _bridge,
    uint256 _slashRatio,            // basis-points, e.g. 5000 = 50%
    uint64  _disputeWindowBlocks    // matches KnomosisBridge for symmetry
) {
    require(_slashRatio <= 10000, "slashRatio > 100%");
    require(IKnomosisDisputeVerifier(_disputeVerifier).sequencerStake()
            == address(this), "verifier-stake-mismatch");
    sequencer           = _sequencer;
    disputeVerifier     = _disputeVerifier;
    bridge              = _bridge;
    slashRatio          = _slashRatio;
    disputeWindowBlocks = _disputeWindowBlocks;
    deploymentId        = keccak256(abi.encode(
        block.chainid, address(this), _knomosisVersionTag));
}

function deposit() external payable;
function withdraw(uint256 amount) external;       // onlySequencer enforced
                                                  //   inline; reverts during
                                                  //   open-dispute lock-up
function slash(uint64 disputeId, address challenger) external;
                                                  // onlyDisputeVerifier
                                                  //   enforced inline
```

**Critical correctness obligations.**

  1. **Immutable-address gating** replaces `onlySequencer` and
     `onlyDisputeVerifier`: each function entry asserts
     `msg.sender == sequencer` or `msg.sender == disputeVerifier`
     against the immutable address set in the constructor.
     There is no role mapping, no `grantRole`, no `revokeRole`.
  2. **Withdrawal lock-up.**  The sequencer cannot withdraw stake
     while a dispute is open against any of its published
     snapshots.  The lock is implemented by reading
     `IKnomosisBridge(bridge).hasOpenDisputeOlderThan(uint64
     thresholdBlock)` and reverting on `true`; the `bridge`
     reference is immutable, so the lock cannot be re-pointed
     at a more permissive contract.
  3. **Single-slash-per-dispute.**  Each `disputeId` can be
     slashed at most once (idempotency mirrors
     `applyWithdraw_idempotent`).  Implemented via a
     `mapping(uint64 => bool) public slashedDispute` that is
     checked-and-set atomically in `slash`.
  4. **Reward calculation matches Lean.**  The on-chain
     `slashRatio * stake / 10000` calculation is byte-equivalent
     to the Lean `DisputeRewardPolicy.proportionalChallengerReward`
     function.  Cross-stack F.1 fixture asserts byte equivalence
     across 64 randomised `(stake, slashRatio)` pairs including
     the corner cases `(0, 0)`, `(2^256-1, 10000)`, and the
     dust-bound boundaries.
  5. **Slash residual policy.**  After paying the challenger,
     the residual `(10000 - slashRatio) * stake / 10000` is
     burned via `Address.sendValue(payable(address(0xdead)), residual)`
     where `0xdead` is the canonical EIP-7702 burn address (NOT
     `address(0)`, which can revert on some L1 forks; documented
     deviation from the audit-2 spec).  Burn-address selection is
     `immutable`, set in the constructor for deployment-flexibility.

**Acceptance criteria.**

  * Forge tests cover the four obligations above.
  * Cross-stack reward-equivalence test in F.1 (64 inputs).
  * Immutable-address gating fixture: non-sequencer caller is
    rejected with `NotSequencer`; non-disputeVerifier caller is
    rejected with `NotDisputeVerifier`.
  * Burn-address fixture: residual is sent to the immutable
    burn address; sum-conservation property
    (`paid + burned == slashed`) verified across 32 random
    samples.

### 9.5 WU E.5 — `KnomosisMigration.sol`

**Owner:** Solidity + Lean; **Reviewer count:** 1 Solidity + 1
Lean (this is the only contract that crosses the trust
boundary in a way that mirrors a Lean kernel-TCB invariant —
specifically Audit-3.2's `AttestedSnapshot` discipline);
**Depends on:** Audit-3.2 `AttestedSnapshot`, A.1 (ECDSA
verify), A.2 (keccak256), A.3 (EIP-712 wrap).

**Deliverable.**  An immutable, single-shot contract that
records a cryptographically attested handoff from a
predecessor `KnomosisBridge` to a successor `KnomosisBridge`.  This
is Knomosis's only mechanism for changing the on-chain rules
post-deployment; it replaces the role traditionally played by
upgradeable proxies and admin keys.  Critically, it does not
change the predecessor's code — it only signals (via an
on-chain flag the predecessor reads) that the handoff has
activated, at which point the predecessor's circuit breakers
trip.

```solidity
contract KnomosisMigration {
    // -- Immutable handoff parameters (set in constructor) --
    address public immutable predecessor;             // old KnomosisBridge
    address public immutable successor;               // new KnomosisBridge
    bytes32 public immutable predecessorDeploymentId;
    bytes32 public immutable successorDeploymentId;
    address public immutable migrationAttestor;       // = predecessor.attestor()
    uint256 public immutable proposedAtBlock;
    uint256 public immutable graceWindowBlocks;       // ≥ 30 days suggested
    bytes32 public immutable migrationStateRoot;      // pred. final state root
    uint64  public immutable migrationStateRootLogIdx;

    // -- One-shot activation --
    bool    public activated;       // false → true once; never back
    uint256 public activatedAtBlock;

    // -- Constructor invariants --
    constructor(
        address _predecessor,
        address _successor,
        uint256 _graceWindowBlocks,
        bytes32 _migrationStateRoot,
        uint64  _migrationStateRootLogIdx,
        bytes   memory _attestorSig
    ) {
        require(_predecessor != address(0) && _successor != address(0),
                "zero-address");
        require(_predecessor != _successor, "self-migration");
        require(_graceWindowBlocks >= MIN_GRACE_WINDOW_BLOCKS,
                "grace-too-short");

        predecessor              = _predecessor;
        successor                = _successor;
        predecessorDeploymentId  = IKnomosisBridge(_predecessor).deploymentId();
        successorDeploymentId    = IKnomosisBridge(_successor).deploymentId();
        migrationAttestor        = IKnomosisBridge(_predecessor).attestor();
        proposedAtBlock          = block.number;
        graceWindowBlocks        = _graceWindowBlocks;
        migrationStateRoot       = _migrationStateRoot;
        migrationStateRootLogIdx = _migrationStateRootLogIdx;

        require(predecessorDeploymentId != successorDeploymentId,
                "same-deploymentId");

        // The successor must be deployed AND must reference *this*
        // contract as its `migration` immutable — closes the
        // "successor doesn't know about the migration" attack vector.
        require(IKnomosisBridge(_successor).migration() == address(this),
                "successor-does-not-reference-this-migration");

        // Verify the attestor signature over the canonical migration
        // record.  Uses the same EIP-712 wrap as A.3.
        bytes32 wrapHash = _eip712WrapHash(
            predecessorDeploymentId,
            successorDeploymentId,
            _migrationStateRoot,
            _migrationStateRootLogIdx,
            _graceWindowBlocks
        );
        address recovered = ECDSA.recover(wrapHash, _attestorSig);
        require(recovered == migrationAttestor, "attestation-invalid");
    }

    // -- Activation: anyone can call after the grace window --
    function activate() external {
        require(!activated, "already-activated");
        require(block.number >= proposedAtBlock + graceWindowBlocks,
                "grace-not-elapsed");
        activated       = true;
        activatedAtBlock = block.number;
        emit MigrationActivated(predecessor, successor, block.number);
    }

    event MigrationActivated(
        address indexed predecessor,
        address indexed successor,
        uint256 atBlock
    );

    // -- Helpers --
    uint256 public constant MIN_GRACE_WINDOW_BLOCKS = 216_000; // ≈ 30 days @ 12s
    function _eip712WrapHash(...) internal view returns (bytes32) { ... }
}
```

**The four-step lifecycle.**

  1. **Propose** (constructor): off-chain, the operators
     deploy a new `KnomosisBridge` (the `successor`) with its
     `migration` immutable set to a *predicted* `CREATE2`
     address.  They then deploy `KnomosisMigration` at exactly
     that predicted address with the predecessor's attestor
     signature over the canonical migration record.  The
     constructor verifies the signature; if it fails, the
     deployment reverts and no on-chain artefact remains.
     This is the same "compute-address-then-deploy"
     discipline that `CREATE2`-based factories use.
  2. **Grace window** (≥ 30 days): the migration record is
     on-chain; the predecessor continues operating
     normally; users can read the on-chain record (or a
     watchdog UI) and decide whether to (a) redeem at the
     predecessor before the migration activates, (b) opt
     into the successor by interacting with the new
     contract, or (c) ignore the migration (not
     recommended; their state will be frozen on the
     predecessor post-migration).
  3. **Activate** (`activate()`): after the grace window,
     anyone (no role gating) calls `activate()`.  The
     contract sets `activated = true`, irrevocably.  The
     predecessor's `circuitOpen` modifier reads
     `migration.activated()` on every state-shaping call
     and reverts with `MigrationActivated` from this point
     onward.  Withdrawals continue at the predecessor (per
     §9.1.4 `withdrawalOpen`).
  4. **Frozen** (post-grace, post-activation): the
     predecessor accepts only withdrawals; the successor is
     fully operational.  No additional state mutations are
     possible at the migration contract — `activated` only
     flips once.

**Critical correctness obligations.**

  1. **Single-shot activation.**  `activated` is a one-way
     boolean.  No deactivation path exists.  This is the
     mathematical mirror of Phase-6's `applyWithdraw_idempotent`:
     the migration's terminal state is reached by a single
     application of `activate()`, after which further calls
     are no-ops (and revert with `already-activated`).
  2. **Attestation chain integrity.**  The constructor
     recovers the signer from the supplied attestor signature
     against the EIP-712 wrap of the canonical migration
     record.  The EIP-712 wrap binds `predecessorDeploymentId`,
     `successorDeploymentId`, `migrationStateRoot`,
     `migrationStateRootLogIdx`, and `graceWindowBlocks`.
     A forged migration cannot bind any of these values
     without a valid signature; a partial migration (e.g.
     wrong stateRoot) cannot bind the right values.  This
     is the mathematical mirror of Audit-3.2's
     `AttestedSnapshot` discipline applied to the migration
     handoff itself.
  3. **Predecessor-attestor binding.**  The
     `migrationAttestor` is read from the *predecessor's*
     `attestor()` getter at construction time.  The
     attacker cannot substitute a different attestor address
     by tampering with the constructor argument — there is
     no constructor argument for the attestor address.  This
     closes the "compromised migration deployer substitutes
     malicious attestor" attack vector.
  4. **Successor-references-this-migration check.**  The
     constructor asserts that the *successor* `KnomosisBridge`
     records this `KnomosisMigration` address as its `migration`
     immutable.  Without this check, a malicious migration
     could be constructed whose successor doesn't actually
     route the handoff — the predecessor would be tricked
     into freezing while the successor doesn't honor the
     state-root handoff.  With the check, such a migration
     reverts at construction time and never lands on chain.
  5. **Grace-window minimum.**  `MIN_GRACE_WINDOW_BLOCKS`
     is a hard floor (≈ 30 days) baked into the contract;
     the constructor reverts if the grace window is shorter.
     This protects users from being rugged by a "fast"
     migration that doesn't give them time to react.  Note
     that this is a `constant` (compile-time), not a
     constructor argument — so even a malicious deployment
     cannot weaken it.
  6. **No state-transfer mutability.**  `migrationStateRoot`
     is captured at construction time and is `immutable`.
     The successor accepts withdrawal proofs against this
     specific root (and any later roots it produces); the
     predecessor's roots strictly *up to* this index remain
     redeemable at the predecessor.  Roots strictly *after*
     `migrationStateRootLogIdx` cannot be submitted to the
     predecessor (its `submitStateRoot` reverts via
     `MigrationActivated` once activated).
  7. **Cross-deployment isolation preserved.**
     `predecessorDeploymentId != successorDeploymentId` is
     asserted at construction time.  Combined with §8.8.5
     deploymentId scoping in `signingInput`, this means
     predecessor signatures cannot be replayed at the
     successor and vice versa — the migration only
     transfers *state* (via the agreed-upon state root); it
     does not rebind in-flight signatures across deployments.

**Mathematical soundness justification.**

The migration contract is the on-chain analog of a
Lean-side proof: it asserts a specific equality
(`successor.migration() == address(this)`) and a specific
signature-verification predicate at construction time.  If
either assertion fails, the contract does not exist at all
(the deployment reverts).  If both succeed, the on-chain
record is *the* truth about the migration: there is no
parallel off-chain channel that could disagree.  This is
analogous to a Lean theorem: once it elaborates, its
conclusion holds; there is no out-of-band weakening path.

The economic-incentive analysis: a malicious `predecessor`
attestor who signs an invalid migration produces a
contract whose constructor reverts (the
`successor-does-not-reference-this-migration` or
`attestation-invalid` checks fail).  Even with full attestor
key compromise, the attacker can at most produce a *valid*
migration to a `successor` that the attacker controls — but
this requires the attacker to also deploy the malicious
successor with `migration` set to the predicted
`KnomosisMigration` address, an observable on-chain action
that the watchdog can react to within the 30-day grace
window.  Users opt in by interacting with the new contract;
no user is automatically transferred.  The blast radius is
therefore bounded by the grace-window duration plus the
fraction of users who fail to react, never by the total
locked value of the predecessor.

**Acceptance criteria.**

  * 100% line coverage on `KnomosisMigration.sol` (constructor +
    `activate()` only; no other functions exist).
  * Constructor-revert fixtures: invalid attestation,
    same-deploymentId, zero-address, self-migration,
    short-grace, successor-does-not-reference-this-migration.
  * Activation-too-early fixture: `activate()` called before
    `proposedAtBlock + graceWindowBlocks` reverts with
    `grace-not-elapsed`.
  * Re-activation fixture: second call to `activate()`
    reverts with `already-activated`.
  * Predecessor freeze fixture: post-`activate()`,
    `predecessor.depositETH()` reverts with
    `MigrationActivated`; `predecessor.withdrawWithProof(...)`
    succeeds against a pre-migration state root.
  * Cross-stack equivalence: an `AttestedSnapshot` produced
    by the Lean side (Audit-3.2) loads correctly via the
    constructor's signature verification (formalised as
    WU F.1.7; see §10.1.7).
  * Grace-window-minimum fixture: a constructor call with
    `_graceWindowBlocks = MIN_GRACE_WINDOW_BLOCKS - 1`
    reverts with `grace-too-short`.

**Test count target.**  ≈ 24 forge tests across the eight
critical correctness obligations + activation lifecycle +
post-activation predecessor behaviour + cross-stack fixture.

## 10. Workstream F — cross-stack verification

This workstream is the safety net.  Each WU here closes a gap
between the Lean-proven property and the Solidity-deployed
behaviour.

### 10.1 WU F.1 — Lean ↔ Solidity behavioural-equivalence corpus

F.1 splits into seven sub-WUs (six per Audit-2, plus F.1.7
formalising the §20.3 immutability-amendment-deferred
`KnomosisMigration` attestation cross-stack obligation).  The
split is by fixture file: each fixture targets a specific
cross-stack invariant and can be developed and audited
independently.  All sub-WUs share the test-driver framework
(F.1.1) which lands first.

#### 10.1.1 WU F.1.1 — Cross-stack test-driver framework

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
none.

**Deliverable.**  The shared infrastructure that lets a Lean
test driver write a JSON fixture file and a `forge` test load
it.  Includes:

  * `Test/Bridge/CrossCheck/Framework.lean` — Lean side:
    deterministic JSON writer (using a small no-Std-deps
    JSON encoder), seeded property-based generator (reuses the
    Audit-3.9 `LegalKernel.Test.Property` infrastructure),
    fixture-file-path resolution.
  * `solidity/test/CrossCheck/Framework.t.sol` — Solidity
    side: `forge`-friendly JSON loader using `vm.readFile` and
    `vm.parseJson`, fixture-by-fixture iteration helpers.
  * Shared seed convention: `KNOMOSIS_PROPERTY_SEED` env var
    drives both Lean and Solidity, so re-runs are byte-stable.

**Acceptance criteria.**

  * Framework module loads + parses an empty fixture file
    without error.
  * Smoke-test fixture round-trips one fake input through the
    framework on both sides.
  * Reproducibility: same seed → same fixture content.

#### 10.1.2 WU F.1.2 — `ecdsa_verify.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, A.1.

**Deliverable.**  A 20-entry fixture of REAL precomputed
secp256k1 vectors for ECDSA verification (re-grounded from the
original 128 random-byte placeholders — see §21.1 / §22.3).  The
Solidity port uses `OpenZeppelin.ECDSA.tryRecover` against a
*registered address* (looked up in `KnomosisIdentityRegistry`),
not against a raw pubkey.  Each entry therefore has shape:

```jsonc
{
  "expectedSigner":   "0x...",       // 20-byte EVM address
  "uncompressedPubkey": "0x...",     // 64 bytes; keccak256(pubkey)[12:] == expectedSigner
  "digest":           "0x...",       // 32-byte EIP-712 digest the signer made
  "sig":              "0x...",       // 65-byte r ‖ s ‖ v signature
  "outcome":          "verifies" | "wrongSigner" | "highS" | "malformed"
}
```

Generation breakdown (matches the `KnomosisDisputeVerifier.checkSignatureInvalid`
control-flow branches at `solidity/src/contracts/KnomosisDisputeVerifier.sol`,
plus the supporting Lean adaptor in `LegalKernel/Bridge/VerifyAdaptor.lean`):

  * 8 valid low-s signatures (the canonical `privkey = 1..8`
    secp256k1 vectors; `expectedSigner` is the keccak-derived
    address of the signing key).  `outcome = "verifies"` ⇒
    `recovered == expectedSigner`.
  * 4 wrong-signer entries: a valid signature paired with a
    *different* key's address as `expectedSigner`.
    `outcome = "wrongSigner"` ⇒ `recovered != expectedSigner`.
  * 4 deliberately high-s signatures (the low-s mate
    `s' = secp256k1Order - s`, with `v` flipped).  `outcome =
    "highS"` ⇒ `OZ.ECDSA.tryRecover` returns
    `InvalidSignatureS`.  This pins the EIP-2 low-s
    canonicalisation property baked into A.1's
    `secp256k1HalfOrder` constant.
  * 4 malformed-length signatures (64 bytes, length ≠ 65).
    `outcome = "malformed"` ⇒ the `sig.length != 65`
    short-circuit fires first.

The vectors are REAL precomputed secp256k1 test data (generated
out-of-band with `cast wallet sign --no-hash`); the corpus is
fixed and hash-independent, so the fixture is byte-identical
across runs regardless of `KNOMOSIS_PROPERTY_SEED` or the hash
binding.  The Solidity side reads the JSON, calls
`digest.tryRecover(sig)`, and asserts the recovery outcome
matches the per-entry `outcome` marker — **unconditionally**, in
every build (it is no longer gated on `isKeccak256Linked`,
because real vectors recover correctly under the FNV fallback and
the production keccak256 binding alike).

**Critical correctness obligations.**

  * The corpus is a fixed set of REAL precomputed secp256k1
    vectors, so the fixture generator needs no secp256k1
    binding and the Solidity recovery cross-check runs in
    every build (FNV or keccak).  The vectors' `expectedSigner`
    addresses are independently checkable (each is the
    keccak-derived address of a known private key).
  * `expectedSigner` is supplied by the off-chain `signerHint`
    parameter to `checkSignatureInvalid` (audit-1: this used
    to be self-derived from `signer : uint64` via a stub —
    closed by the §9.2.2 docstring's API change).
  * The fixture's JSON encoding of `digest` matches the
    on-chain `KnomosisEip712.digest(domainSeparator,
    actionStructHash)` (the Solidity `verdictDigest` /
    `actionStructHash` helpers).

**Acceptance criteria.**

  * 20 / 20 per-entry outcome matches, run **unconditionally**
    (the real vectors are hash-independent).
  * Per-entry assertion that the Solidity-recovered address
    equals `expectedSigner` for `outcome = "verifies"` and
    differs from it for `outcome = "wrongSigner"`.
  * High-s entries: `OZ.ECDSA.tryRecover` returns
    `InvalidSignatureS` (recovered address `0`).
  * Header shape: `count = 20`, `countVerifies = 8`,
    `countWrongSigner = countHighS = countMalformed = 4`.

#### 10.1.3 WU F.1.3 — `keccak256.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, A.2.

**Deliverable.**  A 100-input fixture for keccak256.  Inputs of
varying lengths: 50 short (≤ 32 bytes), 30 medium (32–256
bytes), 20 long (256–2048 bytes).  Each entry is
`{ "input": "0x...", "expected": "0x..." }` where `expected`
is the 32-byte big-endian keccak256 of `input` as produced by
the production Ethereum hash function (validated against
`pycryptodome` / `geth` per A.2's KAT discipline).

**Hash-binding-conditional behaviour.**  Lean's
`Bridge.HashAdaptor.hashBytes` opaque resolves to a production
keccak256 binding only when the runtime adaptor links the
Rust `knomosis-hash-keccak256` crate; without that binding the
adaptor falls back to FNV-1a-64 (an 8-byte-output non-keccak
hash, padded to 32 bytes — see `LegalKernel/Runtime/Hash.lean`
and §15.13).  The fixture generator detects the linked binding
via `Bridge.HashAdaptor.isKeccak256Linked` and:

  * `isKeccak256Linked = true` → emits the fixture and asserts
    byte-exact cross-stack match.
  * `isKeccak256Linked = false` → emits the fixture but logs
    `SKIPPED: keccak256 fallback` and skips the byte-equality
    assertion.  CI requires the production binding to be
    linked before counting this fixture as "passing".

**Acceptance criteria.**

  * 100 / 100 byte-exact matches when the Lean keccak256
    binding is linked; SKIP otherwise (CI fails the
    `cross-stack-equivalence` job if the skip is taken).
  * Includes the F.2 mainnet-block-header golden subset
    (32 entries embedded by reference).
  * Includes the four reference KAT vectors from
    `LegalKernel/Bridge/HashAdaptor.lean` (`kat_empty`,
    `kat_abc`, `kat_helloWorld`, `kat_singleZero`) so a future
    KAT-vector regression in the Rust crate is caught here as
    well.

#### 10.1.4 WU F.1.4 — `deposit_receipt_hash.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, B.2, E.1.1.

**Deliverable.**  A 128-input fixture verifying byte-equivalence
of the L1-side `receiptHash` and the L2-side adaptor-projected
`DepositId`.  This is the most load-bearing cross-stack
fixture: a mismatch here means deposits cannot be matched to
their L2 credit.

**Receipt-hash recipe (mirrors `KnomosisBridge._registerDeposit`
at `solidity/src/contracts/KnomosisBridge.sol`).**  The on-chain
`receiptHash` is

```solidity
receiptHash = keccak256(abi.encode(
    deploymentId,    // bytes32 immutable, set in ctor
    msg.sender,      // address
    resourceId,      // uint64; 0 = native ETH
    token,           // address; address(0) for ETH
    amount,          // uint256
    depositorNonce   // uint64; per-depositor counter
));
```

with `deploymentId = keccak256(abi.encode(block.chainid,
address(this), knomosisVersionTag))`.  Note that the receipt
binds **six** fields, not the five of the pre-audit sketch —
`resourceId` is the audit-additive field that distinguishes
distinct ERC-20 ledgers under the same `(depositor, token,
amount, nonce)` parameters.  Critically, both `resourceId` and
`token` are bound (the bridge's resource-id ↔ token map is
already a bijection via the constructor's
`DuplicateResourceToken` check, but binding both rules out an
adaptor desync at the digest level).

Each fixture entry has shape:

```jsonc
{
  "deploymentId":    "0x...",      // bytes32 (preimage for cross-check
                                    //          decomposed below)
  "deploymentPreimage": {
    "chainid":        12345,
    "contractAddr":   "0x...",     // bridge address
    "knomosisVersionTag": "0x..."      // bytes32
  },
  "depositor":       "0x...",       // 20-byte EVM address
  "resourceId":      42,            // uint64
  "token":           "0x...",       // address; 0x000…0 for ETH
  "amount":          "0x...",       // uint256 (stringified hex)
  "depositorNonce":  7,             // uint64
  "expectedHash":    "0x..."        // 32-byte receipt hash
}
```

**L2-side projection (`Bridge.DepositId : Nat`).**  Lean's
`DepositId` is `Nat` with a 64-bit canonical-encoding bound
(per `LegalKernel/Bridge/State.lean`).  Real L1 hashes are
256 bits and don't fit losslessly.  The runtime adaptor
projects the L1 hash into a 64-bit deployment-canonical form;
the integration plan's reference projection is

```text
DepositId(receiptHash) :=
    natFromBytesBE (receiptHash[0..8])   -- top 8 BE bytes
                                          --  decoded as Nat
```

The fixture records both `expectedHash` (full 32-byte L1 form)
and the projected `expectedDepositId` (Nat).  A deployment
that selects a different projection (sequential `uint64`
numbering, hash[24..32], etc.) substitutes its own projection
in the fixture generator and asserts the deployment-side and
fixture-side agree.

**Generation cases.**  64 randomised entries + 64 corner
cases (precise breakdown below):

  * **16 Native ETH path** entries: `resourceId = 0`,
    `token = address(0)`, `amount` ranging 1 wei to
    2^192 wei.
  * **16 ERC-20 path** entries: `resourceId ∈ [1, 64]`,
    `token` distinct from `address(0)`, `amount` covering
    small / mid / max-uint256.
  * **8 Replay-resistance corners**: identical
    `(depositor, token, amount, nonce)` with distinct
    `chainid` produces distinct hashes.
  * **16 Deployment-replay corners**: identical
    `(depositor, resourceId, token, amount, nonce)` with
    distinct `(chainid, contractAddr, knomosisVersionTag)`
    produces distinct `deploymentId`s, hence distinct
    hashes.
  * **8 Boundary corners**: `amount = 0` (the bridge
    accepts but accounting is a no-op — verified at the
    receipt level only), `nonce = 0`, `nonce = 2^64 − 1`,
    `amount = 2^256 − 1`, and compositions thereof.

Total corner cases: 16 + 16 + 8 + 16 + 8 = **64**.

**Critical correctness obligations.**

  * The fixture generator MUST run against the production
    keccak256 binding; otherwise the cross-check is skipped
    per F.1.3's hash-binding discipline.
  * `expectedDepositId` MUST be computed by the same
    projection function the runtime adaptor uses;
    deployments using a non-default projection record their
    projection's identifier in the fixture header so an
    auditor can reproduce.
  * The Solidity side computes `receiptHash` via the same
    `_registerDeposit` recipe and asserts byte equality to
    `expectedHash`.
  * Including `resourceId` in the digest is non-negotiable
    (closes a class of cross-ledger desync attacks where two
    resourceIds map to the same L1 token via constructor
    misconfiguration; the post-audit-2 constructor's
    `DuplicateResourceToken` check makes such configurations
    unreachable, and binding `resourceId` in the digest gives
    defence-in-depth).

**Acceptance criteria.**

  * 128 / 128 byte-exact matches between L1-computed
    `receiptHash` and the fixture's `expectedHash`.
  * 128 / 128 byte-exact matches between the Lean-computed
    projected `DepositId` and the fixture's
    `expectedDepositId`.
  * Replay-distinguishability sub-suite: the 16
    deployment-replay corners produce 16 *distinct* hashes
    (sanity check of the deploymentId binding).

#### 10.1.5 WU F.1.5 — `withdrawal_proof.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, D.1.5, E.1.3.

**Deliverable.**  A 96-input fixture (64 valid + 32 tampered):
for each valid entry, a `(BridgeState, withdrawalId)` pair plus
the Lean-extracted `WithdrawalProof` and the expected
verifier outcome on the Solidity side.  64 valid entries
because each exercises a 64-level SMT proof and is heavier
than the other fixtures.

**Variable-size leaf and siblings (audit-2 cross-stack format).**
Lean's `WithdrawalProof.leaf : ByteArray` is variable-size
(≈ 56 bytes for a populated cell encoded as
`leafBytes wd = encode (resourceId, recipientL1, amount,
l2LogIndex)`; 32 bytes for the empty-cell sentinel
`emptyLeafHash = bytes32(0)`).  Lean's
`WithdrawalProof.siblings : Vector ByteArray smtHeight`
allows each sibling to be variable-size — in the **dense-pair**
case (sequentially-assigned WithdrawalIds 0 and 1 share a
deepest pair), the leaf-adjacent sibling for id 0 is
`leafBytes wd_1` ≈ 56 bytes, NOT the typical 32-byte
default-hash value.  The pre-audit-2 fixture format treated
leaf and siblings as fixed `bytes32`, which would have
silently broken cross-stack equivalence on every dense-pair
proof.  See `solidity/src/lib/SmtVerifier.sol` (the audit-2
variable-size port) for the on-chain interface this fixture
exercises.

Each entry has shape:

```jsonc
{
  "stateRootHex":    "0x...",       // bytes32 the bridge accepts
  "withdrawalId":    7,
  "leafBlobHex":     "0x...",       // CBE-encoded PendingWithdrawal
                                     //   (resourceId, recipientL1, amount,
                                     //    l2LogIndex); ≈ 56 bytes
  "proof": {
    "leafHex":       "0x...",       // bytes; equals leafBlobHex (the
                                     //   bridge's keccak256 cross-check
                                     //   asserts equality)
    "index":         7,
    "siblingsHex":   ["0x...", ...]  // 64 entries, each variable-size
                                     //   (most are 32-byte default-hash
                                     //   values; dense-pair cases include
                                     //   ≈ 56-byte raw-leaf siblings)
  },
  "tamper":          null            // OR a tamper descriptor for the
                                     //   tampered subset (see below)
}
```

**Tampering subset (32 entries).**  Each tampered entry is
generated by mutating a valid entry per a single
deterministic mutator:

  1. Flip a random bit in `leafHex`.
  2. Flip a random bit in `siblingsHex[k]` for a random `k`.
  3. Swap two distinct sibling positions.
  4. Use the wrong `index` (one that doesn't match
     `withdrawalId`).
  5. Use a different `stateRootHex` (cross-root substitution).

The Solidity side asserts `verifyProof` returns `false` on
each.  `tamper` records which mutator was applied for
debugging.

**Coverage cases.**  The 64 valid entries include:

  * 16 sparse trees (1–4 populated cells, scattered indices).
  * 16 dense-pair cases (sequentially assigned ids 0 and 1
    or 100 and 101 mapping to the same deepest pair) — the
    audit-2 regression class.  At least one entry must
    place a populated leaf adjacent to another populated
    leaf at the deepest level so the leaf-adjacent sibling
    is ≈ 56 bytes, not 32.
  * 16 unmapped-id cases (canonical non-membership proofs:
    `leaf = emptyLeafHash sentinel`; siblings are the
    canonical `defaultHash` path).
  * 16 boundary cases (id = 0, id = 2^64 − 1, id =
    `nextWdId − 1` of a non-empty bridge state).

**Critical correctness obligations.**

  * The Solidity decoder (`KnomosisBridge._decodeWithdrawalProof`)
    reads `leaf` as `bytes` (variable-size) and asserts
    `count == SMT_HEIGHT = 64`.  The fixture's `siblingsHex`
    array MUST have exactly 64 entries; the Lean fixture
    generator enforces this via the `Vector ByteArray
    smtHeight` discipline.
  * `keccak256(leafHex) == keccak256(leafBlobHex)` is
    asserted by the bridge's withdrawal entry point;
    `leafHex` and `leafBlobHex` MUST coincide byte-for-byte.
  * Path-bit indexing: `bit_k = (idx >> k) & 1` with
    `bit_0` selecting at the leaf level (matching Lean's
    `pathBitAtLevel`).  A fixture with a mismatched bit
    convention would falsely fail.
  * Hash binding: the verifier uses the production
    `keccak256` opcode; the Lean fixture generator MUST run
    against the production `Bridge.HashAdaptor.hashBytes`
    binding (otherwise the SMT root computed from
    FNV-1a-64 cannot agree with the on-chain keccak256
    root — the cross-check is skipped per F.1.3
    discipline).

**Acceptance criteria.**

  * 64 / 64 verify-true on Solidity side for valid proofs
    (when the production keccak256 binding is linked).
  * 32 / 32 verify-false on Solidity side for tampered
    proofs (each mutator class represented).
  * Per-entry sanity: `siblings.length == 64`,
    `keccak256(leafHex) == keccak256(leafBlobHex)`,
    `proof.index == withdrawalId mod 2^smtHeight`.
  * At least one dense-pair entry exercises the
    variable-size leaf-adjacent-sibling code path
    (≈ 56-byte sibling).

#### 10.1.6 WU F.1.6 — `dispute_evidence.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, E.2.2, E.2.3, E.2.4, E.2.5.

**Deliverable.**  A 144-input fixture (48 per claim variant ×
3 variants) covering the three MVP dispute-claim Solidity
ports.  Each entry provides the on-chain inputs and the
expected verdict; the fixture also covers the audit-1 +
audit-3 cross-stack invariants for verdict signing and
finalisation control flow.

**Per-variant entry shapes** (mirror the post-audit-3
interfaces in `solidity/src/contracts/KnomosisDisputeVerifier.sol`).

`signatureInvalid` (E.2.2):

```jsonc
{
  "kind":          "signatureInvalid",
  "logEntryHex":   "0x...",       // CBE LogEntry (prevHash, actionHash,
                                   //   signer, nonce, sig)
  "signerHint":    "0x...",       // 20-byte L1 address; audit-1 fix —
                                   //   was previously self-derived from
                                   //   the uint64 signer (a stub)
  "expectedVerdict": "upheld" | "rejected" | "inconclusive"
}
```

`nonceMismatch` (E.2.3):

```jsonc
{
  "kind":               "nonceMismatch",
  "impugnedLogIndex":   12,
  "prefixBlobHex":      "0x...",  // CBE array<LogEntry>(N) with N ≤
                                   //   MAX_PREFIX_LEN = 256
  "expectedVerdict":    "upheld" | "rejected" | "inconclusive"
                                   //  (or "revertMaxPrefixLenExceeded"
                                   //   for the boundary fixtures)
}
```

`doubleApply` (E.2.4 — finalisation path):

```jsonc
{
  "kind":               "doubleApply",
  "impugnedLogIndex":   5,
  "secondaryLogIndex":  8,
  "concatBlobHex":      "0x...",  // The audit-3 finalisation shape:
                                   //   (CBE uint secondaryLogIndex)
                                   //   ‖ (CBE array<bytes>(2) of
                                   //         impugnedBlob,
                                   //         secondaryBlob)
                                   //   with assertFullyConsumed at the
                                   //   end (no trailing garbage)
  "expectedVerdict":    "upheld" | "rejected"
                                   //  (or "revertSelfClaimInvalid",
                                   //   "revertDoubleApplyConcatBadCount",
                                   //   "revertCBEInvalidLength")
}
```

**Verdict-finalisation shape** (audit-1 / E.2.5).
Adjudicators sign the contract-derived
`verdictDigest(disputeId, outcome)`, NOT a free
`verdictHash` parameter (audit-1 closed the per-disputeId
replay vector).  The fixture entries that drive the
end-to-end `finalizeUpheld` / `finalizeRejected` path
include a `verdict` sub-object:

```jsonc
{
  "kind":                "finalizeUpheld" | "finalizeRejected",
  "claimVariant":        "signatureInvalid" | "nonceMismatch" | "doubleApply",
  "disputeId":           42,
  "reEvidenceBlobHex":   "0x...",          // re-evaluated at
                                           //   finalisation time; the
                                           //   file-time evidenceBlob is
                                           //   only emitted in the event
  "signerHint":          "0x..." | null,   // required for signatureInvalid;
                                           //   ignored otherwise
  "signers":             ["0x...", ...],   // ≤ MAX_VERDICT_SIGNERS = 64
  "sigs":                ["0x...", ...],   // 65-byte ECDSA each
  "expectedOutcome":     "uphold" | "reject" | "revertQuorumNotMet"
                                           //  | "revertEvidenceNotUpheld"
                                           //  | "revertTooManySigners"
                                           //  | "revertEvidenceBlobTooLarge"
}
```

**Coverage breakdown** (48 entries per claim × 3 = 144 +
24 verdict-finalisation entries = **168 total**):

  * 16 happy-path UPHELD per claim (Lean evidence verifier
    returns `.upheld`; Solidity side returns 0).
  * 16 happy-path REJECTED per claim (verifier returns
    `.rejected`; Solidity side returns 1).
  * 8 INCONCLUSIVE per claim (e.g. `signatureInvalid` with
    unregistered `signerHint`; `nonceMismatch` with
    impugned index never reached during prefix walk).
  * 8 adversarial per claim (per-variant table below).

**Adversarial sub-cases.**

  * `signatureInvalid`:
    * High-s sig in `logEntryHex` ⇒ `OZ.ECDSA.recover`
      reverts ⇒ `try/catch` ⇒ `VERDICT_UPHELD`.
    * `signerHint = address(0)` ⇒ `VERDICT_INCONCLUSIVE`.
    * `signerHint` registered but with the wrong pubkey
      (defence-in-depth check) ⇒ `VERDICT_INCONCLUSIVE`.
    * Malformed `logEntryHex` (truncated CBE) ⇒
      `revertCBEInvalidLength`.

  * `nonceMismatch`:
    * Prefix length = `MAX_PREFIX_LEN = 256` (boundary
      accepted).
    * Prefix length = `MAX_PREFIX_LEN + 1 = 257` ⇒
      `revertMaxPrefixLenExceeded`.
    * Impugned index out-of-range (no entry at that index
      in the prefix) ⇒ `VERDICT_INCONCLUSIVE`.
    * First action by a never-seen signer (expected nonce
      defaults to 0) ⇒ test both nonce 0 (REJECTED) and
      nonce 1 (UPHELD).

  * `doubleApply`:
    * `impugnedLogIndex == secondaryLogIndex` ⇒
      `revertSelfClaimInvalid` (matches Lean's
      `checkDoubleApply_rejects_self`).
    * `concatBlobHex` array count ≠ 2 ⇒
      `revertDoubleApplyConcatBadCount` (audit-3 fix).
    * `concatBlobHex` with trailing garbage after the
      array ⇒ `revertCBEInvalidLength` from
      `assertFullyConsumed` (audit-3 fix).
    * Distinct signer + same nonce ⇒ REJECTED.
    * Same signer + distinct nonces ⇒ REJECTED.
    * Same signer + same nonce + distinct indices ⇒
      UPHELD.

**Verdict-quorum sub-suite** (audit-1 dedup + audit-1
`MAX_VERDICT_SIGNERS = 64` cap + audit-1 `MAX_EVIDENCE_BLOB_BYTES
= 100_000` cap).  At least 24 entries cover:

  * Quorum just-met: `verified == quorumThreshold` ⇒
    finalisation succeeds.
  * Quorum just-short: `verified == quorumThreshold - 1`
    ⇒ `revertQuorumNotMet`.
  * Same approved signer repeated N times in `signers` ⇒
    `_countVerifiedSignatures` returns 1 (not N) ⇒ quorum
    measured against distinct count.  This is the audit-1
    forgery-resistance regression.
  * `signers.length = MAX_VERDICT_SIGNERS = 64` (boundary
    accepted).
  * `signers.length = MAX_VERDICT_SIGNERS + 1 = 65` ⇒
    `revertTooManySigners`.
  * `evidenceBlob.length = MAX_EVIDENCE_BLOB_BYTES =
    100_000` at file time (boundary accepted).
  * `evidenceBlob.length = MAX_EVIDENCE_BLOB_BYTES + 1` at
    file time ⇒ `revertEvidenceBlobTooLarge`.
  * Cross-disputeId signature replay attempt: a signature
    valid for `verdictDigest(disputeId = 1, .upheld)`
    cannot be replayed for `verdictDigest(disputeId = 2,
    .upheld)` — the recovered address won't match.
  * Cross-outcome signature replay attempt: a signature
    for `(disputeId = 1, .upheld)` cannot be replayed for
    `(disputeId = 1, .rejected)`.

**EIP-712 domain pinning** (audit-1).  The fixture
generator records:

  * `actionDomainName = "KnomosisAction"` (the per-action
    signing domain mirrored at the dispute verifier so it
    can reproduce the digest the user signed).
  * `verdictDomainName = "KnomosisDisputeVerifier"` (the
    adjudicator-signing domain; distinct so a per-action
    signature cannot be re-interpreted as a verdict
    signature).

These names are read by the dispute verifier's
`ACTION_DOMAIN_NAME` / `VERDICT_DOMAIN_NAME` constants
(`solidity/src/contracts/KnomosisDisputeVerifier.sol`); the
fixture also includes a sanity case that verifies the
domains are byte-distinct.

**Critical correctness obligations.**

  * The fixture generator runs against the production
    secp256k1 + keccak256 bindings.  Without them the
    cross-check is skipped per F.1.3 discipline; CI gates
    on production bindings.
  * Solidity side calls the per-claim verifier through
    `_runClaimVerifier` (not directly), so `signerHint` is
    threaded through `finalizeUpheld` / `finalizeRejected`
    correctly.
  * `verdictDigest` is derived on-chain via the
    `verdictDigest(disputeId, outcome)` external view; the
    fixture verifies that its precomputed `verdictDigest`
    equals the on-chain derivation byte-for-byte before
    asserting on signature verification (catches a class
    of cross-stack drift bugs early).
  * Replay-resistance corners (cross-disputeId, cross-
    outcome) MUST be present; their absence in the
    pre-audit fixture spec contributed to the original
    `verdictHash`-as-free-parameter vulnerability.

**Acceptance criteria.**

  * 168 / 168 expected outcomes match (verdict byte or
    revert selector) on the Solidity side.
  * Per-claim quorum-padding attack rejected (count ≤
    distinct-approved-signers regardless of array padding).
  * Cross-disputeId / cross-outcome replay rejected.
  * Audit-3 doubleApply concat shape: `count != 2` and
    trailing-garbage cases revert with the precise
    custom errors.

#### 10.1.7 WU F.1.7 — `migration_attestation.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, A.3, E.5, Audit-3.2 `AttestedSnapshot`.

**Deliverable.**  A 32-input fixture verifying byte-equivalence
between Lean's `AttestedSnapshot` digest (Audit-3.2 in
`LegalKernel/Runtime/AttestedSnapshot.lean`) and
`KnomosisMigration`'s constructor-time EIP-712 wrap digest
(`solidity/src/contracts/KnomosisMigration.sol`'s `_wrapDigest`,
which combines `KnomosisEip712.domainSeparator` and
`KnomosisEip712.migrationStructHash`).  This fixture is the
explicit cross-stack obligation introduced by §20.3
(immutability amendment), where it was scoped as
"deferred to F.1.7 as an MVP-blocker for E.5 only".

Each entry has shape:

```jsonc
{
  "predecessor":              "0x...",       // 20-byte address
  "successor":                "0x...",       // 20-byte address
  "predecessorDeploymentId":  "0x...",       // bytes32
  "successorDeploymentId":    "0x...",       // bytes32
  "migrationStateRoot":       "0x...",       // bytes32
  "migrationStateRootLogIdx": 12345,         // uint64
  "graceWindowBlocks":        216000,        // ≥ MIN_GRACE_WINDOW_BLOCKS
  "chainId":                  1,
  "verifyingContract":        "0x...",       // KnomosisMigration's predicted
                                              //   CREATE3 address
  "expectedDigest":           "0x...",       // 32-byte EIP-712 digest the
                                              //   attestor signs
  "expectedSig":              "0x...",       // 65-byte ECDSA signature
                                              //   over expectedDigest, by a
                                              //   known test attestor
  "expectedRecovered":        "0x..."        // expected recovered signer
                                              //   address (matches the
                                              //   attestor)
}
```

**Generation cases (32 entries).**

  * 16 happy-path entries: distinct `(predecessor,
    successor)` pairs with valid attestor signatures.
    Cross-check that the on-chain `KnomosisMigration`
    constructor accepts each (via a forge fixture that
    deploys a predecessor + successor + migration in
    sequence and asserts no revert).
  * 8 boundary entries: `graceWindowBlocks ==
    MIN_GRACE_WINDOW_BLOCKS = 216_000` (accepted),
    `graceWindowBlocks == 215_999` (rejected with
    `GraceTooShort`).
  * 4 cross-deployment-replay entries: identical
    `(migrationStateRoot, ...)` with distinct
    `(predecessorDeploymentId,
    successorDeploymentId)` pairs ⇒ distinct digests
    ⇒ a signature for one cannot be replayed against
    another.
  * 4 audit-3-direction entries: confirm the
    constructor's `predecessor.migration() ==
    address(this)` check (audit-3 fix).  Two with
    `predecessor.migration() == predicted_addr`
    (accepted); two with `predecessor.migration() ==
    address(0)` (rejected with
    `PredecessorDoesNotReferenceThisMigration`).

**Critical correctness obligations.**

  * The Lean side computes the digest via the
    `LegalKernel.Bridge.Eip712.eip712Wrap` function,
    using the `migration` struct hash form.  Solidity
    side computes via `KnomosisEip712.migrationStructHash`
    and `KnomosisEip712.digest`; the two MUST agree
    byte-for-byte.
  * The audit-3 direction (predecessor pre-committed)
    is the only valid wiring; pre-audit-3 (successor
    pre-committed) MUST be rejected with the
    `PredecessorDoesNotReferenceThisMigration` custom
    error.
  * Cross-deployment-replay: the Lean
    `eip712DomainSeparator_distinguishes` theorem
    proves the abstract property; this fixture pins
    the byte-level distinguishability across the two
    stacks.
  * Production keccak256 binding required (per F.1.3
    discipline) — without it the digest cross-check
    is skipped.

**Acceptance criteria.**

  * 32 / 32 byte-exact digest matches between Lean's
    `eip712Wrap` and Solidity's `_wrapDigest`.
  * `expectedSig` recovers to `expectedRecovered` on
    both stacks (Lean adaptor's `Verify` + Solidity's
    `ECDSA.recover`).
  * Boundary fixtures revert with the documented
    custom errors on the Solidity side.
  * Audit-3 direction asserted: a `KnomosisMigration`
    deployment whose `predecessor.migration() !=
    address(this)` reverts at construction.

### 10.2 WU F.2 — Goldens for keccak256 / ECDSA / RLP

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** A.1, A.2.

**Deliverable.**  Three golden files lifted from real Ethereum
mainnet data:

  * `goldens/block_header_hashes.txt` — keccak256 of 32 real
    block headers.
  * `goldens/transaction_signatures.txt` — 32 real
    `(pk, msg, sig)` triples.
  * `goldens/rlp_encodings.txt` — 32 real RLP-encoded
    transactions, alongside their keccak256 hashes.

Stored in the repository under `solidity/test/goldens/` and
exercised by both Lean tests (`Test/Bridge/Goldens.lean`) and
forge tests (`solidity/test/Goldens.t.sol`).

**Hash-binding-conditional behaviour.**  Lean's `hashBytes`
opaque resolves to production keccak256 only when the
`knomosis-hash-keccak256` Rust adaptor is linked (per A.2 / §15.13).
Without that binding the Lean fallback is FNV-1a-64.  The
Lean test driver branches on
`Bridge.HashAdaptor.isKeccak256Linked`:

  * `true` → asserts byte-exact match against the
    mainnet-derived golden values (matching the existing
    Lean-side `kat_*` discipline in
    `LegalKernel/Bridge/HashAdaptor.lean`).
  * `false` → emits `SKIPPED: keccak256 fallback` for the
    keccak / RLP-then-keccak rows; the ECDSA-verify rows
    are also skipped because the hash binding is upstream
    of EIP-712 digest computation.  CI's
    `cross-stack-equivalence` job fails when the skip is
    taken in a deployment context.

The Solidity side runs unconditionally (the EVM keccak256
opcode is always available); it asserts that its own
computation matches the goldens.

**Acceptance criteria.**

  * 32 / 32 keccak256 matches when the Lean keccak256
    binding is linked; SKIP otherwise.
  * 32 / 32 ECDSA verify accepts when the Lean secp256k1
    binding is linked; SKIP otherwise.
  * 32 / 32 RLP-then-keccak matches when both Lean
    bindings are linked; SKIP otherwise.
  * Solidity-side assertions pass unconditionally on
    every check (independent verification path).
  * CI's `cross-stack-equivalence` job is gated on the
    production bindings being linked; a skip in CI
    fails the job (the bindings are required at the
    deployment-readiness gate).

### 10.3 WU F.3 — End-to-end testnet deployment

**Owner:** ops + Lean + Solidity; **Reviewer count:** 1;
**Depends on:** all preceding WUs.

**Deliverable.**  A scripted deployment to Sepolia (or Holesky)
that runs the §2.3 acceptance script unattended.  The script:

  1. Deploys all four runtime Solidity contracts (`KnomosisBridge`,
     `KnomosisDisputeVerifier`, `KnomosisIdentityRegistry`,
     `KnomosisSequencerStake`) immutably via **`CREATE3`** with
     deterministic salts.  No proxies are involved.

     The choice of `CREATE3` (over the original `CREATE2`
     sketch) is load-bearing.  `CREATE2` derives a contract
     address from `keccak256(0xff ‖ deployer ‖ salt ‖
     keccak256(initCode))` — the init-code hash is part of
     the input, and the init-code includes the constructor
     arguments.  But the four contracts mutually reference
     each other:

       * `KnomosisBridge.disputeVerifier` immutable → predicted
         `KnomosisDisputeVerifier` address.
       * `KnomosisBridge.sequencerStake` immutable → predicted
         `KnomosisSequencerStake` address.
       * `KnomosisDisputeVerifier.bridge` immutable → predicted
         `KnomosisBridge` address.
       * `KnomosisDisputeVerifier.sequencerStake` immutable →
         predicted `KnomosisSequencerStake` address.
       * `KnomosisDisputeVerifier.identityRegistry` immutable →
         predicted `KnomosisIdentityRegistry` address.
       * `KnomosisSequencerStake.disputeVerifier` immutable →
         predicted `KnomosisDisputeVerifier` address.
       * `KnomosisSequencerStake.bridge` immutable → predicted
         `KnomosisBridge` address.

     With `CREATE2` this graph is unsolvable: every contract's
     address depends on its constructor args, which depend on
     the other contracts' addresses, which depend on theirs,
     forming a cycle in `keccak256(initCode)`.
     `CREATE3` (`solidity/src/lib/CREATE3.sol`) resolves the
     cycle by deploying a tiny constant-bytecode "proxy
     factory" via `CREATE2` (whose init-code hash is fixed at
     `0x21c35d…7c1f`) that then deploys the actual contract
     via `CREATE` at the proxy's nonce-1 address.  The
     deployed address depends only on `(deployer, salt)`
     — not on the init-code — so `CREATE3.addressOf(deployer,
     salt)` is the cycle-breaking primitive.

  2. Computes the four contract addresses up-front via
     `CREATE3.addressOf(deployer, salt_i)` for `i ∈
     {bridge, verifier, registry, stake}`, bakes them into
     each contract's constructor args, then deploys via
     `CREATE3.deploy(salt_i, initCode_i)` in any order
     (CREATE3 deployment order is independent of constructor-
     reference direction).

  3. Sets each `KnomosisBridge`-side `migration` immutable to
     `address(0)` for the initial deployment (no successor
     yet exists).  This deliberately rules out using the
     `KnomosisMigration` mechanism to migrate AWAY from this
     deployment — per the audit-3
     `predecessor.migration() == address(this)` constructor
     check (`solidity/src/contracts/KnomosisMigration.sol`),
     a predecessor with `migration = address(0)` cannot be
     pre-committed to ANY future `KnomosisMigration` address.
     This is a deliberate "no migration mechanism for v1"
     design choice; deployments that want a future migration
     route deploy a fresh bridge with `migration` set to a
     `CREATE3`-predicted `KnomosisMigration` address from day
     one (the predicted address need not have code yet — the
     bridge's `circuitOpen` modifier short-circuits when
     `migration == address(0)`, but reverts on
     `migration != address(0) && code.length > 0` calls; if
     the migration contract is never deployed, the bridge
     deposits / state-roots remain DOS-blocked, so the
     migration contract MUST be deployed within the
     same multi-tx deployment for migration-enabled
     bridges).

     **Audit-3 direction (clarification).**  In the future
     migration scenario (when v1 is replaced by v2 via
     `KnomosisMigration`), it is the **predecessor** (the
     v1 bridge being frozen) whose `migration` immutable
     points at the `KnomosisMigration` address, NOT the
     successor (the v2 bridge).  The pre-audit-3 design
     had the successor pre-committed, which silently
     froze the successor on activation — the OPPOSITE of
     the user-exit guarantee.  The audit-3 fix is encoded
     in the constructor's
     `PredecessorDoesNotReferenceThisMigration` check; an
     end-to-end deployment script that wants to enable
     future migrations must:

       * Predict the next `KnomosisMigration` address via
         `CREATE3.addressOf(deployer, migrationSalt)`.
       * Bake that address into the predecessor bridge's
         `migration` constructor arg at v_n deployment.
       * Successor bridge's `migration` is independent
         (typically `address(0)` for the last-migration-
         enabled bridge in a chain, or another
         `CREATE3`-predicted address if the successor
         itself plans to be migrated later).

  4. Post-deploy, calls `disputeVerifier.assertConsistent()`
     and `sequencerStake.assertConsistent()` to verify the
     bidirectional reference invariant:

       * `disputeVerifier.bridge() == bridge` AND
         `bridge.disputeVerifier() == disputeVerifier`
       * `sequencerStake.disputeVerifier() == disputeVerifier`
         AND `disputeVerifier.sequencerStake() ==
         sequencerStake`

     These checks live as post-deploy `assertConsistent()`
     views (rather than constructor-time cross-checks) by
     design: the `CREATE3` mechanism allows contracts to
     deploy in any order without the address-prediction
     cycle, but the *constructor* of each contract cannot
     verify the peer's back-reference because the peer
     might not be deployed yet at the time the constructor
     runs.  The `assertConsistent()` views close the
     invariant after all four contracts are live.

  5. Starts the Knomosis sequencer with the deployment-id derived
     from `keccak256(abi.encode(chainId, bridge address,
     knomosisVersionTag))` (matches the on-chain `deploymentId`
     derivation byte-for-byte; see
     `KnomosisBridge.constructor` and
     `LegalKernel/Encoding/SignInput.lean`).

  6. Performs the seven-step acceptance sequence with a single
     scripted EOA + a scripted MetaMask-equivalent signer (e.g.
     ethers.js).

  7. Asserts each step's success conditions on-chain (event
     emissions, balance changes).  Notable post-audit event
     names:

       * `DepositInitiated` (E.1.1): includes the indexed
         `resourceId` (audit-additive field).
       * `StateRootRangeReverted` (E.1.5, audit-2): emitted
         on `revertToPriorRoot` instead of the pre-audit-2
         `StateRootReverted`; carries the `(floor, ceiling)`
         pair of the reverted range.
       * `WithdrawalRedeemed` (E.1.3): includes the
         `resourceId`.
       * `Slashed` (E.4): includes `paidToChallenger` and
         `burned`.

  8. Verifies that the deployed contracts have **no admin
     surface**: sanity-check calls to `bridge.pause()`,
     `bridge.owner()`, `bridge.proposeUpgrade(...)`,
     `bridge.grantRole(...)` revert with "function not found"
     at the ABI level (the functions do not exist).

**Acceptance criteria.**

  * Single-command `make testnet-acceptance` executes the script
    end-to-end and exits 0.
  * The script logs each step's L1 transaction hash for audit.
  * Pre-deploy assertion: `CREATE3.addressOf` predictions
    match the actual deployed addresses byte-for-byte (sanity-
    checks the cycle-breaking discipline).
  * Post-deploy assertion: `assertConsistent()` returns
    `true` on both `KnomosisDisputeVerifier` and
    `KnomosisSequencerStake`.
  * Negative assertion: no upgrader-key-shaped function
    exists on any of the four deployed contracts (negative
    selector lookup against `pause`, `unpause`,
    `proposeUpgrade`, `executeUpgrade`, `grantRole`,
    `revokeRole`, `transferOwnership`,
    `renounceOwnership`).
  * `KnomosisBridge.migration() == address(0)` at the v1
    deployment (matches the documented "no migration
    mechanism for v1" design).

### 10.4 WU F.4 — Property-based test extension

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** Audit-3.9
property harness.

**Deliverable.**  Three new properties in
`Test/Properties/Bridge.lean`:

  * `prop_deposit_then_withdraw_roundtrip` — for any
    `(amount, recipient)`, depositing then immediately
    withdrawing the same amount returns the bridge state to its
    pre-deposit form (modulo `nextWdId` + `consumed` records).
  * `prop_bridge_account_invariant_holds` — for any reachable
    state under the `bridgeLawSet : MonotonicLawSet` of §12.13
    (`{transfer, deposit, registerIdentity, replaceKey,
    freezeResource}`), the §C.6 `bridge_supply_account`
    equation `totalSupply r es.base + totalWithdrawn es r =
    totalSupply r es₀.base + totalDeposited es r` holds.

    **Why `withdraw` is excluded.**  `Laws.withdraw` is
    *not* `IsMonotonic` — `withdraw_not_monotonic`
    (`LegalKernel/Laws/Withdraw.lean`) explicitly rules out
    an `IsMonotonic` instance, and `MonotonicLawSet`'s
    structure invariant requires every law in the set to
    surrender one.  Constructing a `MonotonicLawSet
    {transfer, deposit, withdraw}` is therefore
    type-impossible.  This property pins the *non-decreasing*
    half of bridge accounting; the strict-equation form
    (which includes withdrawal credits) is exercised by the
    `prop_deposit_then_withdraw_roundtrip` and
    `prop_withdrawal_proof_verifies` properties below, plus
    the §7.6.4 / §7.6.5 chain-level theorems over the
    custom `BridgeReachable` predicate (deferred follow-up;
    see CLAUDE.md "Workstream-C deviations").
  * `prop_withdrawal_proof_verifies` — for any `BridgeState`
    constructed by an arbitrary deposit / transfer / withdraw
    sequence, every pending withdrawal's extracted proof
    verifies against the published root.

Each property runs against `KNOMOSIS_PROPERTY_ITERATIONS=100` by
default; failing seeds are logged via `KNOMOSIS_PROPERTY_SEED`.

**Critical correctness obligations.**

  * All three properties are **purely Lean-side** value-
    level checks (no Solidity cross-stack comparison),
    so they run unconditionally under any `hashBytes`
    binding (production keccak256 or FNV-1a-64 fallback).
    Specifically, `prop_withdrawal_proof_verifies` is
    discharged at the value level by `verifyProof_complete`
    — an *unconditional* theorem in `H : ByteArray →
    ByteArray` (see `LegalKernel/Bridge/WithdrawalRoot.lean`).
    Cross-stack equivalence with Solidity's keccak256 is
    not within F.4's scope; that obligation lives in
    F.1.5 (which does require the production binding).
  * `prop_bridge_account_invariant_holds` quantifies over
    `bridgeLawSet : MonotonicLawSet` — typeclass-driven, so
    the random generator never produces an action outside
    the law set.  The fold-based generator emits actions
    by tag uniformly from the in-set constructors only.

**Acceptance criteria.**

  * 100 / 100 passes per property at the default seed
    (independent of which `hashBytes` binding is linked).
  * Reproducible: a recorded failing seed reproduces the
    failure.
  * Type-level invariant: the law-set generator's
    `MonotonicLawSet` witness elaborates without `withdraw`
    in the law list; attempting to add `withdraw` produces
    a `failed to synthesize IsMonotonic` error at
    elaboration time (forward-protection against future
    additions to the set).

## 11. Workstream G — documentation and amendment

This workstream lands the documentation deliverables.  Each WU is
small but high-leverage; they are listed here as a single
workstream so they can be batched into one PR after the technical
WUs land.

### 11.1 WU G.1 — Genesis Plan amendment §15

**Owner:** Lean reviewer + project maintainer; **Reviewer count:**
2 (this is a Genesis-Plan edit, governed by §14.4); **Depends on:**
substantive completion of A–F.

**Deliverable.**  A new chapter `§15 Ethereum Integration` in
`docs/GENESIS_PLAN.md`.  The chapter covers:

  * The deployment scenario (knomosis-as-rollup).
  * The trust-assumption inventory delta.
  * The `Action` index extension at 12 / 13.
  * The `Event` index extension at 9 / 10.
  * The `ExtendedState` field extension (`bridge`).
  * The `bridge_supply_account` accounting equation.
  * The MVP non-goals (§2.2 of this document, lifted verbatim
    with cross-references).
  * The pointer to this workstream plan as the authoritative
    engineering roadmap.

**Acceptance criteria.**

  * §15 lands as a single PR with a §14.4 two-reviewer sign-off.
  * The chapter cross-references existing §4 / §5 / §8 sections
    where the bridge layer touches them.

### 11.2 WU G.2 — README and CLAUDE.md updates

**Owner:** project maintainer; **Reviewer count:** 1; **Depends on:**
G.1.

**Deliverable.**

  * `README.md` gains an "Ethereum integration" section pointing
    at this document and at the testnet deployment instructions.
  * `CLAUDE.md` gains:
    * a new `Phase E` row in the implementation roadmap table;
    * new build commands for the bridge modules;
    * the bridge-module dependency-graph extension;
    * the new typeclass / theorem entries in the
      "Type-level design properties" table;
    * a fix for the §13.6 reference in the "Two reviewer rule
      for kernel-touching changes" subsection — the two-reviewer
      rule actually lives in Genesis Plan §14.4 (Review
      Discipline), not §13.6 (Runbook: Adding a New Law).  See
      §18.1 of this document.

### 11.3 WU G.3 — ABI document additions

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** C.4, C.5,
D.1, E.1.

**Deliverable.**  `docs/abi.md` gains §12 (Ethereum integration
ABI), covering:

  * `Action` constructor encodings at indices 12, 13, and 14.
  * `Event` constructor encodings at indices 9 and 10.
  * `BridgeState`, `PendingWithdrawal`, `WithdrawalProof` CBE
    encodings.
  * The bridge-actor `ActorId 0` reservation.
  * The keccak256 trailer format (replacing the FNV-1a-64 trailer
    in production deployments).
  * The `KnomosisBridge.sol`, `KnomosisIdentityRegistry.sol`, and
    `KnomosisDisputeVerifier.sol` event ABIs (the off-chain
    ingestor's contract).

### 11.4 WU G.4 — Extraction notes update

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** A.1, A.2, A.3.

**Deliverable.**  `docs/extraction_notes.md` §2 gains the new
trust assumptions (§3.3 of this document, formalised):

  * EUF-CMA on secp256k1.
  * Collision resistance of keccak256.
  * L1 finality.
  * Solidity contract correctness.
  * EIP-1271 contract correctness (opt-in).

Each assumption is paired with the workstream WU that introduces
it and the runtime adaptor symbol that implements it.

### 11.5 WU G.5 — Std-dependency audit refresh

**Owner:** Lean; **Reviewer count:** 1; **Depends on:** B.1
(introduces `Std.Data.TreeMap` lookups under new keys).

**Deliverable.**  `docs/std_dependencies.md` gains an entry for
each new `Std`-library lemma the bridge modules invoke.  No new
imports are expected (all bridge modules use `Std.Data.TreeMap`
already on the allowlist), but the audit must verify this
explicitly.

**Acceptance criteria.**

  * `lake exe tcb_audit` continues to pass (TCB modules unchanged).
  * The std-dep audit document lists every bridge-module Std
    lemma with stability annotations.

## 12. Mathematical correctness obligations

This section consolidates every proof obligation introduced by
the workstream plan.  Each entry names the theorem, summarises
the proof strategy, and identifies the WU that owns it.  Every
theorem ships without `sorry` and is `#print axioms`-clean
(only the three Lean built-ins).

### 12.0 Bridge admissibility (workstream C.0)

| #  | Theorem                                              | WU  | Proof strategy                  |
|----|------------------------------------------------------|-----|---------------------------------|
| 0a | `BridgeAdmissibleWith.toAdmissibleWith`              | C.0 | `And.left` projection           |
| 0b | `apply_bridge_admissible_with_kernel_agreement`      | C.0 | `rfl` after unfolding           |
| 0c | `bridge_replay_impossible`                           | C.0 | lift Phase-3 via projection #0a |

The "0a/0b/0c" numbering keeps the rest of §12's running counter
intact while making the bridge-admissibility prerequisites
explicit.

### 12.1 Locality theorems (per new law)

| # | Theorem                              | WU  | Proof strategy                       |
|---|--------------------------------------|-----|--------------------------------------|
| 1 | `deposit_other_resource_untouched`   | C.2 | `getBalance_setBalance_other`        |
| 2 | `deposit_other_actor_untouched`      | C.2 | `getBalance_setBalance_other`        |
| 3 | `withdraw_other_resource_untouched`  | C.3 | `getBalance_setBalance_other`        |
| 4 | `withdraw_other_actor_untouched`     | C.3 | `getBalance_setBalance_other`        |

Each reduces to a single application of the §4.3 balance lemma.
Proofs are 1–3 lines each.

### 12.2 Per-resource accounting

| # | Theorem                              | WU  | Proof strategy                       |
|---|--------------------------------------|-----|--------------------------------------|
| 5 | `totalSupply_after_deposit`          | C.2 | `totalSupply_setBalance` + arithmetic|
| 6 | `totalSupply_after_withdraw`         | C.3 | `totalSupply_setBalance` + arithmetic|

Both are direct consequences of the §8.1 master lemma.  The
withdraw form requires the precondition (sufficient balance) so
that the `Nat` subtraction is exact (no truncation).

### 12.3 Classification (typeclass instances and witnesses)

| #  | Theorem                              | WU  | Proof strategy                       |
|----|--------------------------------------|-----|--------------------------------------|
| 7  | `deposit_isMonotonic`                | C.2 | direct from #5                       |
| 8  | `deposit_not_conservative`           | C.2 | mirror of `mint_not_conservative`    |
| 9  | `withdraw_not_monotonic`             | C.3 | mirror of `burn_not_monotonic`       |
| 10 | `withdraw_not_conservative`          | C.3 | mirror of `burn_not_conservative`    |

The negative witnesses use the same fixture-construction pattern
as their Phase-2 counterparts (mint / burn): pick a concrete
state where the inequality is strict, derive a contradiction
from the typeclass instance.

### 12.4 Compile and registry preservation

| #  | Theorem                                          | WU    | Proof strategy                  |
|----|--------------------------------------------------|-------|---------------------------------|
| 11 | `Action.compile_injective_extends`               | C.4   | `congrArg .source` (extends)    |
| 12 | `registry_unchanged_when_action_does_not_mutate` | C.4   | case-split on `mutatesRegistry` |
| 13 | `deposit_preserves_registry`                     | C.4   | corollary of #12                |
| 14 | `withdraw_preserves_registry`                    | C.4   | corollary of #12                |
| 15 | `apply_admissible_with_preserves_bridge`         | C.1.3 | rfl after unfolding             |

Each is a structural extension of an existing theorem; no new
proof technique.  Note: theorem #12 *replaces* the pre-Audit-1
`non_replaceKey_preserves_registry_extends`, which was incorrect
since `registerIdentity` is a non-`replaceKey` action that *does*
mutate the registry.  See §19.2.

### 12.5 Encoding round-trip and injectivity

| #  | Theorem                              | WU    | Proof strategy                |
|----|--------------------------------------|-------|-------------------------------|
| 16 | `action_roundtrip_extends`           | C.4   | per-field `*_roundtrip`       |
| 17 | `action_encode_injective_extends`    | C.4   | per-field `*_encode_injective`|
| 18 | `event_roundtrip_extends`            | C.5   | per-field `*_roundtrip`       |
| 19 | `depositId_roundtrip`                | C.1.4 | new instance + Encodable      |
| 20 | `pendingWithdrawal_roundtrip`        | C.1.4 | new instance + Encodable      |
| 21 | `bridgeState_roundtrip`              | C.1.4 | new instance + Encodable      |
| 22 | `bridgeState_encode_deterministic`   | C.1.4 | TreeMap canonicality (Audit-2) |
| 23 | `withdrawalProof_roundtrip`          | D.1.2 | Vector + bytes round-trip     |

All follow the Phase-4 round-trip / injectivity discipline.

### 12.6 EIP-712 wrap (workstream A.3)

| #  | Theorem                              | WU  | Proof strategy                | Status   |
|----|--------------------------------------|-----|-------------------------------|----------|
| 24 | `eip712Wrap_injective`               | A.3 | hash-collision-resistance hyp | Complete |
| 25 | `eip712DomainSeparator_distinguishes`| A.3 | injectivity of domain-encode  | Complete |
| 26 | `eip712Wrap_distinguishes`           | A.3 | composition of #24 + #25      | Complete |

All three theorems ship without `sorry` in
`LegalKernel/Bridge/Eip712.lean`.  Each `#print axioms` returns
a subset of `[propext, Quot.sound]` — no custom axioms, no
new opaque declarations.

The hash-collision-resistance hypothesis is a `Prop` parameter,
not a Lean axiom.  Real-world security depends on the
deployment-supplied keccak256 (Workstream A.2).

**Conclusion-form refinement.**  The §5.3 spec states #24 as
`eip712Wrap m₁ d = eip712Wrap m₂ d → m₁ = m₂`; the implemented
form proves the equivalent but Lean-tractable
`m₁.signInput = m₂.signInput` conclusion.  The two are equivalent
under `signInput` injectivity in `(action, signer, nonce,
deploymentId)`, which is a separate property of the Knomosis CBE
encoding (not stated as a theorem in this Workstream — production
wallet adaptors apply it at the FFI boundary when displaying the
struct fields).  See `LegalKernel/Bridge/Eip712.lean`'s docstring
for the full coverage map and the canonicalisation deviations.

### 12.7 Address book (workstream B.1)

| #  | Theorem                              | WU  | Proof strategy           |
|----|--------------------------------------|-----|--------------------------|
| 27 | `addressBook_invariant`              | B.1 | structural induction     |
| 28 | `assign_fresh_actorId`               | B.1 | case-split on lookup     |
| 29 | `assign_idempotent_for_known`        | B.1 | rfl                      |

### 12.8 L1 ingestor (workstream B.2)

| #  | Theorem                                              | WU  | Proof strategy              |
|----|------------------------------------------------------|-----|-----------------------------|
| 30 | `ingest_lookup_equivalent_for_distinct_addresses`    | B.2 | case-split on event variant |
| 31 | `ingest_emits_bridge_actor`                          | B.2 | direct from constructor     |

### 12.9 Bridge-actor authority (workstream B.3)

| #  | Theorem                                      | WU  | Proof strategy |
|----|----------------------------------------------|-----|----------------|
| 32 | `bridgePolicy_rejects_transfer`              | B.3 | `decide`       |
| 33 | `bridgePolicy_rejects_withdraw`              | B.3 | `decide`       |
| 34 | `bridgePolicy_authorizes_deposit`            | B.3 | `decide`       |
| 35 | `bridgePolicy_authorizes_replaceKey`         | B.3 | `decide`       |
| 36 | `bridgePolicy_authorizes_registerIdentity`   | B.3 | `decide`       |

Plus one structural lemma owned by C.4:

| #  | Theorem                                      | WU  | Proof strategy |
|----|----------------------------------------------|-----|----------------|
| 37 | `registerIdentity_first_time_only`           | C.4 | direct from `applyActionToRegistry` case |

`registerIdentity_first_time_only` states: if
`apply_admissible_with` succeeds on a `registerIdentity actor pk`
action, then the pre-state's registry has no mapping for
`actor`.  This pins the first-time-only invariant at the
type level.

### 12.9a `BridgeState` data and CBE (workstream C.1.1, C.1.4)

| #  | Theorem                                      | WU    | Proof strategy                          |
|----|----------------------------------------------|-------|-----------------------------------------|
| 38 | `byteArrayCompare_total_order`               | C.1.1 | structural induction on byte arrays     |
| 39 | `BridgeState.empty_*` (3 lemmas)             | C.1.1 | rfl (×3)                                |

### 12.10 Withdrawal Merkle tree (workstream D.1)

D.1's theorems are now distributed across the four sub-WUs:

| #  | Theorem                                              | WU    | Proof strategy                     |
|----|------------------------------------------------------|-------|------------------------------------|
| 40 | `defaultHash_well_defined`                           | D.1.1 | `Fin.succ` recursion termination   |
| 41 | `withdrawalRoot_empty_eq_defaultHash_top`            | D.1.1 | rfl                                |
| 42 | `withdrawalRoot_extensional`                         | D.1.1 | TreeMap canonicality               |
| 43 | `constructProof_deterministic`                       | D.1.2 | rfl                                |
| 44 | `constructProof_siblings_length`                     | D.1.2 | static (`Vector n` discipline)     |
| 45 | `verifyProof_total`                                  | D.1.2 | structural recursion on `Fin smtHeight` |
| 46 | `verifyProof_complete`                               | D.1.3 | induction on index bits (unconditional) |
| 47 | `verifyProof_sound`                                  | D.1.4 | contrapositive + collision-free hyp |

### 12.11 Snapshot finalisation (workstream D.3)

| #  | Theorem                                  | WU  | Proof strategy                |
|----|------------------------------------------|-----|-------------------------------|
| 48 | `isFinalised_monotonic_in_currentBlock`  | D.3 | case-split on confirmations   |
| 49 | `isFinalised_implies_no_upheld_against`  | D.3 | direct from `disputeStatus` walk |

### 12.12 Bridge accounting (workstream C.6)

C.6's theorems are now distributed across the five sub-WUs:

| #  | Theorem                                                    | WU    | Proof strategy                       |
|----|------------------------------------------------------------|-------|--------------------------------------|
| 50 | `totalDeposited_insert`                                    | C.6.1 | §8.3 RBMap fold-insert lemmas        |
| 51 | `totalWithdrawn_insert`                                    | C.6.1 | §8.3 RBMap fold-insert lemmas        |
| 52 | `totalDeposited_unchanged_on_other_action`                 | C.6.1 | rfl per branch                       |
| 53 | `totalWithdrawn_unchanged_on_other_action`                 | C.6.1 | rfl per branch                       |
| 54 | `accounting_delta_transfer`                                | C.6.2 | unfold + balance lemmas              |
| 55 | `accounting_delta_deposit`                                 | C.6.2 | unfold + #50                         |
| 56 | `accounting_delta_withdraw`                                | C.6.2 | unfold + #51                         |
| 57 | `accounting_delta_balance_neutral`                         | C.6.2 | rfl per branch                       |
| 58 | `accounting_delta_non_bridge_increasing`                   | C.6.2 | unfold + balance lemmas              |
| 59 | `getBalance_bounded_by_totalSupply`                        | C.6.3 | §8.3 fold-pointwise-le               |
| 60 | `totalWithdrawn_bounded`                                   | C.6.3 | induction + #54..#58, #59            |
| 61 | `bridge_supply_account_general`                            | C.6.4 | induction + #54..#58, #60            |
| 62 | `bridge_supply_account` (strict)                           | C.6.5 | corollary of #61 + #63               |
| 63 | `totalRewarded_zero_under_bridgeLawSet`                    | C.6.5 | induction over `bridgeLawSet`        |

### 12.13 Composition: end-to-end safety theorem

The composition of the above produces the headline safety
theorem for the MVP:

```lean
/-- The bridge deployment law set: transfer + the four
    registry-mutating / balance-mutating bridge laws.  Forms a
    `MonotonicLawSet` because every member is `IsMonotonic`
    (transfer + deposit) or balance-neutral (registerIdentity +
    replaceKey + freezeResource), and `withdraw` is *excluded*
    from this set — deployments wanting strict supply-non-
    decrease build a separate `MonotonicLawSet` without
    `withdraw`. -/
def bridgeLawSet : MonotonicLawSet

/-- Headline safety: under the bridge deployment law set, every
    reachable state simultaneously satisfies three invariants:

      1. **Bridge accounting** — the §C.6 supply-credit-debit
         equation.
      2. **Per-actor nonce monotonicity** — the §3 `expectsNonce`
         invariant lifted across reachability.
      3. **Registry-once-registered** — once an actor's registry
         entry is set, it stays set (possibly with a different
         key after `replaceKey`).

    The conjunction is what `KnomosisBridge.sol` relies on for
    soundness of `withdrawWithProof`: the recipient address can
    be trusted to hold the claimed balance because (1) supply
    accounting is exact, (2) every authoring signature has a
    fresh nonce, and (3) the signing key is bound to the
    identity at the type level. -/
theorem bridge_deployment_safety
    (es₀ es : ExtendedState)
    (h : ReachableViaLaws bridgeLawSet es₀ es) :
    -- (1) bridge accounting:
    (∀ r, totalSupply r es.base + Bridge.totalWithdrawn es r
            = totalSupply r es₀.base + Bridge.totalDeposited es r)
    -- (2) per-actor nonce monotonicity:
  ∧ (∀ a, expectsNonce es.nonces a ≥ expectsNonce es₀.nonces a)
    -- (3) once registered, always registered:
  ∧ (∀ a pk₀, KeyRegistry.lookup es₀.registry a = some pk₀ →
        ∃ pk, KeyRegistry.lookup es.registry a = some pk)
```

The conjunction-of-three is proved by `And.intro` of three
independent inductive theorems, each decomposing over
`ReachableViaLaws` per-action-variant.  Owner: workstream C.6
(the conjunction is bundled with the accounting theorem).

The first-time-registration discipline (a fourth potential
conjunct) is *enforceable* through the §7.0 `BridgeAdmissibleWith`
predicate's clause (7) and the C.4
`registerIdentity_first_time_only` lemma.  However, lifting it
into a state-relational form usable in
`bridge_deployment_safety` requires referencing the
log-history-witness ("registration happened via
`registerIdentity`"), which is not first-order in
`ExtendedState`.  This refinement is *post-MVP*: the
`BridgeAdmissibleWith` predicate enforces the property at every
state-advance call site, but the headline reachability theorem
does not surface it.

### 12.14 Invariants the runtime adaptor must preserve

The adaptors do *not* prove these in Lean (the proofs would
require modelling the IO substrate).  Instead, they are
contracts the runtime tests assert at the value level:

  * **A.1 ECDSA verify**: deterministic; high-s rejected;
    accepts iff secp256k1 verifies.
  * **A.2 keccak256**: deterministic; output exactly 32 bytes;
    matches NIST KAT vectors and `geth` outputs.
  * **B.2 L1 ingestor**: deterministic on the same `(L1 head,
    AddressBook)` pair; reorg-tolerant up to the configured
    confirmation depth.

Each of these is exercised by `Test/Bridge/*` value-level
fixtures and by the property-based suite (workstream F.4).

## 13. Sequencing and dependencies

### 13.1 Dependency DAG

The DAG is shown as an adjacency list (each WU lists its
prerequisites).  Audit-2 decomposed six WUs into 25 sub-WUs;
the table below lists both the parent WUs (italics) and the
sub-WUs.  An ASCII rendering follows the table.

**Adjacency list (prerequisite → dependent):**

| WU      | Title                                | Prerequisites                                       |
|---------|--------------------------------------|-----------------------------------------------------|
| A.1     | ECDSA secp256k1                      | (root — no prerequisites)                           |
| A.2     | keccak256                            | (root)                                              |
| A.3     | EIP-712 wrap                         | A.1, A.2                                            |
| B.1     | AddressBook                          | (root)                                              |
| B.2     | L1 ingestor                          | B.1                                                 |
| B.3     | Bridge actor                         | B.1, B.2, C.4 (for `registerIdentity` constructor)  |
| C.0     | `BridgeAdmissibleWith` predicate     | (depends only on Phase-3 Authority)                 |
| *C.1*   | *BridgeState (parent)*               | *B.1, C.0*                                          |
| C.1.1   | BridgeState data structures          | B.1, C.0                                            |
| C.1.2   | ExtendedState field embedding        | C.1.1                                               |
| C.1.3   | Pass-through preservation theorem    | C.1.2, C.0                                          |
| C.1.4   | BridgeState CBE encoding             | C.1.1                                               |
| C.2     | deposit law                          | C.0, C.1.4                                          |
| C.3     | withdraw law                         | C.0, C.1.4                                          |
| C.4     | Action constructor extension         | C.2, C.3                                            |
| C.5     | Event constructor extension          | C.4                                                 |
| *C.6*   | *Bridge accounting theorem (parent)* | *C.2, C.3, C.4, C.5*                                |
| C.6.1   | totalDeposited / totalWithdrawn defs | C.1.4, C.4, C.5                                     |
| C.6.2   | Per-action accounting deltas         | C.6.1                                               |
| C.6.3   | totalWithdrawn boundedness lemma     | C.6.1, C.6.2                                        |
| C.6.4   | bridge_supply_account_general        | C.6.1, C.6.2, C.6.3                                 |
| C.6.5   | bridge_supply_account strict form    | C.6.4                                               |
| *D.1*   | *SMT root + proof verifier (parent)* | *A.2, C.6.5*                                        |
| D.1.1   | SMT data structures + tree build     | C.1.4, A.2                                          |
| D.1.2   | verifyProof / constructProof defs    | D.1.1                                               |
| D.1.3   | verifyProof_complete (unconditional) | D.1.2                                               |
| D.1.4   | verifyProof_sound (hash-conditional) | D.1.3                                               |
| D.1.5   | Cross-stack SMT goldens              | D.1.4                                               |
| D.2     | Proof extractor                      | D.1.4                                               |
| D.3     | Snapshot finalisation                | D.1.4, D.2                                          |
| *E.1*   | *KnomosisBridge.sol (parent)*           | *A.2, D.1.4*                                        |
| E.1.1   | Deposit entry points                 | A.2, B.2                                            |
| E.1.2   | State-root submission                | A.1                                                 |
| E.1.3   | Withdrawal redemption                | D.1.4, E.1.2                                        |
| E.1.4   | Automatic circuit breakers           | E.5 (interface only; address may be 0)              |
| E.1.5   | Rollback hook                        | E.1.2, E.2.5                                        |
| *E.2*   | *KnomosisDisputeVerifier.sol (parent)*  | *E.1, Phase-6 dispute pipeline*                     |
| E.2.1   | Dispute filing + CBE-decode lib      | E.1.5, Phase-6 `Disputes.Filing`                    |
| E.2.2   | signatureInvalid verifier            | E.2.1, A.1, E.3                                     |
| E.2.3   | nonceMismatch verifier               | E.2.1                                               |
| E.2.4   | doubleApply verifier                 | E.2.1                                               |
| E.2.5   | Verdict finalisation + slash hook    | E.2.2, E.2.3, E.2.4, E.4                            |
| E.3     | KnomosisIdentityRegistry.sol            | (root, Solidity-side)                               |
| E.4     | Sequencer staking                    | E.1.5, E.2.5                                        |
| E.5     | KnomosisMigration.sol                   | Audit-3.2 `AttestedSnapshot`, A.1, A.2, A.3         |
| *F.1*   | *Cross-stack corpus (parent)*        | *A.\*, C.\*, D.\*, E.\**                            |
| F.1.1   | Cross-stack test-driver framework    | (root)                                              |
| F.1.2   | ecdsa_verify.json fixture            | F.1.1, A.1                                          |
| F.1.3   | keccak256.json fixture               | F.1.1, A.2                                          |
| F.1.4   | deposit_receipt_hash.json fixture    | F.1.1, B.2, E.1.1                                   |
| F.1.5   | withdrawal_proof.json fixture        | F.1.1, D.1.5, E.1.3                                 |
| F.1.6   | dispute_evidence.json fixture        | F.1.1, E.2.2, E.2.3, E.2.4, E.2.5                   |
| F.1.7   | migration_attestation.json fixture   | F.1.1, A.3, E.5, Audit-3.2 `AttestedSnapshot`       |
| F.2     | Goldens (keccak / ECDSA / RLP)       | A.1, A.2                                            |
| F.3     | End-to-end testnet deployment        | F.1.*, F.2, all of E.*                              |
| F.4     | Property-based tests                 | C.6.5, D.1.4                                        |
| G.1     | Genesis Plan §15 amendment           | substantive completion of A–F                       |
| G.2     | README + CLAUDE.md                   | G.1                                                 |
| G.3     | ABI doc additions                    | C.4, C.5, D.1.4, E.1                                |
| G.4     | Extraction notes                     | A.1, A.2, A.3                                       |
| G.5     | Std-dependency audit                 | B.1                                                 |

Total leaf-level WUs: **50** (after Audit-2's decomposition,
the immutability-amendment §20 addition of E.5, and the
post-immutability addition of F.1.7 — the latter formalises
the cross-stack `KnomosisMigration` attestation fixture that
§20.3 scoped as deferred);  parent WUs above are
documentation conveniences and do not themselves require
review.

**ASCII rendering** (left-to-right precedence; arrows omitted
for legibility):

```
             [Phases 0–6 + Audit-3 — pre-existing]
                            │
   ┌─────────┬──────────────┼──────────────┬──────────┐
   │         │              │              │          │
  A.1       A.2            B.1            E.3        G.5
   │         │              │              │
   └────┬────┘              ├─── B.2 ── B.3
        │                   │
       A.3                 C.1
                            │
                  ┌─────────┴─────────┐
                 C.2                 C.3
                  └─────────┬─────────┘
                           C.4
                            │
                           C.5
                            │
                           C.6
                            │
              ┌─────────────┼─────────────┐
              │             │             │
             D.1           E.1           F.4
              │             │
             D.2           E.2
              │             │
             D.3           E.4
              │             │
              └──────┬──────┘
                    F.1
                     │
              ┌──────┴──────┐
             F.2           F.3
                            │
                           G.1
                            │
                  ┌─────────┼─────────┐
                 G.2       G.3       G.4
```

### 13.2 Critical path

The longest dependency chain — the time floor for the MVP —
runs through the bridge-admissibility ➜ bridge-laws ➜
accounting ➜ withdrawal-proofs ➜ Solidity ➜ cross-stack ➜
testnet ➜ amendment chain.  After Audit-2's decomposition the
critical path expands but per-step risk decreases:

```
B.1 ─▶ C.0 ─▶ C.1.1 ─▶ C.1.2 ─▶ C.1.4 ─▶ C.2 / C.3 ─▶ C.4 ─▶ C.5 ─▶
       C.6.1 ─▶ C.6.2 ─▶ C.6.3 ─▶ C.6.4 ─▶ C.6.5 ─▶
       D.1.1 ─▶ D.1.2 ─▶ D.1.3 ─▶ D.1.4 ─▶
       E.1.3 ─▶ E.2.1 ─▶ E.2.5 ─▶
       F.1.1 ─▶ F.1.5 ─▶ F.3 ─▶ G.1
```

Twenty-four sequential leaf-WUs along the critical path; C.2
and C.3 land in parallel within one slot, as do the F.1.* sub-
fixtures.  Several leaf-WUs are short (≤ 1 day each);
the wall-clock estimate is preserved by running atomic sub-WUs
back-to-back within a single engineer-week.

**Estimated effort (post-decomposition).**

  * Lean-side WUs (A.3, B.*, C.*, D.*, F.4):
    ≈ 7 engineer-weeks (decomposition added ≈ 1 week of
    review-and-integration overhead, offset by reduced per-PR
    risk).
  * Runtime adaptor WUs (A.1, A.2, ingestor binary):
    ≈ 2 engineer-weeks.
  * Solidity-side WUs (E.*):
    ≈ 5 engineer-weeks (E.2's decomposition added ≈ 1
    engineer-week of fixture authoring).
  * Cross-stack + testnet (F.1.*, F.2, F.3):
    ≈ 2 engineer-weeks (F.1's decomposition added ≈ 1
    engineer-week of per-fixture work).
  * Documentation (G.*):
    ≈ 1 engineer-week.

**Total**: ≈ 17 engineer-weeks of work.

Wall-clock duration with two engineers in parallel: ≈ 9 weeks.
With four engineers (one on Lean kernel-side, one on Lean bridge,
one on Solidity, one on runtime adaptor + ops): ≈ 5 weeks.

The decomposition's wall-clock impact is small because the
critical path is still bounded by the longest dependency chain
(C.6's accounting proof + D.1's SMT proof), which were already
sequential.  The new sub-WUs let multiple engineers work
concurrently *within* a parent WU, which compresses the
elapsed time despite the larger total work-unit count.

### 13.3 Parallelisation opportunities

  * **A.1 and A.2 are independent** of everything Lean-side and
    of each other.  Two engineers can land them in parallel.
  * **B.1 is independent** of A.* and can land first if a fast
    AddressBook test fixture is desired before the cryptographic
    adaptors land.
  * **E.3 (`KnomosisIdentityRegistry`)** is independent of everything
    else Solidity-side and can land in week 1.
  * **D.1 and E.1 can develop in parallel** once C.5 lands — D.1
    builds the proof, E.1 verifies it; F.1 closes the gap.
  * **G.* docs WUs** can be drafted in parallel with the
    technical WUs they document, then refined when the technical
    WUs land.
  * **E.5 (`KnomosisMigration.sol`)** is independent of E.1.4 in
    the dependency sense: E.5 only needs Audit-3.2's
    `AttestedSnapshot` discipline (already landed) plus the
    EIP-712 wrap from A.3.  It can land in parallel with E.1
    sub-WUs as long as `KnomosisBridge`'s constructor exposes the
    `migration` immutable.  Operationally, the initial
    deployment uses `migration = address(0)`; E.5 is exercised
    only when a migration is actually needed.

## 14. Acceptance gates

### 14.1 Per-WU exit criteria

Every WU's exit criteria conform to the same template:

  1. **Proof.**  All theorems listed in §12 for the WU ship
     without `sorry`.  `#print axioms` returns the canonical
     three-axiom set on every theorem.
  2. **Tests.**  `lake test` passes; the new WU-specific test
     module lands with the WU.  Test count grows by the number
     listed in the WU's section.
  3. **Build hygiene.**  `lake build`, `lake exe count_sorries`,
     `lake exe tcb_audit`, `lake exe stub_audit` all pass.
  4. **Documentation.**  Every public declaration (def /
     theorem / structure / instance) has a `/-- ... -/`
     docstring; the file has a `/-! ... -/` header citing the
     WU number.
  5. **Naming hygiene.**  The git-diff naming-violation grep
     (CLAUDE.md §"Names describe content, never provenance")
     returns empty.

### 14.2 Phase-level exit criteria (Phase E complete)

The phase is complete when:

  1. All WUs A.* through G.* meet their per-WU exit criteria.
  2. The §2.3 acceptance script passes on the testnet target.
  3. `kernelBuildTag` is bumped to
     `"knomosis-phase-e-ethereum-integration"` in `LegalKernel.lean`.
  4. `Tests.lean` driver registers the new test suites (estimated
     +12 suites, +120 tests on the Lean side; the immutability
     amendment §20 adds ≈ 24 forge tests on the Solidity side
     for `KnomosisMigration.sol` plus ≈ 16 forge tests for the
     E.1.4 circuit-breaker boundaries plus ≈ 8 negative
     "no-admin-surface" assertions across E.1 / E.2 / E.3 /
     E.4 — total ≈ +48 forge tests vs. the pre-amendment
     baseline).
  5. `docs/GENESIS_PLAN.md §15` lands with two-reviewer sign-off.
  6. The branch `claude/ethereum-kernel-integration-HMexY` (or
     its successor) merges to `main` via a PR that links every
     WU PR in its body.

### 14.3 Continuous-integration changes

The MVP introduces three new CI jobs:

  * **`forge-test`** — runs the Solidity test suite on every PR
    that touches `solidity/`.
  * **`cross-stack-equivalence`** — regenerates F.1 fixtures from
    Lean and asserts the forge tests still pass.
  * **`testnet-acceptance` (manual trigger)** — runs the §2.3
    sequence on a forked-testnet RPC; fails the run on any
    deviation.

Each job uses the same supply-chain pinning as the existing
GitHub Actions workflow (commit-SHA-pinned actions, no implicit
`@latest` references).

## 15. Risks and mitigations

### 15.1 Cryptographic-binding correctness

  * **Risk.**  The Rust `knomosis_verify` or `knomosis_hash_bytes`
    binding contains a subtle bug — e.g. fails to reject high-s
    ECDSA, or zero-pads keccak256 incorrectly — and the rest of
    the system trusts it.
  * **Mitigation.**  Workstreams F.1 and F.2 cross-check both
    bindings against `geth` / OpenZeppelin / NIST KAT vectors.
    Any deviation fails CI before merge.  Additionally, A.1 and
    A.2 each carry a property-based test corpus that reproduces
    failures via the recorded seed.

### 15.2 ECDSA malleability and `s`-canonicalisation drift

  * **Risk.**  An adapter version that *was* low-s-rejecting gets
    silently changed to accept high-s, opening malleability for
    log-bloat attacks.
  * **Mitigation.**  A.1's tests include
    `verifyAdaptor_rejects_high_s` as a hard-fail case.
    `lake exe stub_audit` is extended (workstream F.2 fixture)
    to flag any adapter implementation that omits the
    rejection.

### 15.3 ABI drift between Lean and Solidity

  * **Risk.**  The Lean side computes `DepositId` differently
    from the Solidity side, so a deposit on L1 is never matched
    to a Knomosis credit (or worse, a synthetic deposit credits
    with no L1 backing).
  * **Mitigation.**  F.1's `deposit_receipt_hash.json` fixture
    covers exactly this byte-equivalence.  E.1's test suite
    asserts `keccak256(abi.encode(...))` equality with the Lean
    value.

### 15.4 Reorg handling at the L1 ingestion boundary

  * **Risk.**  An L1 reorg removes a deposit event the Knomosis
    sequencer has already credited, producing a phantom credit.
  * **Mitigation.**  B.2's ingestor enforces a
    confirmation-depth gate (default 64 blocks ≈ 12 minutes
    post-Casper finality slot).  Events are *not* ingested until
    they have at least that many confirmations.  The
    confirmation depth is configurable per-deployment and is
    surfaced in the `docs/abi.md §11` documentation.

### 15.5 Sequencer censorship

  * **Risk.**  A malicious sequencer refuses to include a user's
    `Action.withdraw`, trapping their funds on Knomosis.
  * **Mitigation.**  *Out of MVP scope* but the architecture
    supports an L1-side escape hatch: a future workstream can
    add `forceWithdraw(...)` to `KnomosisBridge.sol` that lets
    users submit an L1 withdraw directly.  The Phase-6 dispute
    pipeline already gives the corresponding off-chain
    enforcement.  Track as a v2 addition.

### 15.6 Gas costs in the dispute verifier

  * **Risk.**  The on-chain `checkEvidence` for `nonceMismatch`
    requires re-running a log prefix in Solidity, which can be
    expensive for long disputes.
  * **Mitigation.**  *MVP-bounded.*  The MVP restricts disputable
    log prefixes to ≤ 256 entries (configurable), keeping the
    one-shot fraud proof tractable.  A bisection game is
    deferred to v2 when dispute length matters.

### 15.7 Trust-assumption inventory growth

  * **Risk.**  The MVP doubles the number of cryptographic /
    economic assumptions the system rests on, and a future
    auditor cannot easily enumerate them.
  * **Mitigation.**  G.4 lands an explicit table in
    `docs/extraction_notes.md §2` listing every new assumption
    with: name, scope, mitigated-by, reviewer-checklist entry.

### 15.8 Migration mechanism compromise

  * **Risk.**  An attacker with control of the predecessor's
    attestor key (the same key used to sign state roots) signs a
    migration record pointing at a malicious successor
    `KnomosisBridge` they control.  Once the 30-day grace window
    elapses and `activate()` is called, the predecessor freezes
    new deposits / new state roots, and users who fail to
    redeem before activation see their pending withdrawals
    stranded at the predecessor (they remain redeemable at the
    predecessor — see point 4 below — but no longer
    extensible to new state).
  * **Why this is *strictly weaker* than the upgradeable
    design's §15.8.**  In the upgradeable design, an upgrade key
    compromise lets the attacker swap in a malicious
    implementation that drains the bridge *atomically* — all
    locked value goes to the attacker in one transaction with no
    user response possible.  In this design, a compromised
    attestor:
      1. Cannot drain the bridge directly: there is no
         `transferAll` function or analogue; the attestor
         signs only state roots and migration records.
      2. Cannot bypass the migration's bidirectional reference
         check: `KnomosisMigration`'s constructor asserts that the
         successor's `migration` immutable points back at the
         migration contract being deployed.  The attacker must
         also deploy a malicious successor `KnomosisBridge`, which
         is an observable on-chain event the watchdog reacts
         to.
      3. Cannot bypass the 30-day minimum grace window: the
         `MIN_GRACE_WINDOW_BLOCKS` `constant` in
         `KnomosisMigration.sol` cannot be weakened by any
         constructor argument or runtime call.
      4. Cannot strand users: the predecessor's
         `withdrawalOpen` modifier (§9.1.4) does not check
         `migration.activated()`, so users can continue to
         redeem against pre-migration state roots indefinitely
         after activation.  The attacker can only freeze *new*
         state — they cannot prevent withdrawal of state
         already attested to.
  * **Mitigations** (defence in depth):
    1. **Attestor key custody.**  The attestor key lives in an
       HSM with TPM-attested boot.  No raw-key export.  Same
       discipline as §15.11.
    2. **Watchdog monitoring.**  An off-chain watchdog
       monitors the L1 contract space for any `KnomosisMigration`
       deployment whose `predecessor` matches the active
       `KnomosisBridge`.  On detection, the watchdog publishes an
       alert (Slack / Discord / Twitter) within seconds.
       Users have ≥ 30 days to respond.
    3. **No automatic frontend handoff.**  The official
       frontend reads the migration's `successor` address but
       *does not* automatically route user funds to it.  Users
       must explicitly opt in to the new contract by signing a
       transaction — the malicious successor cannot
       silently capture user funds.
    4. **Grace-window minimum is constitutional.**  The
       `MIN_GRACE_WINDOW_BLOCKS = 216_000` (≈ 30 days) is a
       Solidity `constant` baked into `KnomosisMigration.sol`'s
       bytecode.  Even an attacker who controls the deployment
       process cannot ship a migration with a shorter grace
       window — the constructor reverts.  This is the
       on-chain equivalent of "the kernel TCB is not field-
       mutable": certain safety-critical parameters must be
       immutable at the bytecode level, not merely at runtime.
    5. **Attestor key rotation via migration.**  If the
       attestor key is suspected compromised, the operators
       deploy a fresh `KnomosisBridge` (with a fresh attestor
       address) plus a `KnomosisMigration` signed by the
       *old* attestor.  The migration activates after 30
       days; the new bridge takes over.  This is the canonical
       attestor-rotation flow — slower than a `setAttestor()`
       call would be, but with a strictly bounded blast
       radius.

### 15.9 Underestimated Lean-side proof difficulty

  * **Risk.**  Two theorems present non-trivial inductive
    arguments that may push back the timeline:
      1. `bridge_supply_account_general` (C.6) — induction on
         `ReachableViaLaws` over a heterogeneous law set with
         per-action accounting witnesses.
      2. `bridge_deployment_safety` (§12.13) — the four-conjunct
         composition, particularly the fourth conjunct's coupling
         to `registerIdentity_first_time_only`.
  * **Mitigation.**  *Pre-flight de-risking.*  For each: land
    the theorem statement as a `sorry`-stub on a feature
    branch first to sanity-check the type signature; only
    promote to a blocking WU once the proof outline is
    sketched.  The permissive form of #1 (with `totalRewarded`)
    and the `True`-placeholder form of #2's fourth conjunct are
    deliberately easier than the strict forms to give fall-back
    landing points.  Neither stub may merge to `main` —
    `lake exe count_sorries` would reject — but they give
    fast feedback during development.

### 15.10 Naming-policy violation in user-contributed PRs

  * **Risk.**  An external contributor's PR slips a process
    marker (`mvp_`, `eth_`, `phase_e_`) into a declaration name.
  * **Mitigation.**  Extend the existing CI workflow with a
    naming-violation grep step using the regex from CLAUDE.md
    §"Names describe content, never provenance".  Failure of the
    step blocks merge.  This is automation-only — no PR template
    or contributor-side process step is required, keeping the
    discipline mechanical rather than discretionary.

### 15.11 Bridge actor private-key compromise

  * **Risk.**  The bridge actor's signing key (held in the
    runtime adaptor's HSM / key store) is compromised.  An
    attacker can mint arbitrary `Action.deposit` actions on L2
    without any L1 lock backing them, draining the bridge's
    L1-locked collateral on first user redemption.
  * **Mitigation.**  *Defence in depth*:
    1. **HSM custody.**  The bridge key lives in an HSM with
       TPM-attested boot.  No raw-key export.
    2. **Per-event L1 receipt verification at admissibility time.**
       The Solidity `KnomosisBridge.sol` records every `DepositInitiated`
       event's `receiptHash` in a contract storage slot.
       `KnomosisDisputeVerifier.sol` accepts a new claim variant
       `unbackedDeposit` (post-MVP refinement) that lets anyone
       challenge a Knomosis `Action.deposit` whose `depositId` does
       not match an L1 `DepositInitiated` event.  The dispute
       upholds; the bridge state rolls back; the attacker's
       deposit is reverted before any redemption.
    3. **Deposit emission rate-limiting.**  The bridge actor's
       `processSignedAction` calls are rate-limited at the
       runtime adaptor (configurable; default 100 deposits per
       block).  An exfiltration attack thus needs many blocks to
       drain the bridge, leaving time for human response.
    4. **Operator monitoring.**  An off-chain watchdog compares
       Knomosis's `totalDeposited` against L1's emitted event sum
       continuously; divergence triggers a pause.

### 15.12 ERC-20 decimal mismatch

  * **Risk.**  Knomosis's `Amount : Nat` is unitless.  ERC-20 tokens
    have their own `decimals()` (typically 6 for USDC, 18 for
    most others); ETH is 18 decimals.  Naively mapping
    `uint256 amount` to `Nat` loses the unit information; a
    1-USDC deposit and a 1-DAI deposit produce the same Knomosis
    amount but represent different value.
  * **Mitigation.**  *Per-resource decimals discipline*:
    1. The Knomosis deployment declares a `ResourceId → Nat` decimals
       map at genesis (e.g. `1 → 18` for ETH, `2 → 6` for USDC).
    2. `KnomosisBridge.sol` validates the mapping at deposit time:
       the deposit-receipt encoding includes the
       `(token, decimals)` pair; the Lean ingestor cross-checks
       the deployed decimals against the genesis map.
    3. `withdrawWithProof` emits the L1 token amount using the
       same decimals map, applied in reverse.
  * **Documentation.**  The `docs/abi.md §12` ABI section
    documents the decimals map at the deployment-record level.

### 15.13 Hash-binding output mismatch (post-deployment)

  * **Risk.**  After landing, an attacker discovers a divergence
    between the Lean-side keccak256 binding and the
    Solidity-side keccak256 (e.g., a Rust-crate update changes
    behaviour on a corner-case input).  The attacker forges a
    state-root proof that the L1 contract accepts but Lean would
    reject — bypassing the dispute pipeline entirely.
  * **Mitigation.**  *Two-layer defence*:
    1. **Build-time golden assertion.**  CI fails the build if
       `runtime/knomosis-hash-keccak256`'s output on the F.2 golden
       corpus diverges from the recorded hashes.  Forces
       investigation of any binding change.
    2. **Run-time self-test.**  `knomosis`'s startup performs a
       100-input hash-binding sanity check against an embedded
       golden table.  Failure exits with status 2 *before* any
       state-affecting action.
    3. **Migration-trigger on divergence detection.**  The
       off-chain watchdog (see 15.11) periodically computes a
       Lean-side state hash and compares against the L1
       contract's believed state hash.  Divergence triggers
       a *migration proposal*: the operators deploy a fresh
       `KnomosisBridge` (with the corrected hash binding) plus a
       `KnomosisMigration` (E.5) signed by the current
       attestor.  The 30-day grace window elapses; users have
       deterministic notice to redeem at the predecessor;
       activation freezes the divergent predecessor.  This is
       slower than a single-shot `pause()` would be — but
       per §4.8, that latency is the price of having no
       upgrader-key trust assumption.  In the interim, the
       existing `DisputeCooldown` and `AttestationStale`
       circuit breakers (§9.1.4) automatically rate-limit
       further damage on the divergent predecessor.

## 16. Out of scope (post-MVP)

The following items are deliberately deferred.  They are listed
here with rationale so that future planners do not re-litigate
them.

  1. **`ActorId` widening to 20 bytes.**  Requires kernel TCB
     change + two-reviewer sign-off.  Registry indirection (B.1)
     is sufficient for the MVP at the cost of one extra TreeMap
     lookup per action.  Re-evaluate when the lookup becomes a
     measured bottleneck.
  2. **ZK proofs of `apply_admissible`.**  Optimistic disputes
     are sufficient for the MVP.  ZK extension requires either
     re-implementing the kernel in a SNARK DSL (Circom / Noir /
     RISC0) or maturing a Lean→ZK extraction pipeline; neither
     is on the MVP critical path.
  3. **Bisection dispute games.**  The MVP's one-shot fraud
     proof works for log prefixes ≤ 256 entries; bisection is
     mandatory for production-scale logs but is not gating.
  4. **ERC-4337 account abstraction.**  EIP-1271 covers contract
     signers; the UserOperation envelope adds significant
     surface that the MVP does not need.
  5. **Cross-rollup interop.**  `deploymentId` already gives
     cross-rollup replay rejection; the bidirectional cross-
     rollup bridge is a future workstream.
  6. **Native ETH gas market.**  Sequencer-as-paymaster is fine
     for the MVP; an on-chain fee market is a v2 concern.
  7. **Sequencer decentralisation.**  Single-sequencer with
     attestation key is fine for the MVP; rotation /
     leader-election / shared-sequencing is a v2 concern.
  8. **L1 escape hatch (`forceWithdraw`).**  Adds censorship
     resistance but increases L1 gas cost and adds attack
     surface.  Track as a v2 priority.
  9. **`preconditionFalse` and `oracleMisreported` claim
     variants in Solidity.**  Both require non-trivial
     state-replay or oracle-policy machinery in Solidity.  MVP
     ships the three simpler variants; v2 ships the remaining
     two.
  10. **Multi-resource bridges.**  The MVP supports a single
      ResourceId per ERC-20 token (1:1 mapping).  Multi-resource
      bundles (e.g. NFT-style ERC-721) are a v2 concern.
  11. **DAO governance for tunable parameters.**  Per §4.8 all
      safety-critical parameters (`disputeWindowBlocks`,
      `slashRatio`, `quorumThreshold`,
      `maxRedemptionWindowBlocks`, `maxAttestationStaleBlocks`,
      `cooldownBlocks`, `tvlCap`) are `immutable` in the MVP.
      Tuning a parameter requires a new bridge deployment +
      `KnomosisMigration` handoff (§9.5).  A future
      `KnomosisGovernanceParameters` contract that the bridge
      reads parameters from (with the bridge's *reference* to
      the governance contract still `immutable`) is a v2
      concern.  When introduced, governance must satisfy two
      properties to remain compatible with §4.8: (i) the
      bridge cannot be re-pointed at a different governance
      contract without a migration; (ii) parameter changes
      take effect after a per-parameter timelock that is
      *itself* immutable in the governance contract,
      preventing single-block sabotage of safety parameters.
      Until then, the operational discipline is "deploy a new
      bridge to tune."
  12. **Programmable migration policies.**  The MVP's
      `KnomosisMigration` is a single-shot, single-successor
      handoff.  Multi-step migrations (e.g. a chain of three
      successors), conditional migrations (e.g. "activate only
      if a quorum of independent attestors signs"), and
      migration-with-restitution (e.g. "if the predecessor's
      hash binding diverges, mint successor-side tokens to
      affected users") are all v2 concerns.  The
      `KnomosisMigration` interface is sufficient for the v2
      machinery to wrap (it can call `predecessor.attestor()`
      and `successor.migration()` to verify chains), but the
      MVP does not pre-bake any wrapping logic.

## 17. Glossary

  * **CBE** — Knomosis Binary Encoding, the deterministic byte codec
    documented in `LegalKernel/Encoding/CBOR.lean` and
    `docs/abi.md`.
  * **Circuit breaker** — an automatic, state-driven `revert`
    guard at the entry point of a state-shaping function.
    Examples (per §9.1.4): `AttestationStale`,
    `DisputeCooldown`, `TvlCapReached`, `MigrationActivated`.
    Distinct from `Pausable.pause()` (which Knomosis does not
    use): a circuit breaker fires on a deterministic
    public-state predicate; no privileged caller is involved.
  * **Deployment** — a single instantiation of Knomosis's runtime
    against a particular `(chainId, rollupId, attestor key)`
    triple.  Distinguished from other deployments via
    `deploymentId`.
  * **Deployment-id** — `keccak256(chainId ‖ address(this) ‖
    knomosisVersionTag)`, computed in each Solidity contract's
    constructor and woven into every EIP-712 domain
    separator.  Mirror of the Lean §8.8.5 `deploymentId`.
    Cross-deployment replay rejection is structural: a
    successor `KnomosisBridge` deployed via `CREATE2` derives a
    different `address(this)`, hence a different
    `deploymentId`, hence cannot accept predecessor signatures.
  * **Dispute window** — the period after a state-root submission
    during which `KnomosisDisputeVerifier.sol` will accept fraud
    proofs.  *Per-deployment immutable*; default 7 days.
    Tuning requires a new `KnomosisBridge` deployment + a
    `KnomosisMigration` handoff (§9.5).
  * **Grace window** — in `KnomosisMigration.sol`, the minimum
    elapsed-block period between migration construction
    (record signed and on-chain) and migration activation
    (predecessor's circuit breaker trips).  ≥ 30 days,
    enforced by the `MIN_GRACE_WINDOW_BLOCKS` Solidity
    `constant`.
  * **Immutable contract** — a Solidity contract deployed via
    `CREATE2` straight to its final address, with all
    deployment-lifetime parameters declared `immutable`, no
    proxy, no `initialize`, no admin role, and no upgrade
    path.  Per §4.8, every contract in workstream E is
    immutable.  Recovery from genuine code defects uses
    `KnomosisMigration.sol` (§9.5).
  * **Migration** — Knomosis's only mechanism for changing on-chain
    rules post-deployment.  Implemented by `KnomosisMigration.sol`
    (§9.5) as a one-shot, attested handoff from a predecessor
    `KnomosisBridge` to a successor `KnomosisBridge`.  Distinct from
    "upgrade" (which Knomosis does not support): migration
    deploys a *new* immutable contract at a *new* address;
    upgrade would mutate code at an *existing* address.
  * **EIP-712** — the Ethereum standard for typed structured
    data signing (`https://eips.ethereum.org/EIPS/eip-712`).
  * **EIP-1271** — the Ethereum standard for contract signers
    (`https://eips.ethereum.org/EIPS/eip-1271`).
  * **Fraud proof** — an L1-verifiable demonstration that a
    sequencer's published state root is wrong.  Maps onto
    Phase-6's `Disputes.Evidence` machinery.
  * **MVP** — minimum viable product; the deliverable scope of
    this plan.
  * **Optimistic rollup** — a rollup architecture in which state
    transitions are presumed valid unless challenged within a
    dispute window.
  * **Sequencer** — the off-chain process that orders Knomosis
    transactions, applies them via `processSignedAction`, and
    publishes state roots to L1.
  * **Settlement** — the act of finalising an L2 state root on
    L1 such that the L1 contract treats it as canonical.
  * **TCB** — trusted computing base; for Knomosis, the union of
    `LegalKernel/Kernel.lean` and `LegalKernel/RBMapLemmas.lean`.
  * **WU** — work unit, the atomic unit of engineering effort
    in the Genesis Plan / this document.

## 18. Audit-1 changelog

This document was audited against the Knomosis codebase shortly
after its initial commit.  The audit found a number of factual
errors, a substantive design gap, and several security /
correctness improvements.  This section records what changed so
that follow-up readers can distinguish the audited (current) form
from the pre-audit form.

### 18.1 Factual corrections

  * **Two-reviewer rule reference** corrected from
    `§13.6` (Genesis-Plan §13.6 is "Runbook: Adding a New Law")
    to `§14.4` (the actual location of "Review Discipline" in
    `docs/GENESIS_PLAN.md`).  Pre-audit text inherited the bad
    reference from `CLAUDE.md`, which has the same drift.  All
    five occurrences fixed.
  * **`BoundedNat (2^160)` for `EthAddress`** was a type error.
    The existing `BoundedNat` in
    `LegalKernel/Encoding/Encodable.lean:234` is hardcoded
    `< 2^64`, not parameterised.  Replaced with `Fin (2^160)`,
    which:
      * proves `i < 2^160` constructively (no runtime check),
      * has a default `Ord (Fin n)` instance for `Std.TreeMap`
        keying,
      * derives `DecidableEq` automatically.
    `EthAddress.ofBytes : ByteArray → Option EthAddress` is the
    deployment-boundary validator that lifts a 20-byte
    `ByteArray` into the `Fin` type.  §6.1.

### 18.2 Substantive design correction: bridge admissibility

  * **The pre-audit document had no concrete plan for enforcing
    bridge-specific preconditions.**  Three obligations —
    deposit-id uniqueness, registration first-time-only, and
    bridge-actor authorisation — were hand-waved as living "in
    the Action-layer compile path, alongside the existing
    authority-level `apply_admissible_with` machinery", but no
    such machinery exists for them.  `Transition.pre` operates
    on `State`, not `ExtendedState` or `BridgeState`.
  * **Resolution: a new WU C.0 introducing
    `BridgeAdmissibleWith`.**  A new admissibility predicate
    that conjuncts the existing `AdmissibleWith` with three
    bridge-specific clauses.  A new `apply_bridge_admissible_with`
    entry point that consumes the stronger witness and
    additionally updates `BridgeState` via a new
    `applyActionToBridgeState` helper (mirroring the existing
    `applyActionToRegistry`).
  * **Three new theorems** in §12.0:
    `BridgeAdmissibleWith.toAdmissibleWith` (projection),
    `apply_bridge_admissible_with_kernel_agreement` (the new
    entry point agrees with the Phase-3 entry point on the
    pre-existing fields), and `bridge_replay_impossible` (the
    Phase-3 anti-replay theorem lifted via the projection).
  * **§7.0 design rationale** added with the trade-off analysis
    of strategies A/B/C and why C was chosen.
  * **Dependency-DAG and critical-path updates** to put C.0
    before C.1 / C.2 / C.3.  The critical path grows from 12 to
    13 WUs; the wall-clock estimate is unchanged because C.0
    fits in the same engineer-week as C.1.

### 18.3 Mathematical corrections

  * **`ingest` purity** corrected.  The pre-audit signature
    `def ingest : AddressBook → L1Event → AddressBook × Option SignedAction`
    was a type error: producing a `SignedAction` requires the
    bridge actor's private key, which lives in the runtime
    adaptor (Rust), not in Lean.  Replaced with
    `AddressBook → Nonce → L1Event →
       AddressBook × Option UnsignedBridgeAction`,
    where `UnsignedBridgeAction` is a new structure carrying
    `(action, signer, nonce)` for the runtime adaptor to sign
    externally.  Pseudocode added showing how the runtime
    composes the signature.  §6.2.
  * **`ingest_commutes_for_distinct_addresses` weakened** to
    `ingest_lookup_equivalent_for_distinct_addresses`.  The
    pre-audit conclusion `b₂ = b₂'` was *false*: even when two
    L1 events touch distinct addresses, the order of ingestion
    can change which address gets the lower `ActorId` (the first
    arrival is assigned the lower id).  The corrected theorem
    asserts only that the `lookup` function returns
    `some _ / none` consistently, which is the property the
    application actually needs.  §6.2 / §12.8.
  * **§12.13 fourth conjunct removed.**  The pre-audit headline
    theorem had a "first-time-registration discipline" conjunct
    with a `True` placeholder for the witnessing log entry —
    effectively meaningless content.  Removed; the discipline
    is now enforced through the `BridgeAdmissibleWith` predicate
    at every state-advance call site (a strictly stronger form,
    just not surfaced as a state-relational reachability
    invariant).  A note explains why lifting it requires
    log-history witnesses that are not first-order in
    `ExtendedState`.
  * **§7.6 `bridge_supply_account` proof shape** clarified.
    Added the boundedness lemma (`totalWithdrawn` is bounded by
    `totalDeposited + genesis_supply`) that justifies the use of
    `=` over `≤` for `Nat` arithmetic.  The proof of the strict
    form was promoted from a one-line corollary to an explicit
    inductive argument that `totalRewarded` collapses to 0 under
    the law-set restriction.

### 18.4 Security and correctness improvements

  * **EIP-712 envelope structure**.  Pre-audit text had
    `keccak256(typeHash ‖ knomosisSignInput)` — non-conforming to
    EIP-712, which requires field-by-field structured encoding.
    Replaced with a proper `KnomosisAction` typed struct with four
    EIP-712 fields (`actionHash : bytes32`, `signer : uint64`,
    `nonce : uint64`, `deploymentId : bytes32`).  The wallet UI
    now renders structured fields rather than an opaque blob.
    §5.3.
  * **Reentrancy on `withdrawWithProof`**.  Pre-audit text
    only required `ReentrancyGuard` on deposit entry points;
    `withdrawWithProof` also needs it (the recipient can be a
    contract).  Added explicit CEI ordering specification: the
    leaf-redemption flag is set *before* the external transfer.
    §9.1.
  * **Dispute-window-vs-redemption discipline**.  Added an
    explicit deployment-time check that the dispute window is
    no shorter than the maximum redemption delay — preventing
    a successful dispute from leaving the bridge under-collateralised
    after a user has already redeemed.  §9.1.
  * **§15.11 added**: bridge actor private-key compromise risk.
    A four-layer mitigation: HSM custody, post-MVP
    `unbackedDeposit` claim variant, runtime rate-limiting,
    off-chain divergence-watchdog.
  * **§15.12 added**: ERC-20 decimals mismatch.  A per-resource
    decimals map at the deployment level; bridge contract +
    Lean ingestor cross-validate.
  * **§15.13 added**: hash-binding output mismatch
    post-deployment.  Three-layer defence: build-time golden
    assertion, run-time self-test, off-chain divergence-watchdog.

### 18.5 Counts and metadata

  * **Work-unit count**: 28 → 29 (C.0 added).
  * **Theorem-obligation count**: 41 → 44 (three C.0 theorems).
  * **`bridge_deployment_safety` conjuncts**: 4 → 3 (the
    placeholder fourth conjunct dropped).
  * **Critical-path length**: 12 → 13 WUs.

### 18.6 Items investigated but deliberately *not* changed

  * **`Verdict.signers` / `Verdict.sigs` references in §9.2**.
    The Audit-3.5 amendment replaced the parallel-list shape
    with `Verdict.signatures : List (ActorId × Signature)` but
    kept `Verdict.signers` / `Verdict.sigs` as back-compat
    accessors.  The pre-audit text says "parallel signers / sigs
    lists" which is now inaccurate at the field level but
    accurate at the accessor level.  The Solidity-side ABI is
    `(address, bytes)[]`, which matches the canonical pair-list
    form.  Kept the accessor-level wording with a clarifying
    note that the canonical wire form is `signatures`.  §9.2.
  * **`ActorId : UInt64` mismatch with Ethereum's 20-byte
    addresses**.  Already correctly identified as a non-goal
    (§2.2 #1).  The registry-indirection path through
    `AddressBook` (B.1) is the documented MVP work-around;
    `EthAddress` (now `Fin (2^160)`) sits in the AddressBook
    keys, while Knomosis's `ActorId` keys remain `UInt64`.  No
    change.
  * **Single-shot dispute proofs vs bisection**.  Already
    correctly identified as a non-goal (§2.2 #3) with the
    `≤ 256-entry log prefix` cap.  The cap is enforced at the
    `KnomosisDisputeVerifier.sol` deployment-parameter level.  No
    change.
  * **MEV / sequencer ordering**.  Out of MVP scope (§2.2 #7).
    No change; tracked as an item for the v2 sequencer
    decentralisation workstream.
  * **CLAUDE.md drift**.  CLAUDE.md still references `§13.6` for
    the two-reviewer rule.  Fixing CLAUDE.md is out of this
    document's scope; the corrected reference here points at
    the actual location.  Workstream G.2 (CLAUDE.md update) is
    the right place to flag the drift; an entry has been added
    to G.2's deliverable list.

## 19. Audit-2 changelog

Audit-2 was a follow-up correctness pass after Audit-1.  Where
Audit-1 fixed factual errors and one design gap, Audit-2's
charter was to improve the *engineering velocity* of the plan
by decomposing complex WUs into atomic sub-WUs, tightening the
Solidity specifications to follow established best practices,
and identifying remaining mathematical edge cases.

### 19.1 WU decomposition (six parent WUs → twenty-five sub-WUs)

Six WUs were identified as posing concentrated risk and were
decomposed:

  * **C.1** (`BridgeState` + `ExtendedState` field embedding) →
    four sub-WUs (C.1.1 data, C.1.2 field embedding, C.1.3
    pass-through theorem, C.1.4 CBE encoding).  Lets the
    invasive `ExtendedState` field-addition land in isolation
    from the data definitions and the encoding lemmas.
  * **C.6** (Bridge accounting theorem) → five sub-WUs (C.6.1
    sum definitions + foldl-shape lemmas, C.6.2 per-action
    deltas, C.6.3 boundedness lemma, C.6.4 master theorem,
    C.6.5 strict-form corollary).  The biggest decomposition;
    the original was a single ~300-line proof that few engineers
    would feel safe touching in one PR.
  * **D.1** (sparse Merkle tree) → five sub-WUs (D.1.1 data
    structures, D.1.2 verifier definitions, D.1.3 unconditional
    completeness, D.1.4 hash-conditional soundness, D.1.5
    cross-stack goldens).  Cleanly separates the unconditional
    completeness proof from the soundness proof under
    `CollisionFree`.
  * **E.1** (`KnomosisBridge.sol`) → five sub-WUs (E.1.1 deposit,
    E.1.2 state-root submission, E.1.3 withdrawal, E.1.4 pause /
    upgrade, E.1.5 rollback hook).  Each owns a self-contained
    contract surface; can be code-reviewed by a different
    Solidity auditor without spilling context.
  * **E.2** (`KnomosisDisputeVerifier.sol`) → five sub-WUs (E.2.1
    filing + CBE-decode lib, E.2.2 / E.2.3 / E.2.4 per-claim
    verifiers, E.2.5 verdict finalisation).  The single most
    porting-risky WU in the plan; per-claim isolation makes
    cross-stack audit tractable.
  * **F.1** (Cross-stack equivalence corpus) → six sub-WUs (F.1.1
    framework, F.1.2 ECDSA, F.1.3 keccak256, F.1.4 deposit-
    receipt, F.1.5 withdrawal-proof, F.1.6 dispute-evidence).
    Per-fixture isolation; each can land independently.

### 19.2 Mathematical correctness corrections

  * **§7.4 `non_replaceKey_preserves_registry_extends` was
    falsified by `registerIdentity`.**  Pre-Audit-2, the
    theorem said "any non-`replaceKey` action preserves the
    registry pointwise".  But `registerIdentity` is a non-
    `replaceKey` action that *does* mutate the registry.
    Replaced with `registry_unchanged_when_action_does_not_mutate`
    parameterised by an explicit `Action.mutatesRegistry`
    predicate, plus `deposit_preserves_registry` and
    `withdraw_preserves_registry` corollaries.
  * **§7.6 / §C.1.1 `BridgeState.consumed` widened from `Unit`
    to `DepositRecord`.**  Pre-Audit-2, `BridgeState.consumed`
    was a `TreeMap DepositId Unit` — recording only the *set*
    of consumed deposit-ids.  This was insufficient for the
    accounting theorem (`totalDeposited` requires per-deposit
    `(resource, amount)` metadata).  Audit-2 widens to
    `TreeMap DepositId DepositRecord` where `DepositRecord =
    (resource, amount)`.  Documented in C.6.1; the change is
    backward-compatible at the wire level (the encoded width
    grows, frozen forever).
  * **§D.1 `WithdrawalProof.siblings` typed length.**  Pre-
    Audit-2, `siblings : List ByteArray` (variable length;
    runtime check).  Audit-2 uses `Vector ByteArray smtHeight`
    so the 64-element discipline is type-enforced; the
    `constructProof_siblings_length` theorem is now a static
    fact rather than an inductive lemma.
  * **§D.1.4 `verifyProof_sound` proof strategy clarified.**
    Pre-Audit-2 said "structural induction on tree depth".
    The actual proof is *contrapositive* under the collision-
    free hypothesis: any divergence at the leaf level
    propagates to a divergence at the root.  The induction *is*
    on depth; the strategy framing was misleading.

### 19.3 Solidity best-practice improvements

  * **OpenZeppelin library catalogue tightened.**  Added
    `Pausable`, `AccessControl`, `Ownable2Step`, `SafeERC20`,
    `EIP712`, `TransparentUpgradeableProxy`,
    `TimelockController`.  Each library's role is documented;
    contract-level patterns (CEI, role-gating, two-step
    ownership) are explicit per-WU.  *(Subsequently revised
    by the §20 Immutability amendment: `Pausable`,
    `AccessControl`'s mutable-role family, `Ownable2Step`,
    `TransparentUpgradeableProxy`, and `TimelockController`
    are all removed.  See §20.)*
  * **`ATTESTOR_ROLE`, `PAUSER_ROLE`, `DISPUTE_VERIFIER_ROLE`,
    `UPGRADER_ROLE`** introduced; no `DEFAULT_ADMIN_ROLE` (no
    self-elevation possible).  *(Subsequently revised by the
    §20 Immutability amendment: roles become `address public
    immutable` constants, not mutable role-mapping entries.
    See §20.)*
  * **ETH transfer via `Address.sendValue`** (not the
    deprecated `transfer(2300 gas)`).  Reentrancy mitigated
    structurally via `nonReentrant` + CEI ordering, not via
    gas stipend.
  * **EIP-712 domain separator includes `address(this)`**
    (the verifying contract address per EIP-712 §3.1) so
    cross-deployment-replay rejection is structural, not
    just `chainId`-conditioned.
  * **Per-deposit-receipt domain separation**: the
    `receiptHash` derivation includes `block.chainid` and
    `address(this)` (E.1.1) so a deposit on chain A cannot
    be replayed on chain B even if the depositor uses the
    same nonce.
  * **EIP-1271 contract signers handled distinctly** in
    `KnomosisIdentityRegistry.sol` (E.3): two register entry
    points (`registerECDSA` / `registerEIP1271`), with the
    EIP-1271 path probing the contract for the EIP-1271
    interface before accepting.  Re-registration without
    revocation is forbidden (closes the silent-kind-change
    vector).

### 19.4 Critical-path and effort updates

  * **Critical-path leaf-WU count**: 13 → 24 (intra-parent
    sub-WUs run sequentially through C.6.1..C.6.5 and
    D.1.1..D.1.4).
  * **Total leaf-WU count**: 29 → 48.
  * **Total effort estimate**: 14 → 17 engineer-weeks (the +3
    accounts for per-PR review and integration overhead the
    decomposition introduces).
  * **Wall-clock estimate (2 engineers)**: 8 → 9 weeks.
    (The decomposition lets multiple engineers work *within*
    parent WUs, which mostly cancels the longer critical
    path.)
  * **Theorem inventory**: 44 → 68.

### 19.5 Items investigated but deliberately *not* changed

  * **`CollisionFree` as a `Prop` parameter, not an axiom.**
    Already correct in Audit-1; explicitly verified in
    Audit-2 against `D.1.4`'s acceptance criterion that
    `#print axioms verifyProof_sound` returns the canonical
    three.  No change.
  * **Test count target (≈ 120 new tests)**.  After Audit-2's
    decomposition, the per-sub-WU acceptance criteria sum to
    ≈ 180 tests, but many are sub-cases of the original parent
    WU's tests (re-counted because each sub-WU lands a
    separate test module).  The phase-level exit criterion
    has been updated to "≈ 180 tests" implicitly via the
    sub-WU acceptance criteria; no change to §14.2 required.
  * **§9.4 `KnomosisSequencerStake.sol` granularity**.  E.4
    is comparable in size to E.1 / E.2 sub-WUs but functions
    as a single coherent contract; decomposing it would
    break a thin abstraction (deposit / withdraw / slash are
    really one stateful machine).  No change.
  * **§B.* (identity workstream) granularity**.  B.1 / B.2 /
    B.3 are already at the right granularity; further
    decomposition would produce sub-WUs smaller than the
    review overhead they save.  No change.

### 19.6 Counts and metadata

  * Leaf-WU count: 29 → **48**.
  * Theorem-obligation count: 44 → **68**.
  * Critical-path leaf-WU count: 13 → **24**.
  * Effort estimate: 14 → **17** engineer-weeks.
  * Solidity-side per-WU reviewer attention: 2 → **2 per
    sub-WU** (E.2 grew to 5 sub-WUs each individually
    reviewed).
  * `bridge_supply_account_general` proof: ≈ 1 monolithic
    inductive proof (~300 lines) → **5 sub-proofs** (each
    ≤ 30 lines tactics).

## 20. Immutability amendment changelog

The Immutability amendment is a forward-looking architectural
revision (not a retrospective audit) that aligns the Solidity
contracts of workstream E with Knomosis's "law-free, proof-
carrying" kernel philosophy.  Pre-amendment, the contracts
were specified as `TransparentUpgradeableProxy`-fronted, with
a 3-of-5 Safe multisig holding `UPGRADER_ROLE` behind a 7-day
timelock, plus a `Pausable` emergency stop and mutable
`AccessControl` role grants.  Post-amendment, the contracts
are deployed immutably; recovery uses the dispute pipeline
(state-level rollback) and `KnomosisMigration.sol` (attested
handoff to a fresh deployment).

The amendment is *additive at the WU level* (one new sub-WU,
E.5) and *substantive at the design level* (it eliminates an
entire trust-assumption class — §15.8 in the pre-amendment
text — and replaces it with a strictly weaker successor risk).
No theorem in §12 is changed; no Lean module is touched; no
TCB invariant is altered.

### 20.1 Why immutability

The mathematical justification — distilled from the §4.8
design principle:

  1. **Knomosis's central invariant** is "behaviour is mutable
     through proof-carrying state transitions; rules are
     immutable in the kernel."  Upgradeable proxies invert
     this: the *rules* themselves become mutable, behind a
     multisig that becomes the de-facto root of trust.
     The architectural mismatch concentrates trust in a
     single key, contradicting the rest of the system's
     mechanically-verified safety properties.
  2. **The dispute pipeline already provides recovery for
     every dispute-tractable failure mode** (bad sequencer,
     invalid signature, nonce mismatch, double-apply,
     malicious attestor).  Per §15.8 (pre-amendment), the
     `Pausable` emergency stop only addressed failure modes
     the dispute pipeline could not handle.  Of those, the
     dominant case (hash-binding divergence — §15.13) is
     equally well addressed by a `KnomosisMigration` handoff to
     a fresh deployment with the corrected hash binding,
     without requiring an upgrader key.
  3. **The `MIN_GRACE_WINDOW_BLOCKS` constant in
     `KnomosisMigration.sol`** is the on-chain analog of the
     kernel's "TCB never grows" rule (§4.1): certain safety
     parameters are immutable at the bytecode level, not at
     runtime.  A 30-day grace window cannot be weakened by
     any constructor argument or runtime call; even a
     compromised attestor cannot ship a fast migration.
  4. **The bidirectional reference check in the
     `KnomosisMigration` constructor** (`successor.migration()
     == address(this)`) is the on-chain analog of Phase-3's
     `applyActionToRegistry` discipline: the predecessor and
     successor must mutually consent to the handoff via
     immutable references; no party can unilaterally force a
     handoff.

### 20.2 Architectural changes

**Removed from workstream E:**

  * `@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol`
    — no proxies; every contract deployed straight to its
    final address via `CREATE2`.
  * `@openzeppelin/contracts/access/Ownable2Step.sol` — no
    contract has an owner.
  * `@openzeppelin/contracts/governance/TimelockController.sol`
    — no governance surface to time-lock.
  * `@openzeppelin/contracts/security/Pausable.sol` — no
    human-triggered pause; circuit breakers (§9.1.4) replace
    it.
  * `@openzeppelin/contracts/access/AccessControl.sol`'s
    *mutable* role-grant family (`grantRole`, `revokeRole`,
    `_setupRole`).  The role-id `bytes32` namespace is no
    longer used; immutable address constants replace it.
  * The 3-of-5 Safe multisig holding `UPGRADER_ROLE` — does
    not exist.
  * The 7-day timelock between `proposeUpgrade` and
    `executeUpgrade` — does not exist (no upgrade exists).
  * The `pause()` / `unpause()` entry points — do not
    exist; circuit breakers fire on observable predicates
    with no privileged caller.

**Added to workstream E:**

  * Per-contract `bytes32 immutable deploymentId =
    keccak256(chainId ‖ address(this) ‖ knomosisVersionTag)` —
    on-chain mirror of the Lean §8.8.5 `deploymentId`.
  * Per-contract `address immutable {attestor,
    disputeVerifier, sequencerStake, bridge, migration}`
    references replacing the corresponding mutable role
    grants.
  * Four automatic circuit breakers in `KnomosisBridge.sol`
    (§9.1.4): `AttestationStale`, `DisputeCooldown`,
    `TvlCapReached`, `MigrationActivated`.  Each fires on a
    deterministic public-state predicate; no privileged
    caller exists.
  * `KnomosisMigration.sol` (§9.5) — a new contract for
    one-shot attested handoff to a successor `KnomosisBridge`.
    Uses the same EIP-712 wrap as workstream A.3.  Builds on
    Audit-3.2's `AttestedSnapshot` discipline.
  * `MIN_GRACE_WINDOW_BLOCKS = 216_000` Solidity `constant`
    — bytecode-level safety floor for migration grace
    windows (≈ 30 days).
  * Bidirectional reference check in `KnomosisMigration`'s
    constructor: the successor must record this migration's
    address as its `migration` immutable, otherwise
    deployment reverts.

### 20.3 Mathematical correctness preservation

No Lean theorem statement, hypothesis, or proof is altered by
this amendment.  Specifically:

  * §12.0 (`BridgeAdmissibleWith`) is unchanged.  The
    Solidity-side admissibility check now invokes immutable
    `attestor` / `disputeVerifier` references instead of
    role-mapping lookups, but the Lean-side
    `BridgeAdmissibleWith` predicate has no Solidity-side
    counterpart that depends on the role-mapping mechanism.
  * §12.6 (EIP-712 wrap) is unchanged.  The wrap's
    `deploymentId` field is supplied by the immutable
    `deploymentId` constructor-derived value rather than a
    mutable parameter, but the wrap's algebraic shape is
    identical to the pre-amendment text.
  * §12.7 (`AddressBook`) is unchanged.
  * §12.8 (`Ingest`) is unchanged.
  * §12.9 (Bridge-actor authority) — theorems #32 – #36 are
    unchanged.
  * §12.10 (`WithdrawalRoot`) is unchanged.
  * §12.11 (Snapshot finalisation) is unchanged.
  * §12.12 (Bridge accounting) is unchanged.
  * §12.13 (`bridge_deployment_safety`) is unchanged.

The Solidity-side cross-stack equivalence corpus (workstream
F.1) requires an additive update: F.1 now also covers
`KnomosisMigration`'s attestation-loading path
(`extractFinalisedProof` ↔ `KnomosisMigration` constructor).
This is formalised as **WU F.1.7** (`migration_attestation.json`
fixture); see §10.1.7.  The rest of F.1 is unaffected.

### 20.4 Trust-assumption inventory delta

Pre-amendment trust assumptions (§3.3, item 4 in the
original text):

  4. *Solidity contract correctness for the four MVP
     contracts*, **plus** *the upgrader Safe multisig is
     not compromised within the 7-day timelock window*.

Post-amendment trust assumptions (§3.3, items 4 + 6):

  4. *Solidity contract correctness for the five MVP
     contracts (now including `KnomosisMigration`)*.
  6. *The migration attestor key is not compromised
     within the 30-day grace window during which the
     watchdog and users have notice and opportunity to
     react.*

Net change: the upgrader-key trust assumption is *replaced*
by the migration-attestor trust assumption.  The latter is
**strictly weaker** in three measurable senses:

  1. **Blast radius.**  An upgrader-key compromise drains
     locked value atomically (one-transaction rug).  A
     migration-attestor compromise can only freeze new state
     after a 30-day grace window during which users can
     redeem.
  2. **Detection time.**  An upgrader-initiated upgrade is
     visible only at the moment of execution (after the
     7-day timelock).  A malicious migration is visible at
     `KnomosisMigration` *deployment* time (≥ 30 days before
     activation), allowing watchdog and user response.
  3. **User-opt-in requirement.**  An upgrader-initiated
     upgrade transparently mutates the contract users
     interact with.  A migration moves authority to a
     *new* contract address; users opt in by interacting
     with it.  The malicious successor cannot silently
     capture user funds.

### 20.5 Counts and metadata

  * Leaf-WU count: 48 → **49** (added E.5).
  * Theorem-obligation count: 68 → **68** (unchanged; no Lean
    theorem is added by this amendment).
  * Critical-path leaf-WU count: 24 → **24** (unchanged; E.5
    is parallelisable with E.1's sub-WUs).
  * Effort estimate: 17 → **17.5** engineer-weeks (added
    ≈ 0.5 weeks for `KnomosisMigration.sol` plus its forge
    tests, which is below the rounding threshold of the
    original estimate but is recorded explicitly).
  * Solidity-side per-contract count: 4 → **5**
    (`KnomosisMigration` added).
  * Forge-test count delta: ≈ +24 for `KnomosisMigration` +
    ≈ +16 for circuit-breaker boundaries + ≈ +8 negative
    "no-admin-surface" assertions = **≈ +48** vs. the
    pre-amendment baseline.
  * OpenZeppelin library catalogue: 7 imports → **7 imports**
    (the count stays the same; the *composition* changes:
    `ReentrancyGuard`, `SafeERC20`, `IERC20`, `Address`,
    `ECDSA`, `EIP712`, `MessageHashUtils`, `IERC1271` —
    plus `AccessControl` retained only for `bytes32`
    role-id constants used in event topic formatting, not
    for role grants.  `Pausable`, `Ownable2Step`,
    `TransparentUpgradeableProxy`, `TimelockController` are
    removed).
  * Eliminated risk class: §15.8 "Solidity contract upgrade
    key compromise" → replaced with §15.8 "Migration
    mechanism compromise" (strictly weaker per §20.4).

### 20.6 Items investigated but deliberately *not* changed

  * **`KnomosisGovernanceParameters` contract.**  An earlier
    sketch of this amendment proposed adding a separate
    governance contract that the bridge reads tunable
    parameters from (with the bridge's *reference* to
    governance still `immutable`).  Investigation concluded
    that any tunable parameter is safer as a fresh
    deployment + migration than as a governance-readable
    field; per §16 item 11, governance parameters are
    deferred to v2.  All MVP parameters are `immutable`.
  * **Multi-attestor migration.**  The attested-handoff
    mechanism could in principle require quorum signing
    by a set of attestors (mitigating the single-attestor
    compromise risk in §15.8).  Per §16 item 12,
    multi-attestor migration is a v2 concern; the MVP's
    single-attestor migration matches the predecessor's
    single-attestor `submitStateRoot` discipline, so no new
    trust assumption is introduced.
  * **Bytecode verification of immutability at deployment
    time.**  An earlier sketch proposed a deployment-script
    step that statically analyses the deployed bytecode to
    confirm absence of upgrade-related opcodes
    (`DELEGATECALL` to admin-modifiable storage,
    `SELFDESTRUCT`).  Investigation concluded that the
    forge-test "no-admin-surface" assertions in §10.3 (F.3)
    and the per-contract source-level audit are sufficient;
    bytecode verification adds tooling complexity without
    catching a class of bugs the source audit misses.  No
    change.
  * **Frontend handoff automation.**  An earlier sketch
    proposed that a watchdog-fed frontend automatically
    routes user transactions to the successor contract
    after migration activation.  Investigation concluded
    that automatic routing reintroduces a soft trust
    assumption (the watchdog's correctness) and a UX risk
    (silent re-routing during a malicious migration).  The
    discipline is "users explicitly opt in to the new
    contract"; the frontend may *display* the migration
    status but does not act on it.  No change.

## 21. Workstream-F audit changelog

A targeted audit of Workstream F was performed after
Workstream-E audits 1, 2, and 3 had landed.  The audit's
charter was narrow: ensure the cross-stack-equivalence
spec (§10) accurately reflects the Solidity contracts as
deployed, not the pre-audit sketches that originally
informed the spec.  The audit identified *no critical*
defects but found substantial drift across every F sub-WU;
this section records what changed.

The audit examined the source code of:

  * `solidity/src/contracts/KnomosisBridge.sol`
  * `solidity/src/contracts/KnomosisDisputeVerifier.sol`
  * `solidity/src/contracts/KnomosisMigration.sol`
  * `solidity/src/contracts/KnomosisSequencerStake.sol`
  * `solidity/src/contracts/KnomosisIdentityRegistry.sol`
  * `solidity/src/lib/CBEDecode.sol`
  * `solidity/src/lib/SmtVerifier.sol`
  * `solidity/src/lib/KnomosisEip712.sol`
  * `solidity/src/lib/CREATE3.sol`

…and the corresponding Lean-side modules under
`LegalKernel/Bridge/`, `LegalKernel/Encoding/`, and
`LegalKernel/Disputes/`.  Per CLAUDE.md's "do not trust
documentation to accurately describe code" discipline,
every F sub-WU's interface description was checked against
the actual deployed entry points.

### 21.1 F.1.2 (`ecdsa_verify.json`) corrections

  * **Cross-stack target updated.**  Pre-audit, the
    fixture targeted `(pubkey, msg, sig, expected_bool)`
    and assumed the Solidity verifier compares against a
    raw pubkey.  Actual interface
    (`KnomosisDisputeVerifier.checkSignatureInvalid`) uses
    `ECDSA.recover` against a *registered address* looked
    up in `KnomosisIdentityRegistry`; the registered pubkey
    is keccak-derived from that address.  Fixture entries
    now record `expectedSigner` (the L1 address) plus
    `uncompressedPubkey` (cross-checked via
    `keccak256(pubkey)[12:] == expectedSigner`).
  * **Audit-1 `signerHint` path covered.**  The audit-1
    fix to `checkSignatureInvalid` added the
    `signerHint : address` parameter (replacing the pre-
    audit-1 self-derivation stub).  Fixture entries
    exercise the four control-flow branches: registered
    + valid sig (REJECTED), registered + invalid sig
    (UPHELD), unregistered (INCONCLUSIVE),
    `signerHint = address(0)` (INCONCLUSIVE).
  * **High-s rejection covered.**  Per A.1's EIP-2 low-s
    discipline, OZ's `ECDSA.recover` reverts on high-s
    sigs.  The dispute verifier's `try/catch` maps the
    revert to `VERDICT_UPHELD`.  Pre-audit fixtures did
    not exercise this path.
  * **Fixture size + real-vector re-grounding**: 100 → 128
    (random placeholders) → **20 REAL secp256k1 vectors**
    (8 valid + 4 wrong-signer + 4 high-s + 4 malformed).  The
    original random-byte entries could never recover to their
    `expectedSigner`, so the Solidity recovery cross-check was
    gated on `isKeccak256Linked` and SKIPPED under the FNV
    default — i.e. never actually exercised.  Re-grounding to
    fixed real vectors (the canonical `privkey = 1..8`
    addresses) makes the corpus hash-independent, so the
    cross-check now runs **unconditionally** in every build.

### 21.2 F.1.3 (`keccak256.json`) corrections

  * **Hash-binding conditionality documented.**  Lean's
    `Bridge.HashAdaptor.hashBytes` resolves to production
    keccak256 only when the Rust `knomosis-hash-keccak256`
    crate is linked; otherwise FNV-1a-64 fallback (per
    §15.13 / `LegalKernel/Runtime/Hash.lean`).  The
    pre-audit spec did not address the fallback case; the
    cross-check is now skipped (with explicit logging) when
    `Bridge.HashAdaptor.isKeccak256Linked = false`, and
    CI gates the `cross-stack-equivalence` job on the
    production binding being linked.
  * **A.2 KAT cross-check added.**  The fixture now
    embeds the four reference KAT vectors from
    `LegalKernel/Bridge/HashAdaptor.lean` (`kat_empty`,
    `kat_abc`, `kat_helloWorld`, `kat_singleZero`) so a
    future regression in the Rust crate is caught here as
    well.

### 21.3 F.1.4 (`deposit_receipt_hash.json`) corrections

  * **`resourceId` field added (critical).**  Pre-audit
    fixture entries had `(chainid, contract_addr,
    depositor_addr, token_addr, amount, depositor_nonce,
    expected_hash)` — five inputs to the keccak256.
    Actual implementation (`KnomosisBridge._registerDeposit`)
    binds **six** fields:
    `(deploymentId, msg.sender, resourceId, token, amount,
    depositorNonce)`.  The `resourceId` is the missing
    field; without it, fixture-side hashes diverge
    byte-for-byte from on-chain hashes for every ERC-20
    deposit.
  * **`deploymentId` decomposition recorded.**  The fixture
    entries record `deploymentId` directly *plus*
    `deploymentPreimage` (`chainid`, `contractAddr`,
    `knomosisVersionTag`) so an auditor can verify the
    on-chain `keccak256(abi.encode(...))` matches.
  * **L2-side projection specified.**  The pre-audit text
    did not address the projection of the 256-bit L1
    `receiptHash` into Lean's `DepositId : Nat` (with its
    64-bit canonical-encoding bound, per
    `LegalKernel/Bridge/State.lean`).  The fixture now
    records `expectedDepositId` alongside `expectedHash`
    and specifies the reference projection
    (`top-8-BE-bytes`).  Deployments using a different
    projection record their projection identifier in the
    fixture header.
  * **Replay-distinguishability sub-suite added.**  16
    cross-deployment-replay corners (identical user-side
    inputs, distinct deployment metadata) verify the
    `deploymentId` binding produces distinct hashes.
  * **Fixture size**: 100 → **128**.

### 21.4 F.1.5 (`withdrawal_proof.json`) corrections

  * **Variable-size leaf and siblings (audit-2 cross-stack
    format) documented.**  Pre-audit-2 SmtVerifier expected
    `bytes32 leaf` and `bytes32[] siblings`; audit-2
    rewrote it as `bytes leaf` and `bytes[] siblings`
    (variable-size each).  In the *dense-pair* case
    (sequentially-assigned `WithdrawalIds 0` and `1`), the
    leaf-adjacent sibling for id 0 is `leafBytes wd_1`
    ≈ 56 bytes — NOT the typical 32-byte default-hash.
    The pre-audit-2 fixture format would silently fail
    cross-stack equivalence on every dense-pair proof; the
    revised fixture format reflects the audit-2 reality.
  * **Dense-pair coverage required.**  The 64 valid
    entries now include 16 dense-pair cases as a hard
    cross-stack regression class.
  * **Tampering subset added.**  32 tampered entries
    (5 mutator classes: bit-flip leaf, bit-flip sibling,
    sibling swap, wrong index, wrong root) verify that
    `verifyProof` returns `false` on tamper.
  * **Per-entry sanity asserts added.**
    `siblings.length == 64`,
    `keccak256(leafHex) == keccak256(leafBlobHex)`,
    `proof.index == withdrawalId mod 2^smtHeight`.
  * **Fixture size**: 64 → **96** (64 valid + 32 tampered).

### 21.5 F.1.6 (`dispute_evidence.json`) corrections

  * **Audit-1 `signerHint` parameter covered.**  Per the
    audit-1 fix to `signatureInvalid` finalisation,
    `finalizeUpheld` / `finalizeRejected` accept a
    `signerHint : address` argument that the dispute
    verifier threads to `_runClaimVerifier`.  Pre-audit
    fixture spec made no provision for this.
  * **Audit-1 `verdictDigest` derivation documented.**
    Adjudicators sign the contract-derived
    `verdictDigest(disputeId, outcome)`, not a free
    `verdictHash` parameter (the pre-audit-1 design had
    `verdictHash` as an unbound caller-supplied field,
    permitting cross-disputeId signature replay).  Fixture
    entries verify the derived digest matches and exercise
    cross-disputeId / cross-outcome replay rejection.
  * **Audit-1 `MAX_VERDICT_SIGNERS = 64` boundary
    covered.**
  * **Audit-1 `MAX_EVIDENCE_BLOB_BYTES = 100_000`
    boundary covered.**
  * **Audit-1 quorum-deduplication regression covered.**
    Repeated approved signers contribute at most 1 to
    the count regardless of array padding (the audit-1
    forgery-resistance fix).
  * **Audit-3 `_runDoubleApplyFromConcat` shape
    documented.**  The post-audit-3 finalisation path for
    `doubleApply` accepts a concatenated blob with shape
    `(uint64 secondaryLogIndex, array<bytes>(2) of
    impugnedBlob, secondaryBlob)` plus strict
    `count == 2` and `assertFullyConsumed` checks.
    Pre-audit fixture spec did not capture this shape;
    the revised spec includes adversarial sub-cases for
    `count != 2` (`DoubleApplyConcatBadCount`) and trailing
    garbage (`CBEInvalidLength`).
  * **EIP-712 domain pinning documented (audit-1).**  The
    fixture records `actionDomainName = "KnomosisAction"` and
    `verdictDomainName = "KnomosisDisputeVerifier"` so the
    cross-protocol-replay-protection invariant (a per-
    action signature cannot be re-interpreted as a verdict
    signature) is byte-pinned across stacks.
  * **Fixture size**: 96 (32 per claim) → **168**
    (48 per claim + 24 verdict-quorum entries).

### 21.6 F.1.7 (`migration_attestation.json`) added

  * **New sub-WU.**  §20.3 (immutability amendment) noted
    that "F.1 now also covers `KnomosisMigration`'s
    attestation-loading path" but never formalised the
    fixture; §9.5 (E.5) deferred the fixture to "F.1.7 as
    an MVP-blocker for E.5 only".  The fixture is now
    formalised as a sub-WU.
  * **Audit-3 direction asserted.**  The fixture's
    audit-3-direction sub-suite (4 entries) verifies the
    constructor's
    `predecessor.migration() == address(this)` check.
    Two entries with `predecessor.migration() ==
    predicted_addr` (accepted); two with
    `predecessor.migration() == address(0)` (rejected
    with `PredecessorDoesNotReferenceThisMigration`).
    This pins the audit-3 fix at the cross-stack level
    so any future regression is caught.
  * **Cross-stack EIP-712 wrap byte equivalence asserted.**
    Lean's `eip712Wrap` (with the migration struct hash
    form) and Solidity's `_wrapDigest` MUST agree
    byte-for-byte across 32 randomised
    `(predecessor, successor, ...)` tuples.
  * **Fixture size**: **32**.

### 21.7 F.2 (Goldens) corrections

  * **Hash-binding-conditional behaviour added.**  Mirrors
    F.1.3.  Lean-side assertions skip with explicit
    logging when the production keccak256 / secp256k1
    bindings are not linked.  Solidity-side assertions
    run unconditionally.

### 21.8 F.3 (End-to-end testnet deployment) corrections

  * **CREATE3 (not CREATE2) documented.**  The pre-audit
    deployment sketch said "deploy via `CREATE2` with
    deterministic salts ... `CREATE2` address prediction
    so each contract's `immutable` references can be set
    at construction time without circular-dependency
    hacks".  This is mathematically wrong: CREATE2
    addresses depend on the init-code hash, which
    includes the constructor args; the four-way reference
    cycle between bridge / verifier / stake / registry is
    unsolvable under CREATE2.
    Actual implementation uses **CREATE3**
    (`solidity/src/lib/CREATE3.sol`), which deploys via a
    constant-bytecode proxy factory at a CREATE2
    intermediate address; the deployed contract sits at
    the proxy's nonce-1 CREATE address, depending only on
    `(deployer, salt)` — independent of init-code.  The
    revised F.3 spec documents the cycle-breaking
    discipline and the seven-edge reference graph
    (bridge → verifier, bridge → stake,
    verifier → bridge, verifier → stake,
    verifier → registry, stake → verifier,
    stake → bridge).
  * **Constructor cross-checks moved to post-deploy
    `assertConsistent()`.**  The actual implementation
    does NOT verify peer back-references in the
    constructor (because CREATE3 lets contracts deploy
    in any order, but a constructor-time peer call would
    fail when the peer isn't deployed yet).  The
    invariant is closed by post-deploy `assertConsistent()`
    views on `KnomosisDisputeVerifier` and
    `KnomosisSequencerStake`.  F.3's acceptance script
    invokes them.
  * **Audit-3 migration direction clarified.**  The
    pre-audit text said "future `KnomosisMigration`
    deployment ... would target a fresh `KnomosisBridge`
    whose `migration` immutable points back at the new
    `KnomosisMigration` address (E.5 enforces the
    bidirectional reference at construction time)" —
    direction is **inverted** under audit-3.  The
    revised text clarifies: the **predecessor** (the
    bridge being frozen) has its `migration` immutable
    pre-committed; the successor's `migration` is
    independent (typically `address(0)`).
  * **"No migration mechanism for v1" design choice
    explicit.**  Setting v1's `migration = address(0)`
    structurally rules out using the `KnomosisMigration`
    pipeline to migrate AWAY from v1 (the audit-3
    constructor check fails for `migration ==
    address(0)`).  Deployments wanting a future migration
    route must deploy with `migration` set to a
    `CREATE3`-predicted address from day one.
  * **Post-audit event names updated.**
    `StateRootRangeReverted` (audit-2; replaced
    `StateRootReverted`).  `DepositInitiated` carries
    `resourceId` (E.1.1).  `WithdrawalRedeemed` carries
    `resourceId` (E.1.3).
  * **No-admin-surface negative selectors expanded.**
    Includes `proposeUpgrade`, `executeUpgrade` (the
    pre-audit list omitted these).

### 21.9 F.4 (Property-based test extension) corrections

  * **`MonotonicLawSet` consistency error fixed.**
    Pre-audit text said `prop_bridge_account_invariant_holds`
    quantifies over "`MonotonicLawSet` containing only
    `{transfer, deposit, withdraw}`".  This is
    type-impossible: `withdraw_not_monotonic`
    (`LegalKernel/Laws/Withdraw.lean`) explicitly rules
    out an `IsMonotonic` instance for `Laws.withdraw`,
    and `MonotonicLawSet`'s structure invariant requires
    every law to surrender one.
    Revised: the property quantifies over
    `bridgeLawSet : MonotonicLawSet` of §12.13
    (`{transfer, deposit, registerIdentity, replaceKey,
    freezeResource}` at the Action level; at the
    Transition level the registry-mutating actions all
    compile to `Laws.freezeResource 0`, so the underlying
    `List Transition` is shorter), which is the
    documented constructible monotonic law set for bridge
    deployments.
  * **Hash-binding conditionality clarified (NOT
    required).**  An initial draft of this audit
    incorrectly claimed `prop_withdrawal_proof_verifies`
    requires the production keccak256 binding.  Re-checking
    `LegalKernel/Bridge/WithdrawalRoot.lean`, the
    `verifyProof_complete` theorem is *unconditional* in
    `H : ByteArray → ByteArray` — the property runs and
    succeeds under any deterministic hash binding
    (production keccak256 or FNV-1a-64 fallback).  F.4 is
    purely Lean-side; cross-stack equivalence with
    Solidity's keccak256 lives in F.1.5, which DOES
    require the production binding.

### 21.10 Cross-cutting

  * **Depends-on lists updated.**  F.1.6 now depends on
    E.2.5 (verdict finalisation, where the `signerHint`
    and `verdictDigest` cross-stack invariants live) in
    addition to E.2.2 / E.2.3 / E.2.4.

### 21.11 Items investigated but deliberately *not* changed

  * **No Lean theorems are added by this audit.**  The F
    workstream is a *cross-stack equivalence* corpus, not
    a kernel-level proof obligation; the audit's charter
    was to align the F spec with the deployed Solidity
    code.  Theorem-obligation count remains at 68.
  * **Fixture file paths.**  Pre-audit text said fixtures
    live under `solidity/test/CrossCheck/` (Solidity side)
    and `Test/Bridge/CrossCheck/` (Lean side).  Neither
    directory exists yet (the fixtures are deferred per
    F.1's acceptance gating).  The audit did not
    pre-create empty directories — the fixture files
    will land alongside their respective sub-WU's
    deliverable.
  * **Property-test seed reproducibility.**  The audit
    confirmed Audit-3.9's seed-based reproducibility
    discipline applies unchanged to F.4's bridge
    properties.  No change.
  * **CI infrastructure.**  Pre-audit §14.3 lists the
    `forge-test`, `cross-stack-equivalence`, and
    `testnet-acceptance` jobs.  The audit confirmed these
    job names and triggers remain accurate.  No change.

### 21.12 Counts and metadata

  * Leaf-WU count: 49 → **50** (added F.1.7).
  * Theorem-obligation count: 68 → **68** (unchanged; F
    has no Lean theorem obligations).
  * Critical-path leaf-WU count: 24 → **24** (unchanged;
    F.1.7 is parallelisable with F.1.5 / F.1.6).
  * Fixture-input count delta (per-fixture):

    | Fixture | Pre-audit | Post-audit | Delta |
    |---------|-----------|------------|-------|
    | F.1.2 (ECDSA)            | 100        | 128 | +28 |
    | F.1.3 (keccak256)        | 100        | 104 (+4 KATs) | +4 |
    | F.1.4 (deposit receipt)  | 100        | 128 | +28 |
    | F.1.5 (withdrawal proof) | 96 (64 + 32 tampered) | 96 (64 + 32 tampered) | 0  |
    | F.1.6 (dispute evidence) | 96         | 168 | +72 |
    | F.1.7 (migration)        | (new)      | 32  | +32 |
    | **Total**                | **492**    | **656** | **+164** |

    F.1.5's input count is unchanged; the audit revised
    the *content* of the fixture (variable-size leaf and
    siblings; dense-pair coverage required) without
    changing the count.  F.1.6's growth (+72) is the
    largest, reflecting the audit-1 + audit-3 expansion
    of the dispute-finalisation control flow.
  * Cross-stack invariant count: pre-audit silent on
    audit-2 / audit-3 fixes → post-audit pins:

    1. Variable-size leaf and siblings (audit-2 / F.1.5).
    2. Dense-pair leaf-adjacent sibling case (audit-2 /
       F.1.5).
    3. `resourceId` in `receiptHash` (F.1.4).
    4. `signerHint` parameter on `signatureInvalid`
       (audit-1 / F.1.6).
    5. `verdictDigest(disputeId, outcome)` derivation
       (audit-1 / F.1.6).
    6. `MAX_VERDICT_SIGNERS = 64` cap (audit-1 / F.1.6).
    7. `MAX_EVIDENCE_BLOB_BYTES = 100_000` cap (audit-1 /
       F.1.6).
    8. Quorum dedup discipline (audit-1 / F.1.6).
    9. doubleApply `count == 2` + `assertFullyConsumed`
       (audit-3 / F.1.6).
    10. Predecessor pre-commitment direction (audit-3 /
        F.1.7).
    11. CREATE3 cycle-breaking discipline (F.3).
    12. Post-deploy `assertConsistent()` discipline (F.3).
    13. `StateRootRangeReverted` event format (audit-2 /
        F.3).

## 22. Workstream-F implementation audit changelog

A deep audit of the Workstream-F implementation (after the F.1
through F.4 deliverables had landed but before the
`claude/cross-stack-verification-8uwUJ` branch merge) found four
defects that this audit pass closes.  The audit's charter mirrored
§21's: do not trust documentation to accurately describe code;
verify each cross-stack invariant against the deployed contract
*and* the canonical Lean module it claims to mirror.

### 22.1 F.1.7 EIP-712 wrap divergence (CRITICAL — 2 cross-stack mismatches in one fixture)

Pre-fix `LegalKernel/Test/Bridge/CrossCheck/MigrationAttestation.lean`
hand-rolled its own EIP-712 plumbing rather than calling the
canonical `LegalKernel.Bridge.eip712DomainSeparator` already used
elsewhere in the kernel.  The hand-roll silently introduced **two
divergences from `solidity/src/lib/KnomosisEip712.sol`**:

  * **Domain type-string mismatch.**  Lean declared
    ```
    EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
    ```
    (4 fields, `address verifyingContract`).  Solidity declares
    ```
    EIP712Domain(string name,string version,uint256 chainId,uint256 rollupId,bytes verifyingContract)
    ```
    (5 fields, `bytes verifyingContract`).  These differ by:
      * Missing `rollupId` field — every Knomosis deployment uses
        `rollupId` to disambiguate multiple rollups on the same L1
        chain; without it the domain separator collides across
        deployments.
      * `address` vs `bytes` declaration for `verifyingContract` —
        EIP-712 spec applies the "hash-before-encode" rule
        differently for the two type forms; a spec-compliant wallet
        parsing the type string would produce a different domain
        hash.  Audit-1 of Workstream A previously closed an
        identical bug for the action domain; the F.1.7 hand-roll
        re-introduced it for the migration domain.

  * **Migration struct type-string mismatch.**  Lean declared
    `uint256 migrationStateRootLogIdx`; Solidity declares
    `uint64 migrationStateRootLogIdx`.  The on-the-wire
    `abi.encode` bytes are identical for any value < 2^64 (Solidity
    pads all uint types ≤ 256 bits to 32-byte words), but
    `keccak256(typeString)` is sensitive to *every byte* of the
    type string — `uint64` and `uint256` differ in two characters,
    so the typeHash differs, so the struct hash differs, so the
    digest differs.  A spec-compliant wallet signing against the
    Lean type string would produce a different digest than the
    Solidity-deployed verifier expects.

The fix:

  1. **Delegate to the canonical `LegalKernel.Bridge.eip712DomainSeparator`.**
     The hand-rolled `migrationDomainSeparator` is replaced by
     a five-argument call into the kernel's existing canonical
     domain-separator function.  Sharing the function across
     the action / dispute / migration flows eliminates a class
     of cross-stack drift bugs by construction.
  2. **Correct the migration type string** to use `uint64
     migrationStateRootLogIdx`, character-for-character matching
     `solidity/src/lib/KnomosisEip712.sol`'s
     `KNOMOSIS_MIGRATION_TYPE_STRING` constant.
  3. **Extend the fixture entry** with the previously-missing
     `rollupId : Nat` field, and thread it through `mkEntry` and
     all four entry generators.
  4. **Add `domainTypeStringForReference` to the fixture header**
     so the Solidity-side test can pin the byte-level identity
     of the domain type string against its own constant.
  5. **Update the Lean-side type-string-matches test** to
     compare `knomosisMigrationTypeString` against the corrected
     `uint64`-form expected string.

### 22.2 F.1.7 Solidity-side digest cross-check was a tautology

Pre-fix `solidity/test/CrossCheck/MigrationAttestation.t.sol`
contained the following placeholder:

```solidity
bytes32 expected = vm.parseJsonBytes32(raw, ...);
bytes32 actual = KnomosisEip712.digest(ds, sh);
bytes32 sink = expected ^ actual;
assertTrue(sink == sink, "no-op sink");
```

The `assertTrue(sink == sink, ...)` is `true` for every value of
`sink`.  The test "passes" regardless of whether `expected` and
`actual` are byte-equal.  The placeholder was inserted to silence
"unused variable" warnings while a follow-up was scheduled — but
no follow-up landed and the test would have masked the §22.1
divergence (or any future drift in the EIP-712 wrap) silently
through every CI run.

The fix replaces the tautology with a real assertion:

```solidity
assertEq(actual, expected, "digest mismatch");
```

…and adds two new assertions (`test_typeString_matches_solidity_constant`
and `test_domainTypeString_matches_solidity_constant`) that pin
the Lean-side type strings byte-for-byte against the Solidity-
side `KnomosisEip712` constants.  These run unconditionally (no
gating on `isKeccak256Linked`) — the type-string text is hash-
binding-independent, so future drift in either side is caught
under any binding mode.

### 22.3 F.1.2 ECDSA `expectedSigner` parsing

Pre-fix `solidity/test/CrossCheck/EcdsaVerify.t.sol` parsed the
`expectedSigner` JSON field via:

```solidity
address expectedSigner = abi.decode(
    vm.parseJson(raw, string.concat(base, ".expectedSigner")),
    (address)
);
```

This works in some Foundry versions but is non-idiomatic — every
other field in the cross-check suite uses
`vm.parseJsonAddress(raw, path)`.  The double-step
`parseJson + abi.decode` form is also the path most likely to
silently break under a Foundry upgrade or fixture-format change.

Fixed by switching to `vm.parseJsonAddress`.  (This was once a
*latent* defect — the recovery cross-check was gated on
`isKeccak256Linked` and skipped under the FNV default — but the
§21.1 real-vector re-grounding has since removed that gate, so the
`vm.parseJsonAddress` path now runs in every build.)

### 22.4 Solidity build warnings

The pre-fix codebase had 3 unsafe-typecast warnings and 4
state-mutability warnings in F.1's cross-check contracts:

  * **3 unsafe-typecast** (`uint256 → uint64`):
    - `DepositReceiptHash.t.sol` — two casts
      (`uint64(resourceId)`, `uint64(nonce)`) for byte-mirroring
      the on-chain `_registerDeposit`'s parameter types.
    - `MigrationAttestation.t.sol` — one cast
      (`uint64(logIdx)`) forced by the
      `KnomosisEip712.migrationStructHash`'s declared parameter type.

  * **4 state-mutability** (could be `view` / `pure`):
    `Framework.t.sol` smoke tests + an unused
    `_assertFixtureIsValidJson` helper.

The fixes:

  1. **`DepositReceiptHash.t.sol` casts removed entirely.**
     Solidity ABI v2 zero-pads every integer type ≤ 256 bits to a
     32-byte word, so `abi.encode(uint64 r)` and `abi.encode(uint256
     r)` produce byte-identical output for any value < 2^64.  The
     pre-fix cast was unnecessary; passing `resourceId` and
     `nonce` as `uint256` to `abi.encode` produces the same bytes
     as the on-chain call.  Bound checks (`assertLt(value, 1
     << 64)`) remain to catch fixture-corruption early.
  2. **`MigrationAttestation.t.sol` cast retained with explicit
     bound check + lint-disable directive.**  The
     `KnomosisEip712.migrationStructHash` library function takes
     `uint64` as a declared parameter type; the cast is forced.
     The bound check `assertLt(logIdx, 1 << 64)` proves the cast
     is exact at runtime; the
     `forge-lint: disable-next-line(unsafe-typecast)` directive
     is the documented Foundry pattern for "the developer has
     reasoned about this and decided it's safe."  Inline comment
     justifies the choice.
  3. **`Framework.t.sol` mutability warnings closed** by adding
     the appropriate `view` / `pure` modifiers, and the unused
     `_assertFixtureIsValidJson` helper deleted (dead code —
     never called, would have been removed in a future refactor
     anyway).

### 22.5 F.4 property strengthening

Pre-fix `prop_bridge_account_invariant_holds` was effectively a
tautology: the test built a single-step state with one `deposit`
application and asserted `TotalSupply s0 ≤ TotalSupply s1`.  This
exercises one direction of `deposit_isMonotonic` but doesn't
actually test the multi-step reachability invariant the §10.4
spec promises.

Strengthened: the property now drives a 4-step trace exercising
every constructor in `bridgeLawSet` (deposit → transfer →
freezeResource → deposit) and asserts non-decrease at every
intermediate step.  This exercises the typeclass-driven
`MonotonicLawSet` non-decrease promise across multiple law
applications, which is the load-bearing invariant for any
production deployment that wants the §C.6 accounting equation.

### 22.6 Counts and metadata

  * Lean test count: 1100 → **1103** (+3 from new
    self-consistency tests added during audit-pass-2: F.1.4 +
    F.1.7 recipe self-consistency + F.1.7 domain-separator
    size invariant).
  * Solidity test count: 189 → **191** passing, +8 still
    conditionally skipped (replaced 1 tautology with 1 real
    assertion + 2 new type-string-pin tests; net +2 passing).
  * Build warnings: 7 (3 unsafe-typecast + 4 state-mutability) → **0**.
  * No new theorem obligations; TCB unchanged; no new axioms.

### 22.7 Audit-pass-2 follow-up

A second-pass deep audit (after the §22.1–22.6 fixes had
landed) found three additional issues, all closed:

  * **One residual unsafe-typecast warning slipped through.**
    The `forge-lint: disable-next-line(unsafe-typecast)`
    directive was placed on the line immediately preceding a
    *comment*, not the line preceding the cast statement.
    Foundry's lint suppressor applies to the next non-comment
    line, but treats the comment-line as the "next line" in
    the placement check.  Fixed by hoisting the cast to a
    dedicated line so the directive is adjacent.

  * **F.1.7 lacked recipe self-consistency coverage.**  The
    `expectedDigest` field in each entry was stored from
    `mkEntry`'s call to `migrationDomainSeparator + structHash
    + computeDigest`; without a self-consistency test, a
    future code-path change that updated one of those
    functions but forgot to regenerate the fixture would
    leave the on-disk digest disagreeing with the recipe.
    The recipe drift would only surface when someone ran
    `KNOMOSIS_FIXTURES_OVERWRITE=1`.  Closed by adding
    `F.1.7: digest = computeDigest(domSep, structHash) (recipe
    self-consistency)` which recomputes the digest from the
    entry's recorded fields and asserts byte-equality with
    `expectedDigest`.

    Hash-binding-independent — under FNV fallback, both sides
    of the equation use FNV (so equality holds); under
    production keccak256, both sides use keccak256 (so
    equality also holds).  The check is therefore valuable
    in BOTH binding modes.

  * **F.1.4 lacked the same self-consistency coverage.**
    Closed by adding
    `F.1.4: deploymentId + receiptHash recipe self-consistency
    (any binding)`, which recomputes the deploymentId and
    receiptHash for each happy-path corner-native entry and
    asserts byte-equality with the stored values.

  * **F.1.7 domain-separator size invariant.**  Added a
    sanity test that pins the post-canonical-delegation
    `migrationDomainSeparator` output size at exactly 32
    bytes — a typo that swapped to a different function
    would surface here as a size mismatch.
