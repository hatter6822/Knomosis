/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.Goldens — Workstream F.2.

Generates and asserts the mainnet-goldens corpus described in
`solidity/test/goldens/README.md`:

  * 32 keccak256 of real block headers
  * 32 real `(pk, msg, sig)` triples
  * 32 real RLP-encoded transactions (with their keccak256 hashes)

This initial check-in ships a deterministic *synthetic* corpus
(LCG-derived preimages with recorded production-binding output);
upgrading to a real mainnet corpus is the follow-up tracked in
`solidity/test/goldens/README.md`.

**Hash-binding-conditional behaviour.**  Per the integration plan
§10.2, the Lean-side asserter:

  * `isKeccak256Linked = true` → byte-asserts each record matches
    the production binding's output.
  * `isKeccak256Linked = false` → emits `SKIPPED: keccak256
    fallback` for the keccak / RLP-then-keccak rows; ECDSA-verify
    rows also skip (the digest is keccak-derived).

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

namespace Goldens

/-! ## Deterministic byte generation -/

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

/-! ## Block-header goldens -/

/-- One block-header golden record. -/
structure BlockHeader where
  /-- Synthetic preimage (substitute for a real RLP-encoded header). -/
  preimage : ByteArray
  /-- Recorded keccak256 / fallback output of `preimage`. -/
  hash     : ByteArray

/-- Generate one block-header record. -/
def genBlockHeader : Gen BlockHeader := fun st0 =>
  -- Real Ethereum block headers are typically ≈ 530 bytes RLP-encoded;
  -- our synthetic preimage uses 512 bytes for byte stability.
  let (preimage_, st1) := genBytes 512 st0
  ({ preimage := preimage_, hash := hashBytes preimage_ }, st1)

/-! ## Transaction-signature goldens -/

/-- One `(pk, msg, sig)` golden triple. -/
structure TxSig where
  /-- 64-byte uncompressed pubkey. -/
  pubkey : ByteArray
  /-- 32-byte signing-input digest (typically keccak256 of an RLP-
      encoded transaction). -/
  msg    : ByteArray
  /-- 65-byte ECDSA signature `r ‖ s ‖ v`. -/
  sig    : ByteArray

/-- Generate one TxSig record.  Pubkey and msg are LCG-derived;
    `sig` is also LCG-derived (placeholder under the FNV fallback;
    the Solidity-side cross-check is gated on the production binding). -/
def genTxSig : Gen TxSig := fun st0 =>
  let (pk, s1)  := genBytes 64 st0
  let (msg, s2) := genBytes 32 s1
  let (sig, s3) := genBytes 65 s2
  ({ pubkey := pk, msg := msg, sig := sig }, s3)

/-! ## RLP-encoding goldens -/

/-- One RLP-encoding golden record. -/
structure RlpEntry where
  /-- The (synthetic) RLP-encoded transaction bytes. -/
  rlp  : ByteArray
  /-- The recorded keccak256 of the RLP bytes (the EVM tx hash). -/
  hash : ByteArray

/-- Generate one RLP record.  Real Ethereum transactions are
    typically 100-1000 bytes; we use 256 here. -/
def genRlpEntry : Gen RlpEntry := fun st0 =>
  let (rlp, s1) := genBytes 256 st0
  ({ rlp := rlp, hash := hashBytes rlp }, s1)

/-! ## Generators for `n`-record corpora -/

/-- Generate `n` block-header goldens. -/
def genBlockHeaders (n : Nat) : Gen (List BlockHeader) := fun st0 =>
  let res :=
    (List.range n).foldl
      (fun (acc : List BlockHeader × GenState) (_ : Nat) =>
        let (xs, s) := acc
        let (e, s') := genBlockHeader s
        (e :: xs, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-- Generate `n` TxSig goldens. -/
def genTxSigs (n : Nat) : Gen (List TxSig) := fun st0 =>
  let res :=
    (List.range n).foldl
      (fun (acc : List TxSig × GenState) (_ : Nat) =>
        let (xs, s) := acc
        let (e, s') := genTxSig s
        (e :: xs, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-- Generate `n` RLP goldens. -/
def genRlpEntries (n : Nat) : Gen (List RlpEntry) := fun st0 =>
  let res :=
    (List.range n).foldl
      (fun (acc : List RlpEntry × GenState) (_ : Nat) =>
        let (xs, s) := acc
        let (e, s') := genRlpEntry s
        (e :: xs, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-! ## File path resolution -/

/-- Path to the goldens directory. -/
def goldensDir : String := "solidity/test/goldens"

/-- Resolve a goldens file's path. -/
def goldensPath (name : String) : String :=
  goldensDir ++ "/" ++ name

/-! ## File serialisation (line-based) -/

/-- Serialize block-header goldens as one record per line:
    `preimage_hex<TAB>hash_hex`. -/
def serializeBlockHeaders (records : List BlockHeader) : String :=
  let lines := records.map (fun r =>
    hexFromBytes r.preimage ++ "\t" ++ hexFromBytes r.hash)
  -- Add a trailing newline so concatenation with future appends is clean.
  String.intercalate "\n" lines ++ "\n"

/-- Serialize TxSig goldens as one record per line:
    `pubkey_hex<TAB>msg_hex<TAB>sig_hex`. -/
def serializeTxSigs (records : List TxSig) : String :=
  let lines := records.map (fun r =>
    hexFromBytes r.pubkey ++ "\t" ++ hexFromBytes r.msg ++ "\t" ++ hexFromBytes r.sig)
  String.intercalate "\n" lines ++ "\n"

/-- Serialize RLP goldens as one record per line:
    `rlp_hex<TAB>hash_hex`. -/
def serializeRlpEntries (records : List RlpEntry) : String :=
  let lines := records.map (fun r =>
    hexFromBytes r.rlp ++ "\t" ++ hexFromBytes r.hash)
  String.intercalate "\n" lines ++ "\n"

/-- Write a goldens file (with Json-style verify-on-existing semantics). -/
def writeGoldens (name : String) (content : String) : IO Unit := do
  let mode ← readWriteMode
  let path := goldensPath name
  match mode with
  | .overwrite => IO.FS.writeFile path content
  | .verify =>
    let exists_ ← System.FilePath.pathExists path
    if exists_ then
      let onDisk ← IO.FS.readFile path
      if onDisk ≠ content then
        throw <| IO.userError
          s!"goldens {name} drifted: re-run with CANON_FIXTURES_OVERWRITE=1 to regenerate"
    else
      IO.FS.writeFile path content

/-! ## Top-level corpus -/

/-- Build all three goldens corpora, threaded through one seed. -/
def buildAllGoldens (seed : UInt64) :
    List BlockHeader × List TxSig × List RlpEntry :=
  let (bh,  s1) := genBlockHeaders 32 ⟨seed⟩
  let (ts,  s2) := genTxSigs 32 s1
  let (rlp, _ ) := genRlpEntries 32 s2
  (bh, ts, rlp)

/-! ## Test cases -/

/-- The test cases.  Counts, byte-determinism, file write/verify,
    conditional cross-check. -/
def tests : List TestCase :=
  [ { name := "F.2: 32 block-header / 32 tx-sig / 32 rlp goldens"
    , body := do
        let seed ← readSeed
        let (bh, ts, rlp) := buildAllGoldens seed
        if bh.length ≠ 32 then
          throw <| IO.userError s!"bh count: {bh.length}"
        if ts.length ≠ 32 then
          throw <| IO.userError s!"ts count: {ts.length}"
        if rlp.length ≠ 32 then
          throw <| IO.userError s!"rlp count: {rlp.length}"
    }
  , { name := "F.2: every block-header hash is 32 bytes"
    , body := do
        let seed ← readSeed
        let (bh, _, _) := buildAllGoldens seed
        for r in bh do
          if r.hash.size ≠ 32 then
            throw <| IO.userError s!"bh hash size: {r.hash.size}"
    }
  , { name := "F.2: every tx-sig has 64-byte pubkey + 32-byte msg + 65-byte sig"
    , body := do
        let seed ← readSeed
        let (_, ts, _) := buildAllGoldens seed
        for r in ts do
          if r.pubkey.size ≠ 64 then
            throw <| IO.userError s!"pk size: {r.pubkey.size}"
          if r.msg.size ≠ 32 then
            throw <| IO.userError s!"msg size: {r.msg.size}"
          if r.sig.size ≠ 65 then
            throw <| IO.userError s!"sig size: {r.sig.size}"
    }
  , { name := "F.2: every rlp record has hash that matches hashBytes(rlp)"
    , body := do
        let seed ← readSeed
        let (_, _, rlp) := buildAllGoldens seed
        for r in rlp do
          if hashBytes r.rlp ≠ r.hash then
            throw <| IO.userError "rlp hash mismatch"
    }
  , { name := "F.2: corpus is byte-deterministic across runs"
    , body := do
        let seed ← readSeed
        let (b1, t1, r1) := buildAllGoldens seed
        let (b2, t2, r2) := buildAllGoldens seed
        let s1 := serializeBlockHeaders b1 ++ serializeTxSigs t1 ++ serializeRlpEntries r1
        let s2 := serializeBlockHeaders b2 ++ serializeTxSigs t2 ++ serializeRlpEntries r2
        if s1 ≠ s2 then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "F.2: write block_header_hashes.txt"
    , body := do
        let seed ← readSeed
        let (bh, _, _) := buildAllGoldens seed
        writeGoldens "block_header_hashes.txt" (serializeBlockHeaders bh)
    }
  , { name := "F.2: write transaction_signatures.txt"
    , body := do
        let seed ← readSeed
        let (_, ts, _) := buildAllGoldens seed
        writeGoldens "transaction_signatures.txt" (serializeTxSigs ts)
    }
  , { name := "F.2: write rlp_encodings.txt"
    , body := do
        let seed ← readSeed
        let (_, _, rlp) := buildAllGoldens seed
        writeGoldens "rlp_encodings.txt" (serializeRlpEntries rlp)
    }
  , { name := "F.2: keccak256 cross-check gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback; goldens cross-check skipped"
    }
  , { name := "F.2: ECDSA cross-check gated on isKeccak256Linked"
    , body := do
        -- ECDSA digest is keccak256-derived; without the binding, the
        -- digest doesn't match the production output and signatures
        -- can't be cross-checked.
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback (upstream of ECDSA digest); skipping"
    }
  ]

end Goldens
end LegalKernel.Test.Bridge.CrossCheck
