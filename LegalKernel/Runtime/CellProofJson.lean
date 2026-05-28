/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

import LegalKernel.FaultProof.Cell
import LegalKernel.FaultProof.Commit
import LegalKernel.Runtime.Hash

/-!
LegalKernel.Runtime.CellProofJson — RH-G fault-proof observer
cell-proof JSON serialiser.

Hoisted from `Main.lean` so the (a) `knomosis export-cell-proofs`
subcommand AND (b) the cross-stack regression tests in
`LegalKernel.Test.Integration.ExportCellProofsCli` can both
reach the helpers.  The JSON format is the cross-stack wire
contract between the Lean cell-proof exporter and the Rust
observer's `CellProof` struct.

## Wire format

One JSON object per cell-proof, snake_case fields matching the
Rust `serde::Deserialize` defaults:

```json
{
  "cell_kind": <Nat>,
  "key_a": "<16 hex chars>",
  "key_b": "<16 hex chars>",
  "cell_value": "<2N hex chars>",
  "witness_commit": "<64 hex chars>"
}
```

Width discipline:
* `cell_kind` — JSON number, range 0..=6 (per `CellTag`).
* `key_a` / `key_b` — left-zero-padded to 16 hex chars
  (representing the low 64 bits of the key as
  big-endian).
* `cell_value` — variable-width raw cell bytes.
* `witness_commit` — exactly 64 hex chars (32-byte
  `commitExtendedState` output).
-/

namespace LegalKernel.Runtime.CellProofJson

open LegalKernel.FaultProof

/-- Format a `ContentHash` as a lowercase hex string with no
    `0x` prefix.  Width-agnostic. -/
def formatHashHex (h : ContentHash) : String :=
  let toHex (b : UInt8) : String :=
    let hi := b.toNat / 16
    let lo := b.toNat % 16
    let toChar (n : Nat) : Char :=
      if n < 10 then Char.ofNat (n + 48)        -- '0'..'9'
               else Char.ofNat (n - 10 + 97)    -- 'a'..'f'
    String.ofList [toChar hi, toChar lo]
  h.toList.foldl (fun acc b => acc ++ toHex b) ""

/-- Format a `CellTag` as `(kindIndex, keyA, keyB)` JSON-stable
    decimal + hex strings.  Both keys are formatted as 16 hex
    chars (low 64 bits, big-endian, left-zero-padded).

    Note: `DepositId` / `WithdrawalId` are `Nat` and may
    structurally exceed `2^64`.  The cross-stack contract
    truncates to the low 64 bits because the Rust `CellProof`
    struct currently uses `u128` keys whose JSON encoding
    convention is the same low-bit projection.  Production
    deployments must keep their deposit / withdrawal IDs within
    the `u64` range (this is also the Solidity contract's bound
    since the L1-side `depositId` field is `uint64`).  -/
def formatCellTag (t : CellTag) : String × String × String :=
  let toHexU64 (n : Nat) : String :=
    let lo : Nat := n % (1 <<< 64)
    -- 16 hex chars = 8 bytes; left-padded with '0'.
    let raw := Nat.toDigits 16 lo
    let pad := List.replicate (16 - raw.length) '0'
    String.ofList (pad ++ raw)
  let kind := toString t.kindIndex
  match t with
  | .balance r a       => (kind, toHexU64 r.toNat, toHexU64 a.toNat)
  | .nonce a           => (kind, toHexU64 a.toNat, toHexU64 0)
  | .registry a        => (kind, toHexU64 a.toNat, toHexU64 0)
  | .localPolicy a     => (kind, toHexU64 a.toNat, toHexU64 0)
  -- DepositId / WithdrawalId are `Nat` already (per
  -- Bridge/State.lean), so no `.toNat` projection.
  | .bridgeConsumed d  => (kind, toHexU64 d, toHexU64 0)
  | .bridgePending w   => (kind, toHexU64 w, toHexU64 0)
  | .bridgeNextWdId    => (kind, toHexU64 0, toHexU64 0)

/-- Encode a `ByteArray` as a lowercase hex string with no `0x`
    prefix.  Width = `2 × bytes.size`. -/
def bytesHex (bs : ByteArray) : String :=
  let toChar (n : Nat) : Char :=
    if n < 10 then Char.ofNat (n + 48)
             else Char.ofNat (n - 10 + 97)
  bs.toList.foldl
    (fun acc b =>
      let hi := b.toNat / 16
      let lo := b.toNat % 16
      acc ++ String.ofList [toChar hi, toChar lo])
    ""

/-- Format a `CellProof` as a single line of JSON suitable for
    the off-chain `knomosis-faultproof-observer`'s consumer.

    Layout uses snake_case field names so a Rust serde-style
    deserializer can consume the output without renames:

    ```
    {"cell_kind":N,"key_a":"HEX","key_b":"HEX","cell_value":"HEX","witness_commit":"HEX"}
    ```

    The `witness_commit` field is `commitExtendedState(p.witnessState)`
    — the verifier-supplied commit that must match the
    `preStateCommit` in `terminateOnSingleStep`. -/
def formatCellProofJson (p : CellProof) : String :=
  let (kind, keyA, keyB) := formatCellTag p.cellTag
  let cellValHex := bytesHex p.cellValue
  let commit := commitExtendedState p.witnessState
  let commitHex := formatHashHex commit
  -- JSON line builder.  String.append used directly to keep
  -- the literal quotes out of the s!"..." parser.
  let q := "\""
  let parts : List String := [
    "{", q ++ "cell_kind" ++ q, ":", kind, ",",
    q ++ "key_a" ++ q, ":", q ++ keyA ++ q, ",",
    q ++ "key_b" ++ q, ":", q ++ keyB ++ q, ",",
    q ++ "cell_value" ++ q, ":", q ++ cellValHex ++ q, ",",
    q ++ "witness_commit" ++ q, ":", q ++ commitHex ++ q,
    "}"
  ]
  String.join parts

end LegalKernel.Runtime.CellProofJson
