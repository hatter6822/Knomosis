<!--
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
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
otherwise noted.  The CBE (Knomosis Binary Encoding) format used
inside payloads is documented in `LegalKernel/Encoding/CBOR.lean`
and Genesis Plan §8.8.

## 2. The Transition Log Format

A Knomosis log file is a sequence of **frames**, each containing one
`LogEntry`.

### 2.1 Frame structure

```
+---------+------------+----------------------+----------+
| MAGIC   | LENGTH     | PAYLOAD (LogEntry)   | TRAILER  |
| 4 bytes | 8 LE bytes | LENGTH bytes         | 8 LE bytes|
+---------+------------+----------------------+----------+
```

Field details:

  * **MAGIC** (4 bytes): the ASCII string `"KNOM"`.  Byte values:
    `0x4B 0x4E 0x4F 0x4D`.  Exact match required.
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
implementation (`knomosis` / `knomosis-replay`) uses FNV-1a-64.

### 2.3 Validation

A reader MUST validate frames in this order:

  1. **MAGIC check.**  Reject with `badMagic` if the first 4 bytes
     don't match `"KNOM"`.
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
     under the `knomosis_hash_bytes` / `knomosis_hash_stream` C ABI
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

The `Action` type has 19 constructors, encoded by their inductive
index (frozen — no phase will renumber existing constructors).
Phase 5 ships indices 0..7; Phase 6 appends 8..11; Workstream B
appends 12; Workstream C appends 13..14; Workstream LP (actor-
scoped policies) appends 15..16; Workstream H (fault-proof
migration) appends 17..18.

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
Action.declareLocalPolicy  := 15  -- Workstream LP (actor-scoped policies)
Action.revokeLocalPolicy   := 16  -- Workstream LP (actor-scoped policies)
Action.faultProofChallenge  := 17 -- Workstream H (fault-proof migration)
Action.faultProofResolution := 18 -- Workstream H (fault-proof migration)
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

Action.declareLocalPolicy policy  →
  CBE-uint(15) ++ CBE-encode(policy : LocalPolicy)

Action.revokeLocalPolicy  →
  CBE-uint(16)

Action.faultProofChallenge bindingHash sIdx eIdx challengerCommit  →
  CBE-uint(17) ++ CBE-bstr(bindingHash) ++ CBE-uint(sIdx) ++
  CBE-uint(eIdx) ++ CBE-bstr(challengerCommit)

Action.faultProofResolution bindingHash gameId winner revertFromIdx  →
  CBE-uint(18) ++ CBE-bstr(bindingHash) ++ CBE-uint(gameId) ++
  CBE-uint(winner) ++ CBE-uint(revertFromIdx)
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

### 5.3 Phase-6 + Workstream-C + Workstream-LP + Workstream-H `Event` Inductive Extension

The §8.9.2 `Event` inductive grows from 5 (Phase 5) to 16
constructors at frozen indices 0..15 (and is further extended to
20 by Workstream GP — indices 16..19, documented in the
"Workstream-GP `Event` Inductive Extension" subsection below):

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
Event.localPolicyDeclared  := 11 -- Workstream LP (actor-scoped policies)
Event.localPolicyRevoked   := 12 -- Workstream LP (actor-scoped policies)
Event.faultProofGameOpened    := 13 -- Workstream H (fault-proof migration)
Event.faultProofBisectionStep := 14 -- Workstream H (fault-proof migration)
Event.faultProofGameSettled   := 15 -- Workstream H (fault-proof migration)
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

### 5.3 Workstream-GP `Event` Inductive Extension

The unified-gas-pool workstream (§15E) appends five more `Event`
constructors at frozen indices 16..20:

```
Event.depositWithFeeCredited     := 16 -- GP §15E v1.0 (fee-split deposit)
Event.actionBudgetTopUp          := 17 -- GP §15E v1.0 (self-funded top-up)
Event.gasPoolClaim               := 18 -- GP §15E v1.0 (pool drain; GP.7)
Event.delegatedActionBudgetTopUp := 19 -- GP.3.4 (delegated top-up)
Event.budgetConsumed             := 20 -- GP.6.4 (per-action budget debit)
```

Field layouts (mirrored from `LegalKernel/Events/Types.lean`, each
field a CBE uint head):

| Tag | Constructor                  | Fields                                                                       |
|-----|------------------------------|------------------------------------------------------------------------------|
| 16  | `depositWithFeeCredited`     | `resource, recipient, poolActor, userAmount, poolAmount, budgetGrant, depositId` |
| 17  | `actionBudgetTopUp`          | `signer, gasResource, gasAmount, budgetIncrement, poolActor`                 |
| 18  | `gasPoolClaim`               | `resource, sequencer, amount`                                                |
| 19  | `delegatedActionBudgetTopUp` | `recipient, signer, gasResource, gasAmount, budgetIncrement, poolActor`      |
| 20  | `budgetConsumed`             | `actor, amount`                                                              |

`depositWithFeeCredited` (16) is emitted IN ADDITION to the
kernel-level `balanceChanged` (0) on a fee-split deposit, so an
indexer can distinguish a fee-split deposit (with its budget-grant
breakdown) from a legacy `depositCredited` (10).  Indexers
maintaining a per-actor budget view (WU GP.6.4) credit the
*recipient* on tag 19 (NOT the signer/payer), per the delegated
top-up semantics.

`budgetConsumed` (20, GP.6.4) is emitted by `extractEvents` on
every admitted action whose signer is NOT exempt from budget
consumption — i.e. `signer ≠ Bridge.bridgeActor` (the bridgeActor
is exempt per the GP.3.2.c kernel consume-exemption) AND the
deployment runs a `.bounded freeTier actionCost _` policy with
`actionCost > 0`.  The `amount` is exactly the kernel's
`actionCost` (`EpochBudgetState.consume` debits precisely that
much).  Indexers consume tag 20 to maintain a per-epoch "budget
consumed" counter and compute "N actions remaining this epoch"
(see §11A).

These tags carry no change to the §11 EVENT-frame layout — they
emit at the existing 9-byte CBE tag head (§11.1) and stream
additively.  The Rust-side streamer's tag registry
(`runtime/knomosis-event-subscribe/src/event_type.rs`) mirrors all
five.

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

External implementers reproducing a Knomosis-compatible client
must respect these emission semantics: rewards via
`Action.reward`, staking via `Action.transfer`, never `burn`
(which would break the kernel-level monotonicity firewall).

### 5.4 Workstream-LP `LocalPolicy` CBE Encoding

Workstream LP (actor-scoped policies) introduces a
`LocalPolicy` first-order data type that on-chain actors can
declare via `Action.declareLocalPolicy` (frozen index 15) to
constrain their *own* outgoing actions.  The `LocalPolicy`
encoding:

```
LocalPolicy := { clauses : List LocalPolicyClause }
LocalPolicy.encode lp  →  CBE-array of CBE-encode(clauses[i])
```

The `LocalPolicyClause` inductive has 3 frozen-index variants
(LP §3.6):

```
LocalPolicyClause.denyTags          := tag 0
LocalPolicyClause.requireRecipientIn := tag 1
LocalPolicyClause.capAmount         := tag 2
```

Per-clause field encodings:

```
LocalPolicyClause.denyTags tags  →
  CBE-uint(0) ++ CBE-array(CBE-uint(t) for t in tags)

LocalPolicyClause.requireRecipientIn r allowed  →
  CBE-uint(1) ++ CBE-uint(r) ++ CBE-array(CBE-uint(a) for a in allowed)

LocalPolicyClause.capAmount r max  →
  CBE-uint(2) ++ CBE-uint(r) ++ CBE-uint(max)
```

The `ExtendedState.localPolicies` field is encoded as a sorted-
key CBE map of `(ActorId, encoded-policy-bytes)` pairs, mirroring
the `KeyRegistry` and `BridgeState.consumed` patterns.  The
post-LP `ExtendedState.encode` appends a 5th segment to the
existing 4-segment encoding (`base ++ nonces ++ registry ++
bridge ++ localPolicies`).  Pre-LP snapshots cannot be decoded
by the post-LP `ExtendedState.decode`; operators upgrade by
re-snapshotting under the post-LP build (see Workstream-LP plan
§4.5 / §12.4).

#### 5.4.1 DoS bounds (frozen)

```
MAX_CLAUSES_PER_POLICY      := 64
MAX_TAGS_PER_DENY           := 64
MAX_RECIPIENTS_PER_REQUIRE  := 64
MAX_POLICY_ENCODE_BYTES     := 16_384
```

These are part of the on-wire ABI contract; the canonical
decoder rejects oversize policies as
`DecodeError.invalidLength` (or fails the
`LocalPolicy.fieldsBounded` decidability check at the encoder
level).  Loosening any bound requires the §13.6 two-reviewer
gate.

#### 5.4.2 Admissibility extension (LP.7)

The `Admissible` predicate gains a 5th top-level conjunct (the
6th condition in §8.2):

```
Admissible P es st  ↔  ... ∧ localPolicyPermits es st.signer st.action
```

where `localPolicyPermits` is:

```
localPolicyPermits es signer action  ↔
  isMetaPolicyAction action = true ∨
  (es.localPolicies.lookup signer).permits signer action
```

`isMetaPolicyAction` returns `true` for `declareLocalPolicy` and
`revokeLocalPolicy` only; this is the structural lockout-
prevention exemption.  Actors with no declared policy see no
admissibility narrowing (the `LocalPolicy.empty.permits` is
vacuously `True`).

#### 5.4.3 Future Solidity-port shape

The Solidity-side mirror of LP is documented in
`solidity/README.md`'s "Future: actor-scoped policies" section.
It will require:

  1. A CBE decoder in `solidity/src/lib/CBEDecode.sol` for the
     `LocalPolicy` and `LocalPolicyClause` types (mirroring the
     Lean codec line-for-line, with the same DoS bounds).
  2. An admissibility-check call in
     `KnomosisBridge.depositETH` / `depositERC20` that consults the
     depositor's L2 `localPolicies` lookup before crediting (a
     defensive layer; the L2 admissibility check already enforces
     this — the Solidity-side check is for fast L1 user feedback).
  3. Two new event-listener mappings for `LocalPolicyDeclared` /
     `LocalPolicyRevoked` in the indexer.

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

## 8. The Runtime CLI (`knomosis`) ABI

The `knomosis` binary exposes six subcommands plus a `help` alias
(Workstream D added the sixth):

```
knomosis [GLOBAL_FLAGS] info
knomosis [GLOBAL_FLAGS] process          LOG IN [OUT]
knomosis [GLOBAL_FLAGS] replay           LOG
knomosis [GLOBAL_FLAGS] bootstrap        LOG
knomosis [GLOBAL_FLAGS] snapshot         LOG SNAP_PATH
knomosis [GLOBAL_FLAGS] withdrawal-proof SNAP_PATH ID
knomosis help
```

Global flags (Audit-3.1 + AR.2.6):

  * `--allow-fallback-hash`  — suppress the WARN-on-startup line
                               emitted when the binary is running
                               with the Lean fallback hash
                               (FNV-1a-64 padded to 32 bytes).
                               Use only for explicit test runs.
  * `--deployment-id <hex>`  — AR.2.6 / M-1.  The deployment's
                               32-byte content identifier (the
                               BLAKE3 hash of the deployment's
                               genesis state in production).
                               Threaded into every `signInput`
                               computation as the
                               cross-deployment-replay-protection
                               domain prefix.  Absent → `knomosis`
                               emits a stderr warning and uses
                               the empty sentinel
                               (`ByteArray.empty`) for back-compat
                               with single-deployment dev mode;
                               `knomosis-replay` REFUSES to start
                               without this flag (see below).

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

  * `knomosis info` — five lines (Audit-3.1): name, build tag, phase
    tag, `hash: <implementation-identifier>`, `hash-grade:
    <production|fallback>`.
  * `knomosis process` — bootstrap diagnostic, then one line per
    processed action (`[idx] OK (n events)` or `[idx] FAIL
    (<error>)`), then `final state hash: <hex>`, then optionally
    a confirmation line if `OUT` was provided.
  * `knomosis replay` — one line `parsed N entries`, then either
    `final state hash: <hex>` on success or `replay failed:
    <repr>` on stderr with exit 1.
  * `knomosis bootstrap` — diagnostic block including log index,
    prev hash, state hash; optionally a `warning: truncated
    partial tail` line on stderr when the log was torn.
  * `knomosis snapshot` — diagnostic block including state hash, log
    index, and confirmation of the snapshot file write.
  * `knomosis withdrawal-proof` (Workstream D.2) — `leaf : <hex>`,
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

The hex output of `knomosis withdrawal-proof` is a human-readable
representation; production deployments serialise the proof to
the wire format expected by `KnomosisBridge.sol` (Workstream E.1.3),
which is a concatenation of `leaf || siblings[0] || siblings[1]
|| ... || siblings[63]` plus a fixed-width index encoding.

```
knomosis-replay [--allow-fallback-hash] --deployment-id <hex> LOG [SNAPSHOT]
```

Global flags (Audit-3.1 + AR.2.6):

  * `--allow-fallback-hash`  — required to run with the Lean
                               fallback hash.  Without it,
                               `knomosis-replay` exits non-zero with
                               `FALLBACK_HASH_NOT_PERMITTED`
                               (the auditor's reproduction
                               guarantee is meaningless under a
                               non-cryptographic hash).
  * `--deployment-id <hex>`  — AR.2.6 / M-1: REQUIRED.
                               `knomosis-replay` exits non-zero with
                               `DEPLOYMENT_ID_MISSING` if absent
                               (the audit binary's
                               cross-deployment-replay-rejection
                               guarantee is meaningless under the
                               empty default; production replay
                               must supply the deployment's
                               canonical identifier explicitly).

Output format (one or two lines):

  * `OK <64-hex-chars> via=<implementation-identifier>` on a clean
    replay (Audit-3.1 fixed 32-byte width × 2 hex chars per byte =
    64 hex chars; `via=fnv1a64-padded-32` for the Lean fallback,
    `via=blake3-256` for the production adaptor).
  * `FALLBACK_HASH_NOT_PERMITTED` (Audit-3.1) on the fallback hash
    without `--allow-fallback-hash`.
  * `DEPLOYMENT_ID_MISSING` (AR.2.6) when `--deployment-id <hex>`
    is absent from the argument list.  Emitted before any other
    diagnostic; `knomosis-replay` refuses to proceed without an
    explicit deploymentId.
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
`knomosis-replay` slices the log to entries `[snap.logIndex..)` to
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

## 10. Network ABI (Workstream RH-C)

The Rust network adaptor (`runtime/knomosis-host/`, RH-C) exposes a
TCP / Unix-socket service that accepts CBE-framed `SignedAction`
requests and forwards them to a configured `Kernel` implementation.
The wire format below is the canonical contract between
`knomosis-host` and any client that submits actions to it
(`knomosis-l1-ingest`, deployment-supplied sequencers, etc.).

### 10.1 Wire-frame layout

**Request:**

```text
offset  size  field
------  ----  -------------------------------------------------
    0    4    payload length N (big-endian u32; 1 ≤ N ≤ max_frame_size)
    4    N    payload (CBE-encoded SignedAction; cross-reference §3)
```

**Response:**

```text
offset  size  field
------  ----  -------------------------------------------------
    0    1    verdict byte (see §10.2)
    1    4    reason length M (big-endian u32; 0 ≤ M)
    5    M    UTF-8 reason payload (may be empty)
```

Two length-prefix conventions: the request uses a 4-byte BE u32
followed by exactly N payload bytes; the response uses a 1-byte
verdict followed by a 4-byte BE u32 reason length and then M
reason bytes.  Symmetric framing in both directions keeps the
protocol self-delimiting and parser-friendly.

The host does **not** parse the CBE payload — every admissibility
decision happens inside the kernel implementation.  The host's
only frame-level invariant is "length matches".

Default `max_frame_size` is 1 MiB; operators override via
`--max-frame-size <bytes>`.  Hard ceiling is 16 MiB, matching
`runtime/knomosis-cross-stack`'s `MAX_RECORD_BYTES`.

The layout above is the **v1** (legacy) framing and remains the default.
Since the FQ Rung-1 amendment (`PROTOCOL_VERSION == 2`) a client may
optionally opt into a per-frame **signer hint** by opening the connection
with a 4-byte magic preamble; this is an additive superset (v1 clients are
unaffected and keep working) specified in §10.4.2.

### 10.2 Verdict byte table

| Byte | Variant         | Semantics                                                       |
|------|-----------------|-----------------------------------------------------------------|
| `0`  | `Ok`            | Kernel admitted the action; L2 state advanced.                  |
| `1`  | `NotAdmissible` | Kernel rejected the action (precondition false, policy denied). |
| `2`  | `ParseError`    | Host or kernel could not decode the CBE bytes.                  |
| `3`  | `Busy`          | Host's worker queue full; client should retry with backoff.     |

The `Busy = 3` verdict is RH-C.4's wire-format extension.  Clients
predating RH-C must be updated to recognise the new byte; the
`knomosis-l1-ingest` submitter (RH-B) already does so.

### 10.2.1 `Verdict::Ok` and the admission-stage ladder

In a centralized single-sequencer deployment `Verdict::Ok` means
"action admitted and L2 state advanced," because synchronous
admission collapses every later stage: the kernel that returns
`Ok` IS the canonical kernel, and the log file it advances IS the
canonical log.

In a future decentralized-sequencing deployment (Phase 7+) the
same byte can mean different things depending on how far the
kernel waits before responding.  Rather than overloading the
single byte, knomosis-host introduces a typed `AdmissionStage`
ladder (defined in `runtime/knomosis-host/src/admission.rs`) and
lets each kernel declare which stage its `Verdict::Ok` byte
commits to.  The stage ladder is a strict total order:

```text
    Received < LocallyAdmitted < Sequenced < Finalized
```

| Stage             | Discriminant | Meaning                                                                                                |
|-------------------|--------------|--------------------------------------------------------------------------------------------------------|
| `Received`        | `0`          | Host parsed the frame; signature not yet verified.  Diagnostic only; never reported to clients.       |
| `LocallyAdmitted` | `1`          | Local kernel's §8.2 admissibility predicate returned `True`.  In a decentralized setting, may reorder. |
| `Sequenced`       | `2`          | Sequencer set has committed canonical ordering for the containing block.                              |
| `Finalized`       | `3`          | L1 has finalized the block (~12 confirmations on Ethereum).  Irreversible under L1 safety.            |

**Per-kernel commitment.**  Each kernel implementation declares
`ok_admission_stage` — the stage at which it emits `Verdict::Ok`:

  * `MockKernel`, `CommandKernel`: declare `Finalized`.
    Synchronous admission is canonical; the wire `Ok` is the
    final word.
  * A future `ConsensusKernel` that waits for consensus before
    responding: declares `Sequenced`.
  * An eager kernel that returns `Ok` after local admission but
    before consensus: declares `LocallyAdmitted`.

The wire byte (`0`) is unchanged across these models.  Operators
read the kernel's declared stage in knomosis-host's startup log
(`kernel=X, ok_stage=Y`); programmatic clients query the stage
via the future RH-D `getInfo` event-subscription preamble.

**Monotonicity invariant.**  For any action, the sequence of
stages observed over time must be monotonically non-decreasing.
An action can transition `LocallyAdmitted → Sequenced →
Finalized` but never the other way.  The only way to "lose" a
stage is for the action to be invalidated wholesale by an L1
fault-proof challenge, at which point the kernel reports
`NotAdmissible` rather than regressing.

**No wire-format change.**  This subsection clarifies the
semantics of an existing byte; it does NOT add fields, change
byte positions, or bump `PROTOCOL_VERSION`.  Existing clients
that read a single verdict byte and disconnect continue to
work; clients wanting finer-grained stage updates will
subscribe via RH-D when it ships.

### 10.2.2 Budget-exhaustion reason (Workstream GP.6.2 / OQ-GP-3)

The per-actor budget admission gate (Workstream GP) rejects an
action whose signer has insufficient epoch budget.  Per the OQ-GP-3
wire-format-stability decision, this rejection does NOT add a new
verdict byte: it FOLDS under the existing `NotAdmissible` (`1`)
verdict, carrying the canonical reason string

```text
    InsufficientBudget
```

in the response's UTF-8 reason field (§10.1).  A client distinguishes
a budget rejection from any other `NotAdmissible` purely by the
reason string; the verdict byte is unchanged, so `PROTOCOL_VERSION`
is unchanged and pre-GP clients keep working.

The reason string is emitted by:

  * the Lean kernel reached through `CommandKernel` — the
    authoritative gate (`apply_bridge_admissible_with_budget`,
    enabled by the `--budget-policy bounded --free-tier N
    --action-cost C --current-epoch E` flags the `CommandKernel`
    forwards).  The budget gate's `none` outcome surfaces as
    `ProcessError.budgetRejected` (`LegalKernel/Runtime/Loop.lean`),
    which the `knomosis process` subcommand prints on **stderr** as a
    structured marker line

    ```text
        knomosis-reason: InsufficientBudget
    ```

    `CommandKernel` lifts the first `knomosis-reason: <TOKEN>` line off
    the subprocess's stderr into the response reason, so a budget
    rejection reaches clients as the wire-stable `InsufficientBudget`
    rather than the generic `knomosis exited with status N`.  A
    non-zero exit with no marker keeps the raw-stderr / generic reason
    (the verdict byte is correct in every case).  Base-admissibility
    failures (`ProcessError.notAdmissible`) emit no marker; and
  * the in-memory `MockKernel` budget gate
    (`runtime/knomosis-host/src/budget.rs`), used by tests and dev
    deployments.

The mock gate additionally surfaces a small family of
budget-gate-specific `NotAdmissible` reason strings for the
signer-correlation safety conjuncts it can check without kernel
balances (`BudgetGateBridgeActorTopUp`, `BudgetGateSelfPoolTopUp`,
`BudgetGateZeroGasTopUp`, `BudgetGateSelfRecipientDelegatedTopUp`,
`BudgetGateNonBridgeDepositWithFee`), plus
`BudgetGateUnsupportedAction` when a valid-but-unmodelled action
reaches the in-memory gate (it fails closed; the authoritative Lean
kernel budgets every action variant).  In the mock's optional STRICT
mode (`BudgetGate::with_strict_checks`) two further reasons surface
the gas-balance / consent conjuncts — `BudgetGateInsufficientGas` and
`BudgetGateDelegationNotAuthorized`.  All are `NotAdmissible` — only
the reason string varies.

### 10.2.3 Budget-config sidecar + epoch advancement (GP.6.2)

The per-actor budget gate's configuration — the bounded policy
(`freeTier`, `actionCost`, `currentEpoch`) plus the epoch-advancement
length — participates in every log entry's post-state hash, so it is
fixed for the life of a log.  Two on-disk / CLI facts follow:

  * **Epoch advancement (`--epoch-length N`).**  With `N > 0` the
    effective budget epoch advances by one every `N` admitted log
    entries (the L2 action-clock realisation of OQ-GP-4), lazily
    replenishing each actor's free tier.  It is a deterministic
    function of the log index, so replay reproduces every epoch.
    `N = 0` (default) keeps the epoch fixed.  The `knomosis` binary,
    the `knomosis-host` daemon, and `CommandKernel` all accept the flag.
  * **`<LOG>.budgetcfg` sidecar.**  When a deployment uses a
    NON-default budget config, the `knomosis` binary writes a one-line
    sidecar next to the log on first successful bootstrap:

    ```text
    knomosis-budget/v1 <freeTier> <actionCost> <currentEpoch> <epochLength>
    ```

    Every log-touching subcommand (`process` / `replay` / `bootstrap` /
    `snapshot`) cross-checks the current flags against this sidecar
    BEFORE replay; a mismatch (the operator forgot or changed a budget
    flag on restart) fails with a clear `budget-config error` naming
    the original flags, rather than an opaque post-state-hash
    mismatch.  Default-config deployments write no sidecar (the
    pre-GP.6.2 on-disk footprint is unchanged).

### 10.2.4 Gas-pool genesis config + sidecar (GP.7.4)

A deployment opts into the unified gas pool by supplying the two
per-leg per-action drain caps; the `knomosis` binary then declares
`gasPoolPolicy` for `gasPoolActor` in the genesis `localPolicies` AND
intersects `gasPoolAuthorityPolicy` into the deployment policy (both
halves of the GP.7.4 contract).  Because the genesis `localPolicies`
declaration participates in every log entry's post-state hash, the
gas-pool config — exactly like the budget config — is fixed for the
life of a log:

  * **Flags (`--gas-pool-eth-cap N` / `--gas-pool-bold-cap M`).**
    Supplying EITHER enables the gas pool (a missing cap defaults to
    `0`, i.e. that leg cannot drain).  The `knomosis` binary, the
    `knomosis-host` daemon, and `CommandKernel` all accept the flags;
    the binary threads them through every log-touching subcommand
    (`process` / `replay` / `bootstrap` / `snapshot` / `replay-up-to` /
    `export-cell-proofs` / `extract-events`).
  * **`<LOG>.gaspoolcfg` sidecar.**  When the gas pool is enabled, the
    `knomosis` binary writes a one-line sidecar next to the log on
    first successful bootstrap:

    ```text
    knomosis-gaspool/v1 <ethCap> <boldCap>
    ```

    Every log-touching subcommand cross-checks the current caps against
    this sidecar BEFORE replay; a mismatch (a forgotten / changed /
    disabled cap on restart) fails with a clear `gas-pool-config error`
    naming the original flags, rather than an opaque post-state-hash
    mismatch.  A gas-pool-DISABLED run against a sidecar-bearing log is
    rejected the same way.  Gas-pool-disabled deployments write no
    sidecar (the pre-GP.7.4 on-disk footprint is unchanged).

### 10.3 Transport

  * **Plain TCP.**  `--listen <ADDR>` (e.g. `127.0.0.1:7654`).
    Default address `127.0.0.1:7654` (loopback) so a
    misconfigured deployment cannot accidentally expose the
    daemon to the public internet.
  * **TLS-on-TCP.**  `--tls-listen <ADDR>` plus `--tls-cert
    <PATH>` and `--tls-key <PATH>` (both PEM-encoded).  TLS 1.3
    is the default minimum protocol version; `rustls` (with the
    `ring` cryptographic backend) terminates TLS at the TCP
    boundary.
  * **Unix domain socket.**  `--unix-socket <PATH>`.  Socket
    file created with mode `0600` (owner read/write only).
    Filesystem permissions are the only authentication boundary;
    operators co-locate knomosis-host with the L1 ingestor at the
    same UID for a localhost-only deployment.

Multiple transports may be configured simultaneously; the daemon
runs one acceptor thread per transport and shares a single
worker queue across them.

### 10.4 Backpressure

`knomosis-host` maintains a bounded mpsc queue of pending requests
(default depth 256, configurable via `--max-queue-depth <N>`).
When the queue is full, the listener thread returns the new
`Busy = 3` verdict **immediately**, without blocking and without
spawning additional work.  Memory usage is bounded by
`max_queue_depth × max_frame_size`.

A second DoS defence caps the **number of simultaneously active
connection handler threads** (default 1024, configurable via
`--max-concurrent-connections <N>`).  When the cap is reached,
new TCP connections receive `Busy` immediately and are closed;
new Unix connections receive `Busy` and are closed; new TLS
connections are closed without a TLS handshake (since writing
a plaintext byte to a TLS-expecting client is meaningless).
This bound complements the queue depth bound — without it, an
attacker opening 100 000 simultaneous TCP connections could
exhaust the host's thread + FD budget even though the queue
itself stays small.

The recommended client policy on `Busy`:

  1. Sleep with exponential backoff (e.g. 100 ms × 2^n, capped
     at 5 s).
  2. Re-submit the same `SignedAction` bytes.  The action's
     idempotency follows from the kernel's nonce gate
     (`expectsNonce_strict_mono`, `nonce_uniqueness`) — duplicate
     submissions of the same `(signer, nonce)` pair after a
     successful prior admission are rejected as
     `NotAdmissible`, not silently accepted.

#### 10.4.1 Optional fair scheduling (Workstream GP.8 / FQ — Rung 0)

By default the worker drains the bounded queue strictly FIFO.  Under
`--scheduler drr` it instead runs a work-conserving
**Deficit-Round-Robin** scheduler keyed by the connection id, so that
under contention for the single serial worker no one connection can
monopolise it (a flooding connection delays only itself; an honest
connection keeps its share and its enqueue capacity).  The DRR caps
are `--per-flow-cap <N>` (per-connection backlog, default 64),
`--max-flows <N>` (distinct active connections, default 4096), and the
existing `--max-queue-depth <N>` (reused as the global cap).

**Rung 0 introduces NO wire-format change.**  It is host-internal: the
request/response layout (§10.1), the verdict byte table (§10.2), and
`PROTOCOL_VERSION` (= 1) are all unchanged, so no client needs any
modification.  The scheduler choice CAN, however, change observable
*behaviour*: under `--scheduler drr` a request may be served in a
different order than FIFO, and a new connection may receive `Busy` (the
`--max-flows` / `--per-flow-cap` caps) where FIFO — bounded only by the
shared `--max-queue-depth` — would still enqueue it.  What the scheduler
never changes is **admissibility**: for any action the kernel admits, the
`Ok` / `NotAdmissible` verdict is identical on both paths.  The connection
id is a classification hint that influences ordering and `Busy`-drop
only, never the kernel's verdict (`GP.8` §2.6 invariant 1).
The Rung-1 extension (§10.4.2) adds an optional, version-gated per-frame
signer hint; it is the inner DRR tier layered on top of this same core.
See `docs/planning/GP.8_SEQUENCER_INTEGRATION_PLAN.md` §2.3–§2.8 for the
design.

Because the connection lifecycle is one-shot (§10.5 — one frame, one
verdict, then close), connection-keyed fairness is meaningful only when
a connection carries multiple in-flight requests (a persistent-connection
mode, future) or when the host fronts a sequencer aggregating many
actors; under strict one-shot, every connection is a single-request flow
and DRR coincides with FIFO.  This is a deployment-topology property, not
a wire-format one — the v1 wire format is unchanged either way.

#### 10.4.2 Rung-1 signer hint (Workstream GP.8 / FQ — `PROTOCOL_VERSION 2`)

Rung 1 refines the fair scheduler into **two tiers**: the unspoofable
connection id (the outer tier, as in Rung 0) and an optional, advisory
per-frame **signer hint** (the inner tier).  The host buckets a
connection's requests by hint, so even when many distinct actors
multiplex one upstream connection, no one actor's burst starves the
others — and a connection that spams many (possibly forged) hints is
confined to its own single outer share (`GP.8` §2.6 invariant 2).

**Opt-in negotiation (a strict superset).**  A Rung-1 (v2) client opens
the connection by sending the 4-byte magic preamble

```text
    b"KNH2"   (= 0x4B4E4832 big-endian; "KNomosis Host, protocol 2")
```

The host peeks the first 4 bytes of every connection exactly once:

  * **equal to the preamble** ⇒ a **v2 connection**; the preamble is
    consumed and every subsequent request is

    ```text
    offset  size  field
    ------  ----  -------------------------------------------------
        0    8    signer hint (big-endian u64; advisory routing only)
        8    4    payload length N (big-endian u32; 1 ≤ N ≤ max_frame_size)
       12    N    payload (CBE-encoded SignedAction; opaque to the host)
    ```

  * **not equal to the preamble** ⇒ a **legacy (v1) connection**; those
    4 bytes ARE the v1 length prefix (§10.1) and are read intact.

A connection's v1/v2 classification is fixed for its lifetime (no
mid-connection renegotiation).  The response framing (§10.1) is
**unchanged** in both directions for both generations.

**Collision-proof disambiguation (the load-bearing correctness claim).**
The peek is sound — a *valid* v1 length can never equal the preamble —
because the magic (`0x4B4E4832` ≈ 1.18 GiB) is strictly above the
compile-time `HARD_MAX_FRAME_SIZE` (16 MiB), and any valid v1 length is
`≤ max_frame_size ≤ HARD_MAX_FRAME_SIZE`.  This `HARD_MAX_FRAME_SIZE <
KNH2_MAGIC` invariant is pinned by a `const` assertion AND a unit test in
`runtime/knomosis-host/src/frame.rs`; `--max-frame-size` is clamped below
the ceiling.  A v1 client that sends an over-`HARD_MAX_FRAME_SIZE` length
is already an oversize-frame protocol error, so at worst a misbehaving
client turns one error into another — never a misadmission.

**Advisory + untrusted (safety boundary).**  The hint influences
*scheduling order and `Busy`-drop only*, never admissibility.  The kernel
authoritatively reads the real signer from the CBE body and verifies the
signature, so a **forged or wrong hint is a fairness-only concern**
(`GP.8` §2.6 invariants 1 & 2): a connection that lies about its hint can
only sub-divide its OWN outer share among its fakes (self-harm), never
steal another connection's share (the unspoofable connection-id outer
tier confines it).  A legacy connection (no hint) is treated as a single
implicit flow — exactly Rung-0 behaviour (§2.6 invariant 3).

**Bounded scheduler state (Rung-1 DoS surface).**  The inner per-tier map
is bounded by `--max-signers-per-conn <N>` (default 256): a connection's
`(N+1)`-th distinct hint receives a targeted `Busy`, confining a
hint-spamming connection to a bounded slice of the scheduler's memory
(`GP.8` §2.6 invariant 4).  The outer `--max-flows` and leaf
`--per-flow-cap` caps are as in Rung 0.

**Per-connection aggregate backlog (`--max-conn-backlog <N>`).**  Because
the two-tier split lets one connection own several signer leaves, a
hint-rotating connection could otherwise buffer up to
`max_signers × per_flow` requests — relaxing the Rung-0 per-connection
bound (which was exactly one `per_flow`, the connection's single leaf).
`--max-conn-backlog` restores it: it caps a connection's *aggregate*
backlog summed across ALL its hints, and **defaults to `--per-flow-cap`**
(so out of the box a connection is confined to one `per_flow`'s worth no
matter how it spreads its hints — spoofed hints stay self-confined).
The cap is checked AFTER the leaf `--per-flow-cap` (so a single-leaf
flood is still attributed to `per_flow`) and BEFORE a new hint is
admitted, so the two counters stay distinct even when they coincide at
the default.  An operator who genuinely multiplexes many signers behind
one persistent / sequencer-fronted connection RAISES it (up to
`--max-queue-depth`, which it must not exceed under `--scheduler drr`).
Like the other DRR caps it is ignored under `--scheduler fifo` and never
affects admissibility — only ordering and `Busy`-drop.

**Interop.**  v1 and v2 clients interoperate against the same host
instance, on BOTH the FIFO and DRR schedulers — the negotiation is a wire
concern, not a scheduler one, so a v2 client works against a FIFO host
(de-framed correctly, gaining no fairness).  This is exercised
end-to-end by `runtime/knomosis-host/tests/wire_compat.rs` and by the
real `knomosis-l1-ingest` raw-TCP submitter
(`submitter::raw_tcp::RawTcpSubmitter`, opt-in `--emit-signer-hints`),
whose framing is byte-pinned against the canonical `encode_frame` /
`encode_hinted_frame` encoders.

**Client encoders.**  `knomosis_host::frame::encode_frame` (v1) and
`encode_hinted_frame` (v2) are the canonical client-side encoders — the
single source of truth for the wire layout.  `knomosis-bench
--emit-hints` calls them directly; the `knomosis-l1-ingest` raw-TCP
submitter hand-rolls the framing but byte-pins it against them in a test.

### 10.5 Connection lifecycle

Each connection handles exactly one request/response cycle, then
closes (HTTP-style one-shot).  Persistent / multiplexed
connections are not supported yet; they're a forward-extension
point if a future workload justifies the complexity.

A Rung-1 (v2) connection (§10.4.2) performs its one-time magic-peek
negotiation at the start of the connection, then reads its single hinted
frame — so on a v2 connection the bytes on the wire are
`KNH2` preamble + `[8-byte hint][4-byte length][payload]`, one request,
then close.  The v2 per-frame format is defined for multiple frames (so a
future persistent-connection mode is a drop-in), but under the current
one-shot lifecycle each connection carries exactly one frame, which is
why connection-keyed fairness coincides with FIFO end-to-end (§10.4.1) —
the fairness signal is realised when a connection multiplexes many
in-flight requests (a future mode or a sequencer-fronted topology).

### 10.6 Exit codes

The `knomosis-host` binary uses the workspace-shared
`OperatorExitCode` discipline (`runtime/knomosis-cli-common/src/exit.rs`):

  * `0` — clean exit (stop flag flipped, every thread joined).
  * `1` — general failure (CLI parse error, tracing init failure).
  * `2` — operator-actionable failure (invalid config, listener
    bind error, TLS config load error, kernel construction error).

The binary does NOT install custom SIGINT/SIGTERM handlers;
Ctrl-C delivers the default libc behaviour (immediate process
termination).  Cooperative shutdown is plumbed internally via
the `Arc<AtomicBool>` stop flag; a future `signal-hook`-backed
handler can flip the flag for graceful drain.

### 10.7 Cross-reference

  * Frame parser: `runtime/knomosis-host/src/frame.rs`.
  * Wire-format verdict / response: `runtime/knomosis-host/src/verdict.rs`.
  * Admission-stage ladder + receipts:
    `runtime/knomosis-host/src/admission.rs`.
  * Engineering plan: `docs/planning/rust_host_runtime_plan.md`
    §RH-C.
  * Kernel abstraction: `runtime/knomosis-host/src/kernel.rs`
    (`Kernel` trait with `ok_admission_stage` method;
    `SubscribableKernel` extension trait for streaming kernels;
    `MockKernel` for tests, `CommandKernel` for production-ish
    use; future `ConsensusKernel` will declare `Sequenced` and
    implement `SubscribableKernel` to emit later stage
    transitions; future `ServeKernel` will talk to a long-
    running `knomosis serve` Lean-side subcommand once that work
    unit lands).
  * Client mirror: `runtime/knomosis-l1-ingest/src/submitter.rs`
    (`HttpSubmitter` placeholder; migration to the canonical
    raw-TCP protocol is a follow-up RH-B PR).

## 11. Event Subscription ABI (Workstream RH-D)

The Rust event-subscription server
(`runtime/knomosis-event-subscribe/`, RH-D) exposes a TCP service
that tails Knomosis's transition log, extracts deployment-facing
events via the Lean `knomosis` subprocess, and streams those events
to subscribers in strict order with bounded-lag eviction.  This
section documents the wire format between
`knomosis-event-subscribe` and a subscriber client.

### 11.1 Wire-frame layout

The protocol is bidirectional but asymmetric: a single inbound
`SUBSCRIBE` frame followed by a stream of outbound `EVENT` and
control frames from the server.  After the SUBSCRIBE the client
never sends another frame; the connection is effectively one-way
(server → client) until either party closes it.

**Client → server (handshake):**

```text
offset  size  field
------  ----  -------------------------------------------------
    0    1    frame kind tag (0 = SUBSCRIBE; see §11.2)
    1    8    resume_from sequence (big-endian u64; 0 = no resume)
```

**Server → client (event frame):**

```text
offset  size  field
------  ----  -------------------------------------------------
    0    1    frame kind tag (1 = EVENT)
    1    8    sequence number (big-endian u64)
    9    4    event payload length N (big-endian u32; 0 ≤ N ≤ max_frame_size)
   13    N    CBE-encoded `Event` bytes (cross-reference `Events/Types.lean`)
```

**Server → client (control / termination frames):**

```text
offset  size  field
------  ----  -------------------------------------------------
    0    1    frame kind tag (2 = LAG_EXCEEDED, 3 = TRUNCATED,
                                4 = SERVER_SHUTDOWN, 5 = INVALID_REQUEST)
    1    8    diagnostic sequence (BE u64; semantically meaningful per kind)
```

Termination frames are followed by an immediate connection
close from the server side.

**Event payload tags (additive extension).**  The `Event` payload
(the `N` bytes of an EVENT frame) is a CBE-encoded `Event` whose
leading 9 bytes are a CBE uint head carrying the constructor tag
(`0x00` tag byte + 8-byte little-endian constructor index; the same
head `knomosis-indexer::decoder` reads).  The set of tags is
**append-only** (`LegalKernel/Events/Types.lean::Event.tag`): a new
constructor — e.g. the Workstream-GP gas-pool family at tags 16/17/18
(`depositWithFeeCredited`, `actionBudgetTopUp`, `gasPoolClaim`), the
GP.3.4 `delegatedActionBudgetTopUp` at 19, and the GP.6.4
`budgetConsumed` at 20 — emits at the SAME 9-byte head with no new
fields in the *frame*.  The frame layout is
therefore unchanged, and no `PROTOCOL_VERSION` bump is required.  The
streamer (`knomosis-event-subscribe`) forwards every event payload
verbatim, recognised or not, so a subscriber built against an older
tag set keeps working against a newer server (forward
compatibility).  The Rust-side tag catalogue lives in
`runtime/knomosis-event-subscribe/src/event_type.rs`
(`EventType` / `peek_event_tag` / `EventClass::classify`), which
mirrors the frozen `Event.tag` indices `0..=20` (the
GP.6.4 `budgetConsumed` at tag 20 included).

### 11.2 Frame kind table

| Byte | Variant            | Direction        | Semantics                                                                       |
|------|--------------------|------------------|---------------------------------------------------------------------------------|
| `0`  | `SUBSCRIBE`        | client → server  | Subscription handshake; carries `resume_from` (8-byte BE u64).                  |
| `1`  | `EVENT`            | server → client  | Sequenced event payload; carries seq + length + CBE bytes.                      |
| `2`  | `LAG_EXCEEDED`     | server → client  | Subscriber lag exceeded threshold; connection closing.  Carries last seq sent.  |
| `3`  | `TRUNCATED`        | server → client  | Requested `resume_from` is older than the keep-history window.  Carries oldest. |
| `4`  | `SERVER_SHUTDOWN`  | server → client  | Server is shutting down (operator stop).  Carries last seq sent.                |
| `5`  | `INVALID_REQUEST`  | server → client  | Client's handshake was malformed.  8-byte payload is reserved (set to 0).       |

### 11.3 `SUBSCRIBE` semantics

The `resume_from` field controls how the server replays events
to a newly-connected client:

  * **`resume_from == 0`** — Live-tail subscription.  The client
    receives every event whose seq is produced AFTER the
    subscription is registered.  Pre-existing events in the
    cache are NOT delivered.  This is the canonical "I want to
    watch for new events" mode.
  * **`resume_from > 0`** — Resume subscription.  The client
    receives every event whose seq is strictly greater than
    `resume_from`, drawn first from the keep-history cache (in
    seq order), then from live tail.

The server emits a `TRUNCATED` frame and closes the connection
if `resume_from + 1 < oldest_cached_seq` (i.e., the client wants
events the server has discarded).  The carried sequence is the
**oldest available** seq — the smallest value the client could
successfully `resume_from` on a retry.

### 11.4 Sequence number invariants

Sequence numbers are assigned by the tail reader in strictly
monotonic order starting at `1` for the first log frame in the
file.

**Across log frames**, seqs are strictly increasing — events
from frame N have a seq strictly less than events from frame
N+1.

**Within a single log frame**, the extractor may produce
multiple events (e.g. a `transfer` action emits both a sender
and receiver `balanceChanged` event).  All such events share
the same seq number.  This is intentional: the seq number
identifies the **causal step**, not the **logical event
index**.  Clients that need event ordering within a seq
inherit the push order from the Lean
`Events.extractEvents` function (deterministic).

So the wire stream's seq sequence is **non-decreasing** (equal
seqs within a frame, strictly increasing across frames).
Clients can rely on:

  * No event is delivered twice.
  * For any two events received in order `(a, b)`, `a.seq ≤
    b.seq`.
  * If `a.seq < b.seq`, all events at seq=a.seq have already
    been delivered before any event at seq=b.seq.
  * No gaps in seqs (other than what the keep-history window
    discards on resume — see §11.3).

### 11.5 Transport

  * **Plain TCP only.**  `--listen <ADDR>` (e.g.
    `127.0.0.1:7655`).  No TLS termination in v1; operators
    needing TLS wrap with a separate terminator (`stunnel`,
    `nginx`, etc.).  TLS support is a forward-extension; the
    `rustls` config from `knomosis-host::tls` is reusable.
  * **No Unix-socket support in v1.**  Unix sockets are a
    forward-extension; the listener layer is identical to
    `knomosis-host`'s and can be ported when needed.

### 11.5.1 Transport timeouts

The daemon enforces two TCP-level timeouts on every accepted
connection to mitigate slowloris-style DoS:

  * `--handshake-read-timeout-ms <N>` (default `10000` / 10 s):
    maximum time the server waits for a complete `SUBSCRIBE`
    handshake frame.  A client that opens the socket but never
    sends the 9-byte handshake is dropped after this window.
    Hard ceiling: 60 000 ms (60 s).
  * `--write-timeout-ms <N>` (default `30000` / 30 s): maximum
    time a single outbound frame write may take.  A client that
    refuses to drain its TCP receive buffer (causing the
    server's `write_all` to block on backpressure) is dropped
    after this window.  Hard ceiling: 300 000 ms (5 min).

When either timeout fires, the dispatch thread marks the
subscriber disconnected and closes the TCP socket WITHOUT a
final wire frame (no LagExceeded / ServerShutdown — the client
is presumed unable to read it).

A capacity-rejection write (when the server's connection-slot
cap is reached) uses a separate, tighter deadline of 250 ms so
a stalled rejected client cannot tie up the acceptor thread.

### 11.5.2 DoS bounds

The daemon enforces multiple bounds beyond the timeouts:

  * `--max-subscribers <N>` (default 256, hard ceiling 65 536):
    cap on registered subscribers.  The (N+1)-th SUBSCRIBE
    handshake receives a `LagExceeded { last_delivered_seq: 0 }`
    frame and is closed.
  * `--max-concurrent-connections <N>` (default 1024, hard
    ceiling 65 536): cap on simultaneously-spawned dispatch
    threads.  Larger than `max_subscribers` to allow handshake-
    in-progress + about-to-drain windows.  Validation rejects
    `max_concurrent_connections < max_subscribers`.
  * `--send-queue-depth <N>` (default 64, hard ceiling 65 536):
    per-subscriber outbound queue depth.  Combined with
    `max_subscribers`, bounds total queued event memory.
  * `--max-subscriber-lag <N>` (default 256, hard ceiling
    1 000 000): per-subscriber lag-counter threshold.  When
    the queue fills and the counter exceeds this, the
    subscriber is evicted with `LagExceeded`.
  * `--max-frame-size <N>` (default 1 MiB, hard ceiling 16 MiB):
    per-event payload cap.  An event whose CBE-encoded payload
    exceeds this is dropped at extraction time (the wire
    protocol cannot represent it).

### 11.6 Backpressure: bounded-lag eviction

Each subscriber holds a bounded outbound queue (default depth
64, configurable via `--send-queue-depth <N>`).  When the queue
is full at event-enqueue time, the server increments a
per-subscriber **lag counter**.  Successful enqueues reset the
counter to zero.  When the counter exceeds
`--max-subscriber-lag` (default 256), the subscriber is
**evicted**:

  1. The subscriber's `disconnected` flag is set.
  2. The dispatch thread reads the flag, emits a `LAG_EXCEEDED`
     frame with `last_delivered_seq`, and closes the socket.

The evicted client can reconnect with
`resume_from = last_delivered_seq` to pick up where they left
off (subject to the keep-history window).  The evicted
subscriber's eviction does not affect other subscribers — each
has its own queue, its own lag counter, and its own dispatch
thread.

### 11.6.1 Graceful shutdown semantics

When the server initiates graceful shutdown (operator stop, or
extractor halt), it broadcasts a Shutdown signal to every live
subscriber.  Per subscriber, the dispatch thread will emit
exactly one `SERVER_SHUTDOWN` frame and close the TCP
connection.

**Post-shutdown event loss.**  The extractor may have already
queued additional `EVENT` frames in some subscribers' channels
*before* the shutdown signal arrived (those events were
broadcast during the extractor's final batch).  The dispatch
thread processes the channel in FIFO order; once it observes
the `Shutdown` sentinel OR the `shutdown_requested` atomic
flag, it emits `SERVER_SHUTDOWN` and closes — *any remaining
Live events in the channel are silently dropped server-side*.

Clients MUST treat `SERVER_SHUTDOWN` as terminal: stop reading,
close the socket, and reconnect later (with `resume_from =
last_delivered_seq` carried in the frame) to recover any dropped
events from the cache.  Subscribers that miss `SERVER_SHUTDOWN`
because their TCP read times out first will see a clean TCP
FIN; they can rely on the same recovery semantics.

### 11.7 Subscriber capacity cap

`--max-subscribers <N>` (default 256) bounds the number of
simultaneous subscribers.  When the cap is reached, the
(N+1)-th SUBSCRIBE handshake is responded to with a
`LAG_EXCEEDED` frame (seq=0) and the connection closed.  The
LAG_EXCEEDED byte is reused for "cannot register" because the
operational meaning is the same: "server cannot serve this
client right now; back off."

### 11.8 Exit codes

The `knomosis-event-subscribe` binary uses the workspace-shared
`OperatorExitCode` discipline:

  * `0` — clean exit (stop flag flipped, every thread joined).
  * `1` — general failure (CLI parse error, tracing init failure).
  * `2` — operator-actionable failure (invalid config, listener
    bind error, log-path missing, extractor binary missing).

The binary does NOT install custom SIGINT/SIGTERM handlers;
Ctrl-C delivers the default libc behaviour.  Cooperative
shutdown is plumbed internally via the `Arc<AtomicBool>` stop
flag; a future `signal-hook`-backed handler can flip it for
graceful drain.

### 11.9 Cross-reference

  * Frame parser: `runtime/knomosis-event-subscribe/src/frame.rs`.
  * Log-tail reader: `runtime/knomosis-event-subscribe/src/tail.rs`.
  * Extractor abstraction (Mock + Subprocess):
    `runtime/knomosis-event-subscribe/src/extract.rs`.
  * Event cache + backfill:
    `runtime/knomosis-event-subscribe/src/event_cache.rs`.
  * Subscriber state machine:
    `runtime/knomosis-event-subscribe/src/subscription.rs`.
  * Server orchestrator:
    `runtime/knomosis-event-subscribe/src/server.rs`.
  * Event-type tag registry (Rust-side catalogue of the frozen
    `Event.tag` space; powers trace-level observability + the
    additive-extension contract):
    `runtime/knomosis-event-subscribe/src/event_type.rs`.
  * Engineering plan:
    `docs/planning/rust_host_runtime_plan.md` §RH-D; gas-pool
    event variants: `docs/planning/unified_gas_pool_plan.md` §GP.6.3.
  * Event constructor table (frozen indices 0..20, including the
    Workstream-GP gas-pool family 16..20):
    `LegalKernel/Events/Types.lean` + §5.3.
  * Event-extraction reference function:
    `LegalKernel/Events/Extract.lean::extractEvents`.
  * `Event` CBE wire codec (the encoder authority that produces the
    bytes streamed in §11.1's EVENT frame):
    `LegalKernel/Encoding/Event.lean` (`Event.encode` / `Event.decode`
    / `Event.tag_matches_encode_tag`).
  * Event-type tag registry (Rust mirror of `Event.tag`):
    `runtime/knomosis-event-subscribe/src/event_type.rs`.

### 11.10 `extract-events` subprocess protocol (RH-D backend)

The event-subscription server obtains the per-log-frame `Event` list
from a Lean `knomosis extract-events --log LOG` subprocess
(`Main.lean::cmdExtractEvents`; the Rust driver is
`knomosis-event-subscribe::extract::subprocess::SubprocessExtractor`).
This is the *backend* protocol (server → `knomosis` subprocess),
distinct from the *subscriber* protocol of §11.1–§11.9 (server →
client).

The subprocess is stateful: it threads a running `ExtendedState`
across requests, reconstructing each frame's post-state via the full
bridge-aware admission path (`replayStepWith` +
`apply_bridge_admissible_with_budget`) so the emitted events are
byte-identical to the runtime's `Loop.processPure` output.

**Request (server → subprocess, one per log frame):**

```text
offset  size  field
------  ----  -------------------------------------------------
    0    8    sequence number (big-endian u64)
    8    4    payload length N (big-endian u32; ≤ 16 MiB)
   12    N    CBE-encoded `LogEntry` (the on-disk frame payload)
```

**Response (subprocess → server):**

```text
offset  size  field
------  ----  -------------------------------------------------
    0    8    sequence number (echoed, big-endian u64)
    8    4    event count K (big-endian u32)
 12+..  ...   K × (4-byte BE event length ‖ `Event.encode` bytes)
```

A clean EOF at a request boundary (stdin closed before the 12-byte
header) terminates the subprocess with exit 0.  A truncated request,
a malformed `LogEntry`, or a replay failure exits non-zero (the
driver observes the resulting stdout EOF as an extractor error and
halts the daemon — no silent gaps).  Replay re-verifies each signed
action via the deployment's `Verify`; the dev binary's opaque
returns `false`, so signed frames require a production-linked verifier
(as for `replay-up-to`).

**Deployment-config forwarding.**  Replay must run under the SAME
deployment config the log was produced with: the `--deployment-id`
(domain-separates signature verification) and the budget policy /
epoch schedule (drives the per-actor admission gate, and is
cross-checked against the `<LOG>.budgetcfg` sidecar at startup).  The
`knomosis-event-subscribe` daemon therefore accepts `--deployment-id`,
`--budget-policy` / `--free-tier` / `--action-cost` / `--current-epoch`,
and `--epoch-length`, and its `SubprocessExtractor` PREPENDS them as
global flags before `extract-events` (so the spawned argv is
`knomosis [those flags] extract-events --log <log>`).  A default-config
deployment forwards nothing (the invocation is unchanged).

**Response size.**  A single log frame's event list is bounded by
`HARD_MAX_EVENT_COUNT` (2^20); the multi-actor laws
(`distributeOthers` / `proportionalDilute`) emit one `balanceChanged`
per affected actor, so the cap is a generous DoS ceiling, not a
per-action bound.  A count above it is a subprocess protocol
violation.

**`Event` payload field layout.**  Each emitted event is
`Event.encode` (`LegalKernel/Encoding/Event.lean`): the constructor
tag head (§5.3) followed by its fields in declaration order, every
field a CBE uint / byte string per the `Encoding.CBOR` convention.
The layout is byte-for-byte the format `knomosis-indexer::decoder`
decodes — notably tag 11 (`localPolicyDeclared`) encodes its `policy`
as a CBE byte string (opaque bytes wrapping the structured policy),
matching the indexer's `read_byte_string`.  The Lean↔indexer
byte-equivalence is mechanically pinned for all 21 tags
(0..=20) by `knomosis-indexer/tests/cross_stack_lean_event.rs`
(a Lean→`decode_event`→`encode_event` round-trip against the
real `event_subscribe_cbe.json` bytes).  GP.6.4 widened the
indexer's `Event` mirror to cover the Workstream-GP gas-pool
family (tags 16..=19); previously those tags decoded to a
typed `UnknownTag`.

## 11A. Indexer Storage Layout (Workstream RH-E)

The Rust SQLite indexer (`runtime/knomosis-indexer/`, RH-E.1)
maintains a per-(actor, resource) balance view in a
`knomosis-storage` (RH-E.0) database.  This section documents the
on-disk key schema so operator tools (queries, dashboards,
audits) can read the indexer's database directly without
re-deriving keys from the source.

### 11A.1 Storage layout (kv keyspaces + GP.6.4 SQL tables)

The indexer's state lives in TWO storage surfaces of the same
SQLite database:

**(a) The `kv` blob table** holds the balance view + control
cells under reserved key prefixes:

| Prefix | Length    | Content                                | Value format          | Workstream |
|--------|-----------|----------------------------------------|-----------------------|------------|
| `b/`   | 18 bytes  | balance for `(actor, resource)`        | 16-byte BE u128       | RH-E.1     |
| `c/`   | varies    | indexer control cells                  | UTF-8 or fixed-width  | RH-E.1     |

The `c/` control cells are `c/cursor`, `c/identifier`, and (new
in GP.6.4) `c/current_epoch` (8-byte BE u64 — the indexer's
persisted epoch counter, see §11A.4).

**(b) Five dedicated GP.6.4 SQL tables** (created by
`knomosis-storage`'s `migration_002_budget_views`, schema
version 2) hold the per-actor budget + per-pool-actor balance
views.  Each is `(actor BLOB PRIMARY KEY, value BLOB)
WITHOUT ROWID`, with an 8-byte BE u64 actor key and a 16-byte
BE u128 value:

| Table                                  | Content                                              | Workstream |
|----------------------------------------|------------------------------------------------------|------------|
| `actor_budgets`                        | lifetime cumulative budget grants per actor          | GP.6.4     |
| `actor_budgets_current_epoch_grants`   | per-actor grants WITHIN the current epoch            | GP.6.4     |
| `actor_budgets_current_epoch_consumed` | per-actor consumption WITHIN the current epoch       | GP.6.4     |
| `pool_balances_eth`                    | per-pool-actor NET ETH (resource 0) balance          | GP.6.4     |
| `pool_balances_bold`                   | per-pool-actor NET BOLD (resource 1) balance         | GP.6.4     |

(The GP.6.4 v1 design used `u/`/`pe/`/`pb/` kv keyspaces; the
v2.1 refactor replaced those with the five physical SQL tables
above so the kv-balance writes and the budget-table writes
commit atomically in one combined transaction — see §11A.6.)

### 11A.2 Balance key layout

Each balance cell is keyed by the fixed-width 18-byte string:

```text
offset  size  field
------  ----  -------------------------------------------------
    0    2    prefix: ASCII "b/" = 0x62 0x2f
    2    8    actor id (big-endian u64)
   10    8    resource id (big-endian u64)
```

The value is exactly 16 bytes: the balance encoded as a
big-endian u128.  An absent cell means "balance is zero" (per
the kernel's no-cell-means-zero convention).

The fixed-width BE encoding ensures `scan(b"b/" + actor(8BE))`
enumerates a single actor's resources in resource-id order,
and `scan(b"b/")` enumerates all (actor, resource, balance)
tuples in lex order.

### 11A.3 Control keys

| Key             | Value type           | Content                                  |
|-----------------|----------------------|------------------------------------------|
| `c/cursor`      | 8-byte BE u64        | Last successfully-processed event seq   |
| `c/identifier`  | UTF-8 text           | Indexer identifier (e.g. `knomosis-indexer/v1`) |

The cursor advances atomically with each batch's balance
updates inside a single `Storage::transaction`.  On restart,
the indexer reads `c/cursor` and subscribes with
`resume_from = cursor_value` per §11.3; the server replays
every event with `seq > cursor_value`.

The identifier cell is initialised on first open.  Opening a
database whose identifier disagrees with the binary's
[`knomosis_indexer::INDEXER_IDENTIFIER`] returns a typed
`IdentifierMismatch` error rather than silently corrupting
the database.

### 11A.4 GP.6.4 budget / pool tables — semantics

The five GP.6.4 tables (§11A.1) track the following.  Budget /
grant / pool credits use CHECKED arithmetic and HALT the batch
on `u128::MAX` overflow (consistent with the balance view's
halt-on-overflow discipline — NOT saturating).  Pool drains use
checked subtraction and HALT on underflow.

  * `actor_budgets[a]` = lifetime cumulative budget grants to
    actor `a`.  Sourced from the three grant events: tag 16
    (`depositWithFeeCredited.budgetGrant` → `recipient`), tag 17
    (`actionBudgetTopUp.budgetIncrement` → `signer`), tag 19
    (`delegatedActionBudgetTopUp.budgetIncrement` → `recipient`,
    NOT `signer`).
  * `actor_budgets_current_epoch_grants[a]` = the same grants,
    but accumulated only WITHIN the current epoch (DELETE-reset
    at every epoch boundary — see "Epoch resets" below).
  * `actor_budgets_current_epoch_consumed[a]` = per-actor budget
    consumption within the current epoch, sourced from tag 20
    (`budgetConsumed.amount` → `actor`).
  * `pool_balances_eth[p]` = per-pool-actor NET ETH (resource 0)
    balance: gross inflows (tags 16/17/19 `pool_amount` /
    `gas_amount` when resource = 0) MINUS drains (tag 18
    `gasPoolClaim.amount` when resource = 0 AND `p` equals the
    operator-configured `--gas-pool-actor`).
  * `pool_balances_bold[p]` = symmetric, for BOLD (resource 1).

**`gasPoolClaim` (tag 18) drain wiring.**  When the daemon runs
WITHOUT `--gas-pool-actor`, tag 18 is a no-op and the pool
tables track GROSS inflows.  When `--gas-pool-actor <id>` is
set, tag 18 with `resource ∈ {0, 1}` DECREMENTS
`pool_balances_{eth,bold}[id]` (halting on underflow), so the
pool tables track the NET live balance.

**Epoch resets ("N actions remaining this epoch").**  The
indexer persists a `c/current_epoch` cell.  On each batch, the
indexer computes `epoch = (seq − 1) / epoch_length` (with
`--epoch-length N`; `0` disables).  The `(seq − 1)` aligns the
indexer's epoch boundaries EXACTLY with the kernel's
`logIndex / epochLength` because the tail reader's `seq` is
1-indexed while the kernel `logIndex` is 0-indexed
(`logIndex = seq − 1`).  When the computed epoch differs from
the persisted one, the two `*_current_epoch_*` tables are
DELETE-reset and the new epoch is persisted — all inside the
same combined transaction (§11A.6).  A deployment UI computes
`remaining_this_epoch(a) = freeTier + grants_this_epoch −
consumed_this_epoch`, which equals the kernel's authoritative
`currentBudget` exactly when `freeTier = 0` (genesis default)
or the actor's carryover ≤ `freeTier`, and is a conservative
lower bound otherwise (the grant events do not carry the kernel
budget balance — see the `remaining_this_epoch` docstring in
`runtime/knomosis-indexer/src/budget_view.rs`).

### 11A.5 Event dispatch table

For each `Event` (frozen tags 0..20 per §5.3), the indexer
applies the following balance-view and budget-table operations,
ALL inside ONE `SqliteCombinedTransaction` (§11A.6).

**Balance view (`b/` kv keyspace):**

| Tag | Event                  | Balance-view effect                            |
|-----|------------------------|------------------------------------------------|
| 0   | `BalanceChanged`       | `set(actor, resource, new_value)` (authoritative) |
| 8   | `RewardIssued`         | `credit(recipient, resource, amount)` (saturating, skipped if BalanceChanged covers same key) |
| 9   | `WithdrawalRequested`  | `debit(sender, resource, amount)` (rejects on underflow, skipped if BalanceChanged covers same key) |
| 10  | `DepositCredited`      | `credit(recipient, resource, amount)` (saturating, skipped if BalanceChanged covers same key) |
| all other tags         | no-op (balance view unaffected)                |

**Budget / pool tables (five SQL tables, GP.6.4):**

| Tag | Event                          | budget-table effect (lifetime + current-epoch) | pool-table effect                              |
|-----|--------------------------------|-------------------------------------------------|------------------------------------------------|
| 16  | `depositWithFeeCredited`       | `actor_budgets[recipient]` AND `…_current_epoch_grants[recipient]` += `budgetGrant` | if `r ∈ {0,1}`: `pool_balances_{eth,bold}[poolActor]` += `poolAmount` |
| 17  | `actionBudgetTopUp`            | both `[signer]` += `budgetIncrement`            | if `gr ∈ {0,1}`: `[poolActor]` += `gasAmount`  |
| 18  | `gasPoolClaim`                 | no-op                                           | if `--gas-pool-actor` set AND `r ∈ {0,1}`: `[gasPoolActor]` −= `amount` (halt on underflow); else no-op |
| 19  | `delegatedActionBudgetTopUp`   | both `[recipient]` += `budgetIncrement` (NOT signer) | if `gr ∈ {0,1}`: `[poolActor]` += `gasAmount` |
| 20  | `budgetConsumed`               | `…_current_epoch_consumed[actor]` += `amount`   | no-op                                          |
| other tags                         | no-op                                       | no-op                                          |

The balance dispatch is **idempotent under `BalanceChanged`
priority**: if a single batch contains both a typed event (e.g.
`RewardIssued`) and a `BalanceChanged` for the same key, the
`BalanceChanged.new_value` wins.  This matches the kernel's
convention of emitting `BalanceChanged` for every
balance-affecting action.

### 11A.5b Mathematical invariant

For any event stream `[e_1, e_2, ..., e_n]` extracted from a
canonical log, after the indexer applies the stream to a
fresh database, the balance view's `get(actor, resource)`
MUST equal the kernel's `getBalance(actor, resource)` for
every `(actor, resource)` pair.  This is the load-bearing
correctness property of the indexer; the
`--verify-against-knomosis` CLI flag is plumbed for future
verification work against a running `knomosis-host`.

### 11A.6 Atomicity contract

Each event-batch (one log frame's worth of events, all
sharing the same seq) commits atomically inside a single
`SqliteCombinedTransaction` — opened once via
`CombinedStorage::begin_combined_tx`, it spans BOTH the `kv`
table (balance cells + cursor) AND the five GP.6.4 budget /
pool tables under one `BEGIN IMMEDIATE`.  `apply_batch`
(`knomosis-indexer/src/indexer.rs`) runs five passes inside
that single transaction:

  0. **Epoch boundary** — `dispatch_epoch_if_crossed` resets
     the two per-epoch tables (`actor_budgets_current_epoch_grants`,
     `..._consumed`) when `seq` crosses an epoch boundary
     (run FIRST so the dispatch loop credits into the
     freshly-reset tables — see §11A.4 for the
     `(seq − 1) / epoch_length` alignment with the kernel's
     `logIndex / epochLength`).
  1. **Balance semantic events** — `RewardIssued` /
     `WithdrawalRequested` / `DepositCredited` for pairs NOT
     covered by a `BalanceChanged` in the same batch.
  2. **Balance authoritative sets** — `BalanceChanged`
     applied as authoritative `set`s (overrides the semantic
     pass for the same `(actor, resource)`).
  3. **GP.6.4 budget / pool dispatch** — `dispatch_event`
     routes tags 16/17/19/20 to the budget tables and tag 18
     to the pool drain (when `--gas-pool-actor` is set).
  4. **Cursor advance** — `advance_cursor_via_combined`
     writes `c/cursor` last.

`tx.commit()` then makes every balance update, budget / pool
update, AND the cursor advance visible at once.

On any per-event error (balance underflow, budget over/under-flow,
corrupt cell, etc.), the combined transaction rolls back; the
cursor does NOT advance; the indexer's next subscribe re-delivers
the failing batch (so an operator can intervene before progress
resumes).  On a `commit()` error, the in-memory cursor is re-synced
from disk: a `disk_cursor >= seq` surfaces `CommitAmbiguous`
(recoverable — the commit landed); a failed re-read poisons the
indexer with `CursorRecoveryFailed` (restart required).

### 11A.6a Halt-on-overflow / -underflow discipline

The balance view's credits are SATURATING (clamp at
`u128::MAX`), matching the kernel's `Nat`-saturation default.
The GP.6.4 budget / pool tables instead use CHECKED arithmetic
(per the `--gas-pool-actor` design decision): a credit that
would overflow `u128`, or a pool drain that would underflow
below zero, returns a typed `BudgetDispatchError` and rolls the
WHOLE batch back rather than silently wrapping or clamping.  A
`u128` budget counter cannot realistically overflow under any
honest workload (it would take ≈ 3.4 × 10³⁸ lifetime grants), so
the halt is a corruption tripwire, not an expected control-flow
path.

### 11A.7 SQLite schema

The underlying `knomosis-storage` schema is built by an
append-only `MIGRATIONS` list
(`knomosis-storage/src/migration.rs`), one entry per schema
version.  **Schema version 1** (`migration_001_initial_kv_table`)
creates the kv + meta tables:

```sql
CREATE TABLE kv(
    key BLOB PRIMARY KEY NOT NULL,
    value BLOB NOT NULL
) WITHOUT ROWID;

CREATE TABLE _meta(
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);
```

**Schema version 2** (`migration_002_budget_views`, GP.6.4)
adds the five budget / pool tables, each with the SAME uniform
`(actor BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT
ROWID` shape (8-byte BE u64 actor key, 16-byte BE u128 value):

```sql
CREATE TABLE actor_budgets(                       -- lifetime-cumulative grants
    actor BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
CREATE TABLE actor_budgets_current_epoch_grants(  -- per-epoch grants (reset on boundary)
    actor BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
CREATE TABLE actor_budgets_current_epoch_consumed(-- per-epoch consumption (reset on boundary)
    actor BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
CREATE TABLE pool_balances_eth(                   -- NET ETH gas-pool inflow (deposits − drains)
    actor BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
CREATE TABLE pool_balances_bold(                  -- NET BOLD gas-pool inflow (deposits − drains)
    actor BLOB PRIMARY KEY NOT NULL, value BLOB NOT NULL) WITHOUT ROWID;
```

`_meta` carries the storage layer's schema version
(`schema_version` key); after both migrations the on-disk
version is `2` (`target_schema_version() == MIGRATIONS.len()`).
Migrations are append-only: once published, a migration body is
never modified, and every `CREATE TABLE` uses `IF NOT EXISTS`
so re-running is idempotent.

All tables share the `kv` table's `WITHOUT ROWID` shape so the
8-byte-BE actor key is the clustered primary key — a point
lookup is one B-tree descent, and a `scan` over a single table
enumerates its actors in ascending key order (matching the Lean
`TreeMap` iteration order).

The database is opened in WAL mode (`journal_mode = WAL`) with
`synchronous = NORMAL` by default.  Operators wanting strict
durability override via `SqliteOpenOptions::with_synchronous`.

### 11A.8 Indexer CLI

The `knomosis-indexer` binary exposes one daemon plus four
one-shot query subcommands:

  * `knomosis-indexer daemon` — long-running daemon that
    subscribes to knomosis-event-subscribe and maintains the
    balance + GP.6.4 budget / pool views.  Required flag:
    `--storage <PATH>`.  Optional flags: `--subscribe <ADDR>`,
    `--max-frame-size <BYTES>`, `--reconnect-backoff-ms <MS>`,
    `--max-reconnects <N>`, `--verify-against-knomosis <URL>`,
    and the GP.6.4 additions `--gas-pool-actor <id>` (enables
    tag-18 pool-drain accounting; absent ⇒ pool ledgers are
    deposit-only), `--epoch-length <N>` (`> 0` ⇒ per-epoch
    grant / consumed tables reset every `N` log frames, aligned
    to the kernel's `logIndex / epochLength`; `0` ⇒ never
    reset), and `--verify-budget-against-knomosis <URL>`
    (reserved; currently returns `NotImplemented`).

  * `knomosis-indexer query <actor> <resource>` — one-shot
    balance lookup.  Output: `<actor> <resource> <balance>\n`.

  * `knomosis-indexer query-budget <actor>` (GP.6.4) —
    one-shot lifetime-cumulative budget lookup.  Output:
    `<actor> <budget>\n`.

  * `knomosis-indexer query-pool-eth <actor>` /
    `knomosis-indexer query-pool-bold <actor>` (GP.6.4) —
    one-shot NET gas-pool inflow lookup for the ETH / BOLD
    resource.  Output: `<actor> <pool_balance>\n`.

  All subcommands exit 0 on success.

### 11A.9 Cross-reference

  * Storage trait surface: `runtime/knomosis-storage/src/storage.rs`.
  * SQLite implementation: `runtime/knomosis-storage/src/sqlite.rs`.
  * Migrations: `runtime/knomosis-storage/src/migration.rs`.
  * Budget tables + transaction (GP.6.4):
    `runtime/knomosis-storage/src/budget_storage.rs`.
  * Combined (kv + budget) transaction (GP.6.4):
    `runtime/knomosis-storage/src/combined_transaction.rs`.
  * Indexer library: `runtime/knomosis-indexer/src/lib.rs`.
  * Event decoder: `runtime/knomosis-indexer/src/decoder.rs`.
  * Balance view: `runtime/knomosis-indexer/src/balance.rs`.
  * Budget / pool view (GP.6.4):
    `runtime/knomosis-indexer/src/budget_view.rs`.
  * Cursor: `runtime/knomosis-indexer/src/cursor.rs`.
  * Indexer orchestration: `runtime/knomosis-indexer/src/indexer.rs`.
  * Wire-protocol client: `runtime/knomosis-indexer/src/client.rs`.
  * Engineering plan:
    `docs/planning/rust_host_runtime_plan.md` §RH-E and
    `docs/planning/unified_gas_pool_plan.md` §GP.6.4.

## 12. Hash Swap-Point ABI (Audit-3.1)

The runtime's content-hash function is defined in
`LegalKernel/Runtime/Hash.lean` with three documented swap-point
symbols.  Production deployments override these via link-time
substitution to a vetted BLAKE3-256 implementation; the Lean
fallback (FNV-1a-64 zero-padded to 32 bytes) is the test-build
default.

Documented C ABI symbol names:

  * `knomosis_hash_bytes`        — `ContentHash f(ByteArray bs)`.
                                Hashes a byte array; returns a
                                32-byte content hash.
  * `knomosis_hash_stream`       — `ContentHash f(List<UInt8> s)`.
                                Hashes a byte stream (list); same
                                32-byte width.
  * `knomosis_hash_identifier`   — `String f(Unit)`.  Returns the
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
`"fnv1a64-padded-32"`).  The CLI binaries (`knomosis`,
`knomosis-replay`) read it at startup to decide whether to emit
the fallback warning or fail-fast.

## 13. Solidity-side ABI surface (Workstream E)

Workstream E ships the L1 Solidity mirror of the kernel as five
immutable contracts in `solidity/`.  Each contract's external
ABI is its public Solidity interface (`solidity/src/interfaces/
IKnomosis*.sol`); the integration plan §9 lists the per-contract
critical correctness obligations.  This section documents the
ABI invariants that downstream consumers (deployment scripts,
indexers, off-chain watchers) can rely on.

### 13.1 Cross-contract reference shape

Every Knomosis Solidity contract exposes:

  * `function deploymentId() external view returns (bytes32)` —
    `keccak256(abi.encode(block.chainid, address(this),
    knomosisVersionTag))`.  Computed in the constructor; immutable.
    Mirror of the Lean §8.8.5 `deploymentId`.

`KnomosisBridge`, `KnomosisDisputeVerifier`, `KnomosisSequencerStake`
each additionally expose:

  * `attestor() / disputeVerifier() / sequencerStake() /
    bridge() / migration()` getters returning the immutable
    addresses set in the constructor.  No setter exists.
  * `assertConsistent() external view returns (bool)` — checks
    the symmetric cross-contract reference (e.g.
    verifier.bridge().disputeVerifier() == address(this)).  This
    is the post-deploy auditor surface; it cannot revert.

### 13.2 Custom-error catalogue

Every revert path uses a typed custom error (no string
reverts).  Selectors are stable across deployments because the
error names are part of the contract's frozen surface:

  * `KnomosisBridge`: `NotAttestor`, `NotDisputeVerifier`,
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
  * `KnomosisDisputeVerifier`: `NotApprovedAdjudicator`,
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
  * `KnomosisIdentityRegistry`: `PubkeyAddressMismatch`,
    `WrongPubkeyLength`, `NotEip1271Conforming`,
    `AlreadyRegistered`, `NotRegistered`.
  * `KnomosisSequencerStake`: `NotSequencer`,
    `NotDisputeVerifier`, `InsufficientStake`,
    `WithdrawDuringOpenDispute`, `AlreadySlashed`,
    `SlashRatioOutOfRange`, `ZeroAddress`, `EthSendFailed`.
  * `KnomosisMigration`: `ZeroAddress`, `SelfMigration`,
    `GraceTooShort`, `SameDeploymentId`,
    `PredecessorDoesNotReferenceThisMigration` (renamed from
    `SuccessorDoesNotReferenceThisMigration` in audit-3 to
    reflect the corrected semantics — the migration freezes the
    PREDECESSOR's state-shaping calls, so the predecessor must
    pre-commit to be retired by THIS migration via its own
    `migration` immutable),
    `AttestationInvalid`, `AlreadyActivated`, `GraceNotElapsed`,
    `InvalidSignatureLength`.

### 13.3 Frozen claim-variant indices (KnomosisDisputeVerifier)

Per the integration plan §9.2.1 / §9.2.4, dispute claim variants
have frozen `uint8` indices that mirror Lean's
`Disputes.Types.DisputeClaim` constructor order.  Adding a
new variant requires a new dispute-verifier deployment plus a
`KnomosisMigration` handoff (no in-place extension path).

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

### 13.4 Withdrawal proof on-chain shape

The `KnomosisBridge.withdrawWithProof(uint64 atLogIndexHigh,
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

### 13.5 Verdict signature shape (post-audit-1)

`KnomosisDisputeVerifier.finalizeUpheld` /
`finalizeRejected` expect adjudicator signatures over the
on-chain-derived verdict digest:

  digest = `verdictDigest(disputeId, outcome)` =
    keccak256(0x1901 ‖ domainSeparator ‖ structHash) where
    domainSeparator = keccak256(EIP712Domain(
        "KnomosisDisputeVerifier", "1", chainId, 0,
        knomosisDisputeVerifierAddress
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

### 13.6 signatureInvalid claim signature shape

`KnomosisDisputeVerifier.checkSignatureInvalid(logEntryBlob,
signerHint)` reconstructs the digest the user signed when
producing the impugned `LogEntry`:

  domainSeparator = keccak256(EIP712Domain(
      "KnomosisAction", "1", chainId, 0,
      bridgeAddress
  ))
  structHash = `actionStructHash(actionHash, signer, nonce,
      bridge.deploymentId())`
  digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)

The `signerHint` argument is the L1 address corresponding
to the LogEntry's `uint64 signer` actor-id.  The runtime
adaptor's L1 ingestor (workstream B.2) provides the
resolution; the on-chain `KnomosisIdentityRegistry` keys
records by address, so the dispute filer must supply the
mapping.

### 13.7 Migration attestation shape

The `KnomosisMigration` constructor's
`_attestorSig` argument is a 65-byte ECDSA signature over the
EIP-712 wrap:

  domainSeparator = keccak256(EIP712Domain(
      "Knomosis", "1", chainId, 0, migrationContractAddress
  ))
  structHash = keccak256(KnomosisMigration(
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

### 13.8 EIP-712 sign-input shape (state root attestations)

`KnomosisBridge.submitStateRoot(bytes32 root, uint64 logIndexHigh,
bytes attestorSig)` expects a 65-byte ECDSA signature over:

  domainSeparator = keccak256(EIP712Domain(
      "KnomosisBridge", "1", chainId, 0, bridgeAddress
  ))
  structHash = keccak256(StateRoot(
      root,
      logIndexHigh,
      deploymentId
  ))
  digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)

This shape is the on-chain mirror of Lean's `signedActionDomain`.

### 13.9 Deployment-time contract addresses

Per workstream E (and the integration plan §9), production
deployments use `CREATE3` with deterministic salts so the bridge
↔ verifier ↔ stake reference cycle can be resolved before
deployment (each contract's predicted address depends only on
`(deployer, salt)`, independent of init-code).  The
`solidity/test/utils/Deployer.sol` reference implementation uses
salts `keccak256("knomosis-bridge-salt")`,
`keccak256("knomosis-dispute-verifier-salt")`, and
`keccak256("knomosis-sequencer-stake-salt")`.  Mainnet deployments
should pick deployment-specific salts (e.g.
`keccak256(abi.encode(deploymentId, "bridge"))`).

## 14. References

  * `LegalKernel/Encoding/CBOR.lean` — CBE primitive layer.
  * `LegalKernel/Encoding/Action.lean` — Action encoding.
  * `LegalKernel/Encoding/SignedAction.lean` — SignedAction
    encoding.
  * `LegalKernel/Encoding/State.lean` — State / ExtendedState
    encoding.
  * `LegalKernel/Encoding/Disputes.lean` — Phase-6 dispute-
    pipeline data-type encodings.
  * `LegalKernel/Encoding/LocalPolicy.lean` — Workstream-LP
    LocalPolicy / LocalPolicies CBE codec.
  * `LegalKernel/Runtime/LogFile.lean` — frame layout +
    crash-consistency.
  * `LegalKernel/Runtime/Snapshot.lean` — snapshot format.
  * `solidity/README.md` — Workstream E developer guide.
  * `solidity/src/contracts/*.sol` — five immutable Solidity
    contracts (E.1 – E.5).
  * `solidity/src/lib/{CBEDecode, SmtVerifier, KnomosisEip712,
    CREATE3}.sol` — the cross-cutting libraries.
  * Genesis Plan §8.7 (Persistence and Logging)
  * Genesis Plan §8.8 (Canonical Encoding)
  * Genesis Plan §13.2 (Repository Layout — for the file paths above)
  * `docs/planning/ethereum_integration_plan.md` §9 (Workstream E spec).
  * `docs/planning/ethereum_integration_plan.md` §20 (Immutability amendment).
  * `docs/planning/actor_scoped_policies_plan.md` (Workstream LP — adds the
    `declareLocalPolicy` / `revokeLocalPolicy` Action ctors at
    frozen indices 15 / 16 and the matching `localPolicyDeclared` /
    `localPolicyRevoked` Event ctors at indices 11 / 12).
  * `docs/planning/lex_implementation_plan.md` (Workstream LX — `lexlaw`
    macro, `deployment` macro, `lex_diff` / `lex_format` audit
    binaries).
  * `docs/planning/fault_proof_migration_plan.md` (Workstream H — the two
    new `Action` ctors at frozen indices 17 / 18 and the three
    new `Event` ctors at indices 13 / 14 / 15, plus the five
    new Solidity contracts and the L1 fault-proof game).
  * `docs/fault_proof_design.md` (Workstream H — design
    rationale).

## 15. Workstream H — Fault-Proof Migration ABI Surface

### 15.1 New Solidity contracts

The five immutable contracts shipped by Workstream H:

  * `solidity/src/contracts/KnomosisStateRootSubmission.sol` —
    Sequencer state-root submission registry.
  * `solidity/src/contracts/KnomosisStepVM.sol` — L1 step VM.
  * `solidity/src/contracts/KnomosisFaultProofGame.sol` —
    Bisection game state machine.
  * `solidity/src/contracts/KnomosisDisputeVerifierV2.sol` —
    Dual-path dispute verifier (fault-proof + adjudicator
    quorum).
  * `solidity/src/contracts/KnomosisFaultProofMigration.sol` —
    V1 → V2 migration handoff.

Plus the cross-cutting library:

  * `solidity/src/lib/StepVMMerkle.sol` — Per-cell Merkle
    proof verification for the L1 step VM.

All contracts immutable per Workstream-E §20 discipline.

### 15.2 New constants

| Constant | Type | Value | Source |
|----------|------|-------|--------|
| `MAX_BISECTION_DEPTH` | `uint64` | 64 | `KnomosisFaultProofGame.sol` |
| `STATE_ROOT_SUBMISSION_BOND` | `uint128` | 1.0 ETH (default) | `KnomosisStateRootSubmission` constructor |
| `MIN_CHALLENGE_BOND` | `uint128` | 0.05 ETH (default) | `KnomosisFaultProofGame` constructor |
| `FAULT_PROOF_DISPUTE_WINDOW` | `uint64` | 216_000 blocks (~30 days) | `KnomosisStateRootSubmission` constructor |
| `BISECTION_RESPONSE_TIMEOUT` | `uint64` | 21_600 blocks (~3 days) | `KnomosisFaultProofGame` constructor |
| `MIN_SUBMISSION_INTERVAL_BLOCKS` | `uint64` | 100 (recommended) | `KnomosisStateRootSubmission` constructor |
| `MAX_OUTSTANDING_ROOTS_PER_SEQUENCER` | `uint64` | 100 (recommended) | `KnomosisStateRootSubmission` constructor |
| `MIN_BISECTION_STEP_INTERVAL_BLOCKS` | `uint64` | 5 (recommended) | `KnomosisFaultProofGame` constructor |
| `MIN_GRACE_WINDOW_BLOCKS` | `uint64` | 216_000 (~30 days) | `KnomosisFaultProofMigration.sol` |
| `MAX_RECIPIENTS_PER_BULK_ACTION` | (Lean) | 256 | `LegalKernel.FaultProof.SubStep` |

### 15.3 New L1 entry points

`KnomosisStateRootSubmission`:

  * `submitStateRoot(uint64 logIndex, bytes32 stateCommit, bytes32 prevLogEntryHash)` payable
  * `finaliseStateRoot(uint64 logIndex)`
  * `revertStateRootsFrom(uint64 fromIdx)` (called by game)
  * `isStateRootReverted(uint64 logIndex) view returns (bool)`

`KnomosisFaultProofGame`:

  * `initiateChallenge(...) payable returns (uint256 gameId)`
  * `submitMidpoint(uint256 gameId, bytes32 midpointCommit)`
  * `respondToMidpoint(uint256 gameId, bool agree)`
  * `terminateOnSingleStep(uint256 gameId, bytes signedActionBytes, CellProof[] cellProofs, bytes32 claimedPostCommit)`
  * `claimTimeout(uint256 gameId)`

`KnomosisStepVM`:

  * `executeStep(bytes32 preStateCommit, uint8 actionKind, bytes actionFields, uint64 signer, CellProof[] cellProofs) pure returns (bytes32 postStateCommit)` — `actionKind` is the frozen `Action` dispatcher index (`0..21`; mirrors `actionKindByte` / the `ActionKind` enum); `actionFields` is the per-variant `actionFieldsForL1` byte layout; `signer` is the action signer's `ActorId`.

`KnomosisDisputeVerifierV2`:

  * `fileDispute(bytes32 disputeHash) returns (uint256)`
  * `finaliseFromFaultProof(uint256 disputeId, uint256 gameId, uint64 revertFromIdx)`
  * `finaliseFromQuorum(uint256 disputeId, address[] signers)`

`KnomosisFaultProofMigration`:

  * `activate()`

### 15.4 New events

`KnomosisStateRootSubmission`:
  * `StateRootSubmitted(uint64 indexed logIndex, bytes32 stateCommit, address indexed sequencer)`
  * `StateRootFinalised(uint64 indexed logIndex, address indexed sequencer)`
  * `StateRootRangeReverted(uint64 indexed floor, uint64 indexed ceiling)`

`KnomosisFaultProofGame`:
  * `FaultProofGameOpened(uint256 indexed gameId, address indexed challenger, bytes32 disputedStateRoot, bytes32 challengerStateRoot)`
  * `BisectionMidpointSubmitted(uint256 indexed gameId, address indexed party, uint64 idx, bytes32 commit)`
  * `BisectionResponseSubmitted(uint256 indexed gameId, address indexed party, bool agree)`
  * `FaultProofGameSettled(uint256 indexed gameId, GameStatus status, address indexed winner, uint128 winnerPayout)`

`KnomosisDisputeVerifierV2`:
  * `DisputeFiledV2(uint256 indexed disputeId, address indexed filer, bytes32 disputeHash)`
  * `DisputeUpheldByFaultProof(uint256 indexed disputeId, uint256 indexed gameId, uint64 revertFromIdx)`
  * `DisputeUpheldByQuorum(uint256 indexed disputeId, address indexed adjudicator)`
  * `DisputeRejected(uint256 indexed disputeId)`

`KnomosisFaultProofMigration`:
  * `MigrationActivated(uint64 indexed activationBlock, address indexed predecessor, address indexed successor)`

## 16. Workstream E — Ethereum Integration ABI Surface (cross-reference)

This section is the **canonical cross-reference** for every Ethereum-
integration ABI surface (Workstream E — A through G).  The wire-
format spec for each surface lives in a more specific section above;
§16 catalogues the surfaces and points to the canonical authority for
each.  WG.3 of `docs/planning/ethereum_workstream_g_plan.md` produces
this section.

### 16.1 Action constructor encodings (Workstream E indices)

| Index | Constructor          | Workstream | Field layout |
|-------|----------------------|------------|--------------|
| 12    | `registerIdentity`   | E-B        | §5.1, §5.2   |
| 13    | `deposit`            | E-C        | §5.1         |
| 14    | `withdraw`           | E-C        | §5.1         |

  * The `Action.withdraw` `recipientL1` field is a **lossless 20-byte
    CBE bytestring** (big-endian byte form of
    `EthAddress = Fin (2^160)`).  Audit-2 fixed an earlier
    truncating 8-byte uint encoding that let two distinct
    EthAddresses sharing low 64 bits collide on `signingInput`.
  * `Action.registerIdentity actor pk` encodes `pk` as a CBE
    bytestring (33 bytes for SEC1-compressed secp256k1; the
    `KnomosisIdentityRegistry.registerECDSA` callsite enforces the
    33-byte length on L1).

Constructor indices are pinned by the AR.5 regression tests
(`LegalKernel/Test/Authority/ActionIndexPins.lean`); the
`naming_audit` + `lex_lint` gates enforce that no Lean rename
silently re-grouping these indices.

### 16.2 Event constructor encodings (Workstream E indices)

| Index | Constructor             | Workstream | Field layout |
|-------|-------------------------|------------|--------------|
| 9     | `withdrawalRequested`   | E-C        | §5.3         |
| 10    | `depositCredited`       | E-C        | §5.3         |

Both events are emitted by `applyActionToBridgeState` (the L2-side
event extractor); the L1 ingestor and the indexer
(`knomosis-indexer`, RH-E.1) subscribe to them via the
knomosis-event-subscribe protocol (§11).  Event indices are pinned
by AR.6 regression tests and the `Event.tag` projection
(`LegalKernel/Events/Types.lean`).

### 16.3 BridgeState CBE encoding

`Bridge.BridgeState.encode` (defined in
`LegalKernel/Encoding/State.lean`) concatenates three segments:

```
BridgeState.encode bs =
  encodeConsumed bs ++       -- consumed: TreeMap DepositId DepositRecord
  encodePending  bs ++       -- pending:  TreeMap WithdrawalId PendingWithdrawal
  CBE-uint(bs.nextWdId)
```

Where:

  * `encodeConsumed` is the canonical sorted-pair encoding
    (`encodeSortedPairs`) of `[(DepositId, DepositRecord.encodeAsBytes)]`.
  * `encodePending` is the canonical sorted-pair encoding of
    `[(WithdrawalId, PendingWithdrawal.encodeAsBytes)]`.
  * Each `DepositRecord` encodes as
    `CBE-uint(resource.toNat) ++ CBE-uint(userAmount) ++
     CBE-uint(poolAmount) ++ CBE-uint(budgetGrant)` (the GP.4.1
     four-field widening; the pre-widening form was the two-segment
     `CBE-uint(resource.toNat) ++ CBE-uint(amount)`).
  * Each `PendingWithdrawal` encodes as
    `CBE-uint(resource.toNat) ++ CBE-bstr(EthAddress.toBytes recipient) ++
     CBE-uint(amount) ++ CBE-uint(l2LogIndex)`.

`BridgeState.decode` is the strict inverse (rejects malformed inputs,
out-of-bound resource ids, sub-20-byte EthAddress strings, etc.).
The injectivity theorems
`Bridge.BridgeState.encodeConsumed_injective`,
`encodePending_injective`, and `encode_injective` (Workstream EI.6 /
EI.7, in `LegalKernel/Encoding/BridgeInjective.lean`) ship under
`#print axioms` ⊆ `[propext, Classical.choice, Quot.sound]`.

### 16.4 WithdrawalProof CBE encoding (on-wire)

The withdrawal proof on-wire shape lives at §13.4; this entry is a
back-reference for completeness.  The CBE-encoded
`WithdrawalProof` is the input to
`KnomosisBridge.withdrawWithProof(...)`'s `proofBlob` parameter; the
companion `leafBlob` is the CBE-encoded `PendingWithdrawal`.

  * Typical sparse-proof total: ≈ 2700 bytes.
  * Dense-pair total: ≈ 2725 bytes.
  * Audit-2 amendment: variable-size `bytes` throughout (rather
    than `bytes32 leafHash` and fixed-32-byte siblings); see §13.4
    for the rationale.

### 16.5 Bridge-actor ActorId 0 reservation

`ActorId 0` is **reserved** for the bridge actor — the deployment
authority that signs every L1-derived Knomosis action.  Reservation is
operational, not structural:

  * `Bridge.AddressBook.empty.nextActorId = 3` (post-GP.7.1) —
    assigned ids start at 3, reserving `ActorId`s 0 / 1 / 2 for the
    bridge actor, the `gasPoolActor`, and the `sequencerActor`
    respectively (pinned by `addressBook_empty_nextActorId`; the
    gas-pool / sequencer slots are the Workstream GP.7.1 reservation).
  * `bridgeActor : ActorId := 0` (`LegalKernel/Bridge/BridgeActor.lean`).
  * `bridgePolicy : AuthorityPolicy` admits only
    `Action.replaceKey`, `Action.registerIdentity`, and
    `Action.deposit` when the signer is `bridgeActor`.  Crucially,
    `Action.withdraw` is **not** admitted (Workstream-C audit-1):
    withdrawals are user-initiated, signed by the L2 sender under
    their own authority policy.  See `bridgePolicy_rejects_withdraw`
    (§12.9 #33 in `Bridge/BridgeActor.lean`).

The reserved-id-0 design lets `bridgePolicy` use a structural
signer-equality check (`signer = bridgeActor`) without requiring the
bridge to register a key in the on-chain `KnomosisIdentityRegistry`.

### 16.6 keccak256 trailer format

In production deployments where `Runtime.Hash.hashBytes` is linked
to `runtime/knomosis-hash-keccak256` (the Workstream RH-A.2 keccak
adaptor), the log-file frame trailer (§2.1, §2.2) is **still
FNV-1a-64** — the trailer's job is crash-consistency on the
sequencer's own disk, not cross-stack collision resistance.

The 32-byte hash *outputs* (state commits, sign-input hashes,
EIP-712 digests, SMT root hashes) DO swap to keccak256 in
production.  The identifier string
`hashImplementationIdentifier ()` returns `"keccak256/EVM-compatible/v1"`
under the production binding (`"fnv1a64-padded-32"` under the
fallback); the `knomosis-replay` CLI's `--allow-fallback-hash` flag
(see §11) is the operator's opt-in to run audit cycles under the
fallback.

The `Bridge.HashAdaptor.isKeccak256Linked : Bool` flag
(`LegalKernel/Bridge/HashAdaptor.lean`) is the runtime-introspectable
gate the cross-stack test suites use to skip per-entry assertions
under the fallback (see §16.8 for the cross-stack hash-binding
gate).

### 16.7 Contract event ABIs (L1 ↔ off-chain ingestor)

The off-chain L1 ingestor (`runtime/knomosis-l1-ingest`, RH-B) decodes
four event signatures from L1 logs and translates them to Knomosis
`SignedAction`s:

**`KnomosisBridge`:**

  * `Deposited(address indexed depositor, address indexed token, uint256 amount, bytes32 indexed receiptHash)`
    → `Action.deposit r recipient amount depositId` where:
      - `r` is derived from the `token` address via the deployment's
        resource registry;
      - `recipient` is the `AddressBook`-resolved `ActorId` for
        `depositor`;
      - `amount` is the deposit amount;
      - `depositId` is `receiptHash` interpreted as a big-endian
        `Nat` (the canonical injective conversion at the bridge
        boundary).

**`KnomosisIdentityRegistry`:**

  * `Registered(address indexed addr, bytes pubkey, uint64 indexed actorId)`
    → `Action.registerIdentity actor pk` where:
      - `actor` is the `AddressBook`-assigned `ActorId` for
        `addr` (newly assigned if not present);
      - `pk` is the SEC1-compressed (33-byte) public-key bytes.
  * `Revoked(uint64 indexed actorId)` → `Action.replaceKey actor
     emptyPubKey` (or a dedicated revocation pathway in v2; the
     v1 mirror uses replaceKey-to-empty as the structural
     revocation primitive).

The ABI selector + topic-hash pin lives in
`runtime/knomosis-l1-ingest/src/events.rs`; the off-chain observer
(`knomosis-faultproof-observer`, RH-G) reuses the same decoder for
the Workstream-H game-state events
(`FaultProofGameOpened` / `BisectionMidpointSubmitted` /
`BisectionResponseSubmitted` / `FaultProofGameSettled` /
`StateRootSubmitted`).

### 16.8 Cross-stack hash-binding gate

The `Bridge.HashAdaptor.isKeccak256Linked` boolean is the
load-bearing gate that the cross-stack test suites
(`LegalKernel/Test/Bridge/CrossCheck/*`,
`solidity/test/CrossCheck/*`) consult to decide whether per-entry
byte-equivalence assertions can run.  Semantics:

  * `false` (default in `lake test`): `hashBytes` is the
    FNV-1a-64 zero-padded fallback.  Solidity's `keccak256` (EVM
    opcode) cannot agree with FNV; the cross-stack suites skip the
    per-entry verdict assertions and emit a `SKIP` line.
    Header-shape, byte-size, and structural-invariant assertions
    still run.
  * `true` (production with `runtime/knomosis-hash-keccak256`
    linked): both sides walk keccak256 and the per-entry verdicts
    match byte-for-byte.

The gate is co-located with the hash adaptor identifier (§16.6) so
operators flip both bits atomically by switching the linked C-ABI
library.

### 16.9 Solidity-side ABI surface (back-reference)

The Solidity-side ABI surface (function selectors, custom errors,
cross-contract reference shape, event ABIs) lives in §13.  The
load-bearing entries:

  * §13.1 Cross-contract reference shape (`deploymentId()`,
    `attestor()` / `disputeVerifier()` / `bridge()`,
    `assertConsistent()`).
  * §13.2 Custom-error catalogue (every revert path is a typed
    custom error; selectors are stable).
  * §13.3 Frozen claim-variant indices.
  * §13.4 Withdrawal proof on-chain shape.
  * §13.5 Verdict signature shape (post-audit-1).
  * §13.6 signatureInvalid claim signature shape.
  * §13.7 Migration attestation shape.
  * §13.8 EIP-712 sign-input shape (state root attestations).
  * §13.9 Deployment-time contract addresses (CREATE3 salts).

### 16.10 Cross-reference

  * Genesis Plan §15D (Workstream E Amendment: Ethereum Integration).
  * `docs/planning/ethereum_integration_plan.md` (Workstreams E-A
    through E-F engineering plan).
  * `docs/planning/ethereum_workstream_g_plan.md` (this WG.3
    deliverable's engineering plan).
  * `docs/extraction_notes.md` §2 (Ethereum trust assumptions
    TA-2.1 – TA-2.5).
  * `solidity/README.md` (operator-facing developer guide for the
    L1 contracts).
  * `LegalKernel/Bridge/*.lean` (Lean-side surfaces).
  * `solidity/src/contracts/*.sol` (L1 contracts).
  * `solidity/src/lib/{KnomosisEip712, CBEDecode, SmtVerifier,
    SmtCellVerifier, CREATE3, StepVMMerkle}.sol` (shared
    libraries).
