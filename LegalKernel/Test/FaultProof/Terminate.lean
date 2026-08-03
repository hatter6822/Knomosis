-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.Test.FaultProof.Terminate — the openings-only verifier
against the sequencer's fold.

`verifierPostRootMulti` holds a pre-root and a bundle; `stepPostRoot`
holds the state.  The property that matters is that they AGREE on the
honest bundle — otherwise an honest sequencer's bundle would not
verify, which is the failure the whole workstream exists to remove —
and that the verifier refuses every dishonest one.

The negative cases are the point.  A verifier that agreed on the honest
bundle and accepted everything else would pass the first test and be
worthless: it would let a responder fold to a root of their choosing.
-/

import LegalKernel.FaultProof.CellStore
import LegalKernel.FaultProof.Terminate
import LegalKernel.Test.Framework

open LegalKernel
open LegalKernel.FaultProof
open LegalKernel.Authority
open LegalKernel.Test

namespace LegalKernel.Test.FaultProof.Terminate

/-- A populated two-resource state with a policy whose free tier
    actually admits a consume.  The same base the cross-stack
    write-bundle goldens use, for the same reason: over an empty one
    the interesting variants no-op and every check passes vacuously. -/
def base : ExtendedState :=
  let st : LegalKernel.State :=
    { balances :=
        ((∅ : Std.TreeMap ResourceId BalanceMap compare).insert 1
           ((((∅ : BalanceMap).insert 7 100).insert 8 40).insert 9 25)).insert 2
           ((∅ : BalanceMap).insert 9 60) }
  { base          := st
  , nonces        := { next := (∅ : Std.TreeMap ActorId Nonce compare).insert 7 3 }
  , registry      := (∅ : KeyRegistry).insert 7 (ByteArray.mk #[1, 2, 3])
  , bridge        := { LegalKernel.Bridge.BridgeState.empty with nextWdId := 5 }
  , epochBudgets  := (∅ : EpochBudgetState).insert 7
                       { lastSeenEpoch := 2, budgetBalance := 50 }
  , budgetPolicy  := .bounded 100 1 2 }

/-- Sign an action as actor 7. -/
def sign (a : Authority.Action) : SignedAction :=
  { action := a, signer := 7, nonce := 3, sig := ByteArray.empty }

/-- The probe set.  Every distinct SHAPE the verifier has to handle,
    not every variant: the two-cell chain and its coinciding case, the
    failing precondition, the state-keyed cell, the duplicate
    epoch-budget cell, the two-resource swap, and each of the
    action-field-derived cells. -/
def probes : List (String × Authority.Action) :=
  [ ("transfer",            .transfer 1 7 8 30)
    -- Two writes at the SAME cell: the second opening is against the
    -- root the first produced, and both must land the same value.
  , ("selfTransfer",        .transfer 1 7 7 30)
  , ("mint",                .mint 1 8 5)
  , ("burn",                .burn 1 8 5)
    -- The precondition FAILS, so `step_impl` is the identity on the
    -- balances and the fold still has to reach the published root.
  , ("burnNoop",            .burn 1 8 999999)
  , ("reward",              .reward 1 8 5)
  , ("freezeResource",      .freezeResource 1)
  , ("withdraw",            .withdraw 1 7 5 LegalKernel.Bridge.EthAddress.zero)
  , ("deposit",             .deposit 1 8 5 3)
  , ("depositWithFee",      .depositWithFee 1 8 9 5 2 3 4)
    -- The recipient IS the signer, so the epoch-budget cell appears
    -- twice in the write set.
  , ("depositWithFeeSelf",  .depositWithFee 1 7 9 5 2 3 5)
  , ("topUpActionBudget",   .topUpActionBudget 1 10 4 9)
    -- The delegated form's `recipient ≠ payer` conjunct FAILS.
  , ("topUpActionBudgetForSelf", .topUpActionBudgetFor 7 1 10 4 9)
  , ("topUpActionBudgetFor", .topUpActionBudgetFor 8 1 10 4 9)
    -- The chain runs pool-first while the write set leads with the
    -- claimant: the two orders are opposite, and a verifier that
    -- confused them computes the mirror of the law.
  , ("claimBudgetRefund",   .claimBudgetRefund 1 2 3 9)
  , ("ammSwap",             .ammSwap 1 2 5 10 9)
  , ("registerIdentity",    .registerIdentity 8 (ByteArray.mk #[1, 2, 3]))
  , ("replaceKey",          .replaceKey 8 (ByteArray.mk #[0xAA, 0xBB]))
  , ("declareLocalPolicy",  .declareLocalPolicy Authority.LocalPolicy.empty)
  , ("revokeLocalPolicy",   .revokeLocalPolicy) ]

/-- Run the verifier on the honest bundle for one probe. -/
def runProbe (a : Authority.Action) : Option StateCommit :=
  stepMultiPostRoot base (sign a) 0

/-- Tests over the honest bundle.

    The chained verifier these once drove — one opening per WRITE
    against a RUNNING root — is retired on all three stacks; the cases
    that were about the CHAIN (order is consensus, an opening goes
    stale) went with it, and the cases that are about ADJUDICATION are
    here, restated against the multiproof.  The multiproof's own
    refusals live in `multiTests` below. -/
def coreTests : List TestCase :=
  [ { name := "the verifier reaches the published post-root on every probe"
    , body := do
        -- Against the STATE, not against another verifier.  This used
        -- to compare `stepMultiPostRoot` with `stepPostRoot` — the
        -- chained fold — which made the assertion "two verifiers
        -- agree" rather than "the verifier is right".  The target is
        -- now `commitExtendedState` of the state the step produces,
        -- computed independently of anything the fold does, which is
        -- also the statement `stepMultiFold_eq_commit_post` proves.
        for (name, a) in probes do
          let st := sign a
          let expected := commitExtendedState (productionApplyBudget base st 0)
          assertEq (expected := some expected.toList)
            (actual := (runProbe a).map ByteArray.toList)
            s!"{name}: the verifier must reach the published post-root"
    }
  , { name := "every probe MOVES the root"
    , body := do
        -- Without this the agreement above would be satisfied by a
        -- verifier that returned its input: every action advances the
        -- signer's nonce, so no probe's post-root is its pre-root —
        -- including the two whose LAW no-ops.
        for (name, a) in probes do
          let got := runProbe a
          if got = some (commitExtendedState base) then
            throw <| IO.userError s!"{name}: the fold left the root alone"
    }
  , { name := "the two bulk variants are refused"
    , body := do
        -- Not an adjudication outcome: their write set is the actor set
        -- at a resource, which an L1 holding only the pre-root cannot
        -- enumerate.  A multiproof does not make it enumerable, so the
        -- exclusion is unchanged.
        for a in [Authority.Action.distributeOthers 1 7 30,
                  Authority.Action.proportionalDilute 1 7 30] do
          assertEq (expected := true)
            (actual := (stepMultiPostRoot base (sign a) 0).isNone)
            "a bulk variant must be refused"
    }
  , { name := "the verifier's cell list is the complete one"
    , body := do
        -- Deriving from the proven counter reaches exactly
        -- `writeCellsAt`, so the frontier check is a check against
        -- COMPLETENESS rather than against a weaker static
        -- declaration.
        for (name, a) in probes do
          assertEq
            (expected := (a.writeCellsAt base 7).map (fun t => t.kindIndex))
            (actual := (verifierWriteCells a 7 base.bridge.nextWdId).map
                         (fun t => t.kindIndex))
            s!"{name}: the derived cell list must be the complete one"
    }
  , { name := "the honest bundle reads back the state"
    , body := do
        -- The bridge between `bundleValueAt` — a lookup over a
        -- SUBMITTED list — and `getCellValue`, which is what every
        -- `VerifierWrites` correctness theorem is stated against.
        -- Checked value-level on every probe, and pinned as a theorem
        -- below.
        for (name, a) in probes do
          let st := sign a
          let b := stepMultiBundle base st
          for t in multiFrontierOf a 7 base.bridge.nextWdId do
            assertEq (expected := some (getCellValue base t).toList)
              (actual := (bundleValueAt b t).map ByteArray.toList)
              s!"{name}: the bundle must read back the state at every frontier cell"
    }
  , { name := "API stability: the honest bundle reads back the state"
    , body := do
        let _proof : ∀ (es : ExtendedState) (st : SignedAction) (t : CellTag),
            t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId →
            bundleValueAt (stepMultiBundle es st) t = some (getCellValue es t) :=
          fun es st t h => bundleValueAt_stepMultiBundle es st t h
        pure ()
    }
  , { name := "the honest bundle plans what the state plans"
    , body := do
        -- The reader congruence, value-level: the bundle's PARTIAL
        -- balance reader and the state's TOTAL one produce the same
        -- plan for every probe, because the cells a derivation reads
        -- are cells the frontier opens.
        for (name, a) in probes do
          let st := sign a
          let b := stepMultiBundle base st
          assertEq (expected := plannedBalances (stateBalanceReader base) a 7)
            (actual := plannedBalances (bundleBalanceReader b) a 7)
            s!"{name}: the bundle's plan must be the state's"
    }
  , { name := "the bundle reader is PARTIAL away from the frontier"
    , body := do
        -- The other half, and the one that makes the congruence's
        -- membership hypothesis load-bearing rather than decorative: a
        -- cell the frontier does not open reads back nothing, so an
        -- omitted opening cannot be passed off as a zero balance.
        let st := sign (.transfer 1 7 8 30)
        let b := stepMultiBundle base st
        assertEq (expected := none) (actual := bundleBalanceReader b 2 99)
          "an unopened balance cell must read as none, not as zero"
        assertEq (expected := some 0) (actual := stateBalanceReader base 2 99)
          "...while the state's reader defaults it, which is the difference"
    }
  , { name := "API stability: the honest bundle plans what the state plans"
    , body := do
        let _reader : ∀ (es : ExtendedState) (st : SignedAction),
            ExtendedState.CanonicalBounds es → ∀ (r : ResourceId) (a : ActorId),
            CellTag.balance r a ∈
              multiFrontierOf st.action st.signer es.bridge.nextWdId →
            bundleBalanceReader (stepMultiBundle es st) r a
              = stateBalanceReader es r a :=
          bundleBalanceReader_stepMultiBundle
        let _plan : ∀ (es : ExtendedState) (st : SignedAction),
            ExtendedState.CanonicalBounds es →
            KeyInjectiveOn (.budgetPolicy ::
              verifierWriteCells st.action st.signer es.bridge.nextWdId) →
            plannedBalances (bundleBalanceReader (stepMultiBundle es st))
                st.action st.signer
              = plannedBalances (stateBalanceReader es) st.action st.signer :=
          plannedBalances_stepMultiBundle
        pure ()
    }
  , { name := "API stability: a written cell is an opened cell"
    , body := do
        -- The membership bridge the congruence runs on, and the place
        -- the collision hypothesis actually does work: without
        -- `KeyInjectiveOn` the frontier could collapse two different
        -- cells and a write to the collapsed one would be invisible.
        let _writes : ∀ (es : ExtendedState) (st : SignedAction),
            KeyInjectiveOn (.budgetPolicy ::
              verifierWriteCells st.action st.signer es.bridge.nextWdId) →
            ∀ (t : CellTag), t ∈ st.action.writeCells st.signer →
            t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId :=
          mem_multiFrontierOf_of_writeCells
        let _policy : ∀ (es : ExtendedState) (st : SignedAction),
            KeyInjectiveOn (.budgetPolicy ::
              verifierWriteCells st.action st.signer es.bridge.nextWdId) →
            CellTag.budgetPolicy ∈
              multiFrontierOf st.action st.signer es.bridge.nextWdId :=
          budgetPolicy_mem_multiFrontierOf
        let _cf : ∀ (ts : List CellTag),
            LegalKernel.Bridge.CollisionFreeOn (ts.map cellKeyPreimage)
              LegalKernel.Runtime.hashBytes →
            (∀ t ∈ ts, t.KeyBounded) → KeyInjectiveOn ts :=
          keyInjectiveOn_of_collisionFree
        pure ()
    }
  , { name := "the derived value is the post-state's, at every frontier cell"
    , body := do
        -- The composition, value-level: for every probe and every cell
        -- the frontier opens (bar the read-only policy cell), what the
        -- verifier DERIVES from the bundle's proven pre-values is what
        -- the step actually leaves in the cell.
        for (name, a) in probes do
          let st := sign a
          let b := stepMultiBundle base st
          let post := productionApplyBudget base st 0
          match plannedBalances (stateBalanceReader base) a 7 with
          | none      => throw <| IO.userError s!"{name}: the plan aborted"
          | some plan =>
            for t in multiFrontierOf a 7 base.bridge.nextWdId do
              if t != CellTag.budgetPolicy then
                assertEq (expected := some (getCellValue post t).toList)
                  (actual := (derivedCellValue (bundleValueAt b)
                    (getCellValue base .budgetPolicy) a 7 0 plan t).map ByteArray.toList)
                  s!"{name}: the derivation must reach the post-state at {repr t}"
    }
  , { name := "API stability: the derived value is the post-state's"
    , body := do
        let _proof : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
            ExtendedState.CanonicalBounds es →
            KeyInjectiveOn (.budgetPolicy ::
              verifierWriteCells st.action st.signer es.bridge.nextWdId) →
            ∀ (t : CellTag),
            t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId →
            t ≠ .budgetPolicy →
            ∀ (plan : List ((ResourceId × ActorId) × Nat)),
            plannedBalances (stateBalanceReader es) st.action st.signer = some plan →
            derivedCellValue (bundleValueAt (stepMultiBundle es st))
                (getCellValue es .budgetPolicy) st.action st.signer idx plan t
              = some (getCellValue (productionApplyBudget es st idx) t) :=
          derivedCellValue_correct
        let _plan : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat)
            (r : ResourceId) (x : ActorId),
            CellTag.balance r x ∈ st.action.writeCells st.signer →
            ∀ (plan : List ((ResourceId × ActorId) × Nat)),
            plannedBalances (stateBalanceReader es) st.action st.signer = some plan →
            plannedBalanceAt plan r x
              = some (LegalKernel.getBalance
                  (productionApplyBudget es st idx).base r x) :=
          plannedBalanceAt_correct
        pure ()
    }
  , { name := "the honest merged fold lands on the published post-root"
    , body := do
        -- The headline, value-level: hand the verifier the PRE-state's
        -- wire and the POST-state's leaves and the single merged walk
        -- reaches `commitExtendedState` of the state the step
        -- produces.  Checked here on every probe; the theorem below is
        -- the same statement with its side conditions named.
        for (name, a) in probes do
          let st := sign a
          let ts := multiFrontierOf a 7 base.bridge.nextWdId
          let post := productionApplyBudget base st 0
          let sibs := multiSiblings smtDepth (stateCellEntries base) (openedOf base ts)
          match multiWalk smtDepth (openedOf post ts) sibs with
          | some (root, []) =>
              assertEq (expected := (commitExtendedState post).toList)
                (actual := root.toList)
                s!"{name}: the fold must land on the published post-root"
          | _ => throw <| IO.userError s!"{name}: the merged fold did not consume the wire"
    }
  , { name := "...and the same wire reproduces the PRE-root"
    , body := do
        -- One wire, two roots.  Without this the case above would be
        -- satisfied by a wire built from the post-state, which is not a
        -- wire any verifier holds.
        for (name, a) in probes do
          let ts := multiFrontierOf a 7 base.bridge.nextWdId
          let sibs := multiSiblings smtDepth (stateCellEntries base) (openedOf base ts)
          match multiWalk smtDepth (openedOf base ts) sibs with
          | some (root, []) =>
              assertEq (expected := (commitExtendedState base).toList)
                (actual := root.toList)
                s!"{name}: the same wire must reproduce the pre-root"
          | _ => throw <| IO.userError s!"{name}: the pre-side fold did not consume the wire"
    }
  , { name := "API stability: the honest merged fold lands on the post-root"
    , body := do
        let _fold : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
            FaultProofAdjudicable st.action = true →
            KeyInjectiveOn (.budgetPolicy ::
              verifierWriteCells st.action st.signer es.bridge.nextWdId) →
            WriteSetComplete es (productionApplyBudget es st idx) st.action st.signer →
            BitsDistinctBelow smtDepth (stateCellEntries es) →
            BitsDistinctBelow smtDepth
              (stateCellEntries (productionApplyBudget es st idx)) →
            (∀ t ∈ multiFrontierOf st.action st.signer es.bridge.nextWdId,
              ∀ u ∈ stateCellTags (productionApplyBudget es st idx),
              smtCellKey u = smtCellKey t → u = t) →
            multiWalk smtDepth
                (openedOf (productionApplyBudget es st idx)
                  (multiFrontierOf st.action st.signer es.bridge.nextWdId))
                (multiSiblings smtDepth (stateCellEntries es)
                  (openedOf es (multiFrontierOf st.action st.signer es.bridge.nextWdId)))
              = some (commitExtendedState (productionApplyBudget es st idx), []) :=
          stepMultiFold_eq_commit_post
        let _post : ∀ (es : ExtendedState) (st : SignedAction) (idx : Nat),
            ExtendedState.CanonicalBounds es →
            KeyInjectiveOn (.budgetPolicy ::
              verifierWriteCells st.action st.signer es.bridge.nextWdId) →
            ∀ (plan : List ((ResourceId × ActorId) × Nat)),
            plannedBalances (stateBalanceReader es) st.action st.signer = some plan →
            (multiFrontierOf st.action st.signer es.bridge.nextWdId).filterMap (fun t =>
                if t = .budgetPolicy then
                  (bundleValueAt (stepMultiBundle es st) t).map
                    (fun v => (smtCellKey t, cellLeaf t v))
                else
                  (derivedCellValue (bundleValueAt (stepMultiBundle es st))
                    (getCellValue es .budgetPolicy) st.action st.signer idx plan t).map
                    (fun v => (smtCellKey t, cellLeaf t v)))
              = openedOf (productionApplyBudget es st idx)
                  (multiFrontierOf st.action st.signer es.bridge.nextWdId) :=
          postOpened_eq_openedOf
        let _total : ∀ (es : ExtendedState) (a : Authority.Action) (signer : ActorId),
            ∃ plan, plannedBalances (stateBalanceReader es) a signer = some plan :=
          plannedBalances_stateBalanceReader_isSome
        pure ()
    }
  , { name := "API stability: the verifier's signature"
    , body := do
        let _proof : StateCommit → Authority.Action → ActorId → Nat →
            MultiBundle → Option StateCommit := verifierPostRootMulti
        pure ()
    }
  ]

/-! ## The multiproof verifier

These cases exercise what the multiproof makes newly possible and newly
refusable: an accepted permutation, a refused duplicate, a refused
short wire, a refused padding bit. -/

/-- The zero-gap wire — what `buildMultiProof` produces from no gaps
    at all.  Used by the cases the verifier refuses on the CELL SET,
    before it reads a byte of the wire, so what it carries is
    immaterial; built rather than written out so it stays whatever the
    builder produces. -/
def zeroGapWire : SmtMultiProof := buildMultiProof [] []

/-- Set bit `g` of a gap mask, LSB-first within each byte — the
    tamper the padding check exists to catch. -/
def setMaskBit (m : ByteArray) (g : Nat) : ByteArray :=
  if h : g / 8 < m.size then
    m.set (g / 8) ((m[g / 8]'h) ||| UInt8.ofNat (2 ^ (g % 8))) h
  else m

/-- The gap levels an honest bundle's wire is indexed by. -/
def probeLevels (a : Authority.Action) : List Nat :=
  multiGapLevels smtDepth
    (openedOf base (multiFrontierOf a 7 base.bridge.nextWdId))

/-- Tests for the multiproof path. -/
def multiTests : List TestCase :=
  [ { name := "the multiproof verifier reaches the sequencer's post-root"
    , body := do
        -- The equivalence that lets every downstream theorem be
        -- inherited rather than re-proved: one merged walk against the
        -- pre-root computes what the chained fold computes.
        for (name, a) in probes do
          let st := sign a
          let expected := stepPostRoot base st 0
          if expected.isNone then
            throw <| IO.userError s!"{name}: the sequencer's fold aborted"
          assertEq (expected := expected.map ByteArray.toList)
            (actual := (stepMultiPostRoot base st 0).map ByteArray.toList)
            s!"{name}: the multiproof and the chained fold disagree"
    }
  , { name := "a permuted bundle yields the same root"
    , body := do
        -- The relaxation `pathSort` bought, at the verifier.  Every
        -- opening is against the SAME root, so order carries no
        -- information — and the chained fold's
        -- `test_reordered_bundle_reverts` becomes this.
        for (name, a) in probes do
          let st := sign a
          let honest := stepMultiBundle base st
          let flipped : MultiBundle := { honest with cells := honest.cells.reverse }
          assertEq
            (expected := (stepMultiPostRoot base st 0).map ByteArray.toList)
            (actual := (verifierPostRootMulti (commitExtendedState base) a st.signer 0
                          flipped).map ByteArray.toList)
            s!"{name}: reversing the bundle changed the root"
    }
  , { name := "the multiproof refuses a forged pre-value"
    , body := do
        -- The pre-side fold is what binds the submitted values to the
        -- published root.  Without it a responder could claim any
        -- pre-value and derive a post-root of their choosing.
        for (name, a) in probes do
          let st := sign a
          let honest := stepMultiBundle base st
          let forged : MultiBundle :=
            { honest with
                cells := match honest.cells with
                         | []            => []
                         | (t, v) :: rest => (t, v ++ ByteArray.mk #[0xFF]) :: rest }
          assertEq (expected := true)
            (actual := (verifierPostRootMulti (commitExtendedState base) a st.signer 0
                          forged).isNone)
            s!"{name}: a forged pre-value was accepted"
    }
  , { name := "a wire short by one sibling is refused, not padded"
    , body := do
        -- The property the single-cell verifier does NOT have.
        -- `recomputeRootFromLeaf` substitutes a padding hash when the
        -- wire runs short and keeps walking, so a truncated proof
        -- reaches SOME root; here the sibling count is derived from
        -- the key set, so short is short.
        for (name, a) in probes do
          let st := sign a
          let honest := stepMultiBundle base st
          if honest.proof.siblings.size == 0 then
            throw <| IO.userError s!"{name}: the honest wire carries no sibling to drop"
          let short : MultiBundle :=
            { honest with
                proof := { honest.proof with siblings := honest.proof.siblings.pop } }
          assertEq (expected := true)
            (actual := (verifierPostRootMulti (commitExtendedState base) a st.signer 0
                          short).isNone)
            s!"{name}: a short wire was accepted"
    }
  , { name := "a mask bit past the last gap is refused"
    , body := do
        -- The malleability slot the exact-shape check closes: a set
        -- bit in the final byte's padding would draw a sibling the
        -- walk never consumes, so two wires would encode one proof.
        for (name, a) in probes do
          let st := sign a
          let honest := stepMultiBundle base st
          let g := (probeLevels a).length
          -- Only probes whose gap count does not fill its last byte
          -- have a padding bit to set; the others have nothing to
          -- test and are skipped rather than asserted about.
          if g % 8 != 0 then
            let tampered : MultiBundle :=
              { honest with
                  proof := { honest.proof with gapMask := setMaskBit honest.proof.gapMask g } }
            assertEq (expected := true)
              (actual := (verifierPostRootMulti (commitExtendedState base) a st.signer 0
                            tampered).isNone)
              s!"{name}: a set padding bit was accepted"
    }
  , { name := "the multiproof wire is smaller than the chained openings"
    , body := do
        -- The calldata claim, measured rather than asserted.  The
        -- chained fold carries one 32-byte bitmask plus siblings per
        -- WRITE, and a separate policy opening; the multiproof carries
        -- one mask plus the siblings the merges did not absorb.
        --
        -- Over this probe set the total is 13 312 -> 3 596 bytes
        -- (-73%), which is MUCH better than the -9.9% the plan
        -- estimated, and the reason is worth stating because it does
        -- not generalise.  The masks are a wash at any density: the
        -- chained path pays 32 bytes per opening and the multiproof
        -- pays `ceil(G/8)`, and `G ~ 255m` for keys that diverge near
        -- the root, so both are ~32m.  The whole difference is
        -- SIBLINGS, and on a sparse state the opened cells are most of
        -- the live ones, so nearly every chained sibling is another
        -- opened cell's sub-tree -- exactly what a merge absorbs.  At
        -- production density (~1e6 live cells) the paths' non-empty
        -- siblings are mostly distinct and the saving falls back
        -- toward the estimate.  The assertion is `<`, not a ratio, so
        -- it stays true either way.
        for (name, a) in probes do
          let st := sign a
          -- The retired shape, reconstructed from the surviving
          -- honest-sequencer bundle: one 32-byte bitmask plus siblings
          -- per WRITE, and a separate opening for the read-only policy
          -- cell.  Rebuilt rather than measured through the old
          -- helpers, which went with the verifier that consumed them.
          let chained :=
            (stepWriteBundle base st 0).foldl
              (fun acc w => acc + w.2.2.2.toWireBytes.size)
              (buildStateCellProof base .budgetPolicy).toWireBytes.size
          let multi := (stepMultiBundle base st).proof.toWireBytes.size
          assertEq (expected := true) (actual := multi < chained)
            s!"{name}: multiproof {multi} bytes vs chained {chained}"
    }
  , { name := "the frontier includes the policy cell"
    , body := do
        -- Under the chained fold the read-only budget policy needed its
        -- own opening and its own 256-level walk, because it is a read
        -- among writes.  Here a read is a write of the same value, so
        -- it is one more cell in the frontier and one fewer walk.
        let f := multiFrontierOf (.transfer 1 7 8 30) 7 0
        assertEq (expected := true)
          (actual := f.any (fun t => smtCellKey t == smtCellKey .budgetPolicy))
          "the policy cell is in the frontier"
        assertEq (expected := true) (actual := pathSorted f)
          "and the frontier is still strictly sorted"
    }
  , { name := "a cell's pre-value is read by cell, not by occurrence"
    , body := do
        -- `preStateValueAt`'s first-occurrence rule existed because a
        -- later write's opening was against the RUNNING state.  With
        -- one opening per cell there is nothing to disambiguate, and
        -- the lookup says so directly.
        let b : MultiBundle :=
          { cells := [(.nonce 7, natCellValue 3), (.budgetPolicy, ByteArray.empty)]
          , proof := zeroGapWire }
        assertEq (expected := some (natCellValue 3).toList)
          (actual := (bundleValueAt b (.nonce 7)).map ByteArray.toList)
          "the opened cell reads back"
        assertEq (expected := (none : Option (List UInt8)))
          (actual := (bundleValueAt b (.nonce 8)).map ByteArray.toList)
          "an unopened cell reads nothing, rather than a default"
    }
  , { name := "a non-adjudicable action is refused before any work"
    , body := do
        let b : MultiBundle := { cells := [], proof := zeroGapWire }
        assertEq (expected := true)
          (actual := (verifierPostRootMulti (ByteArray.mk #[]) 
                        (.distributeOthers 1 7 30) 7 0 b).isNone)
          "distributeOthers is refused"
        assertEq (expected := true)
          (actual := (verifierPostRootMulti (ByteArray.mk #[])
                        (.proportionalDilute 1 7 30) 7 0 b).isNone)
          "proportionalDilute is refused"
    }
  , { name := "a bundle whose cells are not the step's is refused"
    , body := do
        -- The shape check, at the verifier rather than in isolation.
        -- Order is free; content is not.
        let b : MultiBundle := { cells := [(.nonce 7, natCellValue 3)], proof := zeroGapWire }
        assertEq (expected := true)
          (actual := (verifierPostRootMulti (ByteArray.mk #[])
                        (.transfer 1 7 8 30) 7 0 b).isNone)
          "a bundle missing the balance and policy cells is refused"
    }
  ]

/-- Tests. -/
def tests : List TestCase := coreTests ++ multiTests

end LegalKernel.Test.FaultProof.Terminate
