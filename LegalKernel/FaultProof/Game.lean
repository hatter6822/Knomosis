-- SPDX-License-Identifier: GPL-3.0-or-later
/-
  Knomosis  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Knomosis/blob/main/LICENSE
-/

/-
LegalKernel.FaultProof.Game — bisection game data types + state
machine (Workstream H §12 / WUs H.4.1 + H.4.2 + H.4.3).

Formalises the interactive fault-proof game as a state machine
with explicit turn-based transitions.  The Lean side is the
*reference implementation*; the Solidity side
(`solidity/src/contracts/KnomosisFaultProofGame.sol`) ports it
line-for-line under cross-stack equivalence testing.

**Key design correction over v1.**  v1's `BisectionRound` carried
both `claimantMidpoint` and `challengerMidpoint` per round, which
suggested both parties submit midpoints simultaneously.  In the
standard interactive-proof game, **each round has exactly one
midpoint claim** from the responding party; the opposing party
either accepts (collapsing the range to the second half) or
rejects (collapsing to the first half).  v2 implements the
correct shape.

This module is **not** part of the trusted computing base.  Bugs
here would weaken the L1 fault-proof game's correctness but
cannot violate any kernel invariant.
-/

import LegalKernel.Disputes.Types
import LegalKernel.FaultProof.ActionsRoot
import LegalKernel.FaultProof.Step

namespace LegalKernel
namespace FaultProof

open LegalKernel.Authority
open LegalKernel.Disputes
-- `Encodable.decode`: the registry cell's value is a CBE byte string
-- and the nonce cell's a CBE uint, so the F-A gate reads them back
-- through the same codec `CellValue` writes them with.
open LegalKernel.Encoding

/-! ## DoS bounds (Workstream H §2) -/

/-- Maximum bisection depth (per §2 of the workstream plan):
    `MAX_BISECTION_DEPTH = 64`.  Caps the worst-case L1 game
    length at `2 × 64 + ε` transactions per dispute.  Covers log
    lengths up to `2^64`, essentially unbounded. -/
def MAX_BISECTION_DEPTH : Nat := 64

/-! ## Game data types (§12.4.1 / WU H.4.1) -/

/-- A state-root assertion: at log index `idx`, the state root
    is `commit`.  The bisection game's range and midpoint
    submissions all consume this type. -/
structure Claim where
  /-- The log index this claim covers. -/
  idx    : LogIndex
  /-- The claimed state-root commit at `idx`. -/
  commit : StateCommit
  deriving Repr

/-- The disputed range at any point in the game.  Both parties
    have agreed on the commits at `low` and `high` (the
    disagreement was already at the previous level); they
    disagree about the commit at the midpoint.

    `low.idx < high.idx`; equality means the bisection has
    narrowed to a single step. -/
structure DisputedRange where
  /-- The lower bound (both parties agree on this commit). -/
  low    : Claim
  /-- The upper bound (parties may disagree on this commit;
      the upper bound's claim is what the bisection is trying
      to falsify). -/
  high   : Claim
  deriving Repr

/-- Whose turn it is to act in the current round. -/
inductive TurnSide
  /-- The sequencer's turn. -/
  | sequencer
  /-- The challenger's turn. -/
  | challenger
  deriving Repr, DecidableEq

/-- The terminal status of a fault-proof game. -/
inductive GameStatus
  /-- The game is still in progress. -/
  | inProgress
  /-- The challenger lost; bonds redistribute to the sequencer. -/
  | sequencerWon
  /-- The sequencer lost; bonds redistribute to the challenger. -/
  | challengerWon
  /-- The unresponsive party (the loser) timed out. -/
  | timedOutSequencer
  /-- The challenger timed out. -/
  | timedOutChallenger
  deriving Repr, DecidableEq

/-! ## `GameState` (§12.4.1) -/

/-- The bisection game's state.  Bisection proceeds as a
    succession of midpoint submissions and accept/reject
    responses; each round halves the dispute range.  The L1
    contract stores this state per game in a Solidity mapping;
    the Lean side specifies the canonical shape. -/
structure GameState where
  /-- The sequencer's identity. -/
  sequencer       : ActorId
  /-- The challenger's identity. -/
  challenger      : ActorId
  /-- The current disputed range. -/
  range           : DisputedRange
  /-- The midpoint commit submitted in the current round (if
      any).  When `none`, the responding party owes a midpoint
      submission; when `some _`, the opposing party owes an
      accept/reject response. -/
  pendingMidpoint : Option Claim
  /-- The bisection depth so far.  Capped at
      `MAX_BISECTION_DEPTH = 64` by the legality predicate. -/
  depth           : Nat
  /-- Whose turn it is. -/
  turn            : TurnSide
  /-- The sequencer's bond (in deployment-supplied units; ETH
      wei on L1).  Slashed in full to the challenger if the
      sequencer loses. -/
  sequencerBond   : Nat
  /-- The challenger's bond.  Slashed in full to the sequencer
      if the challenger loses. -/
  challengerBond  : Nat
  /-- Game status. -/
  status          : GameStatus
  /-- The deployment-id binding the game to a specific Knomosis
      deployment.  Prevents cross-deployment replay of game
      transcripts. -/
  deploymentId    : ByteArray
  /-- The disputed batch's ACTIONS ROOT (Workstream SB ruling R7):
      the SMT root over the batch's per-action signature-bound leaf
      commitments, fixed when the game opens.  On L1 the game reads
      it from `roots[disputedLogIndex].actionsRoot` at terminate
      time, and the record is immutable at its key while a game is
      open (`markDisputed` blocks reclaim, so the R3 overwrite path
      cannot fire) — so an immutable per-game field is the faithful
      model.  The `terminateOnSingleStep` arm gates on it: the
      responder's action must OPEN at the disputed index against
      this root, which is what stops a losing party from settling on
      an action the batch never committed (the audit-22 model-chain-
      binding MAJOR). -/
  actionsRoot     : ByteArray
  deriving Repr

/-! ## Game transitions (§12.4.2 / WU H.4.2) -/

/-- The legal transitions from one game state to the next.

    **Adjudication reads on-chain data, never a caller
    parameter.**  Both non-trivial transitions take strictly less
    from the caller than the state machine needs and derive the
    rest from `gs`, mirroring the L1 contract:

    * `submitMidpoint` carries only a *commit*.  The index is
      `gs.range.midpointIdx`, computed here exactly as
      `KnomosisFaultProofGame.submitMidpoint` computes
      `mpIdx = (g.low.idx + g.high.idx) / 2`.  Taking the index
      from the caller — as this did — let a party narrow by a
      single step per round, which is why
      `bisection_converges_after_enough_rounds` could only prove
      *linear* narrowing.  With the midpoint canonical the bound
      is logarithmic (`bisection_converges_in_log_rounds`).

    * `terminateOnSingleStep` carries only the step.  There is no
      `claimedPostCommit`: the disputed endpoint is
      `gs.range.high.commit` and the pre-state is
      `gs.range.low.commit`, both already fixed in the game
      state.  Taking the claim from the caller made the
      transition vacuous — the responder supplied both the claim
      and the `KernelStep` whose `postStateCommit` the old
      `kernelStepApply` echoed back, so the responder always won.
      This mirrors the 5-argument
      `KnomosisFaultProofGame.terminateOnSingleStep`, which
      passes `g.low.commit` to the step VM and tests the result
      against `g.high.commit`. -/
inductive GameTransition
  /-- The party whose turn it is submits the commit it claims for
      the canonical midpoint index of the current range. -/
  | submitMidpoint (midpointCommit : StateCommit)
  /-- The opposing party agrees with the pending midpoint;
      range narrows to `[mid.idx, high.idx]`. -/
  | respondAgree
  /-- The opposing party disagrees; range narrows to
      `[low.idx, mid.idx]`. -/
  | respondDisagree
  /-- When range is single-step, terminate by executing.  The
      step VM re-executes from the committed pre-state and its
      output is compared against the committed disputed
      endpoint.

      `actionProof` is the disputed action's INCLUSION PROOF against
      the game's anchored `actionsRoot` (Workstream SB ruling R7):
      the responder must show that the `(kind, signer, fields,
      65-byte sig)` spelling it is executing is the one the batch
      committed at `gs.range.low.idx`.  Mirrors the L1's
      `_requireActionInBatch`; without it the arm adjudicated an
      unauthenticated, caller-supplied action (the audit-22
      MAJOR).

      `registryValue` / `registryProof` are the signer's REGISTRY
      CELL at the pre-state and its single-cell opening against
      `gs.range.low.commit` (Workstream F-A).  Inclusion answers "is
      this the action the batch committed?"; it says nothing about
      whether the action was AUTHORISED, and the step VM cannot
      evaluate the signature scheme — so without this the arm
      adjudicates actions nobody signed.  An ABSENT cell (empty
      value) is the unregistered signer: a real adjudicable state,
      not a malformed call.  Mirrors the L1's `registryValue` /
      `registryProof` calldata. -/
  | terminateOnSingleStep
      (kernelStep : KernelStep) (actionProof : SmtCellProof)
      (registryValue : ByteArray) (registryProof : SmtCellProof)
  /-- A party times out (BISECTION_RESPONSE_TIMEOUT exceeded).
      The loser is *derived* from `gs.turn` at apply-time: the
      party whose turn it is when the deadline elapses is the
      one who failed to respond.  Mirrors Solidity's
      `claimTimeout` semantics (anyone can call; the loser is
      always the current turn-holder).

      Taking the loser as a parameter would be a Lean-side
      semantic mismatch with the Solidity implementation: an
      adversarial transition could specify the wrong loser. -/
  | timeoutLoss
  deriving Repr

/-- Errors `applyTransition` can produce.  Each variant maps
    to a precise revert reason in the L1 game contract. -/
inductive GameError
  /-- The game has already ended. -/
  | gameAlreadyEnded
  /-- Wrong turn (the caller is not the responding party). -/
  | wrongTurn
  /-- The submitted midpoint is outside the disputed range. -/
  | midpointOutOfRange
  /-- A midpoint is already pending; cannot submit another
      until the opposing party responds. -/
  | midpointDuringResponse
  /-- No midpoint pending; cannot accept/reject. -/
  | responseDuringSubmit
  /-- The bisection depth cap has been exceeded. -/
  | bisectionDepthExceeded
  /-- The range is not single-step yet; bisect more first. -/
  | rangeNotSingleStep
  /-- Termination attempted during an active bisection. -/
  | terminationDuringBisection
  /-- The terminate's action does not open at the disputed index
      against the game's anchored actions root (or its signature is
      not the fixed 65-byte secp256k1 wire width).  Mirrors the L1's
      `ActionNotInBatch` / `ActionSigWrongLength` reverts: the
      responder may retry within its turn window with the committed
      action, and loses by timeout if it never can. -/
  | actionNotInBatch
  /-- The supplied registry opening does not verify against the
      disputed range's pre-state root (Workstream F-A).  Mirrors the
      L1's `RegistryOpeningInvalid` revert: the TRUE opening exists
      for both a present and an absent registry cell, so this is a
      calldata defect the responsible party retries within its turn
      window — not a verdict.  Distinguished from a failing
      SIGNATURE, which IS a verdict (the entry was inadmissible, so
      its truthful post-state is the pre-state). -/
  | registryOpeningInvalid
  deriving Repr, DecidableEq

/-! ## State-machine semantics -/

/-- The canonical midpoint of a disputed range.  Floor-divides
    to the lower half on odd-length ranges. -/
def DisputedRange.midpointIdx (r : DisputedRange) : LogIndex :=
  (r.low.idx + r.high.idx) / 2

/-- True iff the range is single-step (`high.idx = low.idx + 1`).
    When this holds, no further bisection is possible; the
    responding party must call `terminateOnSingleStep`. -/
def DisputedRange.isSingleStep (r : DisputedRange) : Prop :=
  r.high.idx = r.low.idx + 1

/-- Decidability of `isSingleStep`.  Reduces to `Nat`-equality. -/
instance instDecidableIsSingleStep (r : DisputedRange) :
    Decidable r.isSingleStep := by
  unfold DisputedRange.isSingleStep
  exact inferInstance

/-- The next turn after the current one.  Used by
    `applyTransition` to flip between sequencer / challenger. -/
def TurnSide.flip : TurnSide → TurnSide
  | .sequencer  => .challenger
  | .challenger => .sequencer

/-! ## The signature gate (Workstream F-A)

The L1's terminal step verifies the disputed action's committed
signature before adjudicating it.  These are the model's three
ingredients: the registered key read out of the opened registry
cell, the nonce read out of the step's own frontier, and the
verdict. -/

/-- Decode a registry cell's value to the public key it holds.

    The cell value is a CBE byte string (`getCellValue`'s registry
    arm), and the canonical ABSENT value is the EMPTY byte array —
    which is why an absent cell decodes to `none` rather than to an
    empty key: a signer with no registered key cannot have authorised
    anything, while a signer registered with the (legal) empty key is
    a different state the encoding keeps distinguishable. -/
def registryCellKey (value : ByteArray) : Option PublicKey :=
  if value.size = 0 then none  -- canonically absent ⇒ unregistered
  else
    match Encodable.decode (T := ByteArray) value.data.toList with
    | .ok (pk, _) => some pk
    | .error _    => none

/-- The signer's nonce, read from the step's own opening frontier.

    The L1 reads it from the `opened` array the step VM has ALREADY
    verified against the pre-root, so the digest is over the
    pre-state's expected nonce — the only value the L2 admission gate
    would have accepted a signature for.  Reading it from the bundle
    is the faithful mirror: a responder cannot sign over a nonce of
    its choosing, because the bundle's nonce cell is root-checked by
    `kernelStepApply`. -/
def frontierNonce (b : MultiBundle) (signer : ActorId) : Option Nonce :=
  match bundleValueAt b (.nonce signer) with
  | some v =>
    match Encodable.decode (T := Nat) v.data.toList with
    | .ok (n, _) => some n
    | .error _   => none
  | none => none

/-- **The F-A verdict.**  True iff the disputed action's committed
    signature verifies under the signer's REGISTERED key over the
    canonical §8.8.5 sign-input.

    Everything uninterpretable is `false` rather than an error: an
    unregistered signer, a malformed registry payload, a frontier
    without a readable nonce cell.  Each is a state of the world the
    game must ADJUDICATE (the entry was inadmissible), not a calldata
    defect — the one calldata defect is the registry OPENING failing
    to verify, which the caller checks separately.

    Parameterised in `verify` exactly as `AdmissibleWith` is: the
    production instance is `Authority.Verify` (opaque, `@[extern]`-
    routed to the linked adaptor), and a test drives the honest path
    with a mock. -/
def signatureAdmissible
    (verify : PublicKey → ByteArray → Signature → Bool)
    (deploymentId : ByteArray) (step : KernelStep)
    (registryValue : ByteArray) : Bool :=
  match registryCellKey registryValue with
  | none => false
  | some pk =>
    match frontierNonce step.bundle step.signedAction.signer with
    | none => false
    | some nonce =>
      verify pk
        (Authority.signingInput step.signedAction.action
          step.signedAction.signer nonce deploymentId)
        step.signedAction.sig

/-- Apply a transition.  Returns the new game state if the
    transition is legal, an error otherwise.  Total function;
    decidable.

    Parameterised in the signature verifier (Workstream F-A).
    `applyTransition` below is this at `Authority.Verify`, the
    production instance — the same `…With`-plus-instance shape
    `Authority.AdmissibleWith` / `Admissible` already use, so every
    existing call site and theorem about the bisection transitions
    reads unchanged while a test can drive the honest signature path
    with a mock. -/
def applyTransitionWith
    (verify : PublicKey → ByteArray → Signature → Bool)
    (gs : GameState) :
    GameTransition → Except GameError GameState
  -- Submit a midpoint.  Legal only when:
  --   * Game is in progress.
  --   * No midpoint already pending.
  --   * Bisection depth hasn't exceeded the cap.
  --   * The midpoint's idx is strictly between low.idx and high.idx
  --     (i.e. the range is at least 2 steps wide).
  | .submitMidpoint midpointCommit =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else if gs.pendingMidpoint.isSome then .error .midpointDuringResponse
    else if gs.depth ≥ MAX_BISECTION_DEPTH then
      .error .bisectionDepthExceeded
    else if gs.range.midpointIdx ≤ gs.range.low.idx
            ∨ gs.range.high.idx ≤ gs.range.midpointIdx then
      -- The index is DERIVED, not supplied.  `KnomosisFaultProofGame`
      -- computes the same value and applies the same guard; the only
      -- way it can fire is a degenerate range (width ≤ 1), which is
      -- what forces `terminateOnSingleStep` instead.
      .error .midpointOutOfRange
    else
      .ok { gs with
              pendingMidpoint :=
                some { idx := gs.range.midpointIdx, commit := midpointCommit },
              turn := gs.turn.flip }

  -- Respond by agreeing.  Range narrows to [mid.idx, high.idx].
  -- The post-response depth (`gs.depth + 1`) must not exceed
  -- `MAX_BISECTION_DEPTH`.  Mirrors Solidity's
  -- `respondToMidpoint` post-increment cap check.
  | .respondAgree =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else if gs.depth ≥ MAX_BISECTION_DEPTH then
      .error .bisectionDepthExceeded
    else
      match gs.pendingMidpoint with
      | none    => .error .responseDuringSubmit
      | some mp =>
        .ok { gs with
                range := { low := mp, high := gs.range.high },
                pendingMidpoint := none,
                depth := gs.depth + 1,
                turn := gs.turn.flip }

  -- Respond by disagreeing.  Range narrows to [low.idx, mid.idx].
  -- Same depth-cap discipline as `respondAgree`.
  | .respondDisagree =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else if gs.depth ≥ MAX_BISECTION_DEPTH then
      .error .bisectionDepthExceeded
    else
      match gs.pendingMidpoint with
      | none    => .error .responseDuringSubmit
      | some mp =>
        .ok { gs with
                range := { low := gs.range.low, high := mp },
                pendingMidpoint := none,
                depth := gs.depth + 1,
                turn := gs.turn.flip }

  -- Single-step termination.  The step VM re-executes the disputed
  -- step from the COMMITTED pre-state and its output is compared
  -- against the COMMITTED disputed endpoint.  Neither side of that
  -- comparison comes from the caller.
  | .terminateOnSingleStep step actionProof registryValue registryProof =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else if !gs.range.isSingleStep then
      .error .rangeNotSingleStep
    else if gs.pendingMidpoint.isSome then
      -- Mirrors `MidpointAlreadyPending` on L1: a bisection round is
      -- open, so the range is not settled enough to terminate on.
      -- This error existed but was unreachable.
      .error .terminationDuringBisection
    else if step.signedAction.sig.size ≠ 65
            ∨ verifyActionProof gs.actionsRoot gs.range.low.idx
                (actionLeafValue step.signedAction) actionProof ≠ true then
      -- AUTHENTICATE BEFORE EXECUTING (Workstream SB ruling R7,
      -- mirroring the L1's `_requireActionInBatch` order): the
      -- disputed action sits at absolute log index `gs.range.low.idx`
      -- (the single step carries state `low.idx` to `low.idx + 1`),
      -- and its signature-bound leaf must open there against the
      -- game's anchored actions root.  The 65-byte width check
      -- mirrors `ActionsRoot.actionLeafCommit`'s
      -- `ActionSigWrongLength` revert and is what keeps the packed
      -- leaf pre-image's split unambiguous
      -- (`actionLeafPreimage_inj`).  An unauthenticated action
      -- REVERTS on L1 — no state change, the responder may retry —
      -- so it is an `.error` here, not a loss.
      .error .actionNotInBatch
    else if step.preStateCommit ≠ gs.range.low.commit
            ∨ step.l2LogIndex ≠ gs.range.high.idx then
      -- On L1 neither disjunct can arise: the contract passes
      -- `g.low.commit` and `g.high.idx` to the step VM itself.  In
      -- the Lean model both travel inside the `KernelStep`, so the
      -- mismatches must be rejected explicitly — otherwise a party
      -- could re-execute the disputed step from a pre-state of its
      -- own choosing (or at a log index of its own choosing, which
      -- `withdraw`'s state-keyed pending cell reads) and produce
      -- whatever post-commit it needed.
      .ok { gs with
              status :=
                match gs.turn with
                | .sequencer  => .challengerWon
                | .challenger => .sequencerWon }
    else if verifyStateCellProof gs.range.low.commit
              (.registry step.signedAction.signer)
              registryValue registryProof ≠ true then
      -- F-A: the registry opening must speak about the disputed
      -- range's PRE-state.  The true opening exists for both a
      -- present and an absent cell, so a failing one is a calldata
      -- defect the responder retries — mirroring the L1's
      -- `RegistryOpeningInvalid` revert, which leaves the game open.
      .error .registryOpeningInvalid
    else
      match kernelStepApply step with
      | none =>
        -- Cell-proof verification failed; the responding party loses.
        .ok { gs with
                status :=
                  match gs.turn with
                  | .sequencer  => .challengerWon
                  | .challenger => .sequencerWon }
      | some vmPostCommit =>
        -- F-A: an entry whose signature does not verify under the
        -- signer's REGISTERED key was inadmissible on the L2, so its
        -- truthful post-state is the PRE-state.  The adjudicated root
        -- is therefore `low.commit` — the full no-op, nonce included
        -- — rather than the step VM's output.  That is what makes a
        -- fabricated endpoint indefensible without also making an
        -- honest no-op endpoint unwinnable.
        let computedPostCommit :=
          if signatureAdmissible verify gs.deploymentId step registryValue then
            vmPostCommit
          else
            gs.range.low.commit
        if computedPostCommit = gs.range.high.commit then
          -- The step VM reproduces the committed endpoint, so the
          -- responding party's position is upheld; they win.
          .ok { gs with
                  status :=
                    match gs.turn with
                    | .sequencer  => .sequencerWon
                    | .challenger => .challengerWon }
        else
          -- Mismatch; responding party loses.
          .ok { gs with
                  status :=
                    match gs.turn with
                    | .sequencer  => .challengerWon
                    | .challenger => .sequencerWon }

  -- Timeout.  The unresponsive party loses — derived from
  -- `gs.turn` at apply-time (the current turn-holder is the one
  -- who failed to respond).  Mirrors Solidity's `claimTimeout`
  -- semantics.
  | .timeoutLoss =>
    if gs.status ≠ .inProgress then .error .gameAlreadyEnded
    else
      .ok { gs with
              status :=
                match gs.turn with
                | .sequencer  => .timedOutSequencer
                | .challenger => .timedOutChallenger }

/-- The production transition semantics: `applyTransitionWith` at
    the deployment-supplied verifier.

    `Authority.Verify` is `opaque` and `@[extern]`-routed to the
    linked adaptor, so this is the compiled runtime's behaviour; the
    Lean-level value stays uninterpreted, which is why every theorem
    that reasons about the signature gate is stated over
    `applyTransitionWith verify` and instantiated here. -/
abbrev applyTransition : GameState → GameTransition → Except GameError GameState :=
  applyTransitionWith Authority.Verify

/-! ## Decidability + determinism -/

/-- `applyTransition` is deterministic: equal inputs produce
    equal outputs.  Mechanical via `rfl`. -/
theorem applyTransition_deterministic
    (gs₁ gs₂ : GameState) (t₁ t₂ : GameTransition)
    (h_gs : gs₁ = gs₂) (h_t : t₁ = t₂) :
    applyTransition gs₁ t₁ = applyTransition gs₂ t₂ := by
  rw [h_gs, h_t]

/-! ## Game well-formedness (§12.4.6 / WU H.4.6) -/

/-- Helper: the pending-midpoint constraint as a decidable
    predicate.  `none` is vacuously well-formed; `some mp`
    requires the midpoint to lie strictly inside the range. -/
def pendingMidpointInRange (gs : GameState) : Prop :=
  match gs.pendingMidpoint with
  | none    => True
  | some mp => gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx

/-- Decidability of `pendingMidpointInRange`.  Case-split on the
    `Option` constructor; each branch is decidable. -/
instance instDecidablePendingMidpointInRange (gs : GameState) :
    Decidable (pendingMidpointInRange gs) := by
  unfold pendingMidpointInRange
  cases gs.pendingMidpoint <;> exact inferInstance

/-! ## Turn–pending alignment (Workstream SB)

The L1 contract's terminate obligation lands on the SEQUENCER in
every reachable game, and the property is EMERGENT there: a game
opens `(turn = sequencer, pending = none)`, `submitMidpoint` is the
only writer of a pending midpoint and flips the turn, and
`respondToMidpoint` is the only clearer and flips it back — so the
reachable set of `(turn, pendingMidpoint.isSome)` is exactly
`{(sequencer, false), (challenger, true)}` and the challenger's only
obligation, ever, is a response.  Nothing pinned that: no contract
test asserted it, no Lean theorem stated it, and the model has no
actor gate at all (`wrongTurn` is declared and never emitted), so a
future transition flipping the turn an odd number of times would
silently hand the challenger a terminate obligation it cannot always
meet.  These lemmas are the pin: the alignment is an invariant of
`applyTransition`, and `Settlement.honest_challenger_wins_of_turn_aligned`
consumes it in place of a bare turn hypothesis. -/

/-- Turn–pending alignment: no midpoint is pending exactly when it
    is the sequencer's turn.  The `↔` (not a one-way implication) is
    what the preservation induction needs — the respond arms consume
    the `some → challenger` direction. -/
def turnAlignedWithPending (gs : GameState) : Prop :=
  gs.pendingMidpoint = none ↔ gs.turn = .sequencer

instance instDecidableTurnAlignedWithPending (gs : GameState) :
    Decidable (turnAlignedWithPending gs) := by
  unfold turnAlignedWithPending
  have : Decidable (gs.pendingMidpoint = none) :=
    decidable_of_iff (gs.pendingMidpoint.isNone = true)
      Option.isNone_iff_eq_none
  exact inferInstance

/-- Alignment holds at the L1 starting state: `initiateChallenge`
    opens every game with the sequencer to move and nothing
    pending. -/
theorem turn_aligned_of_start (gs : GameState)
    (h_p : gs.pendingMidpoint = none) (h_t : gs.turn = .sequencer) :
    turnAlignedWithPending gs :=
  ⟨fun _ => h_t, fun _ => h_p⟩

/-- **Alignment is preserved by every legal transition.**  The
    submit arm installs a midpoint and flips sequencer→challenger;
    the respond arms clear it and flip back; the terminal arms touch
    neither field.  With `turn_aligned_of_start` this makes the
    alignment an invariant of every L1-reachable game. -/
theorem turn_aligned_preserved {gs gs' : GameState}
    {t : GameTransition}
    (h : applyTransition gs t = .ok gs')
    (h_inv : turnAlignedWithPending gs) :
    turnAlignedWithPending gs' := by
  cases t with
  | submitMidpoint c =>
    cases hpm : gs.pendingMidpoint with
    | some mp =>
      -- A pending midpoint makes every submit arm an error.
      simp only [applyTransitionWith, hpm, Option.isSome_some, if_true] at h
      split at h
      · exact absurd h (by simp)
      · exact absurd h (by simp)
    | none =>
      -- The guard passed, so alignment gives `turn = sequencer`;
      -- the update installs `some` and flips to the challenger.
      have ht : gs.turn = .sequencer := h_inv.mp hpm
      simp only [applyTransitionWith, hpm, Option.isSome_none,
                 Bool.false_eq_true, if_false] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · split at h
          · exact absurd h (by simp)
          · injection h with h_gs
            subst h_gs
            unfold turnAlignedWithPending
            simp [ht, TurnSide.flip]
  | respondAgree =>
    cases hpm : gs.pendingMidpoint with
    | none =>
      -- Nothing pending: every respond arm is an error.
      simp only [applyTransitionWith, hpm] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · exact absurd h (by simp)
    | some mp =>
      -- A pending midpoint forces the challenger's turn (the `mpr`
      -- direction of the alignment); the update clears it and
      -- flips back to the sequencer.
      have ht : gs.turn = .challenger := by
        cases h_t : gs.turn with
        | sequencer => exact absurd (h_inv.mpr h_t) (by simp [hpm])
        | challenger => rfl
      simp only [applyTransitionWith, hpm] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · injection h with h_gs
          subst h_gs
          unfold turnAlignedWithPending
          simp [ht, TurnSide.flip]
  | respondDisagree =>
    cases hpm : gs.pendingMidpoint with
    | none =>
      simp only [applyTransitionWith, hpm] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · exact absurd h (by simp)
    | some mp =>
      have ht : gs.turn = .challenger := by
        cases h_t : gs.turn with
        | sequencer => exact absurd (h_inv.mpr h_t) (by simp [hpm])
        | challenger => rfl
      simp only [applyTransitionWith, hpm] at h
      split at h
      · exact absurd h (by simp)
      · split at h
        · exact absurd h (by simp)
        · injection h with h_gs
          subst h_gs
          unfold turnAlignedWithPending
          simp [ht, TurnSide.flip]
  | terminateOnSingleStep step actionProof =>
    -- Every terminal arm is `{ gs with status := … }`: the pending
    -- midpoint and the turn both survive unchanged, so the record
    -- projections the invariant reads are definitionally `gs`'s.
    -- The authentication guard (Workstream SB) only ADDS an error
    -- branch, which the `absurd` leg absorbs.
    simp only [applyTransitionWith] at h
    repeat' split at h
    all_goals
      first
        | (injection h with h_gs; subst h_gs; exact h_inv)
        | exact absurd h (by simp)
  | timeoutLoss =>
    simp only [applyTransitionWith] at h
    repeat' split at h
    all_goals
      first
        | (injection h with h_gs; subst h_gs; exact h_inv)
        | exact absurd h (by simp)

/-- The terminate obligation is the sequencer's: on any aligned game
    with no pending midpoint — the only shape
    `terminateOnSingleStep` accepts — the turn is the sequencer's.
    The Lean pin of the L1 parity argument. -/
theorem terminate_owner_is_sequencer {gs : GameState}
    (h_inv : turnAlignedWithPending gs)
    (h_p : gs.pendingMidpoint = none) :
    gs.turn = .sequencer :=
  h_inv.mp h_p

/-- Well-formedness predicate for a game state.  A game is
    well-formed iff:
      * The disputed range has `low.idx < high.idx` (else the
        bisection is degenerate).
      * The depth has not exceeded the cap.
      * If a midpoint is pending, its idx is strictly within
        the range (`pendingMidpointInRange`).
      * If the game is in progress, the bond pool is positive
        (else there's nothing to redistribute on settlement).

    `→` is encoded as `¬ inProgress ∨ bondPool > 0` so the
    conjunction is decidable via `inferInstance` without
    requiring `Classical.propDecidable`. -/
def gameWellFormed (gs : GameState) : Prop :=
  gs.range.low.idx < gs.range.high.idx ∧
  gs.depth ≤ MAX_BISECTION_DEPTH ∧
  pendingMidpointInRange gs ∧
  (gs.status ≠ .inProgress ∨
    gs.sequencerBond + gs.challengerBond > 0)

/-- Decidability of `gameWellFormed`.  Each conjunct is
    decidable; the conjunction is decidable via
    `inferInstance`. -/
instance instDecidableGameWellFormed (gs : GameState) :
    Decidable (gameWellFormed gs) := by
  unfold gameWellFormed
  exact inferInstance

/-! ## Bisection convergence (§12.4.3 / WU H.4.3) -/

/-- The post-state of a successful `respondAgree` has the
    midpoint as its new low bound and the original high as its
    new high bound.  This is the structural shape lemma the
    range-narrowing lemma depends on.

    Successful applies imply `gs.depth < MAX_BISECTION_DEPTH`
    (the depth-cap gate); the proof derives this from the
    successful-apply hypothesis. -/
theorem applyTransition_respondAgree_shape
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_status : gs.status = .inProgress)
    (h_apply : applyTransition gs .respondAgree = .ok gs') :
    gs'.range.low = mp ∧ gs'.range.high = gs.range.high := by
  unfold applyTransition applyTransitionWith at h_apply
  rw [h_pending] at h_apply
  simp [h_status] at h_apply
  -- The depth-cap gate produces an `if MAX_BISECTION_DEPTH ≤
  -- gs.depth then error else ok ...` expression; a successful
  -- apply (`= .ok gs'`) forces the false branch.  Split:
  by_cases h_cap : MAX_BISECTION_DEPTH ≤ gs.depth
  · simp [h_cap] at h_apply
  · simp [h_cap] at h_apply
    rw [← h_apply]
    exact ⟨rfl, rfl⟩

/-- The post-state of a successful `respondDisagree` has the
    original low as its new low bound and the midpoint as its
    new high bound. -/
theorem applyTransition_respondDisagree_shape
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_status : gs.status = .inProgress)
    (h_apply : applyTransition gs .respondDisagree = .ok gs') :
    gs'.range.low = gs.range.low ∧ gs'.range.high = mp := by
  unfold applyTransition applyTransitionWith at h_apply
  rw [h_pending] at h_apply
  simp [h_status] at h_apply
  by_cases h_cap : MAX_BISECTION_DEPTH ≤ gs.depth
  · simp [h_cap] at h_apply
  · simp [h_cap] at h_apply
    rw [← h_apply]
    exact ⟨rfl, rfl⟩

/-- Helper: a strict-narrowing arithmetic lemma over abstract
    `Nat` operands.  Used by `range_narrows_on_response_agree`
    after substituting the post-state's range bounds. -/
private theorem nat_sub_lt_sub_left
    (lo mp hi : Nat) (h_lo_mp : lo < mp) (h_mp_hi : mp < hi) :
    hi - mp < hi - lo := by
  omega

/-- Helper: a symmetric strict-narrowing arithmetic lemma. -/
private theorem nat_sub_lt_sub_right
    (lo mp hi : Nat) (h_lo_mp : lo < mp) (h_mp_hi : mp < hi) :
    mp - lo < hi - lo := by
  omega

/-- Each successful `respondAgree` transition strictly narrows
    the dispute range under well-formedness on the midpoint
    (mp.idx strictly inside the old range). -/
theorem range_narrows_on_response_agree
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_status : gs.status = .inProgress)
    (h_wf_mp : gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx)
    (h_apply : applyTransition gs .respondAgree = .ok gs') :
    gs'.range.high.idx - gs'.range.low.idx <
      gs.range.high.idx - gs.range.low.idx := by
  obtain ⟨h_lo_lt_mp, h_mp_lt_hi⟩ := h_wf_mp
  obtain ⟨h_lo_eq, h_hi_eq⟩ :=
    applyTransition_respondAgree_shape gs gs' mp h_pending h_status h_apply
  have h_low_idx : gs'.range.low.idx = mp.idx := by rw [h_lo_eq]
  have h_high_idx : gs'.range.high.idx = gs.range.high.idx := by rw [h_hi_eq]
  rw [h_low_idx, h_high_idx]
  exact nat_sub_lt_sub_left _ _ _ h_lo_lt_mp h_mp_lt_hi

/-- Symmetric: `respondDisagree` strictly narrows the range. -/
theorem range_narrows_on_response_disagree
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_status : gs.status = .inProgress)
    (h_wf_mp : gs.range.low.idx < mp.idx ∧ mp.idx < gs.range.high.idx)
    (h_apply : applyTransition gs .respondDisagree = .ok gs') :
    gs'.range.high.idx - gs'.range.low.idx <
      gs.range.high.idx - gs.range.low.idx := by
  obtain ⟨h_lo_lt_mp, h_mp_lt_hi⟩ := h_wf_mp
  obtain ⟨h_lo_eq, h_hi_eq⟩ :=
    applyTransition_respondDisagree_shape gs gs' mp h_pending h_status h_apply
  have h_low_idx : gs'.range.low.idx = gs.range.low.idx := by rw [h_lo_eq]
  have h_high_idx : gs'.range.high.idx = mp.idx := by rw [h_hi_eq]
  rw [h_low_idx, h_high_idx]
  exact nat_sub_lt_sub_right _ _ _ h_lo_lt_mp h_mp_lt_hi

/-! ## Halving (the canonical-midpoint strengthening)

`range_narrows_on_response_*` above give *strict* narrowing, which
is all an arbitrary interior midpoint supports.  Now that
`submitMidpoint` derives the index as `gs.range.midpointIdx`, the
pending midpoint of any reachable state is the canonical one and
each response **halves** the range rather than merely shrinking
it.  That is what upgrades `bisection_converges_after_enough_rounds`
from a linear bound to a logarithmic one. -/

/-- Ceiling-halving bound for both response directions, over bare
    `Nat`.  `respondAgree` leaves `high - (lo+hi)/2`;
    `respondDisagree` leaves `(lo+hi)/2 - lo`.  Both are at most
    `⌈(hi - lo) / 2⌉ = (hi - lo + 1) / 2`.

    Stated on `Nat` for the same reason as
    `midpointIdx_degenerate_iff`: `omega` decides it directly once
    the structure projections are out of the way. -/
theorem midpoint_halves (lo hi : Nat) :
    hi - (lo + hi) / 2 ≤ (hi - lo + 1) / 2 ∧
    (lo + hi) / 2 - lo ≤ (hi - lo + 1) / 2 := by
  omega

/-- After a `respondAgree` on a canonical midpoint, the width is
    at most `⌈w/2⌉`. -/
theorem range_halves_on_response_agree
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_canonical : mp.idx = gs.range.midpointIdx)
    (h_status : gs.status = .inProgress)
    (h_apply : applyTransition gs .respondAgree = .ok gs') :
    gs'.range.high.idx - gs'.range.low.idx ≤
      (gs.range.high.idx - gs.range.low.idx + 1) / 2 := by
  obtain ⟨h_lo_eq, h_hi_eq⟩ :=
    applyTransition_respondAgree_shape gs gs' mp h_pending h_status h_apply
  have h_low_idx : gs'.range.low.idx = mp.idx := by rw [h_lo_eq]
  have h_high_idx : gs'.range.high.idx = gs.range.high.idx := by rw [h_hi_eq]
  rw [h_low_idx, h_high_idx, h_canonical]
  unfold DisputedRange.midpointIdx
  exact (midpoint_halves gs.range.low.idx gs.range.high.idx).1

/-- Symmetric halving bound for `respondDisagree`. -/
theorem range_halves_on_response_disagree
    (gs gs' : GameState) (mp : Claim)
    (h_pending : gs.pendingMidpoint = some mp)
    (h_canonical : mp.idx = gs.range.midpointIdx)
    (h_status : gs.status = .inProgress)
    (h_apply : applyTransition gs .respondDisagree = .ok gs') :
    gs'.range.high.idx - gs'.range.low.idx ≤
      (gs.range.high.idx - gs.range.low.idx + 1) / 2 := by
  obtain ⟨h_lo_eq, h_hi_eq⟩ :=
    applyTransition_respondDisagree_shape gs gs' mp h_pending h_status h_apply
  have h_low_idx : gs'.range.low.idx = gs.range.low.idx := by rw [h_lo_eq]
  have h_high_idx : gs'.range.high.idx = mp.idx := by rw [h_hi_eq]
  rw [h_low_idx, h_high_idx, h_canonical]
  unfold DisputedRange.midpointIdx
  exact (midpoint_halves gs.range.low.idx gs.range.high.idx).2

/-- Every midpoint `submitMidpoint` installs is the canonical one.
    This is what lets a trace assume canonicality without taking it
    on trust: no other value is reachable. -/
theorem submitMidpoint_installs_canonical
    (gs gs' : GameState) (c : StateCommit)
    (h_apply : applyTransition gs (.submitMidpoint c) = .ok gs') :
    gs'.pendingMidpoint = some { idx := gs.range.midpointIdx, commit := c } := by
  -- Non-`only` `simp` at each branch: the three rejecting branches
  -- reduce `h_apply` to `Except.error _ = Except.ok _`, which is
  -- the contradiction that closes them.
  unfold applyTransition applyTransitionWith at h_apply
  by_cases h_status : gs.status = .inProgress
  · by_cases h_pending : gs.pendingMidpoint.isSome
    · simp [h_status, h_pending] at h_apply
    · by_cases h_depth : MAX_BISECTION_DEPTH ≤ gs.depth
      · simp [h_status, h_pending, h_depth] at h_apply
      · by_cases h_oob : gs.range.midpointIdx ≤ gs.range.low.idx
                          ∨ gs.range.high.idx ≤ gs.range.midpointIdx
        · simp [h_status, h_pending, h_depth, h_oob] at h_apply
        · simp [h_status, h_pending, h_depth, h_oob] at h_apply
          rw [← h_apply]
  · simp [h_status] at h_apply

/-! ## Smoke checks -/

/-- An initial game state with a non-trivial range. -/
example : DisputedRange where
  low  := { idx := 0,  commit := ByteArray.empty }
  high := { idx := 64, commit := ByteArray.empty }

/-- Spot-check: the depth cap is the documented 64. -/
example : MAX_BISECTION_DEPTH = 64 := rfl

/-- Spot-check: midpoint of [0, 64] is 32. -/
example :
    DisputedRange.midpointIdx
      { low := { idx := 0, commit := ByteArray.empty },
        high := { idx := 64, commit := ByteArray.empty } } = 32 := rfl

end FaultProof
end LegalKernel
