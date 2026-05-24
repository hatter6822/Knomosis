/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Encoding — round-trip + injectivity
tests for the new `Action.faultProofChallenge` /
`Action.faultProofResolution` constructors at frozen indices
17 / 18 (Workstream H §12.1).
-/

import LegalKernel.Encoding.Action
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.Authority
open LegalKernel.Encoding
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Encoding

private def smallBh : ByteArray := ByteArray.mk #[0x01, 0x02, 0x03]
private def smallCc : ByteArray := ByteArray.mk #[0xAA, 0xBB]

/-- Tests for the new fault-proof Action constructors' encoding. -/
def tests : List TestCase :=
  [ { name := "Action.tag of faultProofChallenge is 17"
    , body := do
        let a : Authority.Action :=
          .faultProofChallenge smallBh 5 10 smallCc
        assertEq (expected := 17) (actual := Action.tag a)
          "frozen index 17"
    }
  , { name := "Action.tag of faultProofResolution is 18"
    , body := do
        let a : Authority.Action :=
          .faultProofResolution smallBh 1 7 9
        assertEq (expected := 18) (actual := Action.tag a)
          "frozen index 18"
    }
  , { name := "faultProofChallenge encode/decode round-trip"
    , body := do
        let a : Authority.Action :=
          .faultProofChallenge smallBh 5 10 smallCc
        let h : Action.fieldsBounded a := by
          unfold Action.fieldsBounded
          refine ⟨?_, ?_, ?_, ?_⟩ <;> decide
        match Encodable.decode (T := Authority.Action)
                (Encodable.encode (T := Authority.Action) a) with
        | .ok (a', _) => assertEq (expected := a) (actual := a') "round-trip"
        | .error _    => assert false "decode failed"
        let _ := h
    }
  , { name := "faultProofResolution encode/decode round-trip"
    , body := do
        let a : Authority.Action :=
          .faultProofResolution smallBh 100 7 250
        let h : Action.fieldsBounded a := by
          unfold Action.fieldsBounded
          refine ⟨?_, ?_, ?_, ?_⟩ <;> decide
        match Encodable.decode (T := Authority.Action)
                (Encodable.encode (T := Authority.Action) a) with
        | .ok (a', _) => assertEq (expected := a) (actual := a') "round-trip"
        | .error _    => assert false "decode failed"
        let _ := h
    }
  , { name := "faultProofChallenge encoded bytes are non-empty"
    , body := do
        let a : Authority.Action :=
          .faultProofChallenge smallBh 0 0 smallCc
        assert ((Encodable.encode (T := Authority.Action) a).length > 0)
          "non-empty encoding"
    }
  , { name := "Distinct faultProofChallenges produce distinct bytes"
    , body := do
        let a1 : Authority.Action :=
          .faultProofChallenge smallBh 0 1 smallCc
        let a2 : Authority.Action :=
          .faultProofChallenge smallBh 0 2 smallCc
        assert ((Encodable.encode (T := Authority.Action) a1) ≠
                (Encodable.encode (T := Authority.Action) a2))
          "distinct disputedEndIdx ⇒ distinct bytes"
    }
  , { name := "faultProofChallenge ≠ faultProofResolution at byte level"
    , body := do
        let a1 : Authority.Action :=
          .faultProofChallenge ByteArray.empty 0 0 ByteArray.empty
        let a2 : Authority.Action :=
          .faultProofResolution ByteArray.empty 0 0 0
        assert ((Encodable.encode (T := Authority.Action) a1) ≠
                (Encodable.encode (T := Authority.Action) a2))
          "constructor-tag distinguishes"
    }
  , { name := "Action.fieldsBounded decidable on faultProofChallenge"
    , body := do
        let a : Authority.Action :=
          .faultProofChallenge ByteArray.empty 1 1 ByteArray.empty
        let _ : Decidable (Action.fieldsBounded a) := inferInstance
        pure ()
    }
  , { name := "Action.fieldsBounded decidable on faultProofResolution"
    , body := do
        let a : Authority.Action :=
          .faultProofResolution ByteArray.empty 1 1 1
        let _ : Decidable (Action.fieldsBounded a) := inferInstance
        pure ()
    }
  ]

end LegalKernel.Test.FaultProof.Encoding
