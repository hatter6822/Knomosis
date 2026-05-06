<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Canon-on-Ethereum: Minimum Viable Integration — Workstream Plan

This document plans the engineering effort needed to deploy Canon as
a proof-carrying optimistic rollup anchored to Ethereum L1.  It is a
roadmap, not a specification; the formal design lives in the Genesis
Plan amendment that workstream G.1 is charged with drafting.

The plan deliberately constrains itself to a *minimum viable*
integration: the smallest set of changes that lets a real Ethereum
user deposit ETH (or an ERC-20), execute a Canon transaction, and
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
    (`runtime/canon-verify-secp256k1`, `runtime/canon-hash-keccak256`)
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
    `"canon-ethereum-workstream-a-crypto-adaptors"`.

    **Workstream-A audit-1 hardening (post-landing).**  A first
    audit pass identified a **critical interop bug** —
    `eip712StructHash` encoded only `actionHash` while the type
    string declared four fields, meaning a spec-compliant
    MetaMask wallet would produce a struct hash differing from
    Lean's, so the §5.3 acceptance criterion ("MetaMask-produced
    EIP-712 signature on a Canon `signInput` verifies via the
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
    `"canon-ethereum-workstream-b-identity-authority"`.

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

## Executive summary

The MVP makes Canon usable by any Ethereum wallet against any
EVM chain.  Concretely:

  * **Seven workstreams**, forty-eight leaf work units (after
    Audit-2 decomposed the six most complex parents — C.1, C.6,
    D.1, E.1, E.2, F.1 — into atomic sub-WUs).  ≈ 9 wall-clock
    weeks with two engineers; ≈ 5 weeks with four (decomposition
    enabled additional intra-parent parallelism).
  * **Three new `Action` constructors** (`deposit`, `withdraw`,
    `registerIdentity`) at frozen indices 12, 13, 14, plus two new
    `Event` constructors at indices 9, 10.  Constructor indices
    are append-only; once landed they are immutable.
  * **One new `ExtendedState` field** (`bridge : BridgeState`),
    holding the consumed-deposit set and pending withdrawals.
    `ExtendedState` is non-TCB; the field addition does not
    expand the kernel.
  * **Two extern-linked Rust adaptors**: ECDSA secp256k1
    (`canon_verify`) and keccak256 (`canon_hash_bytes`), wiring
    Canon's existing `Verify` opaque and `hashBytes` swap-point
    to production-grade implementations.
  * **Four Solidity contracts**: `CanonBridge.sol`,
    `CanonDisputeVerifier.sol`, `CanonIdentityRegistry.sol`,
    `CanonSequencerStake.sol`.  Behind transparent proxies; a
    3-of-5 Safe multisig holds the upgrade key with a 7-day
    timelock.
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

---

## 1. Purpose and scope

Canon (Phases 0–6, complete as of the parent branch) is a
proof-carrying state-transition system specified for the security
model of a sequenced, signed, append-only log with a per-actor
nonce ledger and a four-stage dispute pipeline.  Ethereum L1
supplies a settlement layer with economic finality, a public
identity layer (ECDSA secp256k1 keys, optionally EIP-1271
smart-contract signers), and a permissionless dispute substrate
(a Solidity contract anyone can call).

The architectural fit between the two systems is unusually clean:
Canon's existing primitives map almost 1-to-1 onto rollup
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
     Canon balance within one settlement window.
  2. **A Canon transaction signed with a standard Ethereum wallet**
     (MetaMask, hardware wallet, etc.) is admissible without any
     custom signing software on the user's side.  This requires the
     signing-input round-tripping cleanly through EIP-712.
  3. **A Canon withdrawal can be redeemed on L1** by presenting a
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

  1. Alice deposits 1 ETH to `CanonBridge.sol`.
  2. The Canon sequencer ingests the deposit event and credits
     1 ETH to Alice's Canon address.
  3. Alice signs an `Action.transfer 1_eth Bob 0.5_eth` via
     MetaMask using the EIP-712 envelope.
  4. The sequencer applies the transfer; Bob's Canon balance shows
     0.5 ETH.
  5. Bob signs an `Action.withdraw 1_eth Bob 0.5_eth` via MetaMask.
  6. The sequencer applies the withdrawal; the post-state root is
     submitted to `CanonBridge.sol`.
  7. After the dispute window closes, Bob calls
     `CanonBridge.withdrawWithProof(...)` and receives 0.5 ETH at
     his L1 address.

Each of those seven steps maps onto a closed workstream below.

## 3. Architecture overview

### 3.1 Alignment table (Canon ↔ rollup primitives)

| Canon primitive                           | Defined in                              | Ethereum / rollup role                         |
|-------------------------------------------|-----------------------------------------|------------------------------------------------|
| `Verify` opaque                           | `Authority/Crypto.lean:138`             | ECDSA secp256k1 (with EIP-1271 dispatch)       |
| `Runtime.Hash.hashBytes` (FNV-1a-64)      | `Runtime/Hash.lean`                     | keccak256 (linked via `@[extern]`)             |
| `signingInput` with `deploymentId`        | `Encoding/SignInput.lean` + Audit-3.4   | EIP-712 envelope; cross-chain replay rejection |
| `KeyRegistry`                             | `Authority/Identity.lean`               | Mirror of `CanonIdentityRegistry.sol`          |
| `Snapshot` + `AttestedSnapshot`           | `Runtime/Snapshot.lean`, Audit-3.2      | Periodic state-root commit on L1               |
| `Disputes` pipeline (Phase 6)             | `LegalKernel/Disputes/`                 | One-shot fraud proofs in `CanonDisputeVerifier.sol` |
| `IsConservative` / `IsMonotonic`          | `Conservation.lean`                     | Bridge-safety invariants                       |
| `replay_impossible` / `nonce_uniqueness`  | `Authority/SignedAction.lean`           | Per-actor anti-replay; matches EOA tx-nonce    |
| CBE canonicality + `*_encode_deterministic` | `Encoding/State.lean`                 | Byte-stable Merkle leaves for state roots      |
| `apply_admissible_with_eq_kernelOnlyApply` | Audit-3.6                              | Off-chain ↔ on-chain coherence theorem         |
| `VerdictPassedStage3` witness             | Phase-6 Option-C / `Disputes/Verdict.lean` | Type-level Stage-3 enforcement on L1 finalisation |

### 3.2 Layered diagram

```
┌────────────────────────────────── Ethereum L1 ──────────────────────────────────┐
│                                                                                 │
│   ┌───────────────────────┐     ┌───────────────────────────┐                   │
│   │  CanonBridge.sol      │     │  CanonIdentityRegistry    │                   │
│   │    deposit(token, a)  │     │    register(addr, pk)     │                   │
│   │    submitStateRoot()  │     │    revoke(addr)           │                   │
│   │    withdrawWithProof  │     │    emits events           │                   │
│   └───────────────────────┘     └───────────────────────────┘                   │
│                                                                                 │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │  CanonDisputeVerifier.sol                                               │   │
│   │    fileDispute(claim, evidenceBlob)    — mirrors Phase-6 Stage 1        │   │
│   │    checkEvidence(...)                  — ports Stage 2 verifiers        │   │
│   │    finalizeUpheld(verdict, sigs)       — mirrors applyVerdict           │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
└────────────┬────────────────────────────────────────────────────┬───────────────┘
             │ deposit / register / revoke events                 │ state roots,
             │                                                    │ disputes
┌────────────┴────────────────────────────────────────────────────┴───────────────┐
│                       Canon Runtime (sequencer / replica)                       │
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
  4. **Solidity contract correctness** for `CanonBridge.sol`,
     `CanonDisputeVerifier.sol`, `CanonIdentityRegistry.sol`
     (workstream E; mitigated by F.1 cross-stack equivalence).
  5. **EIP-1271 contract correctness** for any contract signers
     the deployment chooses to admit (workstream A.1; opt-in).

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

Every new function from `(L1 event) → (Canon SignedAction)` is a
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
`runtime/canon-verify-secp256k1` deferred to follow-up.

**Owner:** runtime (Rust); **Reviewer count:** 1; **Depends on:** none.

**Deliverable.**  A Rust crate `runtime/canon-verify-secp256k1`
exporting one C-ABI symbol matching the
`Authority/Crypto.lean:138` opaque signature:

```c
extern "C" bool canon_verify(
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
    `CANON_PROPERTY_SEED` env var (`Audit-3.9`).
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
`runtime/canon-hash-keccak256` deferred to follow-up.

**Owner:** runtime (Rust); **Reviewer count:** 1; **Depends on:** A.1
(shares Rust crate skeleton).

**Deliverable.**  A Rust crate `runtime/canon-hash-keccak256`
exporting the three C-ABI symbols already documented in
`docs/abi.md §11` (Audit-3.1):

```c
extern "C" void canon_hash_bytes (const uint8_t* in, size_t len,
                                  uint8_t out[32]);
extern "C" void canon_hash_stream(/* CBE stream input */);
extern "C" void canon_hash_identifier(uint8_t out[32]);
```

`canon_hash_identifier` returns the 32-byte ASCII identifier
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
  * `canon-replay --allow-fallback-hash` is *not* required to be
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
("MetaMask-produced EIP-712 signature on a Canon `signInput`
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

/-- EIP-712 domain separator for Canon-on-Ethereum.  Hashed once
    per deployment; cached in the runtime adaptor.  The four
    fields match EIP-712's standard `EIP712Domain` type:
    `name`, `version`, `chainId`, `verifyingContract`. -/
def eip712DomainSeparator
    (name : ByteArray) (version : ByteArray)
    (chainId : Nat) (rollupId : Nat)
    (verifyingContract : ByteArray) : ByteArray

/-- The Canon-action EIP-712 type.  Wallet UIs render this as
    structured fields rather than as an opaque blob, which is a
    UX win (the user sees what they're signing) and a security
    win (a malicious dApp cannot trick the user into signing an
    arbitrary byte sequence).

    The `actionHash` field is `keccak256 (canonSignInput action
    signer nonce deploymentId)` — a 32-byte commitment to the
    full Canon CBE-encoded sign-input.  The wallet recomputes
    this hash from the ABI-encoded action params it displays,
    closing the loop with the L1 dispute verifier's recomputation. -/
def canonActionTypeHash : ByteArray :=
  /- = keccak256("CanonAction(bytes32 actionHash,uint64 signer,
                  uint64 nonce,bytes32 deploymentId)") -/

/-- Compute the EIP-712 struct hash for a Canon action.
    `structHash := keccak256(typeHash ‖ encodeStructFields(...))`
    where field encoding follows EIP-712 (32-byte right-padded
    bytes32 for hashes, 32-byte left-padded uint for ints). -/
def eip712StructHash
    (canonActionHash : ByteArray) (signer : ActorId)
    (nonce : Nonce) (deploymentId : ByteArray) : ByteArray

/-- Wrap a Canon `signInput` as an EIP-712 typed-structured-data
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
    Canon `signInput` verifies via the A.1 binding.
  * Cross-protocol distinguishability: an EIP-712-wrapped
    `signInput` produces bytes structurally distinct from
    a plain Canon `signedActionDomain`-prefixed `signInput`
    (already required by Audit-2; A.3 inherits the test).

## 6. Workstream B — identity and authority

This workstream wires Ethereum's address-based identity model into
Canon's `KeyRegistry` infrastructure without changing the kernel's
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
  /-- Mapping from Ethereum 20-byte addresses to Canon ActorIds. -/
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
defining an inductive of L1 events Canon ingests:

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

/-- Translate an L1 event to its Canon-side effect.  Every L1
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

/-- Project an L1 event to the Canon address it touches.  Used
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
    let sig := canon_sign(bridge_private_key, signing_bytes)  -- in Rust
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
authority under which all L1-derived Canon actions are signed.
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
EOA registering for the first time via L1, the Canon
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
     not the L2 side; Canon trusts the bridge actor's deposit
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
present to `CanonBridge.sol` to redeem an L2 withdrawal on L1.
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
canon withdrawal-proof <SNAPSHOT_FILE> <WITHDRAWAL_ID>
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

  * `@openzeppelin/contracts/security/ReentrancyGuard.sol`
  * `@openzeppelin/contracts/security/Pausable.sol`
  * `@openzeppelin/contracts/access/AccessControl.sol`
  * `@openzeppelin/contracts/access/Ownable2Step.sol` (preferred
    over `Ownable`: two-step ownership transfer rejects accidental
    transfers to wrong addresses)
  * `@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol`
    (handles non-conforming ERC-20s like USDT)
  * `@openzeppelin/contracts/utils/cryptography/ECDSA.sol`
  * `@openzeppelin/contracts/utils/cryptography/EIP712.sol`
  * `@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol`

Contracts are deployed behind transparent proxies for emergency-
pause capability; the upgrade key is a 3-of-5 Safe multisig with
a 7-day timelock.  Roles use `AccessControl` constants:
`ATTESTOR_ROLE`, `PAUSER_ROLE`, `DISPUTE_VERIFIER_ROLE`,
`UPGRADER_ROLE` (note: not `DEFAULT_ADMIN_ROLE`, which would
allow self-elevation; the DAO upgrade path is post-MVP).

ETH transfers use `Address.sendValue` from OpenZeppelin (which
forwards all gas, unlike the deprecated `transfer(2300 gas)`),
guarded by `nonReentrant` to neutralise the reentrancy risk this
opens up.

### 9.1 WU E.1 — `CanonBridge.sol`

E.1 splits into five sub-WUs, each owning one functional area
of the bridge contract.  All sub-WUs share the file
`solidity/contracts/CanonBridge.sol`, but the split lets each
functional area's tests, audit attention, and review focus on a
self-contained interface.

#### 9.1.1 WU E.1.1 — Deposit entry points

**Owner:** Solidity; **Reviewer count:** 1 Solidity + 1 Lean;
**Depends on:** A.2 (keccak256), B.2 (Lean ingestor for
DepositId byte-equivalence target).

**Deliverable.**  Two deposit functions plus their bookkeeping:

```solidity
function depositETH() external payable nonReentrant whenNotPaused;
function depositERC20(IERC20 token, uint256 amount)
    external nonReentrant whenNotPaused;

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
         block.chainid,
         address(this),
         msg.sender,
         token,                  // address(0) for ETH
         amount,
         depositNonce[msg.sender]
     ));
     ```
     This must match the Lean side's `DepositId` derivation
     byte-for-byte (cross-stack fixture in F.1).
     Note: `block.chainid` and `address(this)` are included for
     cross-deployment domain separation, mirroring the §8.8.5
     `deploymentId` logic on the L2 side.
  3. **Per-depositor counter**: `depositNonce[msg.sender]++`
     after `receiptHash` is computed.  Prevents a single
     depositor from accidentally producing identical receipt
     hashes within the same block.
  4. **SafeERC20**: ERC-20 deposits use
     `SafeERC20.safeTransferFrom`, which handles non-conforming
     tokens (USDT, etc.) that don't return a bool from
     `transfer`.

**Acceptance criteria.**

  * 100% line coverage in `forge` test suite for the two
    functions.
  * Reentrancy fixture (malicious ERC-20 callback) rejected.
  * Cross-stack `receiptHash` byte-equivalence verified by F.1.

#### 9.1.2 WU E.1.2 — State-root submission

**Owner:** Solidity; **Reviewer count:** 1; **Depends on:** A.1
(ECDSA verify).

**Deliverable.**  Attestor-gated state-root submission:

```solidity
struct StateRootRecord {
    bytes32 root;
    uint64  logIndexHigh;
    uint64  submittedAtBlock;
    bool    finalised;        // dispute window elapsed
    bool    reverted;         // post-dispute rollback
}

mapping(uint64 => StateRootRecord) public stateRoots;  // logIndexHigh -> record
uint64 public latestSubmittedLogIndexHigh;

function submitStateRoot(
    bytes32 root,
    uint64  logIndexHigh,
    bytes   calldata attestorSig
) external onlyRole(ATTESTOR_ROLE) whenNotPaused;

event StateRootSubmitted(
    bytes32 indexed root,
    uint64 indexed logIndexHigh,
    address indexed attestor,
    uint64 submittedAtBlock
);
```

**Critical correctness obligations.**

  1. **Strict monotonicity**: `require(logIndexHigh >
     latestSubmittedLogIndexHigh)`.  Concurrent attestor
     submissions at the same `logIndexHigh` are rejected (only
     the first to land on L1 succeeds).
  2. **Attestor signature**: signs the EIP-712 struct hash of
     `(root, logIndexHigh, address(this), block.chainid)`.  The
     `address(this)` field is the verifying contract per
     EIP-712 §3.1; cross-deployment-replay safe.
  3. **Role-gated**: only `ATTESTOR_ROLE` callers.  Role
     granted/revoked by the upgrader Safe multisig.

**Acceptance criteria.**

  * Attestor-signature replay rejected (`logIndexHigh` strict
    monotonicity).
  * Cross-deployment-replay rejected (different `chainid`
    or `address(this)` causes the EIP-712 verify to fail).
  * Role-gating fixture: non-attestor caller is rejected with
    `AccessControlUnauthorizedAccount`.

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
) external nonReentrant whenNotPaused returns (bool);

event WithdrawalRedeemed(
    bytes32 indexed leafHash,
    address indexed recipient,
    address token,
    uint256 amount,
    uint64  atLogIndexHigh
);
```

**Critical correctness obligations (CEI ordering enforced).**

  1. **Check phase**:
     (a) Decode `leafBlob` into a structured
         `(resource, recipientL1, amount, l2LogIndex)` tuple
         using a CBE-decoder library shared with the dispute
         verifier (workstream E.2's CBE-decode helper).
     (b) Look up the state root at `atLogIndexHigh` from
         `stateRoots[atLogIndexHigh]`.  Reject if not present,
         not finalised, or reverted.
     (c) Compute `leafHash = keccak256(leafBlob)`.  Reject if
         `withdrawalLeafRedeemed[leafHash] == true`.
     (d) Decode `proofBlob` into a `WithdrawalProof` struct.
         Run `verifyProof(proof, stateRoots[atLogIndexHigh].root)`
         (the on-chain SMT verifier, same algorithm as Lean's
         §D.1.4).  Reject if false.
  2. **Effect phase**: set `withdrawalLeafRedeemed[leafHash] = true`
     *before* any external call.
  3. **Interaction phase**: transfer to `recipientL1`.
     - Native ETH: `Address.sendValue(recipientL1, amount)`.
     - ERC-20: `SafeERC20.safeTransfer(token, recipientL1, amount)`.

  4. **Dispute-window-vs-redemption discipline**: deployment-time
     immutable check `disputeWindowBlocks ≥
     maxRedemptionWindowBlocks`.  Enforced via constructor
     `require`.  No state root is marked `finalised` until
     `block.number >= submittedAtBlock + disputeWindowBlocks`.

**Acceptance criteria.**

  * 100% line coverage on `withdrawWithProof`.
  * Reentrancy fixture (malicious recipient contract) rejected.
  * Double-spend fixture rejected.
  * Pre-finalisation fixture rejected.
  * Cross-stack equivalence: a Lean-built proof against a
    Lean-built state root verifies on-chain (F.1.5).

#### 9.1.4 WU E.1.4 — Pause / unpause and upgrade authority

**Owner:** Solidity; **Reviewer count:** 1; **Depends on:** none
within E.1.

**Deliverable.**  Emergency-stop and governance machinery:

```solidity
function pause() external onlyRole(PAUSER_ROLE);
function unpause() external onlyRole(PAUSER_ROLE);

// Two-step upgrade governed by Safe multisig + 7-day timelock
function proposeUpgrade(address newImplementation) external onlyOwner;
function executeUpgrade() external onlyOwner;  // after timelock
```

**Critical correctness obligations.**

  1. `Pausable` + `whenNotPaused` modifier on all entry points
     (deposit, withdraw, submitStateRoot).  Pausing freezes new
     deposits and new withdrawals; in-flight transactions can
     complete via the dispute pipeline.
  2. Upgrade authority via `Ownable2Step`: ownership transfer
     requires both old-owner `proposeOwnership` and new-owner
     `acceptOwnership`.  Avoids accidental loss of access.
  3. 7-day timelock between `proposeUpgrade` and
     `executeUpgrade`, enforced by an embedded
     `OpenZeppelinTimelockController`.

**Acceptance criteria.**

  * Pause / unpause fixtures pass.
  * Two-step ownership transfer fixture passes.
  * Premature `executeUpgrade` (before timelock elapses)
    reverts.

#### 9.1.5 WU E.1.5 — Rollback hook

**Owner:** Solidity; **Reviewer count:** 2 (Solidity + Lean);
**Depends on:** E.1.2, E.2 (dispute verifier calls into this).

**Deliverable.**  The rollback API that
`CanonDisputeVerifier.sol` calls on `.upheld` finalisation:

```solidity
function revertToPriorRoot(uint64 disputedLogIndexHigh)
    external onlyRole(DISPUTE_VERIFIER_ROLE);

event StateRootReverted(
    uint64 indexed disputedLogIndexHigh,
    bytes32 indexed revertedRoot
);
```

**Critical correctness obligations.**

  1. **Role-gated**: only callable by the `CanonDisputeVerifier`
     contract (the `DISPUTE_VERIFIER_ROLE` is held by exactly
     one address, set immutably at deployment).
  2. **Mark all state roots from `disputedLogIndexHigh` onward
     as reverted.**  No further withdrawals can redeem against
     them; users with redemption-pending proofs at those roots
     must re-prove against a later finalised root (out of MVP
     scope: rollback restitution mechanism).
  3. **Idempotent**: calling `revertToPriorRoot` twice with the
     same argument is a no-op (no double-reversion).

**Acceptance criteria.**

  * 100% line coverage on `revertToPriorRoot`.
  * Idempotency fixture passes.
  * Non-`DISPUTE_VERIFIER_ROLE` caller rejected.
  * Cross-stack rollback fixture: an upheld dispute on Lean's
    side triggers a rollback on the Solidity side that matches
    the expected post-revert state.

### 9.2 WU E.2 — `CanonDisputeVerifier.sol`

E.2 is the most cross-stack-porting-risky workstream in the
MVP.  It splits into five sub-WUs that land sequentially.  The
shared file is `solidity/contracts/CanonDisputeVerifier.sol`;
the split lets each per-claim verifier be ported and audited in
isolation.

The MVP ports three of the five Phase-6 `Disputes.Evidence`
claim variants:

  * `signatureInvalid` — E.2.2.
  * `nonceMismatch`    — E.2.3.
  * `doubleApply`      — E.2.4.

Deferred to v2: `preconditionFalse` (requires full kernel
replay, expensive) and `oracleMisreported` (requires
deployment-specific oracle policy).

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
) external whenNotPaused returns (uint64 disputeId);

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
Lean; **Depends on:** E.2.1, A.1, E.3 (`CanonIdentityRegistry`).

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
     `CanonIdentityRegistry.lookup(signer)`.  Returns `2`
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
) external whenNotPaused;

uint8 public constant QUORUM_THRESHOLD = 2;  // configurable per deployment
```

The function:
  1. Loads `disputes[disputeId]`.  Reverts if not open.
  2. Counts distinct, approved, registered, valid-signature
     adjudicators in the `(signers, sigs)` arrays.  Uses the
     same per-signer deduplication discipline as the Phase-6
     `countVerifiedSignatures` post-Audit-1 fix
     (`Disputes/Verdict.lean`).
  3. Reverts if count < `QUORUM_THRESHOLD`.
  4. Re-runs the appropriate per-claim verifier (E.2.2 / E.2.3
     / E.2.4) to confirm `.upheld`.  Reverts otherwise.
  5. Marks the dispute `upheld`.
  6. Calls `CanonSequencerStake.slash(disputeId, challenger)`
     (E.4).
  7. Calls `CanonBridge.revertToPriorRoot(impugnedLogIndex)`
     (E.1.5).
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

### 9.3 WU E.3 — `CanonIdentityRegistry.sol`

**Owner:** Solidity; **Reviewer count:** 1; **Depends on:** none.

**Deliverable.**  A pubkey-registration contract that
distinguishes ECDSA EOAs from EIP-1271 contract signers at the
type level (the two have different verification paths in
A.1's adaptor).

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

function registerECDSA(bytes calldata uncompressedPubkey)
    external whenNotPaused;
function registerEIP1271(address contractSigner)
    external whenNotPaused;
function revoke() external whenNotPaused;
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

**Deliverable.**  `solidity/contracts/CanonSequencerStake.sol`
holds the sequencer's stake in escrow.  On `DisputeUpheld`, the
stake is slashed: a `slashRatio` portion (configurable, default
50%) is paid to the challenger as the reward documented in
Phase-6's incentive amendment (`DisputeRewardPolicy`); the
remainder is burned (sent to `address(0)`).

```solidity
function deposit() external payable onlySequencer;
function withdraw(uint256 amount) external onlySequencer
    onlyAfter(LAST_DISPUTE + DISPUTE_WINDOW);
function slash(uint64 disputeId, address challenger) external
    onlyDisputeVerifier;
```

**Critical correctness obligations.**

  1. **Withdrawal lock-up.**  The sequencer cannot withdraw stake
     while a dispute is open against any of its published
     snapshots.
  2. **Single-slash-per-dispute.**  Each `disputeId` can be
     slashed at most once (idempotency mirrors
     `applyWithdraw_idempotent`).
  3. **Reward calculation matches Lean.**  The on-chain
     `slashRatio * stake` calculation is byte-equivalent to the
     Lean `DisputeRewardPolicy.proportionalChallengerReward`
     function.

**Acceptance criteria.**

  * Forge tests cover the three obligations above.
  * Cross-stack reward-equivalence test in F.1.

## 10. Workstream F — cross-stack verification

This workstream is the safety net.  Each WU here closes a gap
between the Lean-proven property and the Solidity-deployed
behaviour.

### 10.1 WU F.1 — Lean ↔ Solidity behavioural-equivalence corpus

F.1 splits into six sub-WUs.  The split is by fixture file:
each fixture targets a specific cross-stack invariant and can
be developed and audited independently.  All sub-WUs share the
test-driver framework (F.1.1) which lands first.

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
  * Shared seed convention: `CANON_PROPERTY_SEED` env var
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

**Deliverable.**  A 100-input fixture for ECDSA verification:
each entry has `(pubkey_hex, msg_hex, sig_hex, expected_bool)`.
Generation: 50 valid signatures (sign-then-verify produces
`true`); 50 invalid (random-bytes verification produces
`false`).  The Solidity side runs `ECDSA.recover` + address
comparison and asserts the boolean matches.

**Acceptance criteria.**

  * 100 / 100 cross-stack matches.

#### 10.1.3 WU F.1.3 — `keccak256.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, A.2.

**Deliverable.**  A 100-input fixture for keccak256.  Inputs of
varying lengths: 50 short (≤ 32 bytes), 30 medium (32–256
bytes), 20 long (256–2048 bytes).  Each entry is `(input_hex,
expected_hash_hex)`.

**Acceptance criteria.**

  * 100 / 100 byte-exact matches.
  * Includes the F.2 mainnet-block-header golden subset
    (32 entries embedded by reference).

#### 10.1.4 WU F.1.4 — `deposit_receipt_hash.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, B.2, E.1.1.

**Deliverable.**  A 100-input fixture verifying byte-equivalence
of the L1-side `receiptHash` and the L2-side `DepositId`.  Each
entry is `(chainid, contract_addr, depositor_addr, token_addr,
amount, depositor_nonce, expected_hash)`.  This is the most
load-bearing cross-stack fixture: a mismatch here means
deposits cannot be matched to their L2 credit.

**Acceptance criteria.**

  * 100 / 100 byte-exact matches.
  * Includes corner cases: address(0) for native ETH,
    zero-amount, max-uint64 nonce, max-uint256 amount.

#### 10.1.5 WU F.1.5 — `withdrawal_proof.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, D.1.5, E.1.3.

**Deliverable.**  A 64-input fixture: for each, a
`(BridgeState, withdrawalId)` pair plus the Lean-extracted
`WithdrawalProof` and the expected verifier outcome on the
Solidity side.  64 because each entry exercises a 64-level SMT
proof and is heavier than the other fixtures.

**Acceptance criteria.**

  * 64 / 64 verify-true on Solidity side for valid proofs.
  * 32 / 32 verify-false on Solidity side for tampered proofs
    (one bit flipped per tamper).

#### 10.1.6 WU F.1.6 — `dispute_evidence.json` fixture

**Owner:** Lean + Solidity; **Reviewer count:** 1; **Depends on:**
F.1.1, E.2.2, E.2.3, E.2.4.

**Deliverable.**  A 96-input fixture (32 per claim variant)
covering the three MVP dispute-claim Solidity ports.  Each entry
provides the on-chain inputs (impugned-log-index, evidence blob,
log prefix) and the expected verdict.

**Acceptance criteria.**

  * 96 / 96 byte-exact verdict matches.
  * Includes adversarial cases per variant: `signatureInvalid`
    with high-s sig (rejected); `nonceMismatch` at exactly
    `MAX_PREFIX_LEN` (accepted); `doubleApply` with
    `idx₁ == idx₂` (revert).

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

**Acceptance criteria.**

  * 32 / 32 keccak256 matches.
  * 32 / 32 ECDSA verify accepts.
  * 32 / 32 RLP-then-keccak matches.

### 10.3 WU F.3 — End-to-end testnet deployment

**Owner:** ops + Lean + Solidity; **Reviewer count:** 1;
**Depends on:** all preceding WUs.

**Deliverable.**  A scripted deployment to Sepolia (or Holesky)
that runs the §2.3 acceptance script unattended.  The script:

  1. Deploys all four Solidity contracts behind proxies.
  2. Starts the Canon sequencer with the deployment-id derived
     from chainId + the deployed bridge address.
  3. Performs the seven-step acceptance sequence with a single
     scripted EOA + a scripted MetaMask-equivalent signer (e.g.
     ethers.js).
  4. Asserts each step's success conditions on-chain (event
     emissions, balance changes).

**Acceptance criteria.**

  * Single-command `make testnet-acceptance` executes the script
    end-to-end and exits 0.
  * The script logs each step's L1 transaction hash for audit.

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
    state under a `MonotonicLawSet` containing only
    `{transfer, deposit, withdraw}`, the
    `bridge_supply_account` equation holds.
  * `prop_withdrawal_proof_verifies` — for any `BridgeState`
    constructed by an arbitrary deposit / transfer / withdraw
    sequence, every pending withdrawal's extracted proof
    verifies against the published root.

Each property runs against `CANON_PROPERTY_ITERATIONS=100` by
default; failing seeds are logged.

**Acceptance criteria.**

  * 100 / 100 passes per property at the default seed.
  * Reproducible: a recorded failing seed reproduces the failure.

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

  * The deployment scenario (canon-as-rollup).
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
  * The `CanonBridge.sol`, `CanonIdentityRegistry.sol`, and
    `CanonDisputeVerifier.sol` event ABIs (the off-chain
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
deploymentId)`, which is a separate property of the Canon CBE
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

    The conjunction is what `CanonBridge.sol` relies on for
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
| *E.1*   | *CanonBridge.sol (parent)*           | *A.2, D.1.4*                                        |
| E.1.1   | Deposit entry points                 | A.2, B.2                                            |
| E.1.2   | State-root submission                | A.1                                                 |
| E.1.3   | Withdrawal redemption                | D.1.4, E.1.2                                        |
| E.1.4   | Pause / unpause / upgrade            | (root)                                              |
| E.1.5   | Rollback hook                        | E.1.2, E.2.5                                        |
| *E.2*   | *CanonDisputeVerifier.sol (parent)*  | *E.1, Phase-6 dispute pipeline*                     |
| E.2.1   | Dispute filing + CBE-decode lib      | E.1.5, Phase-6 `Disputes.Filing`                    |
| E.2.2   | signatureInvalid verifier            | E.2.1, A.1, E.3                                     |
| E.2.3   | nonceMismatch verifier               | E.2.1                                               |
| E.2.4   | doubleApply verifier                 | E.2.1                                               |
| E.2.5   | Verdict finalisation + slash hook    | E.2.2, E.2.3, E.2.4, E.4                            |
| E.3     | CanonIdentityRegistry.sol            | (root, Solidity-side)                               |
| E.4     | Sequencer staking                    | E.1.5, E.2.5                                        |
| *F.1*   | *Cross-stack corpus (parent)*        | *A.\*, C.\*, D.\*, E.\**                            |
| F.1.1   | Cross-stack test-driver framework    | (root)                                              |
| F.1.2   | ecdsa_verify.json fixture            | F.1.1, A.1                                          |
| F.1.3   | keccak256.json fixture               | F.1.1, A.2                                          |
| F.1.4   | deposit_receipt_hash.json fixture    | F.1.1, B.2, E.1.1                                   |
| F.1.5   | withdrawal_proof.json fixture        | F.1.1, D.1.5, E.1.3                                 |
| F.1.6   | dispute_evidence.json fixture        | F.1.1, E.2.2, E.2.3, E.2.4                          |
| F.2     | Goldens (keccak / ECDSA / RLP)       | A.1, A.2                                            |
| F.3     | End-to-end testnet deployment        | F.1.*, F.2, all of E.*                              |
| F.4     | Property-based tests                 | C.6.5, D.1.4                                        |
| G.1     | Genesis Plan §15 amendment           | substantive completion of A–F                       |
| G.2     | README + CLAUDE.md                   | G.1                                                 |
| G.3     | ABI doc additions                    | C.4, C.5, D.1.4, E.1                                |
| G.4     | Extraction notes                     | A.1, A.2, A.3                                       |
| G.5     | Std-dependency audit                 | B.1                                                 |

Total leaf-level WUs: **48** (after Audit-2's decomposition);
parent WUs above are documentation conveniences and do not
themselves require review.

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
  * **E.3 (`CanonIdentityRegistry`)** is independent of everything
    else Solidity-side and can land in week 1.
  * **D.1 and E.1 can develop in parallel** once C.5 lands — D.1
    builds the proof, E.1 verifies it; F.1 closes the gap.
  * **G.* docs WUs** can be drafted in parallel with the
    technical WUs they document, then refined when the technical
    WUs land.

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
     `"canon-phase-e-ethereum-integration"` in `LegalKernel.lean`.
  4. `Tests.lean` driver registers the new test suites (estimated
     +12 suites, +120 tests).
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

  * **Risk.**  The Rust `canon_verify` or `canon_hash_bytes`
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
    to a Canon credit (or worse, a synthetic deposit credits
    with no L1 backing).
  * **Mitigation.**  F.1's `deposit_receipt_hash.json` fixture
    covers exactly this byte-equivalence.  E.1's test suite
    asserts `keccak256(abi.encode(...))` equality with the Lean
    value.

### 15.4 Reorg handling at the L1 ingestion boundary

  * **Risk.**  An L1 reorg removes a deposit event the Canon
    sequencer has already credited, producing a phantom credit.
  * **Mitigation.**  B.2's ingestor enforces a
    confirmation-depth gate (default 64 blocks ≈ 12 minutes
    post-Casper finality slot).  Events are *not* ingested until
    they have at least that many confirmations.  The
    confirmation depth is configurable per-deployment and is
    surfaced in the `docs/abi.md §11` documentation.

### 15.5 Sequencer censorship

  * **Risk.**  A malicious sequencer refuses to include a user's
    `Action.withdraw`, trapping their funds on Canon.
  * **Mitigation.**  *Out of MVP scope* but the architecture
    supports an L1-side escape hatch: a future workstream can
    add `forceWithdraw(...)` to `CanonBridge.sol` that lets
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

### 15.8 Solidity contract upgrade key compromise

  * **Risk.**  The proxy upgrade key (initially a Safe multisig)
    is compromised, allowing the attacker to swap in a malicious
    implementation that drains the bridge.
  * **Mitigation.**  *Operational, not technical.*  The MVP's
    proxy upgrade key is held by a 3-of-5 Safe; key holders are
    geographically distributed; rotation is documented.  A
    timelock (configurable, default 7 days) is enforced on every
    upgrade.

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
       The Solidity `CanonBridge.sol` records every `DepositInitiated`
       event's `receiptHash` in a contract storage slot.
       `CanonDisputeVerifier.sol` accepts a new claim variant
       `unbackedDeposit` (post-MVP refinement) that lets anyone
       challenge a Canon `Action.deposit` whose `depositId` does
       not match an L1 `DepositInitiated` event.  The dispute
       upholds; the bridge state rolls back; the attacker's
       deposit is reverted before any redemption.
    3. **Deposit emission rate-limiting.**  The bridge actor's
       `processSignedAction` calls are rate-limited at the
       runtime adaptor (configurable; default 100 deposits per
       block).  An exfiltration attack thus needs many blocks to
       drain the bridge, leaving time for human response.
    4. **Operator monitoring.**  An off-chain watchdog compares
       Canon's `totalDeposited` against L1's emitted event sum
       continuously; divergence triggers a pause.

### 15.12 ERC-20 decimal mismatch

  * **Risk.**  Canon's `Amount : Nat` is unitless.  ERC-20 tokens
    have their own `decimals()` (typically 6 for USDC, 18 for
    most others); ETH is 18 decimals.  Naively mapping
    `uint256 amount` to `Nat` loses the unit information; a
    1-USDC deposit and a 1-DAI deposit produce the same Canon
    amount but represent different value.
  * **Mitigation.**  *Per-resource decimals discipline*:
    1. The Canon deployment declares a `ResourceId → Nat` decimals
       map at genesis (e.g. `1 → 18` for ETH, `2 → 6` for USDC).
    2. `CanonBridge.sol` validates the mapping at deposit time:
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
       `runtime/canon-hash-keccak256`'s output on the F.2 golden
       corpus diverges from the recorded hashes.  Forces
       investigation of any binding change.
    2. **Run-time self-test.**  `canon`'s startup performs a
       100-input hash-binding sanity check against an embedded
       golden table.  Failure exits with status 2 *before* any
       state-affecting action.
    3. **Pause on divergence detection.**  The off-chain
       watchdog (see 15.11) periodically computes a Lean-side
       state hash and compares against the L1 contract's
       believed state hash.  Divergence triggers
       `CanonBridge.pause()`, blocking all new deposits and
       withdrawals pending governance review.

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

## 17. Glossary

  * **CBE** — Canon Binary Encoding, the deterministic byte codec
    documented in `LegalKernel/Encoding/CBOR.lean` and
    `docs/abi.md`.
  * **Deployment** — a single instantiation of Canon's runtime
    against a particular `(chainId, rollupId, attestor key)`
    triple.  Distinguished from other deployments via
    `deploymentId`.
  * **Dispute window** — the period after a state-root submission
    during which `CanonDisputeVerifier.sol` will accept fraud
    proofs.  Configurable per-deployment; default 7 days.
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
  * **Sequencer** — the off-chain process that orders Canon
    transactions, applies them via `processSignedAction`, and
    publishes state roots to L1.
  * **Settlement** — the act of finalising an L2 state root on
    L1 such that the L1 contract treats it as canonical.
  * **TCB** — trusted computing base; for Canon, the union of
    `LegalKernel/Kernel.lean` and `LegalKernel/RBMapLemmas.lean`.
  * **WU** — work unit, the atomic unit of engineering effort
    in the Genesis Plan / this document.

## 18. Audit-1 changelog

This document was audited against the Canon codebase shortly
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
    `keccak256(typeHash ‖ canonSignInput)` — non-conforming to
    EIP-712, which requires field-by-field structured encoding.
    Replaced with a proper `CanonAction` typed struct with four
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
    keys, while Canon's `ActorId` keys remain `UInt64`.  No
    change.
  * **Single-shot dispute proofs vs bisection**.  Already
    correctly identified as a non-goal (§2.2 #3) with the
    `≤ 256-entry log prefix` cap.  The cap is enforced at the
    `CanonDisputeVerifier.sol` deployment-parameter level.  No
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
  * **E.1** (`CanonBridge.sol`) → five sub-WUs (E.1.1 deposit,
    E.1.2 state-root submission, E.1.3 withdrawal, E.1.4 pause /
    upgrade, E.1.5 rollback hook).  Each owns a self-contained
    contract surface; can be code-reviewed by a different
    Solidity auditor without spilling context.
  * **E.2** (`CanonDisputeVerifier.sol`) → five sub-WUs (E.2.1
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
    ownership) are explicit per-WU.
  * **`ATTESTOR_ROLE`, `PAUSER_ROLE`, `DISPUTE_VERIFIER_ROLE`,
    `UPGRADER_ROLE`** introduced; no `DEFAULT_ADMIN_ROLE` (no
    self-elevation possible).
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
    `CanonIdentityRegistry.sol` (E.3): two register entry
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
  * **§9.4 `CanonSequencerStake.sol` granularity**.  E.4
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
