# Audit 06 — Runtime modules (`LegalKernel/Runtime/`)

Scope: line-by-line audit of every file under
`/home/user/Knomosis/LegalKernel/Runtime/`.

| File                                                                | LoC  | TCB? |
|---------------------------------------------------------------------|------|------|
| `/home/user/Knomosis/LegalKernel/Runtime/Hash.lean`                    | 272  | No   |
| `/home/user/Knomosis/LegalKernel/Runtime/LogFile.lean`                 | 474  | No   |
| `/home/user/Knomosis/LegalKernel/Runtime/Replay.lean`                  | 267  | No   |
| `/home/user/Knomosis/LegalKernel/Runtime/Snapshot.lean`                | 261  | No   |
| `/home/user/Knomosis/LegalKernel/Runtime/AttestedSnapshot.lean`        | 185  | No   |
| `/home/user/Knomosis/LegalKernel/Runtime/Loop.lean`                    | 365  | No   |

None of these files are in the TCB (`tcb_allowlist.txt` /
`Tools.Common.tcbCoreFiles` list only `Kernel.lean` and
`RBMapLemmas.lean`).  Per each module's docstring, bugs here can lose
log entries, produce wrong replay results, or weaken cross-replica
trust, but cannot violate any kernel invariant.

---

## 1. `LegalKernel/Runtime/Hash.lean`

### Imports (lines 65 – 66)

```
import LegalKernel.Encoding.CBOR
import LegalKernel.Encoding.Encodable
```

Reasonable for a module that provides `hashEncodable` and that needs
the `Stream`, `ByteArray`, and `natToBytesLE` primitives.  No bloat.

### Opaque declarations / extern surface

**There are no `opaque` declarations and no `@[extern]` annotations
in this file.**  This contradicts the module docstring (which
repeatedly promises an `@[extern]` swap-point for `hashBytes` /
`hashStream` / `hashImplementationIdentifier`).  Verified:

```
$ grep -n "@\[extern\]" /home/user/Knomosis/LegalKernel/Runtime/Hash.lean
(no matches)
```

Concretely:

- `hashStream` at `Hash.lean:151` is a plain `def`, body
  `padTo32 (fnv1a64Stream bs)`.
- `hashBytes` at `Hash.lean:159` is a plain `def`, body
  `padTo32 (fnv1a64Bytes bs)`.
- `hashImplementationIdentifier` at `Hash.lean:258` is a plain
  `def`, body `"fnv1a64-padded-32"` (the fallback string).

For contrast, `Verify` in `Authority/Crypto.lean:138` is genuinely
`opaque Verify (...) : Bool` with a docstring at `:122` describing
the `@[extern]` linkage strategy.  The same discipline has not been
applied to `hashBytes`.

**Impact.** As shipped, every Lean-level evaluation of `hashBytes`
reduces to FNV-1a-64-padded-to-32.  The "production deployments link
BLAKE3/keccak256 at the C ABI symbol name" mechanism the docstring
describes is unrealised at the Lean level — there is no Lean-level
swap-point to override.  Any production swap would need to happen
either by (a) actually adding `@[extern "canon_hash_bytes"]` to the
`def`, or (b) at the linker level after Lean compilation.  Option
(b) is fragile: Lean's compiler is free to inline `padTo32 ∘
fnv1a64Bytes` into call sites, defeating link-level override.

### FNV-1a-64 constants (lines 73 – 86)

`fnvOffsetBasis := 0xcbf29ce484222325` and
`fnvPrime := 0x100000001b3`.  These match the canonical FNV-1a-64
constants on `isthe.com/chongo/tech/comp/fnv/`.  Constants are
`UInt64`-typed; arithmetic wraps mod 2^64 as the spec requires.

### Core hash primitives (lines 102 – 168)

- `fnv1a64Stream` (`Hash.lean:102`) is the textbook FNV-1a-64 loop:
  `acc' := (acc XOR b.toUInt64) * fnvPrime`.  Pure `foldl` over a
  `List UInt8`.
- `uint64ToBytesLE` (`Hash.lean:127`) packs a `UInt64` as 8 LE bytes
  via `natToBytesLE n.toNat 8`.
- `padTo32` (`Hash.lean:135`) is `uint64ToBytesLE n ++ ByteArray.mk
  (Array.replicate 24 0)`.  Output width = 8 + 24 = 32 bytes.
- `hashStream` / `hashBytes` / `hashEncodable` (`Hash.lean:151,
  159, 167`) compose the pieces.

### Determinism and width theorems (lines 191 – 235)

- `hashBytes_deterministic`, `hashStream_deterministic`,
  `hashEncodable_deterministic` — all trivial `h ▸ rfl` proofs.
  Useful as term-level API stability anchors.
- `padTo32_size : (padTo32 n).size = 32` is the substantive proof
  (unfolds `uint64ToBytesLE`, applies `ByteArray.size_append` and
  `natToBytesLE_length`).
- `hashBytes_size` / `hashStream_size` follow.
- `zeroHash_size : zeroHash.size = 32` is `rfl`.

### Introspection (lines 258 – 269)

`hashImplementationIdentifier (_ : Unit) : String :=
"fnv1a64-padded-32"`.  Takes `Unit` so the call-site looks like a
function call (anticipating extern overrides), but with no extern
annotation the function is a constant.  `isProductionHash` evaluates
to `false` at the Lean level — `decide (... ≠ ...)` over two
syntactically-equal strings.

### Sharp points

1. **Missing `@[extern]` annotations.**  Already covered.  The
   docstring at `Hash.lean:15-57` aggressively documents the BLAKE3
   adaptor story; the implementation does not deliver it.  Either
   the annotations should be added or the docstring should be
   weakened.

2. **64-bit collision resistance with adversarial supplier.**  The
   docstring admits this (lines 53 – 57).  Acceptable given the
   non-TCB framing, but the runtime CLI's `--allow-fallback-hash`
   gate (referenced in `Replay.lean` docstring at line 36) must
   actually exist to enforce production-only usage; verifying that
   gate is in scope for the `Main.lean` audit, not this one.

3. **`hashEncodable` is parametric over `T : Type`, not
   `Encodable.encode`.**  This is fine, but `Encodable.encode` for
   complex types like `ExtendedState` walks a `Std.TreeMap` —
   non-trivial CPU cost on large states.  Not a correctness issue.

4. **No theorem for `hashStream_size` proves the production
   adaptor's 32-byte guarantee.**  All width theorems are about
   the Lean body.  If the extern override were ever wired and
   returned a different width, the proof would still typecheck
   (theorems are about the Lean expression, not the linked
   binary), but downstream code that depends on
   `(hashStream bs).size = 32` would silently break at runtime.
   The width contract is part of the trust assumption stack.

---

## 2. `LegalKernel/Runtime/LogFile.lean`

### Imports (lines 50 – 53)

```
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.SignedAction
import LegalKernel.Encoding.State
import LegalKernel.Runtime.Hash
```

Reasonable.  Pulls in `SignedAction` for the log payload and `Hash`
for `ContentHash` / `hashStream` / `frameTrailer`.

### Frame format (lines 17 – 35, 62 – 198)

```
+---------+-------------+-------------------+-----------+
| magic   | length      | payload (CBE)     | trailer   |
| 4 bytes | 8 LE bytes  | length bytes      | 8 LE bytes|
+---------+-------------+-------------------+-----------+
```

- Magic = ASCII `"CANO"` (`0x43 0x41 0x4E 0x4F`) defined as
  individual `UInt8` constants at `LogFile.lean:69-78`.
- Length = `natToBytesLE plen 8`.  Eight bytes is room for
  2^64 byte payloads — overkill but uniform with the trailer.
- Payload = the CBE encoding of a `LogEntry`.
- Trailer = `frameTrailer payload := natToBytesLE
  (fnv1a64Stream payload).toNat 8` (`LogFile.lean:182`).
  **Critical: the trailer is FNV-1a-64 8-byte hash, NOT the unified
  32-byte ContentHash.**  This is consistent with the
  module-internal use (torn-write detection only — see
  Sharp Points below), but is asymmetric with the rest of the
  file's 32-byte chain hash discipline.

There is **no version byte** in the frame format.  The magic
`"CANO"` is fixed; if the frame layout ever changes, an old
runtime will fail with `badMagic` only if the new layout also
changes the first 4 bytes — otherwise it would interpret old
bytes against new expectations.  This is a documented decision
(implicit in the absence of a version field) but a forward
compatibility consideration.

### LogEntry encode / decode (lines 119 – 156)

`LogEntry` carries `prevHash : ContentHash`, `signedAction :
SignedAction`, `postStateHash : ContentHash`.  Fields encoded as
ByteArray, SignedAction, ByteArray in order.  Manual pattern-match
decode at `LogFile.lean:142-152`.

Pre-state hash is intentionally omitted (`LogFile.lean:98-102`):
predecessor's `postStateHash` would be redundant.  Reasonable.

No timestamp.  This is good for replay determinism — wall-clock
non-determinism cannot leak in.

### `LogEntry.hash` (lines 168 – 170)

```
hashStream (Encodable.encode signedAction ++ Encodable.encode prevHash)
```

Note the ordering: `signedAction || prevHash`, not the more
conventional `prevHash || signedAction`.  The docstring at
`LogFile.lean:161` mirrors §8.8.4: `BLAKE3(encode signedAction ||
encode previousLogEntryHash)`.  This is the spec; the
implementation matches.

### Frame encoding (lines 186 – 197)

`encodeFrame` is `magic || lenLE || payload || trailer`.  Width
`= 4 + 8 + payloadLen + 8` proven by `encodeFrame_length`
(`LogFile.lean:467`).  Reasonable.

### Frame decoding (lines 211 – 266)

`decodeFrame`:

1. Match the first 4 bytes.  `badMagic` distinguishes
   truncation-in-magic (`_ => .error .truncated` at
   `LogFile.lean:266`) from magic-mismatch (`.badMagic [b0, b1,
   b2, b3]` at `:265`).
2. Read 8-byte length.  `truncated` on `natFromBytesLE` error.
3. Check `plen ≤ rest₁.length ∧ 8 ≤ rest₁.length - plen` — this
   correctly handles both insufficient-payload and
   insufficient-trailer.
4. Compute trailer of payload bytes; check against the recorded
   trailer.  `badTrailer` on mismatch.
5. Decode the CBE payload; require `decode = .ok (e, [])` — any
   trailing bytes inside the payload trigger
   `.error (.payload (.trailingBytes 1))`.

The error hierarchy is precise and useful for diagnostics.

### Multi-frame loader (lines 282 – 323)

`decodeAllFrames'` uses a fuel parameter (`s.length + 1`) to convince
Lean that the recursion terminates.  Termination argument:
`decodeFrame` consumes ≥ 4 + 8 + 0 + 8 = 20 bytes per iteration.
Fuel cap is one greater than the input length, so fuel cannot run
out in practice.  The defensive case `(0, _ :: _, …)` returns
`.truncated` — never reached but kept for totality.

**Subtle.**  The fuel cap is `s.length + 1`, but each iteration
consumes ≥ 1 byte (in the worst case — empty payload still uses 20
bytes).  Fuel is always sufficient.  The `+1` slack is correct.

### File-level IO (lines 355 – 409)

- `appendEntry` (`LogFile.lean:355`) opens the file in `.append`
  mode, writes one frame, closes (handle goes out of scope).  No
  `fsync`; the docstring (`:354`) calls this out: "Production
  deployments SHOULD `fsync` after append; the Lean fallback skips
  fsync (no standard-library API)."  Sharp.
- `readAllEntries` (`LogFile.lean:367`) returns `([], 0, none)` if
  the file doesn't exist.  Treats missing-file as empty-log — this
  is the expected semantics for first-ever runtime startup.
- `truncateFile` (`LogFile.lean:382`) is **read-then-rewrite**, not
  a real `truncate(2)`.  For very large logs this is expensive
  (whole log re-read and re-written).  Lean core does not expose
  POSIX `truncate(2)`; the docstring is explicit (`:381-382`).
  Sharp from a performance / correctness-under-concurrent-writer
  angle.
- `loadAndTruncate` (`LogFile.lean:399`) is the startup path:
  read, if error then truncate to `consumed` (the last good byte
  offset), return prefix.  Crash-consistency invariant: post-call,
  the on-disk file is exactly the recovered prefix.

### Chain verification (lines 427 – 435)

`verifyChain seedHash entries`: linear walk asserting
`e.prevHash.toList == prev.toList` byte-for-byte at each step.  Uses
`==` on `List UInt8` so structural equality drives it.  Reasonable.

### Determinism / width theorems (lines 446 – 472)

- `encodeFrame_deterministic`, `LogEntry_hash_deterministic` —
  trivial `h ▸ rfl`.
- `frameTrailer_length : (frameTrailer payload).length = 8` —
  uses `natToBytesLE_length`.
- `encodeFrame_length` — proves the on-disk-width contract.

**No round-trip theorem.**  The docstring at `LogFile.lean:440-443`
explicitly acknowledges: "The full abstract round-trip
(`decodeAllFrames (encodeAllFrames es) = (es, …, none)`) requires
inducting through the frame format; we prove the single-frame case
and use value-level tests to verify the multi-frame case."  In fact
the single-frame round-trip is also absent at the term level — only
the encoded-width theorem is proven.  Round-trip is exercised by
value-level tests under `LegalKernel/Test/Runtime/`.  Sharp from a
formal-guarantees angle: a bug in the frame format that flipped
encode and decode would not be caught by elaboration.

### Sharp points

1. **No `fsync` after append.**  Crash-consistency depends on the
   filesystem flushing buffers before the runtime acknowledges the
   action.  A power loss between `write` and `flush` can lose
   already-acknowledged entries.  Mitigated by the runtime's
   restart loop (`bootstrap` will truncate the partial tail), but
   the runtime may have *acknowledged* the action upstream before
   the durable write completed — that acknowledgement is invalid.

2. **No real `truncate(2)`.**  Read-then-rewrite has a window where
   the file is in an in-between state (the rewrite may itself be
   torn).  This is rare (truncate runs at startup, no concurrent
   writers) but worth wiring a real syscall in production.

3. **Trailer is 8-byte FNV, not 32-byte ContentHash.**  Different
   hash function than the chain hash.  Acceptable because the
   trailer is only for torn-write detection, but the asymmetry
   blurs the threat model.

4. **No frame-format version field.**  Future format changes would
   need to change the magic.  Currently a non-issue but locks the
   format.

5. **Round-trip not proven at the term level.**  Bugs in the frame
   format are only caught by value-level tests.

---

## 3. `LegalKernel/Runtime/Replay.lean`

### Imports (lines 47 – 50)

```
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.State
import LegalKernel.Runtime.Hash
import LegalKernel.Runtime.LogFile
```

Reasonable.

### `ReplayError` (lines 68 – 83)

Three variants — `chainBroken`, `notAdmissible`, `postHashMismatch`
— each carrying an index.  Variant names map cleanly to the three
checks `replayStep` performs.

### Decidability instances (lines 100 – 148)

- `AdmissibleWith.decRegisteredAndSigned` — manually built.
  Generalises `registry[signer]?` so it can be cased on; if `none`,
  rejects the existential immediately; if `some pk`, decides on
  `verify`'s `Bool` output.
- `AdmissibleWith.decidable` — assembles from `P.decAuth`,
  `(Action.compile st.action).transition.decPre`, and the
  registered-and-signed decidability.
- `Admissible.decidable` — specialises `AdmissibleWith.decidable`
  to `Verify` and `ByteArray.empty` (the empty deploymentId).

**Note: `Admissible.decidable` (line 145) wires `ByteArray.empty`
as the deploymentId.**  This is consistent with `processSignedAction`
in `Loop.lean:172-174` which does the same.  But the docstring at
`Loop.lean:171` notes: "Production deployments using a non-empty
deploymentId should call `processSignedActionWith Verify
<deploymentId>` directly."  Sharp: replay also defaults to empty,
so cross-deployment-replay protection at the replay tool requires
the caller to use a non-default replay path (which is not exposed
here — `replayLoop`, `replay`, and `replayFromSeed` all build on the
non-parameterised `Admissible.decidable`).

### `replayStep` (lines 170 – 187)

Ordering:

1. Chain check (`e.prevHash.toList ≠ prevHash.toList`) — `toList`
   conversion is consistent with `verifyChain` in LogFile.
2. Admissibility check (`if h : Admissible P state e.signedAction`).
3. Post-hash check
   (`(hashEncodable nextState).toList ≠ e.postStateHash.toList`).

The docstring at `Replay.lean:166-169` justifies the ordering: a
chain-broken entry must not reach admissibility (which has
side-effects in the sense of running `verify`, which could be
expensive or — in adversarial settings — could be exploited).
Reasonable.

### `replayLoop` (lines 191 – 199)

Tail-recursive walk.  Threads `(idx, prevHash, state)` through the
list.  Uses `LogEntry.hash e` to advance `prevHash`.  Straightforward.

### `replay` / `replayFromSeed` / `replayHash` (lines 212 – 243)

- `replay P genesis entries := replayLoop P 0 zeroHash genesis entries`
  — starts from the canonical genesis predecessor.
- `replayFromSeed P seedHash seedState entries := replayLoop P 0
  seedHash seedState entries` — used by `bootstrapFromSnapshot`.
- `replayHash` returns only the final `StateHash` (drops the full
  `ExtendedState`).

### Determinism theorem (lines 253 – 264)

`replay_deterministic` — `rw [h_g, h_e]` discharges the goal.  Pure
function, equal inputs → equal outputs.

`replay_empty : replay P genesis [] = .ok genesis` — `rfl`.

### Sharp points

1. **DeploymentId defaults to `ByteArray.empty`.**  `Admissible.decidable`
   at `Replay.lean:147` and `Loop.lean:174` both bake in
   `ByteArray.empty`.  Cross-deployment-replay protection
   (Audit-3.4) requires a non-empty deploymentId; the replay tool
   as shipped does not expose a parameterised version of `replay`,
   so a caller cannot supply a real deploymentId.  This is a
   documented gap (the corresponding `processSignedAction`
   docstring says production should call the `*With` variant
   directly) but the gap is silent at the replay layer.

2. **`replay_deterministic` is structurally trivial but doesn't
   constrain `Verify`.**  Replay determinism is "equal Lean inputs
   produce equal Lean outputs" — it depends on `Verify` being
   pure (which is automatic for an `opaque`).  Sufficient for the
   §8.7 acceptance gate but does not constrain a production
   `Verify` adaptor that misbehaves under concurrent calls.  The
   `Verify` opaque's contract (in `Authority/Crypto.lean:100`)
   carries this assumption.

3. **No round-trip theorem `replay (run runtime) = runtime_state`.**
   The replay-reproduces-runtime claim is a value-level test, not
   a proven theorem.  This is intentional (it would require
   formalising the runtime's IO-monadic semantics).

4. **`postHashMismatch` detection cost.**  `hashEncodable nextState`
   runs `Encodable.encode` over the full state plus a hash walk
   over the resulting bytes.  For large states this is non-trivial
   per step.  Not a correctness issue, but a deployment
   performance characteristic.

---

## 4. `LegalKernel/Runtime/Snapshot.lean`

### Imports (lines 47 – 51)

```
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.State
import LegalKernel.Runtime.Hash
import LegalKernel.Runtime.LogFile
import LegalKernel.Runtime.Replay
```

Reasonable.

### `Snapshot` record (lines 86 – 95)

Four fields: `stateHash`, `encodedState : ByteArray`, `logIndex`,
`seedHash`.  No version field.  No deploymentId.  The
self-attestation gap discussed in `AttestedSnapshot.lean` flows from
this: a `Snapshot` is just bytes-plus-claimed-hash; an adversary
can supply both.

### Snapshot encode / decode (lines 105 – 129)

Field order in `encode`: `stateHash, encodedState, logIndex,
seedHash`.  Manual pattern-match decode.

### `takeSnapshot` (lines 136 – 141)

Computes `hashEncodable state` for `stateHash`, then
`Encodable.encodeBytes (T := ExtendedState) state` for
`encodedState`.  These should agree by construction:
`hashEncodable state := hashStream (Encodable.encode state)`,
and `encodeBytes` is `ByteArray.mk ∘ ... ∘ encode`.  Determinism
holds.

### `restoreSnapshot` (lines 166 – 174)

```
match Encodable.decodeAllBytes (T := ExtendedState) snap.encodedState with
| .ok state =>
  if (hashEncodable state).toList = snap.stateHash.toList then
    .ok (state, snap.seedHash, snap.logIndex)
  else
    .error .hashMismatch
| .error e => .error (.decode e)
```

Note: `hashEncodable state` re-encodes the state to compute the
hash, but the snapshot already carries the encoded bytes.  An
adversary supplying a maliciously-crafted snapshot only needs to
choose `(encodedState, stateHash)` such that `hashStream (encode
(decode encodedState))` equals `stateHash`.  Since `encode ∘ decode
= id` for well-formed bytes, this reduces to choosing a state and
running `takeSnapshot` on it — which the adversary can trivially do.
The check is **structurally vacuous** under adversarial supply, as
the `AttestedSnapshot.lean` docstring acknowledges (`:14-16`).

### `replicaFromSnapshot` (lines 203 – 211)

Composes `restoreSnapshot` and `replayFromSeed`.  Errors flow
through `ReplicaError`.

### Snapshot IO (lines 221 – 241)

- `saveSnapshot`: `IO.FS.writeBinFile path bytes`.  Overwrites.
- `loadSnapshot`: returns `unexpectedEof` on missing-file (uniform
  decode error surface).  Reasonable.

### Determinism theorem (lines 253 – 258)

`takeSnapshot_deterministic` — `rw` trio.

### Sharp points

1. **Self-attestation gap.**  Already covered.  Mitigated by
   `AttestedSnapshot`, but only if the runtime CLI's
   `--require-attestation` gate is wired (which `Snapshot.lean`
   alone does not enforce).

2. **No deploymentId on the bare `Snapshot`.**  A snapshot from
   deployment A can be applied as a snapshot to deployment B if
   the encoded states happen to round-trip.  Audit-3.2's
   `AttestedSnapshot.deploymentId` covers this, but the bare
   `Snapshot` does not.

3. **No version field.**  Cross-version schema migration would
   require ad-hoc handling.

4. **`encodedState` not re-checked against decode round-trip.**
   The check is `hashEncodable (decode encodedState) ==
   stateHash`.  If the decode is not the inverse of encode (e.g.
   due to a bug in `Encodable State` that drops some fields), the
   check could pass with a state that differs from what was
   snapshotted.  Mitigated by per-type `*_roundtrip` lemmas in
   `Encoding/`, but those are theorems about pure types, not about
   the full `ExtendedState` aggregate.

---

## 5. `LegalKernel/Runtime/AttestedSnapshot.lean`

### Imports (lines 36 – 37)

```
import LegalKernel.Runtime.Snapshot
import LegalKernel.Authority.SignedAction
```

Reasonable.

### `AttestedSnapshot` record (lines 56 – 69)

Four fields: `snap`, `deploymentId : ByteArray`, `attestor :
ActorId`, `sig : Signature`.

### Domain string (line 80)

`attestedSnapshotDomain := "legalkernel/v1/attested-snapshot"`.
Distinct from `signedActionDomain` and `verdictDomain` (per the
docstring).  Versioned (`v1`).  Reasonable.

### `attestationSigningInput` (lines 102 – 115)

Builds `domainBytes` from `cborHeadEncode cbeTagBytes
domain.toUTF8.size ++ domain.toUTF8.data.toList`, then concatenates:

```
domainBytes ++
Encodable.encode (T := ByteArray) deploymentId ++
Encodable.encode (T := ByteArray) snapByteArray
```

`snapByteArray` is `ByteArray.mk (Snapshot.encode snap).toArray`.
Length-prefixed bytestring embeds the snapshot bytes
self-delimitingly.  Each component carries its own length, so the
concatenation is injective in `(snap, deploymentId)` — good for
domain separation.

### Verification (lines 127 – 137)

`verifyAttestationWith verify registry att`:

```
match registry[att.attestor]? with
| none    => false
| some pk =>
    verify pk (attestationSigningInput att.snap att.deploymentId) att.sig
```

`verifyAttestation := verifyAttestationWith Verify` — production
default.

### `AttestedSnapshot.encode` / `decode` (lines 146 – 163)

**Encode field order:**

```
[snapByteArray, deploymentId, attestor (as Nat), sig]
```

**Decode** uses do-notation:

```
let (snapByteArray, s₁) ← Encodable.decode (T := ByteArray) s
let (snapValue, _)      ← Snapshot.decode snapByteArray.toList
let (depId, s₂)         ← Encodable.decode (T := ByteArray) s₁
let (attestor, s₃)      ← Encodable.decode (T := Nat) s₂
let (sig, s₄)           ← Encodable.decode (T := ByteArray) s₃
pure (⟨snapValue, depId, UInt64.ofNat attestor, sig⟩, s₄)
```

**Sharp point — silent residual from inner snapshot decode.**  The
`(snapValue, _)` on line 159 discards the residual stream of the
inner `Snapshot.decode`.  Because the outer decode read the
snapshot as a CBE bytestring (length-prefixed), the inner snapshot
bytes should be exactly the right length.  But if they were not —
e.g. an adversary stuffed extra trailing bytes inside the
length-prefixed envelope — the discarded residual would silently
swallow them.  Not a security gap (the signature verification would
fail because the canonical bytes would mismatch), but an
under-strict decode.

**Sharp point — order mismatch between signing input and
on-disk encode.**  `attestationSigningInput` concatenates
`[domain, deploymentId, snapBytes]`, while `AttestedSnapshot.encode`
concatenates `[snapBytes, deploymentId, attestor, sig]`.  This is
intentional (the signing input does not include `attestor` and
`sig`; the on-disk envelope does not include the domain prefix
because it's implicit in the type), but the asymmetry is a
review hazard.  The `attestor` field is signed *by virtue of being
the key whose public key verifies*, not by being in the signing
input — this is the standard signature-protocol pattern, but worth
auditing.

### Sharp points

1. **Decode silently discards inner-snapshot residual** (line 159).

2. **`attestor` not in the signing input.**  Standard pattern but
   means an attestor signing one message could (in principle) be
   re-used to "sign" the same message under a different
   `attestor` field.  Mitigated by the registry lookup (only the
   actor whose `attestor` matches can have their key looked up),
   but the registry could be manipulated externally.

3. **No replay protection across versions of the same snapshot.**
   An attestor that signs `(snap, dep)` once, signs it forever.
   If a deployment rolls back to an older snapshot, the old
   attestation is still valid.  Acceptable for the intended
   threat model but worth noting.

4. **`loadAttestedSnapshot` uses `(IO.FS.readBinFile path).toBaseIO`**
   (`AttestedSnapshot.lean:176-182`).  This is **different** from
   `loadSnapshot` in `Snapshot.lean:234-241`, which uses
   `path.pathExists` first.  The `.toBaseIO` pattern catches any
   IO error (not just missing-file); on permission denied or
   filesystem error, it collapses to `.unexpectedEof`.  This is a
   semantic mismatch between two adjacent IO functions.  Sharp.

---

## 6. `LegalKernel/Runtime/Loop.lean`

### Imports (lines 43 – 50)

```
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.SignedAction
import LegalKernel.Encoding.State
import LegalKernel.Events.Extract
import LegalKernel.Runtime.Hash
import LegalKernel.Runtime.LogFile
import LegalKernel.Runtime.Replay
import LegalKernel.Runtime.Snapshot
```

The full Runtime stack.  Reasonable — this is the orchestrator.

### `RuntimeState` (lines 69 – 84)

Five fields: `policy`, `state`, `prevHash`, `logIndex`, `logPath :
System.FilePath`.

**Sharp point.**  `logPath` is `System.FilePath` — an unchecked
filesystem path.  The runtime calls `appendEntry rs.logPath` and
`IO.FS.readBinFile` on this directly.  If a caller passes a path
containing shell metacharacters, symlinks to a sensitive location,
or a path on a network filesystem, the runtime trusts it.  No
sanitisation, no canonicalisation, no rooted-path check.  This is
the runtime CLI's responsibility, but `Loop.lean` itself provides
no defence.

### `ProcessError` (lines 96 – 103)

Single variant: `notAdmissible`.  The docstring (`Loop.lean:98-100`)
acknowledges this is coarse: "the clause that failed is not
distinguished here (Phase 6 will add finer-grained variants); a
deployment can compute the failing clause via the per-clause
extractors in `Authority/SignedAction.lean`."  Not Phase 6's
problem according to the comment, but per the §15 status table,
Phase 6 is complete — so this is unfinished work that has not been
followed up.

### `processSignedActionWith` (lines 140 – 162)

The parameterised step:

1. Check `AdmissibleWith verify rs.policy d rs.state st`.
2. If admissible: `apply_admissible_with verify ... h`, hash the
   new state, build the `LogEntry`, **then call `appendEntry
   rs.logPath entry`**, then build the new `RuntimeState`.
3. Otherwise: return `notAdmissible`.

**Sharp point — file append happens before the new RuntimeState is
returned.**  If `appendEntry` throws (disk full, permission denied,
filesystem unmounted), the `IO Unit` exception propagates up the
`do` chain.  The caller sees an IO exception, not a
`ProcessError`.  The runtime's `RuntimeState` mutation in memory
has not happened (`rs'` is built after the append), but the
*append* may have partially written bytes.  Whether the partial
write is recoverable depends on the trailer check at next
`loadAndTruncate`.

This is documented (the docstring at `Loop.lean:119-123`: "The
function is pure-state-transformation modulo the file append: the
`IO` is exactly one `IO.FS.Handle.write` call (and possibly file
creation on first append)."), but the exception-vs-error semantics
distinction is worth a careful review.

### `processSignedAction` (lines 172 – 174)

```
def processSignedAction (rs : RuntimeState) (st : SignedAction) :
    IO (Except ProcessError ProcessResult) :=
  processSignedActionWith Verify ByteArray.empty rs st
```

Defaults the deploymentId to `ByteArray.empty`.  **Same concern as
Replay.lean §3**: cross-deployment-replay protection requires a
non-empty deploymentId; the default exposes the runtime to that
class of attack unless the caller uses `processSignedActionWith`
directly.

### `bootstrap` (lines 221 – 240)

1. `loadAndTruncate logPath` — recover the on-disk log.
2. `replay policy genesis entries` — re-derive the runtime state.
3. Set `prevHash := LogEntry.hash <last entry>` or `zeroHash` if
   empty.
4. Build a `RuntimeState`.

The `Option FrameError` carries the truncation diagnostic for
visibility.  Returns `(.error (.replay e))` on replay failure.

### `bootstrapFromSnapshot` (lines 267 – 297)

1. `restoreSnapshot snap`.
2. `loadAndTruncate logPath` — read full log.
3. If `baseIdx > entries.length`, error with `.logIndexOverrun`.
4. `tail := entries.drop baseIdx`.
5. `replayFromSeed policy seedHash state tail`.
6. Build a `RuntimeState` with `logIndex := baseIdx + tail.length`.

**Sharp point.**  `entries.drop baseIdx` *silently truncates* the
prefix of the log that was already covered by the snapshot.  No
check that the prefix's `LogEntry.hash` chain actually leads to
the snapshot's `seedHash`.  An operator who supplies an
inconsistent snapshot (e.g. a snapshot of one deployment over the
log of another that happens to have ≥ `baseIdx` entries) will get
a `replay` error only if the chain check on entry `baseIdx` fails
— and if the chain happens to agree, the replica will silently
diverge.

The `seedHash` parameter to `replayFromSeed` is used as the
"predecessor hash" for the chain check on entry `baseIdx`, so the
chain check *does* run.  But it only checks the *first*
post-snapshot entry, not that the prefix was consistent with the
snapshot.  Acceptable given that the prefix is meant to be
discarded, but worth flagging.

### `processBatch` (lines 312 – 322)

Sequential processing.  On error, retains the previous
`RuntimeState` (`rs' := rs`) and continues.  The errors are
collected per-action.  Reasonable.

**Subtle.**  `processBatch` is **not** `@[tailrec]` annotated and
the recursive call `processBatch rs' rest` happens after `let
result ← processSignedAction rs st`.  In Lean 4, monadic
recursion in `IO` should compile to a tail call after the bind,
but on very long batches stack growth could in principle be a
concern.  No annotation suggests the author isn't relying on it.
Not a correctness issue.

### `processPure` and theorem (lines 336 – 362)

Pure mirror of `processSignedAction` for testing.  Same body minus
the IO append.  `processPure_deterministic` is `rw [h_rs, h_st]`.

### Sharp points

1. **`logPath` is an unchecked `System.FilePath`.**  No
   sanitisation in `Loop.lean`; the CLI bears full responsibility.

2. **Default `deploymentId := ByteArray.empty`.**  Cross-deployment
   replay protection is opt-in only.

3. **`bootstrapFromSnapshot` does not verify that the discarded log
   prefix is consistent with the snapshot's seed hash.**  The first
   post-snapshot entry's chain check covers entry `baseIdx`, but
   the prefix `[0 .. baseIdx)` could be from a different
   deployment.

4. **`ProcessError` is one variant.**  Loss of diagnostic
   granularity; the docstring says "Phase 6 will add finer-grained
   variants" — but Phase 6 is complete per the status table and
   this has not happened.

5. **`appendEntry` exception path is not encoded as a
   `ProcessError`.**  An IO exception during append propagates up
   the `do` chain as an `IO.Error`; the caller's
   `Except ProcessError _` surface does not cover it.  This forces
   the caller to handle two error channels (the `Except` and the
   outer `IO`).

6. **Concurrent appender hazard.**  Nothing in `Loop.lean`
   prevents two `RuntimeState` values from sharing the same
   `logPath`.  If two threads each call `processSignedAction` on
   `(rs1, rs2)` with `rs1.logPath = rs2.logPath`, the file appends
   race and corrupt the on-disk log.  Production deployments must
   enforce single-writer; the Lean side provides no lock.

---

## Cross-cutting findings (summary)

### Highest-priority

1. **`hashBytes` / `hashStream` lack `@[extern]` annotations
   despite extensive docstring claims** (`Hash.lean:151, 159`).
   The "production deployments link BLAKE3/keccak256 at the C ABI
   symbol name" mechanism is not realised at the Lean level.  Any
   production swap relies on link-level interposition, which is
   fragile against Lean's inliner.

2. **`Admissible.decidable` and `processSignedAction` both default
   `deploymentId` to `ByteArray.empty`** (`Replay.lean:148`,
   `Loop.lean:172-174`).  Cross-deployment-replay protection
   (Audit-3.4) is opt-in; the default path is vulnerable.

3. **Self-attesting bootstrap gap on bare `Snapshot`**.  Already
   well-known and mitigated by `AttestedSnapshot`, but only if the
   runtime CLI actually requires attestations
   (`Snapshot.lean:166-174` does not enforce).

4. **`bootstrapFromSnapshot` does not validate the discarded log
   prefix against the snapshot's seed hash**
   (`Loop.lean:267-297`).  The first post-snapshot entry's chain
   check covers entry `baseIdx`, but a malicious or buggy log
   could supply inconsistent prefix bytes.

### Mid-priority

5. **No frame-format version byte** in `LogFile.lean`.  Future
   schema evolution is fragile.

6. **No round-trip theorem for frames or replay at the term level**.
   Both rely on value-level tests.  A frame-format inversion bug
   would not be caught by elaboration.

7. **No `fsync` after append**.  Crash consistency depends on the
   filesystem.  The CLI must wrap appends in `fsync` for true
   durability.

8. **`truncateFile` is read-then-rewrite, not real `truncate(2)`**.
   Performance and atomicity hazard.

9. **Single coarse `ProcessError.notAdmissible`** in `Loop.lean`.
   Diagnostic granularity lost.  Docstring promises a Phase 6
   refinement that has not materialised.

10. **`loadAttestedSnapshot` has different IO-error semantics from
    `loadSnapshot`** — uses `.toBaseIO` whereas `loadSnapshot`
    uses `pathExists` first.  Asymmetric error handling.

11. **`AttestedSnapshot.decode` discards inner-snapshot residual
    silently** (`:159`).  Permits trailing-byte stuffing inside
    the length-prefixed envelope, though signature verification
    would still mismatch.

### Sharp / informational

12. **`UInt64.ofNat attestor` in `AttestedSnapshot.decode`** —
    fine for valid attestors but truncates if a malformed
    `attestor` field exceeds `UInt64.max`.  No range check.

13. **`Loop.lean` has no concurrency guards**.  `RuntimeState`
    values sharing a `logPath` race silently.

14. **No `@[tailrec]` on `processBatch`**.  Probably fine; not
    declared.

### Documentation drift

- `Hash.lean:28-36, 144-150, 156-158, 242-247, 252-257` repeatedly
  promise `@[extern]` swap-points that do not exist in the actual
  declarations.
- `Loop.lean:99-101` promises Phase-6-era `ProcessError`
  refinement that has not materialised (and Phase 6 is now
  complete per `CLAUDE.md`).
- `LogFile.lean:109-112` says hashes are "8-byte FNV-1a-64 outputs"
  but the Audit-3.1 unification has them padded to 32 bytes —
  this docstring fragment is internally inconsistent with the
  module's own `padTo32` discipline.

### Determinism / replay coverage

- Replay determinism (`replay_deterministic`) is a trivial
  consequence of Lean purity.  Holds.
- Frame round-trip is **not** a term-level theorem.
- `replay (run runtime) = runtime_state` is **not** a term-level
  theorem.
- `restoreSnapshot (takeSnapshot s ...) = .ok (s, ...)` is **not**
  a term-level theorem (modulo the `Encodable.decodeAllBytes ∘
  encodeBytes = id` round-trip, which is a per-type lemma in
  `Encoding/`).

All three gaps are documented as "covered by value-level tests"
but they leave the runtime's strongest informal claims
(byte-for-byte replay) unverified at elaboration time.

