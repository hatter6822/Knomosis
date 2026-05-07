<!--
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-->

# Phase 5 ABI: On-Disk and On-Wire Contracts (WU 5.10)

This document specifies the byte-level contracts the Phase-5
runtime depends on.  An external implementer (e.g. a Rust network
adaptor for WU 5.4) can reproduce a compatible client by following
this document alone.

> **Audit-3.1 ABI break.**  Pre-Audit-3 logs and snapshots
> (produced before commit `50abca7`, which landed
> "Audit-3.1: hash swap-point and fixed 32-byte width") embedded
> 8-byte `prevHash` and `postStateHash` fields.  Post-Audit-3
> binaries expect 32-byte hashes throughout.  The migration path
> for any pre-Audit-3 data is "throw away the old log file and
> bootstrap fresh"; for research-stage software this is acceptable
> and was the explicit choice in the audit-3 plan.

## 1. Scope

The Phase-5 ABI covers three boundaries:

  1. **The on-disk transition log format** (WU 5.2).
  2. **The on-disk snapshot format** (WU 5.12).
  3. **The on-wire `SignedAction` and `LogEntry` formats** (the
     same as their on-disk forms; the Phase-5 implementation does
     not yet wire a network adaptor, but documents the formats so
     WU 5.4's Rust adaptor can be a drop-in.)

All multi-byte integers are encoded **little-endian** unless
otherwise noted.  The CBE (Canon Binary Encoding) format used
inside payloads is documented in `LegalKernel/Encoding/CBOR.lean`
and Genesis Plan §8.8.

## 2. The Transition Log Format

A Canon log file is a sequence of **frames**, each containing one
`LogEntry`.

### 2.1 Frame structure

```
+---------+------------+----------------------+----------+
| MAGIC   | LENGTH     | PAYLOAD (LogEntry)   | TRAILER  |
| 4 bytes | 8 LE bytes | LENGTH bytes         | 8 LE bytes|
+---------+------------+----------------------+----------+
```

Field details:

  * **MAGIC** (4 bytes): the ASCII string `"CANO"`.  Byte values:
    `0x43 0x41 0x4E 0x4F`.  Exact match required.
  * **LENGTH** (8 LE bytes): the byte count of the PAYLOAD, encoded
    as an unsigned little-endian 64-bit integer.
  * **PAYLOAD**: the canonical CBE encoding of one `LogEntry` (see
    §3 below).
  * **TRAILER** (8 LE bytes): FNV-1a-64 of the PAYLOAD bytes,
    encoded as an unsigned little-endian 64-bit integer.

### 2.2 FNV-1a-64

The FNV-1a-64 hash is computed over the PAYLOAD bytes only (NOT
over the magic / length / trailer):

```
h = 0xcbf29ce484222325
for each byte b in payload:
    h = (h XOR b.to_u64()) * 0x100000001b3   (mod 2^64)
output: h.to_le_bytes()  -- 8 bytes
```

Production deployments may replace the FNV-1a-64 trailer with
BLAKE3-256 (the first 8 bytes thereof, or the full 32 bytes — both
are documented as future migration paths).  The Phase-5 reference
implementation (`canon` / `canon-replay`) uses FNV-1a-64.

### 2.3 Validation

A reader MUST validate frames in this order:

  1. **MAGIC check.**  Reject with `badMagic` if the first 4 bytes
     don't match `"CANO"`.
  2. **LENGTH bound.**  Reject with `truncated` if fewer than
     `LENGTH + 8` bytes remain after the length field (need
     enough for payload + trailer).
  3. **PAYLOAD parse.**  Decode the payload as a `LogEntry`;
     surface the `DecodeError` directly.
  4. **TRAILER check.**  Compute FNV-1a-64 of the payload bytes
     and compare against the trailer; reject with `badTrailer`
     on mismatch.
  5. **Trailing-byte check.**  The payload decoder MUST consume
     exactly `LENGTH` bytes; surface `trailingBytes` if fewer were
     consumed.

### 2.4 Atomicity

The frame layout's design intent is *atomic-or-detectable*:

  * A complete write produces a frame that passes all five checks.
  * A torn write (writer crash mid-flush) leaves a frame that
    fails one of: MAGIC (if the crash happened before the magic
    was flushed), LENGTH (if the crash was in the length bytes),
    PAYLOAD (if the crash was inside the payload — the trailer
    won't match), or TRAILER (if the crash was inside the
    trailer).

The Phase-5 reader's `loadAndTruncate` operation walks the file
frame-by-frame, stopping at the first failure and truncating the
file to the byte offset of that frame.  Crash-consistency
acceptance: 1000 randomized crash points → 1000 successful
recoveries.

## 3. The `LogEntry` CBE Encoding

```
LogEntry := [prevHash, signedAction, postStateHash]
```

Encoded as the concatenation of:

  1. **prevHash** (CBE bytestring): the previous frame's
     `LogEntry.hash` output, OR the 32-byte `zeroHash` (32 zero
     bytes) for the very first frame's `prevHash`.  **Audit-3.1
     fixed-width contract:** all `LogEntry` hashes are exactly
     32 bytes regardless of which hash implementation is linked.
     The Lean fallback emits FNV-1a-64 (8 bytes) zero-padded to
     32; production deployments link a BLAKE3-256 implementation
     under the `canon_hash_bytes` / `canon_hash_stream` C ABI
     symbols, producing 32 bytes directly.  CBE-encoded as
     `0x02 :: <8 LE bytes length=32> :: <32 hash bytes>`.
  2. **signedAction** (CBE structure): the `SignedAction` encoding
     from §4 below.
  3. **postStateHash** (CBE bytestring): the 32-byte hash of the
     post-application `ExtendedState`'s CBE encoding.  Same
     fixed-width contract as `prevHash`.

## 4. The `SignedAction` CBE Encoding

```
SignedAction := [action, signer, nonce, sig]
```

Encoded as the concatenation of:

  1. **action** (CBE Action; see §5).
  2. **signer** (CBE uint, 9 bytes): the actor ID as
     `0x00 :: <8 LE bytes>`.
  3. **nonce** (CBE uint, 9 bytes): the nonce as
     `0x00 :: <8 LE bytes>`.
  4. **sig** (CBE bytestring): the deployment-specific signature
     bytes.  For Ed25519, this is 64 bytes (length prefix + 64
     bytes of payload).

## 5. The `Action` CBE Encoding

The `Action` type has 15 constructors, encoded by their inductive
index (frozen — no phase will renumber existing constructors).
Phase 5 ships indices 0..7; Phase 6 appends 8..11; Workstream B
appends 12; Workstream C appends 13..14.

```
Action.transfer            := 0
Action.mint                := 1
Action.burn                := 2
Action.freezeResource      := 3
Action.replaceKey          := 4
Action.reward              := 5
Action.distributeOthers    := 6
Action.proportionalDilute  := 7
Action.dispute             := 8   -- Phase 6
Action.disputeWithdraw     := 9   -- Phase 6
Action.verdict             := 10  -- Phase 6
Action.rollback            := 11  -- Phase 6
Action.registerIdentity    := 12  -- Workstream B (Ethereum integration)
Action.deposit             := 13  -- Workstream C (bridge L1 → L2)
Action.withdraw            := 14  -- Workstream C (bridge L2 → L1)
```

Each Action is encoded as `<constructor uint> :: <fields>`.  For
example:

```
Action.transfer r sender receiver amount  →
  CBE-uint(0) ++ CBE-uint(r) ++ CBE-uint(sender) ++
  CBE-uint(receiver) ++ CBE-uint(amount)
```

(All five fields are 9-byte CBE uints; total transfer encoding is
`9 * 5 = 45` bytes.)

The full per-constructor table is in
`LegalKernel/Encoding/Action.lean`.

### 5.1 Phase-6 Dispute / Verdict Field Encodings

Phase 6 adds four constructors with the following field layouts:

```
Action.dispute (d : Dispute)  →
  CBE-uint(8) ++ CBE-encode(d)

Action.disputeWithdraw idx  →
  CBE-uint(9) ++ CBE-uint(idx)

Action.verdict (v : Verdict)  →
  CBE-uint(10) ++ CBE-encode(v)

Action.rollback targetIdx  →
  CBE-uint(11) ++ CBE-uint(targetIdx)

Action.registerIdentity actor pk  →
  CBE-uint(12) ++ CBE-uint(actor) ++ CBE-bstr(pk)

Action.deposit r recipient amount depositId  →
  CBE-uint(13) ++ CBE-uint(r) ++ CBE-uint(recipient) ++
  CBE-uint(amount) ++ CBE-uint(depositId)

Action.withdraw r sender amount recipientL1  →
  CBE-uint(14) ++ CBE-uint(r) ++ CBE-uint(sender) ++
  CBE-uint(amount) ++ CBE-bstr(recipientL1)
```

The `Action.withdraw` `recipientL1` field is encoded as a
**lossless 20-byte CBE bytestring** (the big-endian byte form of
`EthAddress = Fin (2^160)`).  An earlier draft truncated to a
9-byte CBE uint, which let two distinct EthAddresses sharing low
64 bits collide on `signingInput`; the audit-2 fix preserves the
full 160-bit address in the signed payload.  See
`Bridge/AddressBook.lean:EthAddress.{toBytes,ofBytes}` for the
big-endian conversion and the `EthAddress.ofBytes_toBytes`
round-trip lemma.

### 5.2 Workstream-B Identity Registration

Workstream B (Ethereum integration §6) adds `Action.registerIdentity`
at frozen index 12.  The constructor enables the bridge actor to
register a new `(actor, pk)` mapping in the `KeyRegistry` for
addresses that have just been assigned an `ActorId` by the
`AddressBook`.

The action's authority-layer effect (registry insertion) is
distinct from `replaceKey` (which is signed by the *old* key);
the bridge runtime distinguishes the two by checking the
`AddressBook` lookup before generating the action.  Deployments
that grant the bridge actor `registerIdentity` authority
(via `AuthorityPolicy.union` with `bridgePolicy`) thereby permit
first-time identity registration without granting general
key-rotation permission.

The `Dispute` payload encodes as:

```
Dispute := { challenger, claim, evidence, nonce, sig }
        →  CBE-uint(challenger.toNat) ++
           CBE-encode(claim) ++
           CBE-bytes(evidence) ++
           CBE-uint(nonce) ++
           CBE-bytes(sig)
```

`DisputeClaim` is a 5-variant tagged union (indices 0..4):

```
DisputeClaim.preconditionFalse idx     := tag 0 ++ CBE-uint(idx)
DisputeClaim.signatureInvalid idx      := tag 1 ++ CBE-uint(idx)
DisputeClaim.nonceMismatch idx         := tag 2 ++ CBE-uint(idx)
DisputeClaim.oracleMisreported idx ev  := tag 3 ++ CBE-uint(idx) ++ CBE-bytes(ev)
DisputeClaim.doubleApply idx₁ idx₂     := tag 4 ++ CBE-uint(idx₁) ++ CBE-uint(idx₂)
```

The `Verdict` payload encodes as:

```
Verdict := { disputeId, outcome, rationale, signers, sigs }
        →  CBE-uint(disputeId) ++
           CBE-encode(outcome) ++
           CBE-bytes(rationale) ++
           CBE-list(signers, of CBE-uint) ++
           CBE-list(sigs,    of CBE-bytes)
```

`EvidenceVerdict` is a 3-variant tag (indices 0..2):

```
EvidenceVerdict.upheld       := tag 0
EvidenceVerdict.rejected     := tag 1
EvidenceVerdict.inconclusive := tag 2
```

The full per-constructor table for the dispute types is in
`LegalKernel/Encoding/Disputes.lean`.

### 5.3 Phase-6 + Workstream-C `Event` Inductive Extension

The §8.9.2 `Event` inductive grows from 5 (Phase 5) to 11
constructors at frozen indices 0..10:

```
Event.balanceChanged       := 0
Event.nonceAdvanced        := 1
Event.identityRegistered   := 2
Event.identityRevoked      := 3
Event.timeRecorded         := 4
Event.disputeFiled         := 5  -- Phase 6
Event.disputeWithdrawn     := 6  -- Phase 6
Event.verdictApplied       := 7  -- Phase 6
Event.rewardIssued         := 8  -- Phase-6 incentive amendment
Event.withdrawalRequested  := 9  -- Workstream C (bridge)
Event.depositCredited      := 10 -- Workstream C (bridge)
```

`Event.rewardIssued (resource, recipient, amount)` is emitted
by `actionEvents` for every `Action.reward _ _ _` (in addition
to the kernel-level `balanceChanged` event, which is delta-
filtered).  Indexers that subscribe to deployment-level reward
semantics filter on `rewardIssued`; indexers that observe
kernel-level balance deltas use `balanceChanged`.

The Phase-5 indexer schema continues to deserialise correctly
under the Phase-6 schema; new event constructors are simply
unrecognised by Phase-5-only consumers.

### 5.3 Phase-6 Incentive-Integration Amendment Runtime Structures

The amendment introduces three deployment-runtime structures
that are NOT serialised to disk but DO emit `Action`s the runtime
must sign and append to the log via `apply_admissible`:

  * **`DisputeRewardPolicy`** — a deployment-supplied policy
    that returns `Option (ResourceId × Amount)` for the
    challenger and per-adjudicator rewards.  Atomic
    constructors: `empty`, `flatChallengerReward`,
    `flatAdjudicatorReward`, `union` (left-biased fallthrough).
    Graduated constructors: `byClaimVariant`,
    `proportionalChallengerReward`.  Emits a list of
    `Action.reward` records via `disputeRewardActions`.

  * **`StakingPolicy`** — a deployment-supplied anti-fraud
    staking policy with `(stakeResource, stakeAmount,
    escrowActor, treasuryActor)`.  Emits a single
    `Action.transfer` from challenger to escrow at filing time
    (`stakeFilingActions`) and a single
    `Action.transfer` from escrow to treasury at resolution
    time on rejected/inconclusive verdicts
    (`stakeResolutionActions`).  Upheld verdicts emit no
    resolution action — the rollback to
    `log[0..impugnedIdx-1]` implicitly returns the stake by
    replaying to a state BEFORE the staking transfer.

  * **List `DisputeRewardPolicy`** — a multi-policy bundle
    supporting cross-resource rewards.  `disputeRewardActionsMulti
    policies log d v` returns the foldr-concatenation of
    `disputeRewardActions p log d v` over each `p` in
    `policies`.

External implementers reproducing a Canon-compatible client
must respect these emission semantics: rewards via
`Action.reward`, staking via `Action.transfer`, never `burn`
(which would break the kernel-level monotonicity firewall).

## 6. The `Snapshot` Encoding

```
Snapshot := [stateHash, encodedState, logIndex, seedHash]
```

Encoded as the concatenation of:

  1. **stateHash** (CBE bytestring, 32 bytes payload after
     Audit-3.1).
  2. **encodedState** (CBE bytestring, variable length): the CBE
     encoding of the `ExtendedState`, length-prefixed as a
     bytestring (so a snapshot reader can skip past it without
     parsing).
  3. **logIndex** (CBE uint, 9 bytes).
  4. **seedHash** (CBE bytestring, 32 bytes payload after
     Audit-3.1).

Snapshots are written to a single file with no framing; readers
parse the entire file as one `Snapshot` record.

## 7. The Sign-Input Encoding (§8.8.5)

The bytes a signer attests to:

```
signInput(action, signer, nonce, deploymentId) :=
  CBE-bytestring("legalkernel/v1/signedaction") ++
  CBE-bytestring(deploymentId) ++
  CBE(action) ++
  CBE-uint(signer) ++
  CBE-uint(nonce)
```

The domain string `"legalkernel/v1/signedaction"` is 27 ASCII
bytes; its CBE-bytestring form is `0x02 :: <0x1B 0x00 0x00 0x00
0x00 0x00 0x00 0x00> :: <27 bytes>` = 36 bytes.  The deployment ID
is the genesis state hash (32 bytes after Audit-3.1's fixed-width
hash unification).

Production deployments hash the resulting bytes with BLAKE3-256
(or whatever hash the `Verify` adaptor expects) and pass the
digest to `Verify`.  The Phase-5 stub passes the bytes themselves
(since `Verify` is opaque at the Lean level).

## 8. The Runtime CLI (`canon`) ABI

The `canon` binary exposes six subcommands plus a `help` alias
(Workstream D added the sixth):

```
canon [GLOBAL_FLAGS] info
canon [GLOBAL_FLAGS] process          LOG IN [OUT]
canon [GLOBAL_FLAGS] replay           LOG
canon [GLOBAL_FLAGS] bootstrap        LOG
canon [GLOBAL_FLAGS] snapshot         LOG SNAP_PATH
canon [GLOBAL_FLAGS] withdrawal-proof SNAP_PATH ID
canon help
```

Global flags (Audit-3.1):

  * `--allow-fallback-hash`  — suppress the WARN-on-startup line
                               emitted when the binary is running
                               with the Lean fallback hash
                               (FNV-1a-64 padded to 32 bytes).
                               Use only for explicit test runs.

Argument semantics:

  * `LOG`        — path to the append-only log file.
  * `IN`         — path to a binary file of concatenated
                   `SignedAction` CBE records (no framing —
                   each record's CBE encoding terminates exactly
                   at the next record's start).
  * `OUT`        — optional; path to write the final 32-byte
                   `ContentHash` (Audit-3.1 fixed-width).
  * `SNAP_PATH`  — path to write or read the `Snapshot` encoding.
  * `ID`         — a `WithdrawalId` (Nat) to look up in the
                   snapshot's `bridge.pending` map (Workstream D.2).

Exit codes:

  * `0` — success.
  * `1` — runtime error (bootstrap failed, parse error, replay
          failed, etc.).
  * `2` — argument error (unrecognised subcommand).

Output format (stdout):

  * `canon info` — five lines (Audit-3.1): name, build tag, phase
    tag, `hash: <implementation-identifier>`, `hash-grade:
    <production|fallback>`.
  * `canon process` — bootstrap diagnostic, then one line per
    processed action (`[idx] OK (n events)` or `[idx] FAIL
    (<error>)`), then `final state hash: <hex>`, then optionally
    a confirmation line if `OUT` was provided.
  * `canon replay` — one line `parsed N entries`, then either
    `final state hash: <hex>` on success or `replay failed:
    <repr>` on stderr with exit 1.
  * `canon bootstrap` — diagnostic block including log index,
    prev hash, state hash; optionally a `warning: truncated
    partial tail` line on stderr when the log was torn.
  * `canon snapshot` — diagnostic block including state hash, log
    index, and confirmation of the snapshot file write.
  * `canon withdrawal-proof` (Workstream D.2) — `leaf : <hex>`,
    `index : <decimal>`, `siblings:` followed by 64 indented
    hex lines (root-to-leaf order), then `root : <hex>`
    (the snapshot's `bridgeWithdrawalRoot` against which the
    L1 verifier hashes the path).  Exit 1 if the snapshot file
    fails to load or the id is not in the snapshot's pending
    set; exit 2 if the `ID` argument is not a valid Nat.

### 8.1 Workstream-D `WithdrawalProof` On-Wire Format

The `WithdrawalProof` is the data the user submits to L1 for
withdrawal redemption.  Its structure (per
`Bridge/WithdrawalRoot.lean`):

```lean
structure WithdrawalProof where
  leaf     : ByteArray                 -- canonical CBE encoding of PendingWithdrawal
  index    : WithdrawalId              -- Nat
  siblings : Vector ByteArray smtHeight  -- exactly 64 32-byte hashes
```

Convention: `siblings[0]` is the **root-adjacent** sibling (depth
1), `siblings[63]` is the **leaf-adjacent** sibling (depth 64).
The verifier walks leaf-to-root: at iteration `level` (0..63), it
combines the current value with `siblings[63 - level]` via
`hashUp H bit current sibling` where `bit = (idx >>> level) & 1`
(LSB-up).

The hex output of `canon withdrawal-proof` is a human-readable
representation; production deployments serialise the proof to
the wire format expected by `CanonBridge.sol` (Workstream E.1.3),
which is a concatenation of `leaf || siblings[0] || siblings[1]
|| ... || siblings[63]` plus a fixed-width index encoding.

```
canon-replay [--allow-fallback-hash] LOG [SNAPSHOT]
```

Global flags (Audit-3.1):

  * `--allow-fallback-hash`  — required to run with the Lean
                               fallback hash.  Without it,
                               `canon-replay` exits non-zero with
                               `FALLBACK_HASH_NOT_PERMITTED`
                               (the auditor's reproduction
                               guarantee is meaningless under a
                               non-cryptographic hash).

Output format (one or two lines):

  * `OK <64-hex-chars> via=<implementation-identifier>` on a clean
    replay (Audit-3.1 fixed 32-byte width × 2 hex chars per byte =
    64 hex chars; `via=fnv1a64-padded-32` for the Lean fallback,
    `via=blake3-256` for the production adaptor).
  * `FALLBACK_HASH_NOT_PERMITTED` (Audit-3.1) on the fallback hash
    without `--allow-fallback-hash`.
  * `REPLAY_ERROR <repr>` on a replay-time failure.
  * `SNAPSHOT_ERROR <repr>` when a requested snapshot fails to
    restore (decoded but `stateHash` did not match the recomputed
    hash, etc.).
  * `SNAPSHOT_DECODE_ERROR <repr>` when the snapshot bytes don't
    parse (corrupt / truncated / wrong type / missing file).
  * `SNAPSHOT_INDEX_OVERRUN snap_index=N log_entries=M` when the
    snapshot's `logIndex` exceeds the log file's entry count
    (deployment-level inconsistency: snapshot taken at a point
    the log no longer covers).
  * `LOG_TRUNCATED entries=<count>` (info line, written before
    the success / error line) when the log file had a partial
    tail; replay still proceeds against the recovered prefix.

**Snapshot+log semantics (Genesis Plan §13.2).**  When a snapshot
is provided, the LOG file is the *full* log (not pre-sliced).
`canon-replay` slices the log to entries `[snap.logIndex..)` to
apply "only subsequent log entries".  The tool refuses to produce
an `OK` line if the snapshot fails to restore or if the
`logIndex` is inconsistent with the log file.

**Security contract.**  The tool refuses to print an `OK <hash>`
line when a requested snapshot fails to restore.  Earlier drafts
silently fell back to the empty genesis state, producing a
hash-of-empty-state line that masked the snapshot failure.  The
current implementation exits 1 without proceeding to replay if the
snapshot was requested but cannot be recovered.

Exit codes: `0` on `OK`, `1` on any failure (snapshot or replay).

## 10. Future Network ABI (WU 5.4 placeholder)

When the Rust network adaptor lands, it will expose:

  * **Wire format**: a length-prefixed `SignedAction` CBE record
    over TCP, followed by a single `Verdict`-style response byte
    (0 for OK, 1 for `notAdmissible`, 2 for parse error).
  * **Unix socket protocol**: the runtime listens on a
    deployment-configurable Unix socket path; the Rust adaptor
    relays incoming TCP requests through it.
  * **Authentication**: the Rust adaptor enforces TLS at the TCP
    boundary; the Unix socket is filesystem-permission-protected.

This section will be expanded in the WU 5.4 follow-up PR.

## 11. Hash Swap-Point ABI (Audit-3.1)

The runtime's content-hash function is defined in
`LegalKernel/Runtime/Hash.lean` with three documented swap-point
symbols.  Production deployments override these via link-time
substitution to a vetted BLAKE3-256 implementation; the Lean
fallback (FNV-1a-64 zero-padded to 32 bytes) is the test-build
default.

Documented C ABI symbol names:

  * `canon_hash_bytes`        — `ContentHash f(ByteArray bs)`.
                                Hashes a byte array; returns a
                                32-byte content hash.
  * `canon_hash_stream`       — `ContentHash f(List<UInt8> s)`.
                                Hashes a byte stream (list); same
                                32-byte width.
  * `canon_hash_identifier`   — `String f(Unit)`.  Returns the
                                implementation identifier.  Lean
                                fallback returns
                                `"fnv1a64-padded-32"`; BLAKE3-256
                                deployment returns `"blake3-256"`.

Theorems about these functions reason about the Lean body, not
the linked implementation.  Production-grade implementations
must respect the same width / purity contract: deterministic
across invocations, exactly 32 bytes output, no IO side effects.

`isProductionHash : Bool` is the runtime-introspectable flag
derived from the identifier (`true` iff the identifier ≠
`"fnv1a64-padded-32"`).  The CLI binaries (`canon`,
`canon-replay`) read it at startup to decide whether to emit
the fallback warning or fail-fast.

## 12. Solidity-side ABI surface (Workstream E)

Workstream E ships the L1 Solidity mirror of the kernel as five
immutable contracts in `solidity/`.  Each contract's external
ABI is its public Solidity interface (`solidity/src/interfaces/
ICanon*.sol`); the integration plan §9 lists the per-contract
critical correctness obligations.  This section documents the
ABI invariants that downstream consumers (deployment scripts,
indexers, off-chain watchers) can rely on.

### 12.1 Cross-contract reference shape

Every Canon Solidity contract exposes:

  * `function deploymentId() external view returns (bytes32)` —
    `keccak256(abi.encode(block.chainid, address(this),
    canonVersionTag))`.  Computed in the constructor; immutable.
    Mirror of the Lean §8.8.5 `deploymentId`.

`CanonBridge`, `CanonDisputeVerifier`, `CanonSequencerStake`
each additionally expose:

  * `attestor() / disputeVerifier() / sequencerStake() /
    bridge() / migration()` getters returning the immutable
    addresses set in the constructor.  No setter exists.
  * `assertConsistent() external view returns (bool)` — checks
    the symmetric cross-contract reference (e.g.
    verifier.bridge().disputeVerifier() == address(this)).  This
    is the post-deploy auditor surface; it cannot revert.

### 12.2 Custom-error catalogue

Every revert path uses a typed custom error (no string
reverts).  Selectors are stable across deployments because the
error names are part of the contract's frozen surface:

  * `CanonBridge`: `NotAttestor`, `NotDisputeVerifier`,
    `AttestationStale`, `DisputeCooldown`, `TvlCapReached`,
    `MigrationActivated`, `NonMonotonic`, `UnknownStateRoot`,
    `StateRootReverted`, `PreFinalisation`, `AlreadyRedeemed`,
    `InvalidProof`, `InvalidLeafSizeForResource`,
    `UnsupportedResource`, `EthValueMismatch`,
    `InvariantViolation_DisputeWindowVsRedemption`,
    `BridgeAccountingMismatch(uint256 totalLockedValue, uint256 amountRequested)`
    (added by audit-1; reserved specifically for the TVL
    underflow check at withdrawal time, distinct from the
    constructor-time invariant check),
    `InvalidSignatureLength`,
    `ZeroSequencerStake` (added by audit-2),
    `DuplicateResourceToken(address token)` (added by audit-2),
    `TransferAmountMismatch(uint256 declared, uint256 received)`
    (added by audit-2; rejects fee-on-transfer / rebasing
    ERC-20s),
    `InvalidRecipient` (added by audit-3; rejects withdrawals
    to address(0)).
  * `CanonDisputeVerifier`: `NotApprovedAdjudicator`,
    `UnknownDispute`, `AlreadyDecided`, `NotOpen`,
    `QuorumNotMet`, `EvidenceNotUpheld`, `EvidenceNotRejected`,
    `SelfClaimInvalid`, `InvalidClaimVariant`,
    `MaxPrefixLenExceeded`, `PrefixSignerMissing`,
    `InvalidSignatureLength`, `VerifierBridgeMismatch`,
    `ZeroAddress`, `QuorumThresholdOutOfRange`, `VerdictReplay`,
    `EvidenceBlobTooLarge(uint256 actual, uint256 maxBytes)`
    (added by audit-1), `TooManySigners(uint256 supplied,
    uint256 maxAllowed)` (added by audit-1),
    `MissingSignerHint` (added by audit-1),
    `DoubleApplyConcatBadCount(uint64 declared, uint64 expected)`
    (added by audit-3; rejects malformed
    `_runDoubleApplyFromConcat` blobs).
  * `CanonIdentityRegistry`: `PubkeyAddressMismatch`,
    `WrongPubkeyLength`, `NotEip1271Conforming`,
    `AlreadyRegistered`, `NotRegistered`.
  * `CanonSequencerStake`: `NotSequencer`,
    `NotDisputeVerifier`, `InsufficientStake`,
    `WithdrawDuringOpenDispute`, `AlreadySlashed`,
    `SlashRatioOutOfRange`, `ZeroAddress`, `EthSendFailed`.
  * `CanonMigration`: `ZeroAddress`, `SelfMigration`,
    `GraceTooShort`, `SameDeploymentId`,
    `PredecessorDoesNotReferenceThisMigration` (renamed from
    `SuccessorDoesNotReferenceThisMigration` in audit-3 to
    reflect the corrected semantics — the migration freezes the
    PREDECESSOR's state-shaping calls, so the predecessor must
    pre-commit to be retired by THIS migration via its own
    `migration` immutable),
    `AttestationInvalid`, `AlreadyActivated`, `GraceNotElapsed`,
    `InvalidSignatureLength`.

### 12.3 Frozen claim-variant indices (CanonDisputeVerifier)

Per the integration plan §9.2.1 / §9.2.4, dispute claim variants
have frozen `uint8` indices that mirror Lean's
`Disputes.Types.DisputeClaim` constructor order.  Adding a
new variant requires a new dispute-verifier deployment plus a
`CanonMigration` handoff (no in-place extension path).

  * `0` — `CLAIM_PRECONDITION_FALSE` (deferred to v2)
  * `1` — `CLAIM_SIGNATURE_INVALID` (E.2.2; MVP)
  * `2` — `CLAIM_NONCE_MISMATCH` (E.2.3; MVP)
  * `3` — `CLAIM_ORACLE_MISREPORTED` (deferred to v2)
  * `4` — `CLAIM_DOUBLE_APPLY` (E.2.4; MVP)

Verdict outcomes (frozen):

  * `0` — `VERDICT_UPHELD`
  * `1` — `VERDICT_REJECTED`
  * `2` — `VERDICT_INCONCLUSIVE`

Dispute statuses (frozen):

  * `0` — `STATUS_OPEN`
  * `1` — `STATUS_UPHELD`
  * `2` — `STATUS_REJECTED`
  * `3` — `STATUS_INCONCLUSIVE`
  * `4` — `STATUS_WITHDRAWN`

### 12.4 Withdrawal proof on-chain shape

The `CanonBridge.withdrawWithProof(uint64 atLogIndexHigh,
bytes proofBlob, bytes leafBlob)` function expects:

  * `leafBlob` — CBE-encoded `PendingWithdrawal`:
      uint  resourceId    (CBE: 9 bytes)
      bytes recipientL1   (CBE: 1 tag + 8 length + 20 payload = 29 bytes)
      uint  amount        (9 bytes)
      uint  l2LogIndex    (9 bytes)
      → total: 56 bytes (audit-2 lossless 20-byte address encoding).
  * `proofBlob` — CBE encoding of the `WithdrawalProof`
    (post-audit-2; mirrors Lean's `WithdrawalProof` shape
    with variable-size leaf and siblings):
      bytes leaf          (CBE bytes; mirrors Lean's
                            `WithdrawalProof.leaf : ByteArray` —
                            ≈ 56 bytes for populated, 32 for
                            sentinel; equals leafBlob byte-for-byte
                            for canonical proofs)
      uint  index         (9 bytes)
      array siblings[64]  (CBE array head + 64 × CBE bytes; each
                            sibling is variable-size — typically
                            32 bytes for the 32-byte default-hash
                            values, but can be ~56 bytes for the
                            leaf-adjacent sibling in the
                            dense-pair case).
      → typical sparse total: ≈ 2700 bytes; dense-pair total:
        ≈ 2725 bytes.

The pre-audit-2 design used `bytes32 leafHash` and 64 fixed
32-byte siblings; this was incompatible with Lean's
variable-size `WithdrawalProof.leaf : ByteArray` and broke
cross-stack equivalence in the dense-pair case.  The
post-audit-2 design uses variable-size bytes throughout,
matching Lean exactly.

The Solidity-side `SmtVerifier.recomputeRoot(idx, leaf,
siblings)` mirrors `LegalKernel.Bridge.WithdrawalRoot.verifyProofRec`
line-for-line.  The cross-stack F.1.5 fixture (workstream F)
asserts byte-equivalence across 64 randomised inputs.

### 12.5 Verdict signature shape (post-audit-1)

`CanonDisputeVerifier.finalizeUpheld` /
`finalizeRejected` expect adjudicator signatures over the
on-chain-derived verdict digest:

  digest = `verdictDigest(disputeId, outcome)` =
    keccak256(0x1901 ‖ domainSeparator ‖ structHash) where
    domainSeparator = keccak256(EIP712Domain(
        "CanonDisputeVerifier", "1", chainId, 0,
        canonDisputeVerifierAddress
    ))
    structHash = keccak256(Verdict(
        disputeId,            // uint64 → uint256
        outcome,              // uint8  → uint256
        deploymentId          // bytes32 verbatim
    ))

The `verdictDigest(uint64, uint8)` view is exposed publicly so
off-chain tooling can reproduce the digest before signing.

The previous design accepted a `bytes32 verdictHash`
parameter from the caller and trusted it; this allowed
adjudicator signatures to be replayed across disputes (sign
once, replay for ANY dispute).  The audit-1 fix removes the
parameter and derives the digest from `(disputeId, outcome,
deploymentId)`.

### 12.6 signatureInvalid claim signature shape

`CanonDisputeVerifier.checkSignatureInvalid(logEntryBlob,
signerHint)` reconstructs the digest the user signed when
producing the impugned `LogEntry`:

  domainSeparator = keccak256(EIP712Domain(
      "CanonAction", "1", chainId, 0,
      bridgeAddress
  ))
  structHash = `actionStructHash(actionHash, signer, nonce,
      bridge.deploymentId())`
  digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)

The `signerHint` argument is the L1 address corresponding
to the LogEntry's `uint64 signer` actor-id.  The runtime
adaptor's L1 ingestor (workstream B.2) provides the
resolution; the on-chain `CanonIdentityRegistry` keys
records by address, so the dispute filer must supply the
mapping.

### 12.7 Migration attestation shape

The `CanonMigration` constructor's
`_attestorSig` argument is a 65-byte ECDSA signature over the
EIP-712 wrap:

  domainSeparator = keccak256(EIP712Domain(
      "Canon", "1", chainId, 0, migrationContractAddress
  ))
  structHash = keccak256(CanonMigration(
      predecessorDeploymentId,
      successorDeploymentId,
      migrationStateRoot,
      migrationStateRootLogIdx,
      graceWindowBlocks
  ))
  digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)

The attestor signs the digest off-chain; the Solidity
constructor recovers the signer via OpenZeppelin's `ECDSA.recover`
(low-s canonicalisation enforced by OZ).

### 12.8 EIP-712 sign-input shape (state root attestations)

`CanonBridge.submitStateRoot(bytes32 root, uint64 logIndexHigh,
bytes attestorSig)` expects a 65-byte ECDSA signature over:

  domainSeparator = keccak256(EIP712Domain(
      "CanonBridge", "1", chainId, 0, bridgeAddress
  ))
  structHash = keccak256(StateRoot(
      root,
      logIndexHigh,
      deploymentId
  ))
  digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)

This shape is the on-chain mirror of Lean's `signedActionDomain`.

### 12.9 Deployment-time contract addresses

Per workstream E (and the integration plan §9), production
deployments use `CREATE3` with deterministic salts so the bridge
↔ verifier ↔ stake reference cycle can be resolved before
deployment (each contract's predicted address depends only on
`(deployer, salt)`, independent of init-code).  The
`solidity/test/utils/Deployer.sol` reference implementation uses
salts `keccak256("canon-bridge-salt")`,
`keccak256("canon-dispute-verifier-salt")`, and
`keccak256("canon-sequencer-stake-salt")`.  Mainnet deployments
should pick deployment-specific salts (e.g.
`keccak256(abi.encode(deploymentId, "bridge"))`).

## 13. References

  * `LegalKernel/Encoding/CBOR.lean` — CBE primitive layer.
  * `LegalKernel/Encoding/Action.lean` — Action encoding.
  * `LegalKernel/Encoding/SignedAction.lean` — SignedAction
    encoding.
  * `LegalKernel/Encoding/State.lean` — State / ExtendedState
    encoding.
  * `LegalKernel/Runtime/LogFile.lean` — frame layout +
    crash-consistency.
  * `LegalKernel/Runtime/Snapshot.lean` — snapshot format.
  * `solidity/README.md` — Workstream E developer guide.
  * `solidity/src/contracts/*.sol` — five immutable Solidity
    contracts (E.1 – E.5).
  * `solidity/src/lib/{CBEDecode, SmtVerifier, CanonEip712,
    CREATE3}.sol` — the cross-cutting libraries.
  * Genesis Plan §8.7 (Persistence and Logging)
  * Genesis Plan §8.8 (Canonical Encoding)
  * Genesis Plan §13.2 (Repository Layout — for the file paths above)
  * `docs/ethereum_integration_plan.md` §9 (Workstream E spec).
  * `docs/ethereum_integration_plan.md` §20 (Immutability amendment).
