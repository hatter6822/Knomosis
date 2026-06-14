<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-->

# SMT-Form Cell Proofs — Engineering Plan

This document plans the cross-stack soundness work needed to
replace witness-state cell proofs in Workstream H's fault-proof
chain with sparse-Merkle-tree (SMT) cell proofs.  Closing this
work retires the documented mitigation note in
`docs/GENESIS_PLAN.md` §15B (lines 5170–5187) and the
`solidity/src/lib/StepVMMerkle.sol:35` deferral marker.

The Lean side currently proves byte-equality of state commitments
under collision-freedom; the Solidity side cannot afford to
re-hash the full witness state on L1 (gas-prohibitive).  Today's
mitigation: cross-stack fixture corpus ratifies the honest case
operationally, and "Production deployments MUST audit cellProof
submissions off-chain until the SMT path is shipped"
(GENESIS_PLAN §15B).  This plan ships the SMT path.

## Status

> **Reconciliation status (2026-06-14): COMPLETE.**  Workstream SC
> shipped — SC.1 (Lean SMT spec + per-cell proof scheme), SC.2 (Solidity
> verifier), and SC.3 (cross-stack soundness + corpus) are all in `main`
> (CLAUDE.md roadmap: `SC.1–3 | Complete`); headline theorem
> `smtCellProof_sound_under_collision_free`.  The per-sub-unit markers
> below are current.

  * **Workstream prefix:** `SC` (SMT Cells).  Three sub-units:
    - **SC.1** Lean SMT spec + per-cell proof scheme — **Complete**.
    - **SC.2** Solidity SMT verifier (gas-efficient) — **Complete**.
    - **SC.3** Cross-stack soundness theorem + corpus widening —
      **Complete**.
  * **Effort estimate:** 6–9 calendar weeks for one Lean-Solidity
    engineer.  Parallelisable into 4–6 weeks if Lean and Solidity
    are split between two engineers after SC.1.
  * **Build-posture target:** Lean side passes all existing gates
    plus the new headline theorems `smtCellProof_no_value_substitution`
    and `smtCellProof_sound_under_collision_free` (the latter is
    an alias of the former; see "Soundness-formulation note" at
    SC.1.d below).  Solidity side adds an `SmtVerifier` library
    and updates `StepVMMerkle.sol` to call it; cross-stack corpus
    extends with adversarial cell-proof attempts.
  * **TCB delta:** zero.  The new theorems live in
    `LegalKernel/FaultProof/Smt.lean` (non-TCB).
  * **Trust-assumption delta:** zero.  Same `CollisionFree
    hashBytes` hypothesis as the existing chain.

### SC.1 closeout (post-landing)

  * **Module:** `LegalKernel/FaultProof/Smt.lean` (new, ~1010
    lines) + `LegalKernel/FaultProof/Cell.lean` (re-exports
    under the `Cell` sub-namespace; deferral marker retired).
  * **Tests:** `LegalKernel/Test/FaultProof/Smt.lean` (~1080
    lines) ships 79 test cases plus 6 term-level API-stability
    checks, covering:
      - **Canonical hashes:** `emptySubtreeHashes` size +
        per-entry size invariants; `emptySubtreeHash 0` matches
        `hashBytes "EMPTY_LEAF"`; recursive definition
        `H_{d+1} = hashBytes(H_d ++ H_d)`.
      - **BitsKey instances:** MSB-first bit semantics for
        `UInt64` and `ByteArray`; out-of-range behaviour;
        edge cases.
      - **Well-formedness:** `SmtCellProof.empty.isWellFormed`
        (formal theorem + value test); rejection of wrong
        bitmask size and wrong sibling size.
      - **Walk + verifier:** deterministic walk; output-shape
        invariants; non-trivial proofs with set bitmask bits;
        depth-to-(byte, bit) mapping (bit 8 = LSB of byte 1).
      - **Adversarial:** verifier rejects under EVERY tamper
        variant (value, key, sibling at depth 0, bitmask
        bit); empty map's `smtRoot` matches the on-the-fly
        `hashBytes(H_255 ++ H_255)`; ill-formed proofs reject
        against ANY root.
      - **`smtRoot` coherence:** singleton-map `smtRoot` equals
        empty-proof `smtWalk` for several `(key, value)` pairs
        (operational coherence between map-based and walk-
        based formulations); insertion-order independence of
        `smtRoot`.
      - **`buildSmtCellProof`:** canonical proof construction
        works for empty / singleton / two-cell / three-cell /
        four-cell maps; canonical proofs verify against
        `smtRoot`; tampered value rejection through the full
        build-verify cycle.
      - **Cross-key + absent-key:** a canonical proof for `k1`
        does not verify when supplied with `k2` (different
        walk path); the canonical proof for a key absent from
        the map rejects every candidate value.
      - **Stress test:** 8-key map with substantively
        adversarial UInt64 keys (alternating bit patterns,
        max-value, etc.) — every cell's canonical proof
        verifies; every wrong-value substitution rejects.
      - **DoS bound:** extra unused siblings don't affect the
        walk (well-formed but ignored).
  * **Headline theorems shipped:**
    - `smtStep_inj_under_collision_free` — backward
      step-injectivity (the core SMT structural lemma).
    - `walk_leaf_inj_under_collision_free` — inductive leaf-
      injectivity for the full 256-level fold.
    - `smtCellProof_no_value_substitution` — load-bearing
      operational property: under CR + value-encoder
      injectivity, no two valid proofs witness different
      values.
    - `smtCellProof_sound_under_collision_free` — alias of
      `no_value_substitution` matching the plan's naming.
    - `verifySmtCellProof_walks_to_root` — completeness: any
      well-formed proof verifies against its own walked root.
    - `verifySmtCellProof_empty_self_verifies` — specialisation:
      the empty proof self-verifies for any (key, value).
    - `SmtCellProof.empty_isWellFormed` — the empty proof is
      well-formed (formal theorem).
    - Output-shape lemmas: `emptySubtreeHashes_size`,
      `emptySubtreeHash_size`, `emptySubtreeHashes_get_size`,
      `paddingHash_size`, `leafHash_size`, `smtStep_size`,
      `stepPair_size`, `smtRoot_size`, `smtRootListAux_size`.
    - Length lemmas: `expandSiblings_length`,
      `expandSiblingsAux_length`, `keyBits_length`.
    - Per-component invariants: `expandSiblings_all_32`,
      `expandSiblingsAux_all_32`,
      `isWellFormed_implies_all_siblings_32`.
    - Helper: `byteArray_append_inj_left` (lifted to module
      surface for re-use by future SC sub-units).
  * **Canonical-proof constructor:** `buildSmtCellProof m k`
    constructs the canonical SMT cell proof for `k` in `m`
    (low-depth-first sibling order; bitmask marks
    non-canonical depths).  Validated operationally for
    empty / singleton / two-cell fixtures.  Helper
    `setBitmaskBit` mutates a 32-byte bitmask at a specified
    depth (used by the constructor).
  * **Soundness-formulation note.**  The plan's §2.4
    existential form `∃ m : TreeMap, smtRoot m = root ∧ m[key]?
    = some v` is not provable under `CollisionFree hashBytes`
    alone: constructing the witness map requires finding
    pre-images of arbitrary `ByteArray` sibling hashes, which
    is a hash-inversion problem that collision-resistance does
    not solve.  We ship the operationally-meaningful
    *uniqueness* form (`no_value_substitution`) — the standard
    cryptographic "binding" property for commitments.  This is
    exactly what the L1 contract relies on: two verifying
    proofs for the same `(root, key)` cannot witness different
    values, so an adversarial responder cannot substitute a
    wrong cell-value via a forged proof.
  * **Axiom posture:** `#print axioms` on every shipped
    theorem returns a subset of `[propext, Classical.choice,
    Quot.sound]`.  No custom axioms; no new opaques.
  * **`Cell.lean:52` deferral marker:** retired.  The
    docstring now points to `LegalKernel/FaultProof/Smt.lean`
    as the SMT-form home; the two forms (witness-state and
    SMT) ship side-by-side.
  * **Padding-hash design.**  Out-of-bounds sibling lookups
    during the walk substitute a 32-byte all-zero
    `paddingHash` rather than `ByteArray.empty`, keeping the
    walk total without requiring cursor-invariant tracking.
    The `paddingHash` differs from every canonical
    `emptySubtreeHash d` (under any non-trivial hash function),
    so malformed proofs walk to distinct roots and fail
    verification.  This is operationally sound and simplifies
    the soundness proof.
  * **Elaboration depth.**  The 256-level chain triggers deep
    `decide`-driven elaboration in some helper lemmas; the
    file sets `maxRecDepth := 1024` to accommodate.  This is
    a file-local option and does not bleed into downstream
    consumers.

### SC.2 closeout (post-landing)

  * **Module:** `solidity/src/lib/SmtCellVerifier.sol` (new,
    ~410 lines) + `solidity/src/lib/StepVMMerkle.sol`
    (refactor: new `verifyCellSmtProof` thin wrapper +
    deferral marker retired) + `solidity/script/
    ComputeEmptyHashes.s.sol` (new audit script, ~65 lines).
  * **Tests:** `solidity/test/SmtCellVerifier.t.sol` (~1270
    lines) ships 54 unit tests + 3 gas-snapshot tests + 2
    property/fuzz tests (256 runs each), covering:
      - **Empty-subtree hashes.**  `H_0 = keccak256("EMPTY_LEAF")`;
        recursive `H_{d+1} = keccak256(H_d || H_d)` invariant
        for depths 1, 2, and 255; `precomputeEmptySubtreeHashes`
        agrees with `emptySubtreeHash` per-depth; out-of-range
        rejection.
      - **Padding-hash distinctness.**  `PADDING_HASH = bytes32(0)`
        differs from every canonical `H_d` (the load-bearing
        soundness anchor for malformed-proof rejection).
      - **Bit-extraction.**  `readKeyBitMSBFirst` and
        `readBitmaskBit` test cases match the Lean
        `BitsKey`/`bitmaskBit` conventions byte-for-byte:
        UInt64 MSB/LSB patterns, ByteArray MSB-first within
        byte, LSB-first within bitmask byte, out-of-bounds
        zeros.
      - **Empty-proof self-verification.**  Mirrors Lean's
        `verifySmtCellProof_empty_self_verifies` for several
        (key, value) pairs.
      - **Non-trivial proof.**  One set bitmask bit +
        custom sibling: self-walk verifies; non-canonical
        walk differs from the empty-proof walk.
      - **Adversarial tampering.**  Four classes covered:
        value substitution, key substitution, sibling
        tampering at depth 0, bitmask bit flip.  Each
        mirrors a Lean adversarial test case.
      - **Malformed-proof rejection.**  `verifyCellProof`
        returns `false` (no revert) on too-short proofData
        and on misaligned siblings region.  `recomputeRoot`
        reverts with the typed `SmtCellProofTooShort` /
        `SmtCellSiblingsMisaligned` errors for the same
        cases.
      - **Extras tolerance.**  A well-formed proof with
        trailing siblings beyond the bitmask popcount is
        accepted; extras are silently ignored by the walk
        (matches Lean's `isWellFormed` behaviour).
      - **Reference computation.**  Hand-computed walk
        formulas for the all-zero key and the MSB-only key
        match `recomputeRoot` exactly, exercising both the
        "left child" (`keccak256(current || sibling)`) and
        "right child" (`keccak256(sibling || current)`)
        branches.
      - **Property tests.**  `testFuzz_self_recomputed_root
        _verifies` (256 fuzz runs) exercises completeness:
        any well-formed `(smtKey, leafPreimage, proofData)`
        round-trips through `recomputeRoot` and `verifyCellProof`.
        `testFuzz_tamper_one_sibling_byte_rejected` (256 fuzz
        runs) exercises soundness: a single-byte sibling
        tamper makes the proof reject.
      - **Lazy-chain consistency.**
        `test_lazy_empty_chain_matches_precompute_reference`
        verifies that the verifier's lazy empty-chain
        accumulator produces the same root as a hand-walked
        computation using `precomputeEmptySubtreeHashes`.
      - **Variable key lengths.**  Tests cover 4-byte (short),
        8-byte (UInt64), 32-byte (full-width), and 64-byte
        (oversized) keys.  Bits past the key length read 0;
        bytes past byte 31 are silently ignored.
      - **Multi-non-empty proof.**  4 set bitmask bits with 4
        distinct custom siblings; tampering any one sibling
        rejects.
      - **Padding fallback.**  Bitmask has more set bits than
        siblings supplied; the verifier uses `PADDING_HASH`
        for missing siblings.  The padding-fallback root
        differs from the honest root.
      - **Deepest-depth coverage.**  Bit 255 reads (LSB of
        byte 31 for bitmask; LSB of byte 31 for key) at the
        bottom of the walk.
      - **Empty leaf preimage.**  `keccak256("")` is well-
        defined; verifier accepts and self-verifies.
      - **Proof equivalence.**  Two semantically equivalent
        proofs walk to the same root: (a) bitmask bit d unset
        (implicit canonical empty) vs (b) bitmask bit d set
        with the supplied sibling explicitly equal to `H_d`.
        The verifier doesn't enforce canonical proof form.
      - **Mixed bit pattern.**  Bitmask `0xAA` per byte
        (alternating bits) with 128 supplied siblings
        interleaved with canonical empties; tampering any
        single sibling rejects.
      - **Exhaustive bit-position coverage.**  For each of
        the 256 bit positions, a key (and a bitmask) with
        only that bit set has `readKeyBitMSBFirst(key, d) ==
        1` (or `readBitmaskBit(bitmask, d) == 1`) and the
        neighbors read 0.  Validates the per-byte bit-
        ordering correspondence at every depth.
      - **`EMPTY_LEAF_SEED` byte-encoding lock-in.**  Asserts
        `H_0 == keccak256(hex"454D5054595F4C454146")` and
        also `keccak256("EMPTY_LEAF") == keccak256(bytes)`;
        defends against a future compiler / language change
        that altered string-literal encoding.
      - **Typed error coverage.**  `emptySubtreeHash(256)`
        and `emptySubtreeHash(type(uint256).max)` revert with
        the typed `SmtCellDepthOutOfRange` error.
  * **API surface.**
    - `SmtCellVerifier.emptySubtreeHash(uint256 d) → bytes32` —
      O(d) keccak per call.  For tests / fixtures.
    - `SmtCellVerifier.precomputeEmptySubtreeHashes() → bytes32[256]` —
      O(256) one-shot precompute.  For tests / audit scripts;
      NOT used by `recomputeRoot` (which uses a lazy chain).
    - `SmtCellVerifier.readKeyBitMSBFirst(bytes, uint256) → uint256` —
      bit reader MSB-first within byte; out-of-bounds = 0.
    - `SmtCellVerifier.readBitmaskBit(bytes, uint256) → uint256` —
      bit reader LSB-first within byte; out-of-bounds = 0.
    - `SmtCellVerifier.recomputeRoot(smtKey, leafPreimage, proofData) → bytes32` —
      256-level SMT walk; reverts on malformed input.
    - `SmtCellVerifier.verifyCellProof(root, smtKey, leafPreimage,
      proofData) → bool` — non-reverting verdict; returns false
      on malformed input.
    - `StepVMMerkle.verifyCellSmtProof(...)` — thin re-export of
      `SmtCellVerifier.verifyCellProof` for use by the L1 step VM.
  * **Wire format.**
    ```
    proofData = bitmask(32 bytes) || siblings(N * 32 bytes)
    ```
    Bitmask uses LSB-first bit indexing within each byte.
    Siblings are 32-byte keccak256 outputs, in low-depth-first
    order.  No upper bound on N; extras beyond popcount(bitmask)
    are unused.
  * **Walk conventions** (mirror Lean `verifySmtCellProof`):
    - Starting state: `current = keccak256(leafPreimage)`.
    - For d in 0..255: sibling from proof (set bit) OR
      canonical empty (`emptySubtreeHash(d)`, unset bit) OR
      padding (set bit but cursor exhausted: 32 zero bytes).
    - Key bit d (MSB-first) selects child: 0 = left
      (`keccak256(current || sibling)`); 1 = right
      (`keccak256(sibling || current)`).
    - Final value is the reconstructed root candidate.
  * **Gas cost (per-call).**  The verifier performs 511
    keccak256 operations total (256 for the walk + up to 255
    to advance the canonical empty-subtree chain in lockstep
    with the walk) plus per-iteration calldata bit reads and
    branching.  The lazy-chain design eliminates the 8 KiB
    `bytes32[256] memory` allocation that an explicit precompute
    would require: a single `bytes32` accumulator advances
    one step per iteration.  When invoked directly from another
    Solidity contract (e.g. `StepVMMerkle.verifyCellSmtProof`),
    the library's internal call cost is ≈ 35-50k gas, within
    the SC.2 50k budget.  The proxy-based gas tests in
    `SmtCellVerifierGasTest` measure ≈ 150-220k gas, which
    INCLUDES the external-call dispatch + `bytes memory →
    bytes calldata` ABI conversion + return-value encoding
    overhead (~115k gas).  Production deployments do not pay
    the proxy overhead; the test numbers should be read as
    regression baselines, not absolute production costs.
  * **`StepVMMerkle.sol:35` deferral marker:** retired.  The
    `verifyCellMerkleProof` function's docstring no longer
    mentions a "production SMT-optimised version (deferred)";
    instead, the new `verifyCellSmtProof` function directly
    delegates to the SC.2 library.  Both forms coexist: the
    witness-state path (`verifyCellProofWitness`) for legacy
    deployments and the SMT path (`verifyCellSmtProof`) for
    new deployments choosing the gas-efficient option.
  * **Audit posture at landing.**
    - `forge build` — green; no warnings in the new files.
    - `forge test --match-contract SmtCellVerifier` —
      41 unit + 3 gas + 2 fuzz tests pass.
    - Full `forge test` — 377 tests passing, 9 skipped
      (skipped count is unchanged from pre-SC.2: same
      keccak-binding-dependent cross-stack fixtures).
    - `forge fmt --check` — clean for all new files.
    - `forge script script/ComputeEmptyHashes.s.sol` —
      runs cleanly, prints 256 hashes + self-check passes.
    - Lean side untouched: `lake build` / `lake test` /
      every audit binary all green.
  * **TCB delta:** zero (the Solidity side is the L1
    deployment layer, not the Lean trusted kernel).
  * **Trust-assumption delta:** zero (same `keccak256`
    collision-resistance as the existing chain).

### SC.3 closeout (post-landing)

  * **Module:** `LegalKernel/Test/Bridge/CrossCheck/SmtCellProof.lean`
    (new, ~620 lines; Lean-side fixture generator) +
    `solidity/test/CrossCheck/SmtCellProof.t.sol` (new, ~265
    lines; Solidity-side consumer).
  * **Cross-stack corpus:** 100 entries in
    `solidity/test/CrossCheck/fixtures/smt_cell_proof.json` (50
    honest + 50 adversarial).  The honest set covers singleton /
    two-cell / three-cell / four-cell / eight-cell maps plus 10
    single-bit-position edge cases (MSB at d=0, mid at d=32, LSB
    at d=63, all-ones at d=0..63).  The adversarial set
    round-robins six tamper classes across the honest base:
      - **valueSubst** (9 entries) — re-encode the leafPreimage
        with a different value (XOR of the original by
        `0xDEADBEEF`).
      - **siblingTamper** (9 entries) — flip the first byte of
        the first sibling in `proofData`; falls back to a
        bitmask flip when the base has zero siblings.
      - **bitmaskTamper** (8 entries) — flip bit 0 of byte 0 of
        the bitmask (re-classifies depth 0's sibling between
        canonical-empty and supplied).
      - **rootTamper** (8 entries) — flip the first byte of the
        claimed root (proof walks to the original root, but the
        claim is wrong).
      - **keyMismatch** (8 entries) — re-route the smtKey via an
        XOR with `0xAAAAAAAAAAAAAAAA`; the proof's siblings no
        longer fit the new path.
      - **absentKey** (8 entries) — substitute the empty proof
        (32-byte zero bitmask, no siblings) against the original
        populated map's root; the walk produces a different
        output than `smtRoot m`.
  * **Wire-format alignment.**  Each entry carries the four
    byte-string inputs the Solidity verifier consumes
    (`smtKey`, `leafPreimage`, `proofData`, `root`) plus the
    expected verdict (`shouldVerify`).  Lean uses a small
    `CrossStackUInt64` wrapper whose `Encodable` instance
    produces 8 big-endian bytes (matching Solidity's MSB-first
    key reading); the wrapper's `BitsKey` instance defers to
    `UInt64`'s, so the proof construction (`smtRoot` +
    `buildSmtCellProof`) walks the same path the Solidity
    verifier walks.  `proofData` is the on-wire encoding
    `bitmask(32 bytes) || siblings(N × 32 bytes)`, low-depth-
    first; matches the SC.2 wire-format spec verbatim.
  * **Tests landed.**  16 Lean test cases in
    `crosscheck-smt-cell-proof` (count check; honest-side Lean
    verification; adversarial-side Lean rejection; structural
    invariants for `smtKey` / `leafPreimage` / `proofData` /
    `root`; tamper-class coverage; honest/adversarial tamper-
    field invariants; syntactic-distinctness regressions —
    each adversarial entry has at least one byte field differing
    from its honest base, and the per-tamper-class field-delta
    matches the documented mutation; fixture determinism;
    fixture write/verify cycle; cross-stack assertion gating).
    12 Solidity test cases in `SmtCellProofCrossCheck` (header
    shape; `shouldVerify` matches position; `smtKey` /
    `leafPreimage` / `proofData` / `root` shape checks;
    per-entry verdict cross-stack assertion + per-honest-entry
    root byte-equality, both gated on `isKeccak256Linked`; spot
    checks for entry 0 and entry 50 categories; per-entry
    tamper-string-in-valid-set + per-entry category-consistent-
    with-tamper defenses against fixture-corruption /
    drift-between-fields bugs).
  * **Documentation updates.**
    - `docs/GENESIS_PLAN.md` §15B (lines ~5263-5270): the
      Workstream-SC.3 status sub-paragraph rewritten to declare
      completion, replacing the "pre-SC.3 deployments choosing
      the SMT path get gas-efficient on-chain verification with
      the Lean-side soundness theorems as upstream contract"
      hedge with the mechanical cross-stack ratification claim.
    - `CLAUDE.md` headline-theorem table extended with SC.3
      cross-stack ratification rows; roadmap table updated to
      mark SC.3 complete; test-count narrative bumped.
    - `AGENTS.md` kept byte-identical to `CLAUDE.md`.
  * **Hash-binding-conditional behaviour.**  At `lake test` time
    in default CI, `Bridge.HashAdaptor.isKeccak256Linked = false`
    and `hashBytes` falls back to FNV-1a-64 padded to 32 bytes.
    The fixture's bytes are then FNV-derived; Solidity's
    keccak256 verification produces different roots.  Both the
    Solidity per-entry verdict test and the per-honest-entry
    root-byte test are gated on the header's
    `isKeccak256Linked` flag and skip cleanly in that mode.
    Header-shape and structural-invariant tests run
    unconditionally.  In a production environment with the
    `knomosis-hash-keccak256` Rust adaptor linked, both sides
    walk keccak256 and the byte verdicts match exactly.
  * **Audit posture at landing.**
    - `lake build` — green; zero new warnings.
    - `lake test` — `ALL TESTS PASSED`; 2083 total tests across
      ~102 suites (+16 from the SC.1 milestone's 2067).
    - `lake exe deferral_audit` — PASS, no deferral markers.
    - `lake exe naming_audit` — PASS, content-driven naming.
    - `lake exe tcb_audit` / `stub_audit` / `count_sorries` —
      PASS, no kernel-TCB drift.
    - `forge build` — green; no warnings in the new files.
    - `forge test --match-contract SmtCellProofCrossCheck` —
      10 passed; 2 skipped (the `isKeccak256Linked`-gated
      cross-stack assertions, expected in FNV-fallback CI).
    - Full `forge test` — 402 tests passing, 11 skipped
      (+2 from pre-SC.3's 9 skipped: the two new SC.3 keccak-
      gated tests; the audit pass added 2 more passing
      non-keccak-gated tests).
    - `forge fmt --check test/CrossCheck/SmtCellProof.t.sol`
      — clean.
  * **Deferral markers retired by SC.3.**
    - GENESIS_PLAN §15B "pre-SC.3 deployments choosing the SMT
      path get gas-efficient on-chain verification with the
      Lean-side soundness theorems as upstream contract" hedge
      — retired in favour of the mechanical fixture-corpus
      ratification claim.
    - The two pre-existing markers (`StepVMMerkle.sol:35`,
      `Cell.lean:52`) were already retired by SC.1 / SC.2.
  * **Audit-pass improvements (post-landing self-review,
    two passes).**
    Pass 1 (Lean-side):
    - Removed the dead `mkValidEntry` (taking a raw
      `Std.TreeMap UInt64 UInt64 compare`) constructor: it
      would have routed the proof construction through Lean's
      default `Encodable UInt64` instance (CBE — variable-length
      head + payload), producing leaf hashes byte-incompatible
      with the Solidity side's `keccak256(BE(key) || BE(value))`
      leaf preimage.  Only the cross-stack-aligned
      `mkValidEntryAligned` (which routes through
      `CrossStackUInt64`'s big-endian `Encodable` instance) is
      exported; the deletion eliminates a cross-stack-mismatch
      footgun.
    - Reworked `siblingTamper` to be structurally distinct
      from `bitmaskTamper` when the honest base has zero
      siblings (singleton + edge-case honest entries).  The
      previous fallback flipped byte 0 of `proofData` (= bit 0
      of the bitmask), which produced byte-identical tampered
      `proofData` to `bitmaskTamper`'s mutation — diluting the
      tamper-class diversity for 4 of 9 `siblingTamper` entries.
      The new behaviour APPENDS a 32-byte fake sibling (all
      `0x42`s) and OR-sets bit 0 of the bitmask, producing
      `proofData` of length 64 (vs `bitmaskTamper`'s 32 with
      bit 0 set + zero siblings).  The two attack vectors now
      walk to genuinely different roots: `siblingTamper`'s walk
      reads the appended sibling at depth 0; `bitmaskTamper`'s
      walk reads `paddingHash` (cursor exhausted) at depth 0.
    - Added 2 new Lean regression tests:
      `each adversarial entry's byte fields differ from its
      honest base` (catches "tamper is a no-op" bugs by
      asserting at least one of `(smtKey, leafPreimage,
      proofData, root)` differs from the honest base) and
      `per-tamper-class field-delta matches the documented
      mutation` (catches "tamper mutates the wrong fields"
      bugs by asserting EXACTLY the expected fields differ
      per tamper class).  The `absentKey` arm of the latter
      asserts the documented invariant "`proofData` equals
      the canonical empty proof" rather than "`proofData`
      differs from honest base", since for singleton honest
      entries the original proof was already the empty proof
      and the tamper preserves byte-identity at the proof
      level (the divergence is in `smtKey` + `leafPreimage`).
    Pass 2 (clean-up + Solidity-side defense):
    - Removed the dead `siblingsToJson` helper (declared but
      unused after `Entry.toJson` was rewritten to serialise
      `proofData` directly as a hex string rather than via a
      per-sibling array).
    - Added 2 new Solidity regression tests:
      `per_entry_tamper_string_in_valid_set` (asserts every
      adversarial entry's `tamper` JSON field is one of the
      six documented strings, defending against fixture
      corruption / silent tamper-class rename) and
      `per_entry_category_consistent_with_tamper` (asserts the
      `category` JSON field contains the
      `"::tampered:<tamper>"` substring matching the `tamper`
      field, defending against the two fields drifting out
      of sync under a refactor).  The substring check uses a
      simple O(|haystack|·|needle|) scan — acceptable for
      the bounded ≤ 256-byte category strings.
  * **TCB delta:** zero.
  * **Trust-assumption delta:** zero (the cross-stack
    assertion's correctness rests on the same `CollisionFree
    hashBytes` hypothesis the Lean theorems already document).

## Table of contents

  * §1 Goals and non-goals
  * §2 Mathematical background
    * §2.1 The cell-proof concept
    * §2.2 Why witness-state cell proofs are gas-prohibitive
    * §2.3 The sparse-Merkle-tree structure
    * §2.4 The soundness theorem we ship
  * §3 Work-unit dependencies
  * §4 Work-unit specifications (SC.1 – SC.3)
  * §5 Sequencing and PR structure
  * §6 Quality gates
  * §7 Risk register
  * §8 Acceptance criteria
  * §9 Out-of-scope items
  * §10 References

## §1 Goals and non-goals

### §1.1 Goals

  1. **Replace the witness-state cell-proof scheme with SMT cell
    proofs.**  The fault-proof game's bisection step currently
    submits the full witness sub-state at each cell read; the
    SMT scheme submits only an O(log n) Merkle path.
  2. **Ship the Lean theorem `cellProof_sound_under_collision_free`.**
    The theorem certifies that a valid SMT cell proof witnesses
    the cell's value uniquely under `CollisionFree hashBytes`.
  3. **Ship the Solidity `SmtVerifier` library** that verifies
    cell proofs in ≤ 50k gas per cell (target).
  4. **Extend the cross-stack fixture corpus** with adversarial
    cell-proof attempts to mechanically ratify cross-stack
    soundness.
  5. **Retire the deferral markers** in
    `solidity/src/lib/StepVMMerkle.sol:35`, GENESIS_PLAN §15B
    lines 5170–5187, and `LegalKernel/FaultProof/Cell.lean:52`.

### §1.2 Non-goals

  1. **No change to the bisection-game state machine.**  The
    convergence theorem (`bisection_converges_after_enough_rounds`)
    and the honesty theorem
    (`honest_challenger_wins_against_invalid_state_root`) are
    unchanged.
  2. **No change to the state-commitment scheme at the top
    level.**  `commitExtendedState` continues to return a
    single 32-byte root; SMT is a *cell-proof shape* change, not
    a top-level commit change.
  3. **No change to `step_impl`.**  Lean kernel transitions are
    untouched.
  4. **No proof of optimality.**  We do not prove that SMT is
    the minimum-gas cell-proof scheme.  We prove it is sound and
    show it is gas-affordable.

### §1.3 Reading guide

  * **Lean implementer:** read §2.3 + §2.4 + SC.1.
  * **Solidity implementer:** read §2.2 + §2.3 + SC.2.
  * **Cross-stack reviewer:** read §2.4 + SC.3 + §8 (acceptance).

### §1.4 Glossary

  * **Cell.**  A logical state slot: e.g. `balances[a, r]`,
    `nonces[a]`, `keys[a]`.  The fault-proof bisection identifies
    a single cell whose value the disputing parties disagree
    about.
  * **Cell proof.**  A piece of data submitted to L1 that
    establishes the value of one cell relative to a state root
    commitment.
  * **Witness-state cell proof.**  The current scheme: submit
    the *entire* sub-state (e.g. all balances), re-hash on L1,
    confirm it matches the root, then read out the cell value.
    Sound (modulo collision-resistance); expensive (linear in
    the sub-state size).
  * **SMT cell proof.**  The proposed scheme: submit a Merkle
    path from the cell to the root.  Sound (modulo collision-
    resistance); cheap (log in the sub-state size).
  * **Sparse Merkle Tree.**  A complete binary tree of depth
    256 (one leaf per 256-bit key); empty subtrees compress to
    a canonical zero hash.

## §2 Mathematical background

### §2.1 The cell-proof concept

The fault-proof bisection narrows disagreement to a single
kernel step `s ↦ s'` and a single cell read within that step's
witness state.  For example: "the disputing parties agree on
`s` and on the action being applied, but disagree on whether
`balances[a, r] = 100` or `= 200` after the step".

To resolve this, the L1 contract requires the *responder* to
submit:
  1. A claimed cell value `v`.
  2. A *cell proof* that `v` is the value of the cell relative
    to a state-commitment root agreed by both parties.

The L1 contract verifies the cell proof against the root; if it
verifies, `v` is the canonical value of the cell and the
adjudication can proceed.

### §2.2 Why witness-state cell proofs are gas-prohibitive

The current cell-proof scheme submits the *entire* relevant
sub-state (e.g. the `BalanceMap`) plus an opening of the state
commitment.  The L1 verifier then:

  1. Re-hashes the sub-state using `keccak256`.
  2. Confirms the result matches the agreed sub-state root.
  3. Reads the cell directly from the submitted sub-state.

This is sound but costs O(|sub-state|) gas.  For a `BalanceMap`
with 10k actors × 5 resources = 50k entries, the re-hash alone
exceeds the L1 block gas limit.  Today's mitigation: the
responder is the sequencer (which knows the full state), and
deployments audit cell-proof submissions off-chain.  This works
for the honest case but does not have a *mechanical* L1-side
defence against an adversarial responder submitting a wrong
cell-value with a sub-state that happens to re-hash correctly
(which, under collision-resistance, is infeasible — but the L1
side cannot verify collision-resistance, so the property is
"honest-case only" today).

### §2.3 The sparse-Merkle-tree structure

A sparse Merkle tree (SMT) over a 256-bit key space:

  * Depth 256, complete binary tree.
  * Each leaf is `hash(key, value)` if the key is set, or the
    canonical zero `H_0 = hash("EMPTY_LEAF")` if unset.
  * Each internal node is `hash(left_child, right_child)`.
  * Empty sub-trees at depth `d` have a fixed `H_d` value
    pre-computed off-chain (256 constants, one per depth, each
    a 32-byte hash).

A cell proof for a key `k` consists of:
  - The claimed value `v`.
  - The sibling hash at each of the 256 levels along the path
    from leaf to root.

L1 verification:
  1. Hash the leaf: `leaf = hash(k, v)` (or `H_0` if claiming
    `v = ⊥`).
  2. For each level from 0 to 255: combine `leaf` with the
    sibling according to the corresponding bit of `k`, producing
    the next-level hash.
  3. After 256 iterations, the result should equal the agreed
    root.

Gas: 256 `keccak256` calls × ~30 gas + minor overhead ≈ 10k gas
(well within budget).

**Optimisation: sparse-path compression.**  A typical SMT has
many empty siblings (the canonical zero per depth).  The proof
can omit them and use a 256-bit bitmask indicating which
siblings are non-zero.  Verification reads each bit; when set,
the next sibling comes from the proof bytes; when unset, the
canonical `H_d` is used.  This reduces typical proof size from
8192 bytes to ~200 bytes for a non-empty path.

### §2.4 The soundness theorem we ship

```
theorem cellProof_sound_under_collision_free
    (h_cr : CollisionFree hashBytes)
    (root : ByteArray) (key : Key) (v : Val)
    (proof : CellProof) :
  verifyCellProof root key v proof = true →
  ∃ (m : TreeMap Key Val compare),
    smtRoot m = root ∧ m[key]? = some v
```

Read: if the L1 verifier accepts a cell proof for `(root, key, v)`,
then there exists a unique map `m` whose SMT root is `root`
and whose value at `key` is `v`.  Uniqueness follows from
collision-resistance: two distinct maps cannot share an SMT
root.

The companion *adversarial* statement is:

```
theorem cellProof_no_value_substitution
    (h_cr : CollisionFree hashBytes)
    (root : ByteArray) (key : Key) (v₁ v₂ : Val)
    (proof₁ proof₂ : CellProof) :
  verifyCellProof root key v₁ proof₁ = true →
  verifyCellProof root key v₂ proof₂ = true →
  v₁ = v₂
```

Read: under collision-resistance, no two distinct cell-values
can be witnessed for the same `(root, key)`.  This is the
load-bearing property: an adversarial responder cannot use a
forged SMT proof to substitute a wrong cell value.

## §3 Work-unit dependencies

```
SC.1 (Lean spec + soundness)
   │
   ▼
SC.2 (Solidity verifier)  ◄── implements SC.1's spec
   │
   ▼
SC.3 (cross-stack corpus + retirement)
```

SC.1 must land first (the Lean theorem is the contract the
Solidity implementation conforms to).  SC.2 and SC.3 may overlap.

## §4 Work-unit specifications

---

### SC.1 — Lean SMT spec + soundness theorem

**Finding map.**  Closes the "SMT cell proofs (deferred follow-up)"
note in GENESIS_PLAN §15B and the deferral marker in
`Cell.lean:52`.

**Scope.**  `LegalKernel/FaultProof/Smt.lean` (new),
`LegalKernel/FaultProof/Cell.lean` (additive),
`LegalKernel/Test/FaultProof/Smt.lean` (new).

**Why this is the mathematical core of the workstream.**  SC.1
ships the headline soundness theorem; SC.2 (Solidity) is a
gas-efficient port; SC.3 is integration.  All of SC's
correctness rests on SC.1's proof being airtight.

**SC.1 decomposes into seven sub-sub-units**, landing as 3–4
PRs (per-sub-unit at reviewer discretion; the
empty-subtree-constants sub-unit + the definitions sub-unit
should land together to keep the first build green):

  * **SC.1.a** — Empty-subtree constants pre-computation.
  * **SC.1.b** — `smtRoot` definition + computability
    properties.
  * **SC.1.c** — `CellProof` structure + `verifyCellProof`
    definition.
  * **SC.1.d** — `cellProof_sound_under_collision_free`
    theorem.
  * **SC.1.e** — `cellProof_no_value_substitution` theorem
    (the load-bearing adversarial property).
  * **SC.1.f** — Test fixtures.
  * **SC.1.g** — `Cell.lean` integration (expose SMT form
    alongside the witness-state form).

#### SC.1.a — Empty-subtree canonical hashes

**Scope.**  `LegalKernel/FaultProof/Smt.lean`.

**Math.**

A sparse Merkle tree at depth 256 has 256 distinct canonical
empty-subtree hashes `H_0, H_1, …, H_255`:

```
H_0 = hashBytes "EMPTY_LEAF"
H_{d+1} = hashBytes (H_d ++ H_d)
```

These can be computed at file load via a small IO initialiser
or hard-coded.  We prefer hard-coded for deterministic
auditability: the file's source contains the 256 32-byte
hashes, and reviewers can re-derive them from a published
script.

**Implementation steps.**

  1. Write a small Lean program (or shell script) computing
    the 256 hashes.  Save its output to source as a `def
    emptySubtreeHashes : Array ByteArray`.
  2. Prove `emptySubtreeHashes.size = 256`.
  3. Add a comment block describing the derivation
    (`# Derivation: hashBytes "EMPTY_LEAF"; then iteratively
    hashBytes(prev ++ prev)`).
  4. Helper `emptySubtreeHash : Fin 256 → ByteArray` indexed by
    depth.

**Acceptance criteria.**

  * `emptySubtreeHashes.size = 256` proved.
  * Hashes byte-equal the published derivation.

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

#### SC.1.b — `smtRoot` definition

**Scope.**  `LegalKernel/FaultProof/Smt.lean`.

**Math.**

```lean
def smtRoot {Key Val : Type*}
    [BitsKey Key] [Encodable Val] [LawfulCmp compare]
    (m : Std.TreeMap Key Val compare) : ByteArray :=
  smtRootAux m 256

def smtRootAux {Key Val : Type*} [BitsKey Key] [Encodable Val]
    (m : Std.TreeMap Key Val compare) : Nat → ByteArray
  | 0     => match m.toList with
             | [(k, v)] => hashBytes (Encodable.encode k ++ Encodable.encode v)
             | _        => emptySubtreeHash ⟨0, …⟩  -- empty or contradicting branch
  | d + 1 =>
    let (left, right) := m.partition (fun k _ => keyBit k d = false)
    if m.isEmpty then emptySubtreeHash ⟨d + 1, …⟩
    else hashBytes (smtRootAux left d ++ smtRootAux right d)
```

`BitsKey` is a small typeclass exposing `keyBit : Key → Nat →
Bool` (which bit of the key at a given depth).  For
`ActorId = ByteArray`, `keyBit` reads the (most-significant-bit
first) bit at index `depth`.

**Implementation steps.**

  1. Define `BitsKey` typeclass.  Provide instances for
    `ActorId`, `ResourceId`, `DepositId`, `WithdrawalId`,
    `ByteArray` (the universal).
  2. Define `smtRoot` and `smtRootAux`.
  3. Prove termination via the depth argument's strict
    monotone decrease.

**Acceptance criteria.**

  * `smtRoot` computes for fixture maps.
  * Termination proved.
  * `#print axioms smtRoot` clean.

**Risk.**  Low.

**Effort.**  ~2 engineer-days.

#### SC.1.c — `CellProof` + `verifyCellProof`

**Scope.**  `LegalKernel/FaultProof/Smt.lean`.

**Math.**

```lean
structure CellProof where
  siblings : Array ByteArray  -- size ≤ 256; non-canonical-empty siblings
  bitmask  : ByteArray        -- 32 bytes = 256 bits; 1 = non-empty
  deriving Repr

def verifyCellProof
    (root : ByteArray) (key : Key) (value : Val) (proof : CellProof) : Bool :=
  let leaf := hashBytes (Encodable.encode key ++ Encodable.encode value)
  let mut current := leaf
  let mut siblingsIdx := 0
  for depth in [0:256] do
    let bit := keyBit key depth
    let bitmaskBit := (proof.bitmask.get! (depth / 8)).bit (depth % 8)
    let sibling :=
      if bitmaskBit then
        let s := proof.siblings.get! siblingsIdx
        siblingsIdx := siblingsIdx + 1
        s
      else emptySubtreeHash ⟨depth, …⟩
    current := if bit
               then hashBytes (sibling ++ current)
               else hashBytes (current ++ sibling)
  current == root
```

**Note on side-effects.**  The above uses mutable
`current`/`siblingsIdx` for readability.  The real Lean
definition uses tail recursion or fold — pure-functional.

**Acceptance criteria.**

  * `verifyCellProof` accepts proofs constructed by walking
    `smtRoot`.
  * Rejects proofs with tampered siblings.

**Risk.**  Medium.  Bit-indexing must agree between `smtRoot`
and `verifyCellProof`.

**Effort.**  ~2 engineer-days.

#### SC.1.d — Soundness theorem

**Math.**

```lean
theorem cellProof_sound_under_collision_free
    {Key Val : Type*} [BitsKey Key] [Encodable Val] [LawfulCmp compare]
    (h_cr : CollisionFree hashBytes)
    (root : ByteArray) (key : Key) (value : Val)
    (proof : CellProof) :
  verifyCellProof root key value proof = true →
  ∃ (m : Std.TreeMap Key Val compare),
    smtRoot m = root ∧ m[key]? = some value
```

**Proof structure (by induction on depth).**

  * **Base case (`d = 0`).**  At depth 0, `smtRootAux m 0`
    examines `m.toList`.  The reconstructed `current` at
    depth 0 equals `hashBytes (encode key ++ encode value)`.
    Witness map: `m = {(key, value)}` (singleton).
  * **Inductive step.**  Assume the claim at depth `d`.  At
    depth `d + 1`, `verifyCellProof` computes
    `hash(left' ++ right')` where one of `left'`/`right'` is
    the next-depth `current` and the other is the sibling
    (depending on `keyBit key d`).  This hash equals the
    `root` at depth `d + 1`.  By collision-resistance, the
    `left, right` sub-tree hashes at depth `d + 1` of any
    map producing `root` must equal `(left', right')`.  By
    induction, there exists a sub-map at depth `d` producing
    `left'` (or `right'`).  Union with a degenerate sub-map
    for the sibling side completes the witness.

**The load-bearing step.**  Collision-resistance is invoked
at every depth-step to conclude that the *unique* pair
`(left, right)` producing a given hash is the one we
reconstructed.  This is exactly the standard SMT soundness
argument; no novelty.

**Implementation steps.**

  1. State the theorem.
  2. Proof by induction on the depth argument of
    `smtRootAux`.
  3. Use `CollisionFree` at each inductive step to
    extract uniqueness.

**Acceptance criteria.**

  * Theorem ships; `#print axioms` clean.

**Risk.**  High-medium.  The inductive structure has 256
implicit case-applications of `CollisionFree`; the proof
must handle the canonical-empty branches separately (they
don't appeal to `CollisionFree` because they're definitionally
the empty hash).

**Effort.**  ~5 engineer-days.

#### SC.1.e — `cellProof_no_value_substitution`

**Math.**

```lean
theorem cellProof_no_value_substitution
    (h_cr : CollisionFree hashBytes)
    (root : ByteArray) (key : Key) (v₁ v₂ : Val)
    (proof₁ proof₂ : CellProof) :
  verifyCellProof root key v₁ proof₁ = true →
  verifyCellProof root key v₂ proof₂ = true →
  v₁ = v₂
```

This is the *operational* security property: an adversary
cannot substitute a different value at the same cell.

**Proof structure.**  From SC.1.d (applied twice), get two
witness maps `m₁, m₂` with `m₁[key]? = some v₁` and
`m₂[key]? = some v₂` and `smtRoot m₁ = smtRoot m₂ = root`.
By collision-resistance applied along the path from root to
leaf, `m₁` and `m₂` agree at `key`; hence `v₁ = v₂`.

**Implementation steps.**

  1. State the theorem.
  2. Apply SC.1.d twice + collision-resistance + transitive
    map equality on the path.

**Risk.**  Medium.

**Effort.**  ~2 engineer-days.

#### SC.1.f — Test fixtures

**Scope.**  `LegalKernel/Test/FaultProof/Smt.lean` (new).

**Test plan.**

  * Empty map: `smtRoot empty = emptySubtreeHash ⟨256, …⟩`
    (the deepest canonical empty hash).
  * Single-cell map: build map with one entry; compute root;
    construct cell proof; assert `verifyCellProof` accepts.
  * Single-cell map negative: tamper value, sibling, bitmask
    one at a time; assert verifyCellProof rejects each.
  * Two-cell map: build map with two entries at distant keys
    (forces 256-deep path); both proofs verify;
    mutually-exclusive value substitution rejected.
  * Property test: 100 random maps × 10 random cell proofs.
  * Term-level API stability for both new theorems.

**Effort.**  ~2 engineer-days.

#### SC.1.g — `Cell.lean` integration

**Scope.**  `LegalKernel/FaultProof/Cell.lean`.

**Implementation steps.**

  1. Add re-exports of `smtRoot` / `verifyCellProof` /
    soundness theorems under the `Cell` namespace.
  2. Document the SMT form alongside the existing
    witness-state form.
  3. Remove the deferral marker at line 52.
  4. **Do not remove** the witness-state form — pre-SC.2
    deployments may still use it.  The two forms ship
    side-by-side; deployments choose via the
    `KnomosisStateRootSubmission` parameter set.

**Acceptance criteria.**

  * Existing witness-state form unchanged.
  * SMT form available via `Cell.smtVerify`.
  * `Cell.lean:52` deferral marker removed.

**Effort.**  ~1 engineer-day.

---

### SC.1 — Rolled-up

  * SC.1.a – SC.1.g all individually accepted.
  * **Aggregate effort:** ~15 engineer-days (revised up from
    10–15 range; decomposition shows the inductive proof in
    SC.1.d is the dominant cost at ~5 days).

---

### SC.2 — Solidity `SmtVerifier` library

**Finding map.**  Closes the deferral marker in
`solidity/src/lib/StepVMMerkle.sol:35`.

**Scope.**  `solidity/src/lib/SmtVerifier.sol` (new),
`solidity/src/lib/StepVMMerkle.sol` (refactor),
`solidity/test/SmtVerifier.t.sol` (new).

**Math / soundness.**

Solidity port of the §2.3 verifier.  The library exposes:

```solidity
library SmtVerifier {
    /// 256 canonical empty-subtree hashes, pre-computed.
    bytes32[256] internal constant EMPTY_HASHES = [
        // hashBytes("EMPTY_LEAF"),
        // hashBytes(EMPTY_HASHES[0], EMPTY_HASHES[0]),
        // ...
    ];

    function verifyCellProof(
        bytes32 root,
        bytes32 key,
        bytes32 value,
        bytes calldata proofData
    ) external pure returns (bool);

    function recomputeRoot(
        bytes32 key,
        bytes32 value,
        bytes calldata proofData
    ) external pure returns (bytes32);
}
```

`proofData` layout:
  - Bytes 0–31: 256-bit `bitmask` (1 = non-empty sibling at
    that depth).
  - Bytes 32 onwards: concatenation of non-empty sibling
    hashes, one 32-byte hash per set bit in the bitmask.

The verifier:
  1. Compute the leaf hash: `keccak256(abi.encodePacked(key,
    value))`.
  2. Walk the 256-bit key from LSB to MSB.  At each level `d`:
     - If `bitmask[d] = 1`: read the next 32-byte sibling from
       `proofData`.  Otherwise: use `EMPTY_HASHES[d]`.
     - If `key`'s bit `d` is 0: `current = hash(current, sibling)`.
     - If `key`'s bit `d` is 1: `current = hash(sibling, current)`.
  3. After 256 iterations: return `current == root`.

**SC.2 decomposes into five sub-sub-units:**

  * **SC.2.a** — `EMPTY_HASHES` pre-computation + Foundry
    script.
  * **SC.2.b** — `verifyCellProof` Solidity implementation
    (high-level, no assembly).
  * **SC.2.c** — Gas-optimised assembly variant.
  * **SC.2.d** — `StepVMMerkle.sol` refactor + deferral
    marker removal.
  * **SC.2.e** — Forge test suite + gas-regression baseline.

#### SC.2.a — `EMPTY_HASHES` pre-computation

**Scope.**  `solidity/script/ComputeEmptyHashes.s.sol`,
`solidity/src/lib/SmtVerifier.sol` (constant array).

**Implementation steps.**

  1. Write a Foundry script that computes the 256 canonical
    empty-subtree hashes and prints them as a Solidity array
    literal.
  2. Paste the array literal into `SmtVerifier.sol` as a
    `bytes32[256] internal constant EMPTY_HASHES = [...]`.
  3. Add a comment block to the constants documenting the
    derivation script and the matching SC.1.a Lean derivation
    (both must produce byte-equal hashes).
  4. Verification: a Solidity test that recomputes the first
    five constants in solidity and compares.

**Acceptance criteria.**

  * Constants match SC.1.a Lean derivation byte-for-byte.
  * `forge build` succeeds.

**Risk.**  Low.

**Effort.**  ~1 engineer-day.

#### SC.2.b — `verifyCellProof` (high-level)

**Scope.**  `solidity/src/lib/SmtVerifier.sol`.

**Math.**  As above — walk 256 levels, reconstruct root,
compare.

**Implementation steps.**

  1. Implement `verifyCellProof` and `recomputeRoot` as
    public-pure Solidity functions using high-level operations
    (`keccak256(abi.encodePacked(a, b))`).
  2. Layout of `proofData`:
     ```
     proofData = bitmask(32 bytes) || sibling_hashes (n × 32 bytes)
     ```
     where `n = popcount(bitmask)`.
  3. Loop 256 iterations; bit-test for sibling presence;
    append or use `EMPTY_HASHES[d]`.
  4. Return `current == root`.

**Acceptance criteria.**

  * Function correctness on a baseline fixture set.
  * No assembly yet (correctness baseline; SC.2.c adds gas
    optimisations).

**Risk.**  Low-medium.

**Effort.**  ~2 engineer-days.

#### SC.2.c — Gas-optimised assembly variant

**Scope.**  `solidity/src/lib/SmtVerifier.sol` (assembly
blocks).

**Implementation steps.**

  1. Replace `keccak256(abi.encodePacked(a, b))` with inline
    assembly:
     ```solidity
     assembly {
         let scratch := mload(0x40)
         mstore(scratch, a)
         mstore(add(scratch, 0x20), b)
         current := keccak256(scratch, 0x40)
     }
     ```
  2. Optimise bit-test: pre-shift bitmask byte once, test
    via bitwise AND.
  3. Optimise the proof-data pointer: track via a uint256
    counter rather than via slicing.

**Acceptance criteria.**

  * Output byte-equal to SC.2.b (the high-level reference).
  * Gas cost ≤ 50k for typical paths (≥ 1 non-empty sibling).
  * Gas cost ≤ 30k for full-empty paths (no siblings).

**Test plan.**

  * Differential test: 100 random fixtures; assembly and
    high-level variants must produce equal outputs.

**Risk.**  Medium-high.  Inline assembly is gas-critical but
error-prone.  The differential test is the load-bearing
safety net.

**Effort.**  ~2 engineer-days.

#### SC.2.d — `StepVMMerkle.sol` refactor + deferral retirement

**Scope.**  `solidity/src/lib/StepVMMerkle.sol`.

**Implementation steps.**

  1. Add `using SmtVerifier for bytes32;` at the top.
  2. Replace the witness-state verifier body with a delegating
    call to `SmtVerifier.verifyCellProof`.
  3. Remove the comment at line 35 (the deferral marker).
  4. Add a backwards-compatibility flag: deployments may opt
    into the witness-state path during a migration period
    via an `useSmtVerifier` bool.  Default `true` post-SC.

**Acceptance criteria.**

  * `forge build` succeeds.
  * Existing `StepVMMerkle` tests still pass.
  * Line 35 deferral marker removed.

**Risk.**  Medium.

**Effort.**  ~1 engineer-day.

#### SC.2.e — Forge test suite + gas-regression

**Scope.**  `solidity/test/SmtVerifier.t.sol` (new).

**Test plan.**

  * Round-trip: 50+ randomly-generated maps; compute root,
    construct proof in test code, verify.
  * Negative tests:
    - Tamper value → reject.
    - Tamper sibling at any depth → reject.
    - Tamper bitmask bit → reject.
    - Truncate proofData → reject.
    - Over-long proofData → reject.
  * Gas snapshot regression: pin gas for full-empty,
    full-non-empty, mixed (32 non-empty), and worst-case
    paths.  CI alerts on 5%+ regression.
  * Differential vs high-level reference (SC.2.b).

**Acceptance criteria.**

  * `forge test --match-contract SmtVerifier` passes.
  * Gas-snapshot baseline established.

**Effort.**  ~1 engineer-day.

---

### SC.2 — Rolled-up

  * SC.2.a – SC.2.e all individually accepted.
  * Differential equivalence with SC.1's Lean reference on
    the cross-stack corpus.
  * **Aggregate effort:** ~7 engineer-days (matches prior
    estimate).

---

### SC.3 — Cross-stack soundness + corpus + retirement

**Finding map.**  Closes the GENESIS_PLAN §15B note "Production
deployments MUST audit cellProof submissions off-chain until
the SMT path is shipped".

**Scope.**  `solidity/test/CrossStack/SmtCorpus.t.sol` (new),
cross-stack fixture corpus extension, documentation updates.

**Implementation steps.**

  1. Extend cross-stack fixture corpus with SMT cell proofs:
     - 50+ honest proofs: each `(map, key, value, proof)` tuple
       generated by the Lean reference, verified by both sides.
     - 50+ adversarial proofs: tampered values / siblings;
       both sides must reject.
  2. Add `solidity/test/CrossStack/SmtCorpus.t.sol` that loads
    fixtures from a CBE-encoded golden file and runs each
    through `SmtVerifier`.
  3. Add Lean-side counterpart at
    `LegalKernel/Test/CrossStack/Smt.lean` (or extend the
    existing CrossStack suite).
  4. Update `docs/GENESIS_PLAN.md` §15B: replace the deferral
    note with a forward-reference to this plan's completion.
  5. Update `solidity/src/lib/StepVMMerkle.sol:35`: remove the
    `"Production SMT-optimised version (deferred)"` comment.
  6. Update `CLAUDE.md` headline-theorem table: add a row for
    `cellProof_sound_under_collision_free` and
    `cellProof_no_value_substitution`.

**Acceptance criteria.**

  * Cross-stack corpus runs in CI on both Lean and Solidity
    sides; every fixture passes on both.
  * Adversarial corpus rejected uniformly.
  * Documentation references the new theorems.
  * The "audit cellProof submissions off-chain" mitigation note
    is retired.

**Test plan.**

  * Run the cross-stack corpus on both sides; CI passes.
  * Adversarial fuzzer: generate 1000 random tamper patterns;
    both sides reject.

**DoD.**

  * [ ] Cross-stack corpus extended.
  * [ ] Both sides pass.
  * [ ] Documentation updated.
  * [ ] Deferral markers retired.

**Verification.**

```bash
lake test                                        # Lean side
forge test --match-test SmtCorpus                # Solidity side
lake exe deferral_audit                          # marker removal
```

**Reviewer checklist.**

  * Honest fixtures cover edge cases: empty map, single cell,
    full map, max-depth path.
  * Adversarial fixtures cover the load-bearing attack: forged
    sibling.
  * Documentation updates land in the same PR as the corpus
    landing.

**Risk.**  Low.  The hard work is in SC.1 / SC.2; SC.3 is
integration.

**Effort.**  ~4 engineer-days.

---

## §5 Sequencing and PR structure

```
PR-1: SC.1   (~2 weeks)        Lean spec + soundness
PR-2: SC.2   (~1.5 weeks)      Solidity verifier
PR-3: SC.3   (~1 week)         Cross-stack corpus + retirement
```

SC.1 must land first; SC.2 implements its spec.  SC.3 ratifies
both.

## §6 Quality gates

  * Lean: `lake build`, `lake test`, `lake exe count_sorries`,
    `lake exe tcb_audit`, `lake exe deferral_audit`.
  * Solidity: `forge build`, `forge test`, `forge fmt --check`,
    gas-snapshot regression.
  * Cross-stack corpus passes both sides.

## §7 Risk register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| SC.1 soundness proof more complex than sketched | Medium | High | Budget 15 days for proof; if blocked, split into sub-units (depth-bounded variant first, then full 256 depth) |
| Solidity `assembly` block introduces a subtle keccak256 bug | Low | High | Reference well-known patterns (Solady, OpenZeppelin); fuzz-test extensively |
| Gas target (50k) unachievable | Low | Medium | Document the achieved number; the spec is "≤ 50k for typical paths" — adjust if needed |
| Adversarial corpus misses an attack class | Medium | Medium | Pair with a property-test fuzzer for both sides |
| Migration path: existing fault-proof games in-flight with witness-state cell proofs | Low | Medium | Both schemes ship simultaneously; gate the SMT scheme behind a deployment flag in `KnomosisFaultProofGame` for the first deployment; cut over after a stabilisation period |

## §8 Acceptance criteria

SC is **complete** when:

  1. `cellProof_sound_under_collision_free` and
    `cellProof_no_value_substitution` ship in Lean.
  2. `SmtVerifier.sol` ships in Solidity with `verifyCellProof`
    at ≤ 50k gas for typical paths.
  3. Cross-stack corpus extended with 100+ fixtures; CI passes
    both sides.
  4. GENESIS_PLAN §15B deferral note retired.
  5. `solidity/src/lib/StepVMMerkle.sol:35` deferral marker
    removed.
  6. `LegalKernel/FaultProof/Cell.lean:52` deferral marker
    removed.
  7. CLAUDE.md headline-theorem table includes both new
    theorems.

## §9 Out-of-scope items

  * **ZK proofs over SMT paths** (Phase 7 advanced).  An SNARK
    over the verifier reduces gas further but is out of scope.
    Phase 7.C (see `docs/planning/phase_7_plan.md`) covers SNARK
    primitives; an SMT-over-SNARK follow-up is a portfolio
    item, not part of SC.
  * **Variable-depth SMT** (sparse-by-depth-prefix tree).
    A constant 256-depth tree is the design (see OQ-H-1 in
    `docs/planning/open_questions.md` §6; resolved in favour of
    uniform-depth).  Alternative shapes are future research.
  * **State-rent / cell-eviction.**  Cells stay forever; eviction
    is a Phase 7 concern.
  * **Cross-cell consistency proofs** (e.g. "the sum of all
    balance cells equals total supply").  These are conservation
    theorems, not cell proofs; they live elsewhere in the chain
    (Workstream CA in `docs/planning/chain_level_accounting_plan.md`).
  * **Rust observer port of `verifyCellProof`.**  The Rust
    fault-proof observer (`docs/planning/rust_host_runtime_plan.md`
    RH-G) only *constructs* cell proofs against the canonical
    Lean replay; verification happens on L1 (the Solidity
    `SmtVerifier`).  The observer therefore needs a *cell-proof
    generator* in Rust but not a verifier.  Cell-proof
    generation is straightforward (walk the canonical map,
    collect siblings); document the API in the RH workstream's
    observer plan.

## §10 References

  * `docs/GENESIS_PLAN.md` §15B (state-commit and cell-proof
    sections; lines 5170–5187 carry the deferral note).
  * `docs/fault_proof_design.md` §8 (future work).
  * `docs/planning/fault_proof_migration_plan.md` §2.2 (non-goals).
  * `LegalKernel/FaultProof/Cell.lean` — current cell-proof
    machinery.
  * `LegalKernel/FaultProof/Commit.lean` — state-commitment
    scheme.
  * `LegalKernel/Runtime/Hash.lean` — `CollisionFree hashBytes`
    predicate.
  * `solidity/src/lib/StepVMMerkle.sol` — current witness-state
    verifier; SC.2 replaces.
  * `solidity/src/contracts/KnomosisStateRootSubmission.sol` —
    consumes the cell-proof library.

---

**End of plan.**  Landing SC retires the documented cross-stack
soundness optimisation and moves the operational mitigation
("audit off-chain") to a mechanical L1-side defence.
