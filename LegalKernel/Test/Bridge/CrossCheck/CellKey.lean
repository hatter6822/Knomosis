-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.Bridge.CrossCheck.CellKey — cross-stack corpus for
the canonical SMT cell-key derivation.

An SMT cell proof opens exactly one leaf, and which leaf is
determined by the key.  `KnomosisStepVM` must therefore DERIVE the
key from the cell's logical identity rather than accept one from
the caller — otherwise a proof opening cell X can be presented as
a proof about cell Y.  That only helps if both stacks derive the
SAME key: a divergence means the Lean-computed state root and the
L1-recomputed root disagree for reasons no test would attribute to
the key derivation.

This corpus pins the two halves separately, because they fail
differently:

  * `preimageHex` — the packed `(kind, keyA, keyB)` layout.  Hash
    independent, so it is pinned UNCONDITIONALLY and catches any
    width, order or padding drift even under the fallback hash.
  * `keyHex` — `hashBytes(preimage)`.  Pinned only when a
    production keccak256 adaptor is linked, matching the discipline
    of the other cross-stack corpora.

Solidity mirror: `StepVMMerkle.deriveCellSmtKey`, which is
`keccak256(abi.encodePacked(uint8, uint256, uint256))`.
-/

import LegalKernel.Bridge.HashAdaptor
import LegalKernel.FaultProof.KeyDerivation
import LegalKernel.Test.Bridge.CrossCheck.Framework
import LegalKernel.Test.Framework

namespace LegalKernel.Test.Bridge.CrossCheck

open LegalKernel
open LegalKernel.Bridge
open LegalKernel.FaultProof
open LegalKernel.Runtime
open LegalKernel.Test

namespace CellKey

/-- The tags the corpus covers: one per kind, plus same-kind tags
    differing only in their key components (the case a truncating
    or field-swapping derivation would collapse). -/
def corpusTags : List CellTag :=
  [ .balance 0 0
  , .balance 1 2
  , .balance 2 1                    -- field order matters
  , .balance 0xFFFFFFFFFFFFFFFF 0xFFFFFFFFFFFFFFFE
  , .nonce 5
  , .registry 5                     -- same key, different kind
  , .localPolicy 5
  , .epochBudget 5
  , .bridgeConsumed 9
  , .bridgePending 9                -- same key, different kind
  , .bridgeConsumed 0x1_0000_0000_0000_0000  -- beyond 2^64
  , .bridgeNextWdId
  , .bridgeAmmReserveEth
  , .bridgeAmmReserveBold
  , .bridgeBoldCircuitClosed
  , .bridgeBoldTvlCap
  , .bridgeBoldTotalLockedValue
  , .bridgeAmmDisabled
  , .budgetPolicyFreeTier
  , .budgetPolicyActionCost
  , .budgetPolicyCurrentEpoch
  ]

/-- One corpus entry. -/
def entryJson (t : CellTag) : Json :=
  let (kind, keyA, keyB) := t.flatKey
  .obj
    [ ("kind",        .num kind)
    , ("keyA",        .str (toString keyA))
    , ("keyB",        .str (toString keyB))
    , ("preimageHex", .str (hexFromBytes (cellKeyPreimage t)))
    , ("keyHex",      .str (hexFromBytes (smtCellKey t)))
    ]

/-- The full fixture. -/
def encodeFixture : Json :=
  .obj
    [ ("identifier",        .str "knomosis/cell-key/v1")
    , ("isKeccak256Linked", .bool isKeccak256Linked)
    , ("hashIdentifier",    .str (hashImplementationIdentifier ()))
    , ("count",             .num corpusTags.length)
    , ("entries",           .arr (corpusTags.map entryJson))
    ]

/-- The fixture file name. -/
def fixtureName : String := "cell_key.json"

/-- Write the fixture file. -/
def writeCorpus : IO Unit :=
  writeFixture fixtureName encodeFixture.encode

/-- Tests. -/
def tests : List TestCase :=
  [ { name := "cell-key: preimage is 65 bytes for every corpus tag"
    , body := do
        for t in corpusTags do
          assertEq (expected := 65) (actual := (cellKeyPreimage t).size)
            s!"preimage width for {repr t}"
    }
  , { name := "cell-key: derived key is 32 bytes for every corpus tag"
    , body := do
        for t in corpusTags do
          assertEq (expected := 32) (actual := (smtCellKey t).size)
            s!"key width for {repr t}"
    }
  , { name := "cell-key: no two corpus tags share a pre-image"
    , body := do
        -- Pinned on the PRE-IMAGE, not the key: a pre-image
        -- collision is a derivation bug that no hash can repair,
        -- and it is detectable under the fallback hash too.
        let keyed : List (CellTag × List UInt8) :=
          corpusTags.map (fun t => (t, (cellKeyPreimage t).toList))
        let rec check : List (CellTag × List UInt8) → IO Unit
          | [] => pure ()
          | (t, k) :: rest => do
            for (t', k') in rest do
              if k == k' then
                throw <| IO.userError
                  s!"PRE-IMAGE COLLISION: {repr t} and {repr t'} — a cell \
                     proof for one would verify as a proof about the other"
            check rest
        check keyed
    }
  , { name := "cell-key: the beyond-2^64 deposit id does not alias"
    , body := do
        -- The reason the key is hashed rather than packed into
        -- `1 + 8 + 8` bytes: `DepositId` is an unbounded `Nat`, so a
        -- u64-truncating derivation would collapse these two.
        let a := cellKeyPreimage (.bridgeConsumed 0)
        let b := cellKeyPreimage (.bridgeConsumed 0x1_0000_0000_0000_0000)
        assert (a.toList != b.toList)
          "deposit ids differing by exactly 2^64 must not alias"
    }
  , { name := "cell-key: write cell_key.json fixture file"
    , body := writeCorpus
    }
  ]

end CellKey

end LegalKernel.Test.Bridge.CrossCheck
