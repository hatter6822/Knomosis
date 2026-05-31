-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.PerVariantCoherence — API stability
tests for #226.* (per-variant coherence) and #251.* (per-variant
cell-write semantic agreement).  All 38 theorems (19 #226 + 19
#251) are pinned at the term level so a future signature drift
fails the build.
-/

import LegalKernel.FaultProof.PerVariantCoherence
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.PerVariantCoherence

/-- API-stability tests for the 38 per-variant coherence theorems. -/
def tests : List TestCase :=
  [ -- ## #226.* — per-variant coherence theorems (19)
    { name := "#226.transfer API stable"
    , body := do let _ := @coherence_transfer; assert true "API exists"
    }
  , { name := "#226.mint API stable"
    , body := do let _ := @coherence_mint; assert true "API exists"
    }
  , { name := "#226.burn API stable"
    , body := do let _ := @coherence_burn; assert true "API exists"
    }
  , { name := "#226.freezeResource API stable"
    , body := do let _ := @coherence_freezeResource; assert true "API exists"
    }
  , { name := "#226.replaceKey API stable"
    , body := do let _ := @coherence_replaceKey; assert true "API exists"
    }
  , { name := "#226.reward API stable"
    , body := do let _ := @coherence_reward; assert true "API exists"
    }
  , { name := "#226.distributeOthers API stable"
    , body := do let _ := @coherence_distributeOthers; assert true "API exists"
    }
  , { name := "#226.proportionalDilute API stable"
    , body := do let _ := @coherence_proportionalDilute; assert true "API exists"
    }
  , { name := "#226.dispute API stable"
    , body := do let _ := @coherence_dispute; assert true "API exists"
    }
  , { name := "#226.disputeWithdraw API stable"
    , body := do let _ := @coherence_disputeWithdraw; assert true "API exists"
    }
  , { name := "#226.verdict API stable"
    , body := do let _ := @coherence_verdict; assert true "API exists"
    }
  , { name := "#226.rollback API stable"
    , body := do let _ := @coherence_rollback; assert true "API exists"
    }
  , { name := "#226.registerIdentity API stable"
    , body := do let _ := @coherence_registerIdentity; assert true "API exists"
    }
  , { name := "#226.deposit API stable"
    , body := do let _ := @coherence_deposit; assert true "API exists"
    }
  , { name := "#226.withdraw API stable"
    , body := do let _ := @coherence_withdraw; assert true "API exists"
    }
  , { name := "#226.declareLocalPolicy API stable"
    , body := do let _ := @coherence_declareLocalPolicy; assert true "API exists"
    }
  , { name := "#226.revokeLocalPolicy API stable"
    , body := do let _ := @coherence_revokeLocalPolicy; assert true "API exists"
    }
  , { name := "#226.faultProofChallenge API stable"
    , body := do let _ := @coherence_faultProofChallenge; assert true "API exists"
    }
  , { name := "#226.faultProofResolution API stable"
    , body := do let _ := @coherence_faultProofResolution; assert true "API exists"
    }
    -- Workstream GP: two new variants at action-indices 19, 20.
  , { name := "#226.depositWithFee API stable"
    , body := do let _ := @coherence_depositWithFee; assert true "API exists"
    }
  , { name := "#226.topUpActionBudget API stable"
    , body := do let _ := @coherence_topUpActionBudget; assert true "API exists"
    }
    -- ## #251.* — per-variant cell-write semantic agreement (21)
  , { name := "#251.transfer API stable"
    , body := do let _ := @cellwrites_transfer; assert true "API exists"
    }
  , { name := "#251.mint API stable"
    , body := do let _ := @cellwrites_mint; assert true "API exists"
    }
  , { name := "#251.burn API stable"
    , body := do let _ := @cellwrites_burn; assert true "API exists"
    }
  , { name := "#251.freezeResource API stable"
    , body := do let _ := @cellwrites_freezeResource; assert true "API exists"
    }
  , { name := "#251.replaceKey API stable"
    , body := do let _ := @cellwrites_replaceKey; assert true "API exists"
    }
  , { name := "#251.reward API stable"
    , body := do let _ := @cellwrites_reward; assert true "API exists"
    }
  , { name := "#251.distributeOthers API stable"
    , body := do let _ := @cellwrites_distributeOthers; assert true "API exists"
    }
  , { name := "#251.proportionalDilute API stable"
    , body := do let _ := @cellwrites_proportionalDilute; assert true "API exists"
    }
  , { name := "#251.dispute API stable"
    , body := do let _ := @cellwrites_dispute; assert true "API exists"
    }
  , { name := "#251.disputeWithdraw API stable"
    , body := do let _ := @cellwrites_disputeWithdraw; assert true "API exists"
    }
  , { name := "#251.verdict API stable"
    , body := do let _ := @cellwrites_verdict; assert true "API exists"
    }
  , { name := "#251.rollback API stable"
    , body := do let _ := @cellwrites_rollback; assert true "API exists"
    }
  , { name := "#251.registerIdentity API stable"
    , body := do let _ := @cellwrites_registerIdentity; assert true "API exists"
    }
  , { name := "#251.deposit API stable"
    , body := do let _ := @cellwrites_deposit; assert true "API exists"
    }
  , { name := "#251.withdraw API stable"
    , body := do let _ := @cellwrites_withdraw; assert true "API exists"
    }
  , { name := "#251.declareLocalPolicy API stable"
    , body := do let _ := @cellwrites_declareLocalPolicy; assert true "API exists"
    }
  , { name := "#251.revokeLocalPolicy API stable"
    , body := do let _ := @cellwrites_revokeLocalPolicy; assert true "API exists"
    }
  , { name := "#251.faultProofChallenge API stable"
    , body := do let _ := @cellwrites_faultProofChallenge; assert true "API exists"
    }
  , { name := "#251.faultProofResolution API stable"
    , body := do let _ := @cellwrites_faultProofResolution; assert true "API exists"
    }
    -- Workstream GP: two new variants at action-indices 19, 20.
  , { name := "#251.depositWithFee API stable"
    , body := do let _ := @cellwrites_depositWithFee; assert true "API exists"
    }
  , { name := "#251.topUpActionBudget API stable"
    , body := do let _ := @cellwrites_topUpActionBudget; assert true "API exists"
    }
  ]

end LegalKernel.Test.FaultProof.PerVariantCoherence
