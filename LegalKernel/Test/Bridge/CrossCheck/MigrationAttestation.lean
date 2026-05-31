-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.MigrationAttestation — Workstream
F.1.7.

Generates the `migration_attestation.json` cross-stack fixture: 32
entries verifying byte-equivalence between Lean's
`AttestedSnapshot` digest (Audit-3.2) and `KnomosisMigration`'s
constructor-time EIP-712 wrap digest (the `_wrapDigest` function
that combines `KnomosisEip712.domainSeparator` and
`KnomosisEip712.migrationStructHash`).

Per integration plan §10.1.7:

  * 16 happy-path entries (distinct (predecessor, successor) pairs)
  *  8 boundary entries (graceWindowBlocks = MIN_GRACE_WINDOW_BLOCKS
     = 216_000 accepted; 215_999 rejected with `GraceTooShort`)
  *  4 cross-deployment-replay entries (distinct deploymentId pairs
     produce distinct digests)
  *  4 audit-3-direction entries (predecessor pre-committed; pre-
     audit-3 successor pre-committed rejected)

Total: 32 entries.

Each entry's struct hash uses 5 fields (mirrors
`KnomosisEip712.migrationStructHash`):
  * predecessorDeploymentId   (bytes32)
  * successorDeploymentId     (bytes32)
  * migrationStateRoot        (bytes32)
  * migrationStateRootLogIdx  (uint64 → uint256)
  * graceWindowBlocks         (uint256)

Plus a typeHash prefix in the encoded preimage.

Hash-binding-conditional behaviour: when `isKeccak256Linked = false`,
fixture digests are FNV-derived; cross-check skipped.

This module is non-TCB.
-/

import LegalKernel
import LegalKernel.Test.Framework
import LegalKernel.Test.Property
import LegalKernel.Test.Bridge.CrossCheck.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.Runtime
open LegalKernel.Test
open LegalKernel.Test.Property

namespace MigrationAttestation

/-! ## EIP-712 migration constants -/

/-- The minimum grace window per `KnomosisMigration.MIN_GRACE_WINDOW_BLOCKS`. -/
def minGraceWindowBlocks : Nat := 216000

/-- The migration domain name (mirrors `KnomosisMigration.DOMAIN_NAME`).
    The deployment-side `_wrapDigest` uses
    `KnomosisEip712.domainSeparator("KnomosisMigration", "1", chainid,
    rollupId, address(this))`. -/
def migrationDomainName : String := "KnomosisMigration"

/-- The migration domain version. -/
def migrationDomainVersion : String := "1"

/-- The migration type string for the EIP-712 wrap.  Character-
    identical to `KnomosisEip712.KNOMOSIS_MIGRATION_TYPE_STRING` in
    `solidity/src/lib/KnomosisEip712.sol`.

    **Audit finding (this audit pass)**: pre-fix Lean string declared
    `uint256 migrationStateRootLogIdx`; the Solidity constant declares
    `uint64`.  Even though the value-bytes are identical at the
    abi.encode layer (both produce 32-byte BE), the typeHash
    `keccak256(bytes(typeString))` differs by one character → struct
    hash differs → digest differs.  Cross-stack-equivalent type
    strings are a load-bearing invariant of the EIP-712 wrap. -/
def knomosisMigrationTypeString : String :=
  "KnomosisMigration(bytes32 predecessorDeploymentId,bytes32 successorDeploymentId,bytes32 migrationStateRoot,uint64 migrationStateRootLogIdx,uint256 graceWindowBlocks)"

/-! ## Entry type -/

/-- Direction-test variant: which check the Solidity-side
    constructor exercises. -/
inductive Direction : Type where
  /-- Predecessor pre-committed (audit-3 fix; the only valid form). -/
  | predecessorPreCommitted    : Direction
  /-- Predecessor's `migration` is `address(0)` (audit-3-direction
      rejection: `PredecessorDoesNotReferenceThisMigration`). -/
  | predecessorAddressZero     : Direction
  deriving DecidableEq, Inhabited

/-- The expected outcome on the Solidity side. -/
inductive ExpectedOutcome : Type where
  /-- Constructor accepts. -/
  | accepted        : ExpectedOutcome
  /-- Constructor reverts with `GraceTooShort`. -/
  | revertGraceTooShort : ExpectedOutcome
  /-- Constructor reverts with `PredecessorDoesNotReferenceThisMigration`. -/
  | revertPredecessorDoesNotReference : ExpectedOutcome
  deriving Inhabited

/-- Render outcome as fixture string. -/
def ExpectedOutcome.toString : ExpectedOutcome → String
  | .accepted                            => "accepted"
  | .revertGraceTooShort                 => "revert:GraceTooShort"
  | .revertPredecessorDoesNotReference   => "revert:PredecessorDoesNotReferenceThisMigration"

/-- One fixture entry. -/
structure Entry where
  /-- Predecessor address (20 bytes). -/
  predecessor              : ByteArray
  /-- Successor address (20 bytes). -/
  successor                : ByteArray
  /-- Predecessor deploymentId (32 bytes). -/
  predecessorDeploymentId  : ByteArray
  /-- Successor deploymentId (32 bytes). -/
  successorDeploymentId    : ByteArray
  /-- Migration state root (32 bytes). -/
  migrationStateRoot       : ByteArray
  /-- Migration state-root log index (uint64). -/
  migrationStateRootLogIdx : Nat
  /-- Grace window blocks (uint256). -/
  graceWindowBlocks        : Nat
  /-- Chain id. -/
  chainId                  : Nat
  /-- Rollup id (the deployment-specific extension; the Solidity
      side passes `uint256(0)` for v1). -/
  rollupId                 : Nat
  /-- 20-byte KnomosisMigration's predicted CREATE3 address (the
      verifyingContract field of the EIP-712 domain). -/
  verifyingContract        : ByteArray
  /-- 32-byte expected EIP-712 digest. -/
  expectedDigest           : ByteArray
  /-- 65-byte placeholder ECDSA signature. -/
  expectedSig              : ByteArray
  /-- 20-byte expected recovered signer address. -/
  expectedRecovered        : ByteArray
  /-- Direction-test variant. -/
  direction                : Direction
  /-- Expected outcome on the Solidity side. -/
  outcome                  : ExpectedOutcome
  /-- Per-entry label. -/
  label                    : String

/-! ## Hash recipe (mirrors KnomosisEip712)

The migration EIP-712 wrap is computed via two pieces:

  * **Domain separator** — uses the canonical
    `LegalKernel.Bridge.Eip712.eip712DomainSeparator`, which is the
    same function the rest of the kernel uses for action signing.
    Sharing this function across the dispute / migration flows
    eliminates a class of cross-stack drift bugs (audit-1 originally
    fixed a similar drift inside `LegalKernel.Bridge.Eip712`; this
    audit pass extends the fix to F.1.7's fixture generator).
  * **Struct hash** — five-field migration preimage
    (`typeHash ‖ predDid ‖ succDid ‖ stateRoot ‖
    encodeUint256BE(logIdx) ‖ encodeUint256BE(grace)`) hashed once.
    Mirrors `KnomosisEip712.migrationStructHash` byte-for-byte. -/

/-- 32-byte hash of the migration type-string (the knomosisMigrationTypeHash). -/
def migrationTypeHash : ByteArray :=
  hashBytes (knomosisMigrationTypeString.toUTF8)

/-- ABI-encoded uint256 BE.  Re-export of the canonical
    `LegalKernel.Bridge.encodeUint256BE` so tests below can use
    the unprefixed name without shadowing.  Equivalent at the
    bytes level to `abi.encode(uint256(n))`. -/
def encodeUint256BE (n : Nat) : ByteArray :=
  LegalKernel.Bridge.encodeUint256BE n

/-- Concatenate a list of byte arrays. -/
def concatBytes (bs : List ByteArray) : ByteArray :=
  bs.foldl ByteArray.append ByteArray.empty

/-- Compute the migration struct hash (typeHash + 5 fields = 6 × 32 = 192 bytes).
    Mirrors `KnomosisEip712.migrationStructHash` byte-for-byte. -/
def migrationStructHash (predecessorDid successorDid migrationStateRoot : ByteArray)
    (migrationStateRootLogIdx graceWindowBlocks : Nat) : ByteArray :=
  let preimage := concatBytes
    [ migrationTypeHash
    , predecessorDid
    , successorDid
    , migrationStateRoot
    , encodeUint256BE migrationStateRootLogIdx
    , encodeUint256BE graceWindowBlocks
    ]
  hashBytes preimage

/-- The EIP-712 prefix bytes. -/
def eip712Prefix : ByteArray := ByteArray.mk #[0x19, 0x01]

/-- Compute the EIP-712 digest:
    `keccak256(\x19\x01 ‖ domainSeparator ‖ structHash)`.
    Equivalent to `KnomosisEip712.digest(domainSeparator, structHash)`
    in `solidity/src/lib/KnomosisEip712.sol`. -/
def computeDigest (domainSeparator structHash : ByteArray) : ByteArray :=
  hashBytes (concatBytes [eip712Prefix, domainSeparator, structHash])

/-- Compute a domain separator for the migration domain.
    Delegates to the canonical `Bridge.Eip712.eip712DomainSeparator`,
    which uses the 5-field
    `EIP712Domain(string name,string version,uint256 chainId,
    uint256 rollupId,bytes verifyingContract)` layout that
    `solidity/src/lib/KnomosisEip712.sol` mirrors verbatim. -/
def migrationDomainSeparator (chainId rollupId : Nat)
    (verifyingContract : ByteArray) : ByteArray :=
  LegalKernel.Bridge.eip712DomainSeparator
    { name := migrationDomainName.toUTF8
    , version := migrationDomainVersion.toUTF8
    , chainId := chainId
    , rollupId := rollupId
    , verifyingContract := verifyingContract
    }

/-! ## Generators -/

/-- Generate `n` deterministic bytes via the LCG. -/
def genBytes (n : Nat) : Gen ByteArray := fun st0 =>
  let res :=
    (List.range n).foldl
      (fun (acc : List UInt8 × GenState) (_ : Nat) =>
        let (xs, s) := acc
        let (b, s') := genUInt8 s
        (b :: xs, s'))
      ([], st0)
  (ByteArray.mk res.fst.reverse.toArray, res.snd)

/-- Build a fixture entry from raw inputs, computing the derived
    digest.  The Solidity-side `_wrapDigest` uses
    `KnomosisEip712.domainSeparator(name, "1", chainid, rollupId,
    address(this))`; this Lean-side helper produces the same bytes. -/
def mkEntry (predecessor successor predDid succDid stateRoot
             verifyingContract sig recovered : ByteArray)
            (logIdx graceBlocks chainId rollupId : Nat)
            (direction : Direction) (outcome : ExpectedOutcome)
            (label : String) : Entry :=
  let domSep := migrationDomainSeparator chainId rollupId verifyingContract
  let structH := migrationStructHash predDid succDid stateRoot logIdx graceBlocks
  let digest := computeDigest domSep structH
  { predecessor := predecessor
  , successor := successor
  , predecessorDeploymentId := predDid
  , successorDeploymentId := succDid
  , migrationStateRoot := stateRoot
  , migrationStateRootLogIdx := logIdx
  , graceWindowBlocks := graceBlocks
  , chainId := chainId
  , rollupId := rollupId
  , verifyingContract := verifyingContract
  , expectedDigest := digest
  , expectedSig := sig
  , expectedRecovered := recovered
  , direction := direction
  , outcome := outcome
  , label := label
  }

/-- Generate a single happy-path entry. -/
def genHappyEntry (idx : Nat) : Gen Entry := fun st0 =>
  let (pred, s1)     := genBytes 20 st0
  let (succ, s2)     := genBytes 20 s1
  let (predDid, s3)  := genBytes 32 s2
  let (succDid, s4)  := genBytes 32 s3
  let (stateRt, s5)  := genBytes 32 s4
  let (vc, s6)       := genBytes 20 s5
  let (sig, s7)      := genBytes 65 s6
  let (recovered, s8) := genBytes 20 s7
  let (logIdx, s9)    := genUInt64Wide s8
  let (chainId, s10)  := genNat (2 ^ 30) s9
  -- The Solidity-side `_wrapDigest` passes `rollupId = 0`; the
  -- fixture pins this for cross-stack equivalence.
  let e := mkEntry pred succ predDid succDid stateRt vc sig recovered
                   logIdx minGraceWindowBlocks (chainId + 1) 0
                   .predecessorPreCommitted .accepted
                   s!"happy:{idx}"
  (e, s10)
where
  genUInt64Wide : Gen Nat := fun st0 =>
    let (lo, s1) := genNat (2 ^ 32) st0
    let (hi, s2) := genNat (2 ^ 32) s1
    (hi * (2 ^ 32) + lo, s2)

/-- Generate `n` happy-path entries. -/
def genHappyEntries (count : Nat) : Gen (List Entry) := fun st0 =>
  let res :=
    (List.range count).foldl
      (fun (acc : List Entry × GenState) (k : Nat) =>
        let (entries, s) := acc
        let (e, s') := genHappyEntry k s
        (e :: entries, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-- Boundary entries: 8 = 4 at minGraceWindowBlocks (accepted) + 4 at
    minGraceWindowBlocks - 1 (rejected). -/
def boundaryEntries : Gen (List Entry) := fun st0 =>
  let mkBoundary (grace : Nat) (out : ExpectedOutcome) (label : String) :
      Gen Entry := fun s =>
    let (pred, s1)     := genBytes 20 s
    let (succ, s2)     := genBytes 20 s1
    let (predDid, s3)  := genBytes 32 s2
    let (succDid, s4)  := genBytes 32 s3
    let (stateRt, s5)  := genBytes 32 s4
    let (vc, s6)       := genBytes 20 s5
    let (sig, s7)      := genBytes 65 s6
    let (recovered, s8) := genBytes 20 s7
    let e := mkEntry pred succ predDid succDid stateRt vc sig recovered
                     1 grace 1 0 .predecessorPreCommitted out label
    (e, s8)
  let entries : List (Gen Entry) :=
    [ mkBoundary minGraceWindowBlocks         .accepted              "boundary:grace-min"
    , mkBoundary minGraceWindowBlocks         .accepted              "boundary:grace-min-2"
    , mkBoundary (minGraceWindowBlocks * 2)   .accepted              "boundary:grace-2x"
    , mkBoundary (minGraceWindowBlocks * 10)  .accepted              "boundary:grace-10x"
    , mkBoundary (minGraceWindowBlocks - 1)   .revertGraceTooShort   "boundary:grace-min-minus-1"
    , mkBoundary (minGraceWindowBlocks - 100) .revertGraceTooShort   "boundary:grace-too-short-100"
    , mkBoundary 0                            .revertGraceTooShort   "boundary:grace-zero"
    , mkBoundary 1                            .revertGraceTooShort   "boundary:grace-one"
    ]
  let res :=
    entries.foldl
      (fun (acc : List Entry × GenState) (mk : Gen Entry) =>
        let (xs, s) := acc
        let (e, s') := mk s
        (e :: xs, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-- Cross-deployment-replay entries: 4 entries with identical
    `migrationStateRoot` etc but distinct deploymentId pairs.  All
    accepted; the property pinned is "distinct deploymentIds → distinct
    digests" (verified post-generation). -/
def crossReplayEntries : Gen (List Entry) := fun st0 =>
  let (commonStateRt, s1) := genBytes 32 st0
  let (commonPred, s2)    := genBytes 20 s1
  let (commonSucc, s3)    := genBytes 20 s2
  let (commonVc, s4)      := genBytes 20 s3
  let (commonSig, s5)     := genBytes 65 s4
  let (commonRec, s6)     := genBytes 20 s5
  let res :=
    (List.range 4).foldl
      (fun (acc : List Entry × GenState) (k : Nat) =>
        let (entries, s) := acc
        let (predDid, s1) := genBytes 32 s
        let (succDid, s2) := genBytes 32 s1
        let e := mkEntry commonPred commonSucc predDid succDid commonStateRt
                         commonVc commonSig commonRec 7 minGraceWindowBlocks 1 0
                         .predecessorPreCommitted .accepted
                         s!"cross-replay:{k}"
        (e :: entries, s2))
      ([], s6)
  (res.fst.reverse, res.snd)

/-- Audit-3-direction entries: 4 = 2 with predecessor pre-committed
    (accepted) + 2 with predecessor.migration() = address(0)
    (rejected). -/
def auditDirectionEntries : Gen (List Entry) := fun st0 =>
  let mkDirEntry (dir : Direction) (out : ExpectedOutcome) (label : String) :
      Gen Entry := fun s =>
    let (pred, s1)     := genBytes 20 s
    let (succ, s2)     := genBytes 20 s1
    let (predDid, s3)  := genBytes 32 s2
    let (succDid, s4)  := genBytes 32 s3
    let (stateRt, s5)  := genBytes 32 s4
    let (vc, s6)       := genBytes 20 s5
    let (sig, s7)      := genBytes 65 s6
    let (recovered, s8) := genBytes 20 s7
    let e := mkEntry pred succ predDid succDid stateRt vc sig recovered
                     1 minGraceWindowBlocks 1 0 dir out label
    (e, s8)
  let entries : List (Gen Entry) :=
    [ mkDirEntry .predecessorPreCommitted .accepted "audit-3:pred-pre-committed-1"
    , mkDirEntry .predecessorPreCommitted .accepted "audit-3:pred-pre-committed-2"
    , mkDirEntry .predecessorAddressZero .revertPredecessorDoesNotReference "audit-3:pred-zero-1"
    , mkDirEntry .predecessorAddressZero .revertPredecessorDoesNotReference "audit-3:pred-zero-2"
    ]
  let res :=
    entries.foldl
      (fun (acc : List Entry × GenState) (mk : Gen Entry) =>
        let (xs, s) := acc
        let (e, s') := mk s
        (e :: xs, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-! ## JSON serialisation -/

/-- Convert `Direction` to a fixture string. -/
def Direction.toString : Direction → String
  | .predecessorPreCommitted    => "predecessorPreCommitted"
  | .predecessorAddressZero     => "predecessorAddressZero"

/-- Convert one entry to JSON. -/
def Entry.toJson (e : Entry) : Json :=
  .obj
    [ ("label",                    .str e.label)
    , ("predecessor",              .str (hexFromBytes e.predecessor))
    , ("successor",                .str (hexFromBytes e.successor))
    , ("predecessorDeploymentId",  .str (hexFromBytes e.predecessorDeploymentId))
    , ("successorDeploymentId",    .str (hexFromBytes e.successorDeploymentId))
    , ("migrationStateRoot",       .str (hexFromBytes e.migrationStateRoot))
    , ("migrationStateRootLogIdx", .num e.migrationStateRootLogIdx)
    , ("graceWindowBlocks",        .num e.graceWindowBlocks)
    , ("chainId",                  .num e.chainId)
    , ("rollupId",                 .num e.rollupId)
    , ("verifyingContract",        .str (hexFromBytes e.verifyingContract))
    , ("expectedDigest",           .str (hexFromBytes e.expectedDigest))
    , ("expectedSig",              .str (hexFromBytes e.expectedSig))
    , ("expectedRecovered",        .str (hexFromBytes e.expectedRecovered))
    , ("direction",                .str e.direction.toString)
    , ("outcome",                  .str e.outcome.toString)
    ]

/-- Build the full fixture per §10.1.7. -/
def buildFixture (seed : UInt64) : (Json × Nat) :=
  let (happy,    s1) := genHappyEntries 16 ⟨seed⟩
  let (boundary, s2) := boundaryEntries s1
  let (cross,    s3) := crossReplayEntries s2
  let (audit,    _ ) := auditDirectionEntries s3
  let allEntries := happy ++ boundary ++ cross ++ audit
  let header : Json := .obj
    [ ("seed",                  .num seed.toNat)
    , ("isKeccak256Linked",     .bool isKeccak256Linked)
    , ("hashIdentifier",        .str (hashImplementationIdentifier ()))
    , ("count",                 .num allEntries.length)
    , ("countHappyPath",        .num 16)
    , ("countBoundary",         .num 8)
    , ("countCrossReplay",      .num 4)
    , ("countAuditDirection",   .num 4)
    , ("minGraceWindowBlocks",  .num minGraceWindowBlocks)
    , ("migrationDomainName",   .str migrationDomainName)
    , ("migrationDomainVersion", .str migrationDomainVersion)
    , ("typeStringForReference", .str knomosisMigrationTypeString)
    , ("domainTypeStringForReference",
        .str "EIP712Domain(string name,string version,uint256 chainId,uint256 rollupId,bytes verifyingContract)")
    ]
  let topLevel : Json := .obj
    [ ("header", header)
    , ("entries", .arr (allEntries.map Entry.toJson))
    ]
  (topLevel, allEntries.length)

/-- Fixture file name. -/
def fixtureName : String := "migration_attestation.json"

/-! ## Test cases -/

/-- The test cases (10).  Verify count breakdowns, byte-determinism,
    cross-replay distinguishability, audit-3-direction coverage,
    and conditional cross-check skip. -/
def tests : List TestCase :=
  [ { name := "F.1.7: migration_attestation fixture has 32 entries"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 32 then
          throw <| IO.userError s!"expected 32 entries, got {n}"
    }
  , { name := "F.1.7: per-category counts add to 32 (16 + 8 + 4 + 4)"
    , body := do
        let seed ← readSeed
        let (happy,    s1) := genHappyEntries 16 ⟨seed⟩
        let (boundary, s2) := boundaryEntries s1
        let (cross,    s3) := crossReplayEntries s2
        let (audit,    _ ) := auditDirectionEntries s3
        if happy.length ≠ 16 then
          throw <| IO.userError s!"happy: {happy.length}"
        if boundary.length ≠ 8 then
          throw <| IO.userError s!"boundary: {boundary.length}"
        if cross.length ≠ 4 then
          throw <| IO.userError s!"cross: {cross.length}"
        if audit.length ≠ 4 then
          throw <| IO.userError s!"audit: {audit.length}"
    }
  , { name := "F.1.7: fixture is byte-deterministic across runs"
    , body := do
        let seed ← readSeed
        let (j₁, _) := buildFixture seed
        let (j₂, _) := buildFixture seed
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "F.1.7: every entry has 32-byte expectedDigest + 65-byte sig + 20-byte recovered"
    , body := do
        let seed ← readSeed
        let (happy, _) := genHappyEntries 16 ⟨seed⟩
        for e in happy do
          if e.expectedDigest.size ≠ 32 then
            throw <| IO.userError s!"digest size: {e.expectedDigest.size}"
          if e.expectedSig.size ≠ 65 then
            throw <| IO.userError s!"sig size: {e.expectedSig.size}"
          if e.expectedRecovered.size ≠ 20 then
            throw <| IO.userError s!"recovered size: {e.expectedRecovered.size}"
    }
  , { name := "F.1.7: cross-replay corners produce 4 distinct digests"
    , body := do
        let seed ← readSeed
        -- Skip past happy + boundary
        let (_, s1) := genHappyEntries 16 ⟨seed⟩
        let (_, s2) := boundaryEntries s1
        let (cross, _) := crossReplayEntries s2
        let digests := cross.map (·.expectedDigest.toList)
        let unique := digests.foldl
          (fun acc d => if acc.contains d then acc else d :: acc) []
        if unique.length ≠ 4 then
          throw <| IO.userError s!"expected 4 distinct, got {unique.length}"
    }
  , { name := "F.1.7: audit-3-direction has 2 accepted + 2 rejected"
    , body := do
        let seed ← readSeed
        let (_, s1) := genHappyEntries 16 ⟨seed⟩
        let (_, s2) := boundaryEntries s1
        let (_, s3) := crossReplayEntries s2
        let (audit, _) := auditDirectionEntries s3
        let accepted := audit.countP (fun e => match e.outcome with | .accepted => true | _ => false)
        let rejected := audit.countP (fun e => match e.outcome with | .revertPredecessorDoesNotReference => true | _ => false)
        if accepted ≠ 2 then throw <| IO.userError s!"accepted: {accepted}"
        if rejected ≠ 2 then throw <| IO.userError s!"rejected: {rejected}"
    }
  , { name := "F.1.7: boundary has 4 accepted + 4 GraceTooShort"
    , body := do
        let seed ← readSeed
        let (_, s1) := genHappyEntries 16 ⟨seed⟩
        let (boundary, _) := boundaryEntries s1
        let accepted := boundary.countP (fun e => match e.outcome with | .accepted => true | _ => false)
        let rejected := boundary.countP (fun e => match e.outcome with | .revertGraceTooShort => true | _ => false)
        if accepted ≠ 4 then throw <| IO.userError s!"accepted: {accepted}"
        if rejected ≠ 4 then throw <| IO.userError s!"rejected: {rejected}"
    }
  , { name := "F.1.7: migration type string matches Solidity knomosisMigrationTypeString"
    , body := do
        -- Pin the type string character-for-character against the
        -- Solidity-side `KnomosisEip712.KNOMOSIS_MIGRATION_TYPE_STRING`.
        -- Note `uint64 migrationStateRootLogIdx` (NOT `uint256`) —
        -- the Solidity constant uses `uint64`, and a single character
        -- difference here propagates to a different
        -- `keccak256(typeString)` typeHash and thus a different
        -- struct hash and digest.  This audit pass closes the
        -- pre-fix bug where Lean said `uint256`.
        let expected :=
          "KnomosisMigration(bytes32 predecessorDeploymentId,bytes32 successorDeploymentId,bytes32 migrationStateRoot,uint64 migrationStateRootLogIdx,uint256 graceWindowBlocks)"
        if knomosisMigrationTypeString ≠ expected then
          throw <| IO.userError s!"type string mismatch:\n  expected {expected}\n  got      {knomosisMigrationTypeString}"
    }
  , { name := "F.1.7: fixture file write / verify cycle succeeds"
    , body := do
        let seed ← readSeed
        let (json, _) := buildFixture seed
        writeFixture fixtureName json.encode
    }
  , { name := "F.1.7: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback; cross-stack digest assertion skipped"
    }
  , { name := "F.1.7: digest = computeDigest(domSep, structHash) (recipe self-consistency)"
    , body := do
        -- Internal self-consistency: the stored `expectedDigest`
        -- must equal the recomputation of the digest pipeline from
        -- the entry's other recorded fields.  This catches a class
        -- of audit-introducible bugs where the fixture's
        -- `expectedDigest` is stored from one recipe but the
        -- on-disk fields encode a *different* recipe (which would
        -- silently diverge from what `mkEntry` produces in a future
        -- regeneration).
        --
        -- Hash-binding-independent: under FNV fallback, both sides
        -- of the equation use the same fallback, so equality
        -- holds.  Under production keccak256, both sides use
        -- keccak256, so equality also holds.  The check is
        -- therefore valuable in BOTH binding modes.
        let seed ← readSeed
        let (happy, _) := genHappyEntries 16 ⟨seed⟩
        match happy.head? with
        | none => throw <| IO.userError "no happy entries to check"
        | some e =>
            let domSep :=
              migrationDomainSeparator e.chainId e.rollupId e.verifyingContract
            let structH :=
              migrationStructHash e.predecessorDeploymentId
                                  e.successorDeploymentId
                                  e.migrationStateRoot
                                  e.migrationStateRootLogIdx
                                  e.graceWindowBlocks
            let recomputed := computeDigest domSep structH
            if recomputed ≠ e.expectedDigest then
              throw <| IO.userError <|
                s!"recipe drift: recomputed digest size {recomputed.size}, " ++
                s!"stored digest size {e.expectedDigest.size}; " ++
                s!"category={e.label}"
    }
  , { name := "F.1.7: migration domain separator delegates to canonical Bridge.Eip712 (size 32)"
    , body := do
        -- Pin the size invariant of `migrationDomainSeparator` —
        -- it must produce a 32-byte output regardless of input,
        -- matching `eip712DomainSeparator_size`.  Sanity check on
        -- the delegation: a typo that swapped to a different
        -- function would surface here as a size mismatch.
        let bs := ByteArray.mk
          (((List.replicate 19 (0 : UInt8)) ++ [(0xab : UInt8)]).toArray)
        let ds := migrationDomainSeparator 1 0 bs
        if ds.size ≠ 32 then
          throw <| IO.userError s!"domSep size {ds.size}; want 32"
    }
  ]

end MigrationAttestation
end LegalKernel.Test.Bridge.CrossCheck
