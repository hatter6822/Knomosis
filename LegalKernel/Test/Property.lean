/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.Property — Audit-3.9 property-based testing harness.

A minimal, in-tree property-based testing harness using a
deterministic LCG (no `Std.Random` dependency, no third-party
package).  Designed to complement the value-level fixture tests
with sampled coverage of the encoding round-trip and pipeline
idempotency properties.

Reproducibility: every property test logs its seed on failure.
The default seed is `0xKNOMOSIS_2026` (literal `212918432562934`);
operators can override via the `KNOMOSIS_PROPERTY_SEED` environment
variable.  `KNOMOSIS_PROPERTY_ITERATIONS` overrides the default
iteration count (100).

This module is **not** part of the trusted computing base.  Bugs
here surface as false positives (additional reviewer load) or
false negatives (a property regression slipping through), but
cannot violate any kernel invariant.
-/

import LegalKernel.Test.Framework

namespace LegalKernel.Test
namespace Property

/-! ## Deterministic LCG

A Linear Congruential Generator with the parameters used in
`drand48` (POSIX): `a = 0x5DEECE66D`, `c = 0xB`, modulus `2^48`.
Sufficient for property-test seeding; not cryptographic. -/

/-- LCG state: a 48-bit seed (stored as `UInt64` with the top 16
    bits unused). -/
structure GenState where
  /-- The LCG seed. -/
  seed : UInt64
  deriving Repr

/-- Step the LCG once.  Returns the new seed; drawing functions
    derive their output from the seed bits. -/
def stepSeed (s : UInt64) : UInt64 :=
  -- (s * 0x5DEECE66D + 0xB) mod 2^48
  let prod := s * 0x5DEECE66D + 0xB
  prod &&& 0xFFFFFFFFFFFF

/-- A generator for type T: takes a state, returns a value and an
    updated state. -/
abbrev Gen (T : Type) : Type := GenState → T × GenState

/-! ## Primitive generators -/

/-- Generate a `Nat` in the range `[0, max)`. -/
def genNat (max : Nat) : Gen Nat := fun st =>
  let s' := stepSeed st.seed
  let v  := if max = 0 then 0 else s'.toNat % max
  (v, ⟨s'⟩)

/-- Generate a `UInt8`. -/
def genUInt8 : Gen UInt8 := fun st =>
  let (n, st') := genNat 256 st
  (UInt8.ofNat n, st')

/-- Generate a `Bool`. -/
def genBool : Gen Bool := fun st =>
  let (n, st') := genNat 2 st
  (decide (n = 1), st')

/-- Generate a `ByteArray` of length up to `lenMax`. -/
def genByteArray (lenMax : Nat) : Gen ByteArray := fun st =>
  let (len, st1) := genNat (lenMax + 1) st
  let rec loop (n : Nat) (acc : List UInt8) (s : GenState) : List UInt8 × GenState :=
    if n = 0 then (acc, s)
    else
      let (b, s') := genUInt8 s
      loop (n - 1) (b :: acc) s'
  let (bytes, st2) := loop len [] st1
  (ByteArray.mk bytes.toArray, st2)

/-! ## Higher-order combinators -/

/-- Map a function over a generator's output. -/
def Gen.map {α β : Type} (g : Gen α) (f : α → β) : Gen β := fun st =>
  let (v, st') := g st
  (f v, st')

/-- Sequence two generators monadically. -/
def Gen.bind {α β : Type} (g : Gen α) (f : α → Gen β) : Gen β := fun st =>
  let (v, st') := g st
  f v st'

/-! ## The `forAll` driver

Run a property `prop : T → Bool` on `n` random samples drawn from
`g`.  Throws an `IO.userError` on the first failing sample,
including the failing value's representation and the seed for
reproduction. -/

/-- Run `prop` on `n` random `T`-values.  Throws on the first
    counter-example.  Reports the failing value via `Repr` and the
    triggering seed. -/
def forAll {T : Type} [Repr T]
    (n : Nat) (initialSeed : UInt64) (g : Gen T) (prop : T → Bool) :
    IO Unit := do
  let mut st : GenState := ⟨initialSeed⟩
  let mut failingSeed : Option UInt64 := none
  let mut failingValue : Option T := none
  for _ in [0 : n] do
    let prevSeed := st.seed
    let (v, st') := g st
    st := st'
    if failingValue.isNone ∧ ! prop v then
      failingSeed := some prevSeed
      failingValue := some v
  match failingSeed, failingValue with
  | none, _ => pure ()
  | some seed, some v =>
    throw <| IO.userError s!"property failed at seed {seed}: counter-example = {repr v}"
  | some seed, none =>
    throw <| IO.userError s!"property failed at seed {seed} (no counter-example captured)"

/-! ## Default seed + iteration count

These match the plan: fixed default for reproducibility, env-var
overrides for diversifying CI runs.  Read the env vars in
test-suite drivers; here we expose the defaults as constants. -/

/-- Default seed for property tests.  Override via the
    `KNOMOSIS_PROPERTY_SEED` env var in the test driver. -/
def defaultSeed : UInt64 := 212918432562934   -- 0xC1D8E6F4F8B6 ≈ "KNOMOSIS 2026"

/-- Default per-property iteration count.  Override via
    `KNOMOSIS_PROPERTY_ITERATIONS`. -/
def defaultIterations : Nat := 100

/-- Read the seed from the env var if set, else the default. -/
def readSeed : IO UInt64 := do
  match (← IO.getEnv "KNOMOSIS_PROPERTY_SEED") with
  | none => pure defaultSeed
  | some s =>
    -- Accept hex (with 0x prefix) or decimal.
    if s.startsWith "0x" then
      pure (UInt64.ofNat ((s.drop 2).foldl (fun acc c =>
        acc * 16 +
        (if c.isDigit then c.toNat - '0'.toNat
         else if c.toNat ≥ 'a'.toNat ∧ c.toNat ≤ 'f'.toNat then c.toNat - 'a'.toNat + 10
         else if c.toNat ≥ 'A'.toNat ∧ c.toNat ≤ 'F'.toNat then c.toNat - 'A'.toNat + 10
         else 0)) 0))
    else
      pure (UInt64.ofNat s.toNat!)

/-- Read the iteration count from the env var if set, else the default. -/
def readIterations : IO Nat := do
  match (← IO.getEnv "KNOMOSIS_PROPERTY_ITERATIONS") with
  | none => pure defaultIterations
  | some s => pure s.toNat!

end Property
end LegalKernel.Test
