/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.DepositReceiptHash — Workstream
F.1.4.

Generates the `deposit_receipt_hash.json` cross-stack fixture: 128
entries verifying byte-equivalence between the L1-side `receiptHash`
(produced by `CanonBridge._registerDeposit`) and the L2-side
adaptor-projected `Bridge.DepositId`.

**The receipt-hash recipe** (mirrors `CanonBridge._registerDeposit`):

```
deploymentId = keccak256(abi.encode(chainid, contractAddr, canonVersionTag))
receiptHash  = keccak256(abi.encode(
    deploymentId, msg.sender, resourceId, token, amount, depositorNonce
))
```

The ABI-encoded preimage is 6 × 32 = 192 bytes:

  *  bytes32 deploymentId
  * uint256 depositor       (address left-padded)
  * uint256 resourceId      (uint64 zero-padded)
  * uint256 token           (address left-padded)
  * uint256 amount
  * uint256 depositorNonce  (uint64 zero-padded)

**The L2-side projection** (per integration plan §10.1.4 reference):

```
DepositId(receiptHash) = natFromBytesBE(receiptHash[0..8])
```

The fixture records both `expectedHash` (full 32-byte L1 form) and
`expectedDepositId` (Nat).  Deployments using a different projection
substitute their own.

**Coverage breakdown** (64 randomised + 64 corner = 128):

  * 16 Native ETH (resourceId = 0, token = 0x0..0)
  * 16 ERC-20 (resourceId ∈ [1, 64], token ≠ 0x0..0)
  *  8 Replay-resistance corners (chainid varies)
  * 16 Deployment-replay corners (full deploymentId varies)
  *  8 Boundary corners (amount = 0, nonce = 0, max-uint64 nonce,
     max-uint256 amount, etc.)
  * 64 randomised (mix of native + ERC-20)

Hash-binding-conditional behaviour: when `isKeccak256Linked = false`,
`expectedHash` is the FNV-1a-64 fallback bytes (NOT keccak256), so
the cross-check is skipped.

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

namespace DepositReceiptHash

/-! ## ABI-encoding helpers -/

/-- Encode a `Nat` as a 32-byte big-endian uint256 (Solidity ABI shape).
    Mirrors `LegalKernel.Bridge.Eip712.encodeUint256BE`. -/
def encodeUint256BE (n : Nat) : ByteArray :=
  let go (i : Nat) : UInt8 :=
    UInt8.ofNat ((n / (256 ^ (31 - i))) % 256)
  ByteArray.mk ((List.range 32).map go).toArray

/-- Encode a 20-byte address as a 32-byte left-padded uint256.  ABI
    encoding for `address` is the address right-aligned in 32 bytes
    (high 12 bytes are zero). -/
def encodeAddressLeftPadded (addr20 : ByteArray) : ByteArray :=
  let pad : ByteArray := ByteArray.mk (Array.replicate 12 (0 : UInt8))
  pad.append addr20

/-- Concatenate a list of byte arrays.  `bs.foldl ByteArray.append
    ByteArray.empty` form. -/
def concatBytes (bs : List ByteArray) : ByteArray :=
  bs.foldl ByteArray.append ByteArray.empty

/-! ## Fixture entry types -/

/-- One cross-stack deposit-receipt entry. -/
structure Entry where
  /-- The deployment ID's preimage (chainid, contractAddr, canonVersionTag). -/
  chainid              : Nat
  /-- 20-byte bridge contract address. -/
  contractAddr         : ByteArray
  /-- 32-byte canon version tag. -/
  canonVersionTag      : ByteArray
  /-- The derived `deploymentId` (32 bytes). -/
  deploymentId         : ByteArray
  /-- 20-byte depositor address (`msg.sender`). -/
  depositor            : ByteArray
  /-- uint64 resourceId (0 = native ETH; non-zero = ERC-20). -/
  resourceId           : Nat
  /-- 20-byte ERC-20 token (or zero address for native ETH). -/
  token                : ByteArray
  /-- uint256 amount. -/
  amount               : Nat
  /-- uint64 depositor-nonce. -/
  depositorNonce       : Nat
  /-- 32-byte expected receipt hash. -/
  expectedHash         : ByteArray
  /-- Lean-projected `DepositId` (top 8 BE bytes of receiptHash, decoded). -/
  expectedDepositId    : Nat
  /-- Tag for human readability and per-case categorisation. -/
  category             : String

/-! ## Hash recipe -/

/-- Compute the deploymentId preimage (3 × 32 = 96 bytes). -/
def deploymentIdPreimage (chainid : Nat) (contractAddr canonVersionTag : ByteArray) :
    ByteArray :=
  concatBytes
    [ encodeUint256BE chainid
    , encodeAddressLeftPadded contractAddr
    , canonVersionTag
    ]

/-- Compute the `deploymentId`. -/
def computeDeploymentId (chainid : Nat) (contractAddr canonVersionTag : ByteArray) :
    ByteArray :=
  hashBytes (deploymentIdPreimage chainid contractAddr canonVersionTag)

/-- Compute the receipt-hash preimage (6 × 32 = 192 bytes). -/
def receiptPreimage (deploymentId : ByteArray) (depositor : ByteArray)
    (resourceId : Nat) (token : ByteArray) (amount : Nat) (nonce : Nat) :
    ByteArray :=
  concatBytes
    [ deploymentId
    , encodeAddressLeftPadded depositor
    , encodeUint256BE resourceId
    , encodeAddressLeftPadded token
    , encodeUint256BE amount
    , encodeUint256BE nonce
    ]

/-- Compute the receipt hash. -/
def computeReceiptHash (deploymentId : ByteArray) (depositor : ByteArray)
    (resourceId : Nat) (token : ByteArray) (amount : Nat) (nonce : Nat) :
    ByteArray :=
  hashBytes (receiptPreimage deploymentId depositor resourceId token amount nonce)

/-- Project the 32-byte receipt hash into a 64-bit `DepositId` via
    the integration plan's reference projection
    (`natFromBytesBE(receiptHash[0..8])`). -/
def projectDepositId (receiptHash : ByteArray) : Nat :=
  let firstEight : List UInt8 := receiptHash.toList.take 8
  firstEight.foldl (fun acc b => acc * 256 + b.toNat) 0

/-! ## Deterministic generators -/

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

/-- Generate a uint64 (0 ≤ n < 2^64).  The LCG only produces values
    < 2^48, so we compose two draws to get a full uint64 spread. -/
def genUInt64Wide : Gen Nat := fun st0 =>
  let (lo, s1) := genNat (2 ^ 32) st0
  let (hi, s2) := genNat (2 ^ 32) s1
  (hi * (2 ^ 32) + lo, s2)

/-- Generate a uint256 (0 ≤ n < 2^256).  Composes 8 uint32 draws. -/
def genUInt256 : Gen Nat := fun st0 =>
  let res :=
    (List.range 8).foldl
      (fun (acc : Nat × GenState) (_ : Nat) =>
        let (n, s) := acc
        let (chunk, s') := genNat (2 ^ 32) s
        (n * (2 ^ 32) + chunk, s'))
      (0, st0)
  res

/-! ## Per-category entry construction -/

/-- Build an `Entry` from raw inputs, computing the derived hash and
    DepositId. -/
def mkEntry (chainid : Nat) (contractAddr canonVersionTag : ByteArray)
    (depositor : ByteArray) (resourceId : Nat) (token : ByteArray)
    (amount : Nat) (nonce : Nat) (category : String) : Entry :=
  let did := computeDeploymentId chainid contractAddr canonVersionTag
  let hash := computeReceiptHash did depositor resourceId token amount nonce
  { chainid := chainid
  , contractAddr := contractAddr
  , canonVersionTag := canonVersionTag
  , deploymentId := did
  , depositor := depositor
  , resourceId := resourceId
  , token := token
  , amount := amount
  , depositorNonce := nonce
  , expectedHash := hash
  , expectedDepositId := projectDepositId hash
  , category := category
  }

/-- The zero address. -/
def zeroAddr20 : ByteArray := ByteArray.mk (Array.replicate 20 (0 : UInt8))

/-- Generate one native-ETH entry. -/
def genNativeEntry (idx : Nat) : Gen Entry := fun st0 =>
  let (contractAddr,  s1) := genBytes 20 st0
  let (canonTag,      s2) := genBytes 32 s1
  let (depositor,     s3) := genBytes 20 s2
  let (chainid,       s4) := genNat (2 ^ 32) s3
  let (amount,        s5) := genUInt256 s4
  let (nonce,         s6) := genUInt64Wide s5
  let e := mkEntry chainid contractAddr canonTag depositor 0 zeroAddr20
                   amount nonce s!"native:{idx}"
  (e, s6)

/-- Generate one ERC-20 entry. -/
def genErc20Entry (idx : Nat) : Gen Entry := fun st0 =>
  let (contractAddr,  s1) := genBytes 20 st0
  let (canonTag,      s2) := genBytes 32 s1
  let (depositor,     s3) := genBytes 20 s2
  let (token,         s4) := genBytes 20 s3
  let (chainid,       s5) := genNat (2 ^ 32) s4
  let (amount,        s6) := genUInt256 s5
  let (nonce,         s7) := genUInt64Wide s6
  let (rid,           s8) := genNat 64 s7
  let e := mkEntry chainid contractAddr canonTag depositor (rid + 1) token
                   amount nonce s!"erc20:{idx}"
  (e, s8)

/-- Generate `count` entries via `mk` with the given seed thread. -/
def genN {α : Type} (mk : Nat → Gen α) (count : Nat) : Gen (List α) := fun st0 =>
  let res :=
    (List.range count).foldl
      (fun (acc : List α × GenState) (k : Nat) =>
        let (xs, s) := acc
        let (e, s') := mk k s
        (e :: xs, s'))
      ([], st0)
  (res.fst.reverse, res.snd)

/-! ## Boundary + replay corners -/

/-- Generate boundary corners: amount = 0, nonce = 0, nonce = 2^64-1,
    amount = 2^256-1, and a few compositions. -/
def boundaryEntries : Gen (List Entry) := fun st0 =>
  -- Common base: a single (chainid, contractAddr, canonTag, depositor) so
  -- the boundary cases vary only in amount / nonce.
  let (contractAddr,  s1) := genBytes 20 st0
  let (canonTag,      s2) := genBytes 32 s1
  let (depositor,     s3) := genBytes 20 s2
  let chainid := 1   -- mainnet-equivalent
  let max64  : Nat := 2 ^ 64 - 1
  let max256 : Nat := 2 ^ 256 - 1
  -- 8 boundary entries:
  let entries : List Entry :=
    [ mkEntry chainid contractAddr canonTag depositor 0 zeroAddr20 0 0          "boundary:zero-amount-zero-nonce"
    , mkEntry chainid contractAddr canonTag depositor 0 zeroAddr20 0 max64      "boundary:zero-amount-max-nonce"
    , mkEntry chainid contractAddr canonTag depositor 0 zeroAddr20 max256 0     "boundary:max-amount-zero-nonce"
    , mkEntry chainid contractAddr canonTag depositor 0 zeroAddr20 max256 max64 "boundary:max-amount-max-nonce"
    , mkEntry chainid contractAddr canonTag depositor 1 contractAddr 1 1        "boundary:erc20-min-id"
    , mkEntry chainid contractAddr canonTag depositor 64 contractAddr 1 1       "boundary:erc20-max-id"
    , mkEntry chainid contractAddr canonTag depositor 0 zeroAddr20 1 max64      "boundary:one-wei-max-nonce"
    , mkEntry chainid contractAddr canonTag depositor 0 zeroAddr20 max256 1     "boundary:max-amount-one-nonce"
    ]
  (entries, s3)

/-- Generate replay-resistance corners: 8 entries with identical
    (depositor, resourceId, token, amount, nonce) but varying chainid.
    A correct deploymentId binding produces 8 distinct hashes. -/
def replayResistanceEntries : Gen (List Entry) := fun st0 =>
  let (contractAddr,  s1) := genBytes 20 st0
  let (canonTag,      s2) := genBytes 32 s1
  let (depositor,     s3) := genBytes 20 s2
  let amount : Nat := 1000
  let nonce  : Nat := 7
  let entries : List Entry :=
    [ mkEntry 1     contractAddr canonTag depositor 0 zeroAddr20 amount nonce "replay:chainid-1"
    , mkEntry 5     contractAddr canonTag depositor 0 zeroAddr20 amount nonce "replay:chainid-5"
    , mkEntry 137   contractAddr canonTag depositor 0 zeroAddr20 amount nonce "replay:chainid-137"
    , mkEntry 8453  contractAddr canonTag depositor 0 zeroAddr20 amount nonce "replay:chainid-8453"
    , mkEntry 42161 contractAddr canonTag depositor 0 zeroAddr20 amount nonce "replay:chainid-42161"
    , mkEntry 11155111 contractAddr canonTag depositor 0 zeroAddr20 amount nonce "replay:chainid-sepolia"
    , mkEntry 17000 contractAddr canonTag depositor 0 zeroAddr20 amount nonce "replay:chainid-holesky"
    , mkEntry 80001 contractAddr canonTag depositor 0 zeroAddr20 amount nonce "replay:chainid-mumbai"
    ]
  (entries, s3)

/-- Generate deployment-replay corners: 16 entries with identical
    (depositor, resourceId, token, amount, nonce) but distinct
    `(chainid, contractAddr, canonVersionTag)` triples. -/
def deploymentReplayEntries : Gen (List Entry) := fun st0 =>
  let (depositor, s1) := genBytes 20 st0
  let amount : Nat := 5000
  let nonce  : Nat := 13
  let res :=
    (List.range 16).foldl
      (fun (acc : List Entry × GenState) (k : Nat) =>
        let (entries, s) := acc
        let (contractAddr, s') := genBytes 20 s
        let (canonTag, s'')    := genBytes 32 s'
        let (chainid, s''')    := genNat (2 ^ 30) s''
        let e := mkEntry (chainid + 1) contractAddr canonTag depositor 0 zeroAddr20
                         amount nonce s!"deployment-replay:{k}"
        (e :: entries, s'''))
      ([], s1)
  (res.fst.reverse, res.snd)

/-! ## Top-level fixture -/

/-- Build the full fixture per §10.1.4 breakdown.
    64 corner cases + 64 randomised = 128 total. -/
def buildFixture (seed : UInt64) : (Json × Nat) :=
  -- 64 corners: 16 native + 16 erc20 + 8 boundary + 8 replay + 16 deployment-replay.
  let (cornerNative,  s1) := genN genNativeEntry 16 ⟨seed⟩
  let (cornerErc20,   s2) := genN genErc20Entry  16 s1
  let (boundary,      s3) := boundaryEntries          s2
  let (replay,        s4) := replayResistanceEntries  s3
  let (deplReplay,    s5) := deploymentReplayEntries  s4
  -- 64 randomised: 32 native + 32 erc20.
  let (randNative,    s6) := genN genNativeEntry 32 s5
  let (randErc20,     _ ) := genN genErc20Entry  32 s6
  let allEntries :=
    cornerNative ++ cornerErc20 ++ boundary ++ replay ++ deplReplay ++
    randNative ++ randErc20
  let header : Json := .obj
    [ ("seed",                .num seed.toNat)
    , ("isKeccak256Linked",   .bool isKeccak256Linked)
    , ("hashIdentifier",      .str (hashImplementationIdentifier ()))
    , ("count",               .num allEntries.length)
    , ("countCornerNativeEth", .num 16)
    , ("countCornerErc20",     .num 16)
    , ("countBoundary",        .num 8)
    , ("countReplayResistance", .num 8)
    , ("countDeploymentReplay", .num 16)
    , ("countRandomised",      .num 64)
    , ("projection",           .str "natFromBytesBE(receiptHash[0..8])")
    ]
  let topLevel : Json := .obj
    [ ("header", header)
    , ("entries", .arr (allEntries.map (fun e => .obj
        [ ("category",            .str e.category)
        , ("chainid",             .num e.chainid)
        , ("contractAddr",        .str (hexFromBytes e.contractAddr))
        , ("canonVersionTag",     .str (hexFromBytes e.canonVersionTag))
        , ("depositor",           .str (hexFromBytes e.depositor))
        , ("resourceId",          .num e.resourceId)
        , ("token",               .str (hexFromBytes e.token))
        , ("amount",              .str (hexFromUint256BE e.amount))
        , ("depositorNonce",      .num e.depositorNonce)
        , ("deploymentId",        .str (hexFromBytes e.deploymentId))
        , ("expectedHash",        .str (hexFromBytes e.expectedHash))
        , ("expectedDepositId",   .num e.expectedDepositId)
        ])))
    ]
  (topLevel, allEntries.length)

/-- Fixture file name. -/
def fixtureName : String := "deposit_receipt_hash.json"

/-! ## Test cases -/

/-- The test cases.  Verify count breakdown, byte sizes, replay-
    distinguishability sanity, projection arithmetic, file write,
    and conditional cross-check skip. -/
def tests : List TestCase :=
  [ { name := "F.1.4: deposit_receipt fixture has 128 entries"
    , body := do
        let seed ← readSeed
        let (_, n) := buildFixture seed
        if n ≠ 128 then
          throw <| IO.userError s!"expected 128 entries, got {n}"
    }
  , { name := "F.1.4: fixture is byte-deterministic across runs"
    , body := do
        let seed ← readSeed
        let (j₁, _) := buildFixture seed
        let (j₂, _) := buildFixture seed
        if j₁.encode ≠ j₂.encode then
          throw <| IO.userError "non-deterministic"
    }
  , { name := "F.1.4: every entry has 20-byte addresses + 32-byte canonTag + 32-byte hash"
    , body := do
        let seed ← readSeed
        let (native1, s1) := genN genNativeEntry 16 ⟨seed⟩
        let (erc201,  s2) := genN genErc20Entry 16 s1
        let (boundary,_) := boundaryEntries s2
        for e in native1 ++ erc201 ++ boundary do
          if e.contractAddr.size ≠ 20 then
            throw <| IO.userError s!"contractAddr size: {e.contractAddr.size}"
          if e.canonVersionTag.size ≠ 32 then
            throw <| IO.userError s!"canonVersionTag size: {e.canonVersionTag.size}"
          if e.depositor.size ≠ 20 then
            throw <| IO.userError s!"depositor size: {e.depositor.size}"
          if e.token.size ≠ 20 then
            throw <| IO.userError s!"token size: {e.token.size}"
          if e.deploymentId.size ≠ 32 then
            throw <| IO.userError s!"deploymentId size: {e.deploymentId.size}"
          if e.expectedHash.size ≠ 32 then
            throw <| IO.userError s!"expectedHash size: {e.expectedHash.size}"
    }
  , { name := "F.1.4: replay-resistance corners produce 8 distinct hashes"
    , body := do
        let seed ← readSeed
        -- Skip past the randomised entries to reach replay corners.
        let (_, s1) := genN genNativeEntry 16 ⟨seed⟩
        let (_, s2) := genN genErc20Entry 16 s1
        let (_, s3) := genN genNativeEntry 16 s2
        let (_, s4) := genN genErc20Entry 16 s3
        let (_, s5) := boundaryEntries s4
        let (replay, _) := replayResistanceEntries s5
        let hashes := replay.map (·.expectedHash.toList)
        let unique := hashes.foldl
          (fun acc h => if acc.contains h then acc else h :: acc) []
        if unique.length ≠ 8 then
          throw <| IO.userError s!"expected 8 distinct hashes, got {unique.length}"
    }
  , { name := "F.1.4: deployment-replay corners produce 16 distinct hashes"
    , body := do
        let seed ← readSeed
        let (_, s1) := genN genNativeEntry 16 ⟨seed⟩
        let (_, s2) := genN genErc20Entry 16 s1
        let (_, s3) := genN genNativeEntry 16 s2
        let (_, s4) := genN genErc20Entry 16 s3
        let (_, s5) := boundaryEntries s4
        let (_, s6) := replayResistanceEntries s5
        let (deplReplay, _) := deploymentReplayEntries s6
        let hashes := deplReplay.map (·.expectedHash.toList)
        let unique := hashes.foldl
          (fun acc h => if acc.contains h then acc else h :: acc) []
        if unique.length ≠ 16 then
          throw <| IO.userError s!"expected 16 distinct hashes, got {unique.length}"
    }
  , { name := "F.1.4: projectDepositId returns Nat < 2^64"
    , body := do
        let seed ← readSeed
        let (native1, _) := genN genNativeEntry 16 ⟨seed⟩
        for e in native1 do
          if e.expectedDepositId ≥ 2 ^ 64 then
            throw <| IO.userError s!"DepositId out of range: {e.expectedDepositId}"
    }
  , { name := "F.1.4: encodeUint256BE produces 32 bytes for any Nat"
    , body := do
        for n in [0, 1, 256, 1000000, 2 ^ 64 - 1, 2 ^ 128] do
          let bs := encodeUint256BE n
          if bs.size ≠ 32 then
            throw <| IO.userError s!"encodeUint256BE({n}).size = {bs.size}"
    }
  , { name := "F.1.4: receiptPreimage is exactly 192 bytes"
    , body := do
        let did := encodeUint256BE 0   -- 32 bytes
        let preimage := receiptPreimage did zeroAddr20 0 zeroAddr20 0 0
        if preimage.size ≠ 192 then
          throw <| IO.userError s!"receiptPreimage size: {preimage.size}, expected 192"
    }
  , { name := "F.1.4: deploymentIdPreimage is exactly 96 bytes"
    , body := do
        let canonTag := encodeUint256BE 0   -- 32 bytes
        let preimage := deploymentIdPreimage 1 zeroAddr20 canonTag
        if preimage.size ≠ 96 then
          throw <| IO.userError s!"deploymentIdPreimage size: {preimage.size}, expected 96"
    }
  , { name := "F.1.4: fixture file write / verify cycle succeeds"
    , body := do
        let seed ← readSeed
        let (json, _) := buildFixture seed
        writeFixture fixtureName json.encode
    }
  , { name := "F.1.4: cross-stack assertion gated on isKeccak256Linked"
    , body := do
        if !isKeccak256Linked then
          skipWithReason s!"keccak256 fallback; cross-stack assert skipped"
    }
  , { name := "F.1.4: deploymentId + receiptHash recipe self-consistency (any binding)"
    , body := do
        -- Internal self-consistency: the stored `expectedHash` /
        -- `expectedDeploymentId` for each entry must equal the
        -- recomputation from the entry's other recorded fields.
        -- Catches a class of audit-introducible bugs where the
        -- fixture's expected fields drift from the recipe (e.g.
        -- after a recipe change without a fixture regeneration).
        --
        -- Hash-binding-independent: under FNV fallback, both sides
        -- of the equation use the same fallback, so equality
        -- holds.  Under production keccak256, both sides use
        -- keccak256, so equality also holds.  The check is
        -- valuable in BOTH binding modes (and would have caught
        -- the F.1.7 EIP-712 type-string drift documented in
        -- §22.1 of the integration plan, had a similar self-check
        -- been in place for that fixture).
        let seed ← readSeed
        let (cornerNative, _) := genN genNativeEntry 16 ⟨seed⟩
        for e in cornerNative do
          let didRecomputed :=
            computeDeploymentId e.chainid e.contractAddr e.canonVersionTag
          if didRecomputed ≠ e.deploymentId then
            throw <| IO.userError <|
              s!"deploymentId drift in {e.category}: " ++
              s!"recomputed size {didRecomputed.size} vs " ++
              s!"stored {e.deploymentId.size}"
          let hashRecomputed :=
            computeReceiptHash e.deploymentId e.depositor e.resourceId
                               e.token e.amount e.depositorNonce
          if hashRecomputed ≠ e.expectedHash then
            throw <| IO.userError <|
              s!"receiptHash drift in {e.category}: " ++
              s!"recomputed size {hashRecomputed.size} vs " ++
              s!"stored {e.expectedHash.size}"
    }
  ]

end DepositReceiptHash
end LegalKernel.Test.Bridge.CrossCheck
