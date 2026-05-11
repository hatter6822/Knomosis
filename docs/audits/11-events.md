# Events — `LegalKernel/Events/Types.lean` and `LegalKernel/Events/Extract.lean`

**Files:**
* `LegalKernel/Events/Types.lean` (285 lines)
* `LegalKernel/Events/Extract.lean` (508 lines)

**TCB:** No.  Both modules are non-TCB; their bugs produce wrong
observations but do not violate kernel invariants.

---

## `LegalKernel/Events/Types.lean`

### Imports (lines 45–49)

```
import LegalKernel.Kernel
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.LocalPolicy
import LegalKernel.Bridge.AddressBook
import LegalKernel.Bridge.State
```

* All imports are inside the project, reasonable.  `Bridge.AddressBook`
  and `Bridge.State` are pulled for the `EthAddress` / `DepositId` /
  `WithdrawalId` types used in bridge events.
* The `Kernel` import is for `ResourceId`, `ActorId`, `Amount`.

**Finding:** Imports are correct.

### `Event` inductive (lines 77–193)

16 constructors (indices 0..15):

* 0 — `balanceChanged`
* 1 — `nonceAdvanced`
* 2 — `identityRegistered`
* 3 — `identityRevoked`
* 4 — `timeRecorded`
* 5 — `disputeFiled`
* 6 — `disputeWithdrawn`
* 7 — `verdictApplied`
* 8 — `rewardIssued`
* 9 — `withdrawalRequested`
* 10 — `depositCredited`
* 11 — `localPolicyDeclared`
* 12 — `localPolicyRevoked`
* 13 — `faultProofGameOpened`
* 14 — `faultProofBisectionStep`
* 15 — `faultProofGameSettled`

`deriving Repr, DecidableEq` — fine, both are auto-derivable for an
inductive with `BEq`-deriving payload types.

**Hazard observation:** The "frozen index" annotations in the
docstrings are a *contract* with indexers, not a mechanical
property of the constructor list.  If a future PR re-orders the
constructors, Lean will still compile, but every off-chain indexer
that consumed events under the old order will silently
mis-interpret.  The encoder in
`LegalKernel/Encoding/*` (audited separately) is the load-bearing
defense; reviewers should confirm the encoder pins the constructor
indices by an explicit tag byte rather than relying on
constructor-declaration order.

**Hazard observation:** `identityRevoked` (line 101) is documented
as "reserved for a future `revokeKey` Action constructor; Phase 5's
`Action` layer does not currently emit this event."  Similarly,
`timeRecorded` (line 105) is "not currently emitted."  These are
dead constructors at the moment.  If a reviewer adds a new event
constructor, the natural place to add it (alphabetically or
semantically) would shift these dead constructors' indices — but
the indexer contract pins their indices.  Recommend either: (a)
delete them now (TODO-flagged change), or (b) document explicitly
in the source that they MUST remain at their current index.

**Finding:** The event vocabulary is complete for Phase 5 + Phase 6
+ Workstream LP + Workstream C + Workstream H.  Indices are
documented but not mechanically enforced; the encoder is the
canonical contract.

### Convenience predicates (lines 199–281)

Nine predicates: `isBalanceChange`, `isRegistryChange`, `actor`,
`resource`, `isDisputeEvent`, `isRewardIssued`, `isBridgeEvent`,
`isLocalPolicyEvent`, `isFaultProofEvent`.  All are pure pattern
matches; no proofs.

**Finding:** No issues.  The pattern matches cover the constructor
space exhaustively (Lean would error on a missing case in a
non-`_ ->` arm; the catch-alls handle the rest).

---

## `LegalKernel/Events/Extract.lean`

### Imports (lines 58–60)

```
import LegalKernel.Authority.SignedAction
import LegalKernel.Disputes.Types
import LegalKernel.Events.Types
```

All project-internal, reasonable.

### Helpers (lines 89–105)

`balanceChangeEvents` (line 89): `filterMap` over a list of actors,
emitting `balanceChanged` only when pre / post differ.  Pure
function; no side effects.

`affectedActors` (line 100): returns the actors in `r`'s pre-state
`BalanceMap`, minus an excluded actor.  Uses
`bm.toList.map (·.1)` to project keys, then `filter (· ≠ excluded)`.

**Hazard observation:** `affectedActors` does not include actors
who *gained* a balance through the action but had no pre-state
entry.  For `distributeOthers` and `proportionalDilute` this is
fine (those laws don't add new actors — they distribute among
existing ones), but a future law that *introduces* new actors at a
resource would not have its new-actor balanceChanged event emitted
unless the helper is updated.  Currently sound; flagged for future
extensibility.

### `actionEvents` (lines 109–240)

Pattern-match over `Action`'s 19 constructors (Transfer, Mint, Burn,
FreezeResource, ReplaceKey, Reward, DistributeOthers,
ProportionalDilute, Dispute, DisputeWithdraw, Verdict, Rollback,
RegisterIdentity, Deposit, Withdraw, DeclareLocalPolicy,
RevokeLocalPolicy, FaultProofChallenge, FaultProofResolution).

For each:

* **Transfer (line 112):** delta-filtered `balanceChanged` for both
  sender and receiver.  Both events suppressed on a self-transfer
  (sender == receiver) since the §4.11 fix preserves the balance.
  Correct.
* **Mint / Burn (lines 125, 129):** delta-filtered `balanceChanged`
  for the affected actor.  Correct.
* **FreezeResource (line 133):** empty list.  Correct (no balance
  change).
* **ReplaceKey (line 135):** unconditional `identityRegistered`.
  Note the comment "Always, unconditionally" — even if the new key
  equals the old key, the event fires.  This is correct given the
  semantic (the registry mutation is the observable, not the
  key-byte equality).
* **Reward (line 137):** delta-filtered `balanceChanged` AND
  unconditional `rewardIssued`.  Both emitted; the `balanceEv` is
  empty if `oldV = newV` (e.g. `reward _ _ 0`), but the `rewardEv`
  always fires.  This is documented and matches Phase-6
  incentive-integration intent.
* **DistributeOthers / ProportionalDilute (lines 148, 150):** use
  `balanceChangeEvents` over `affectedActors`.  Correct.
* **Dispute (line 152):** emit `disputeFiled` with the *primary*
  impugned index extracted from the claim variant.  The five claim
  variants are pattern-matched exhaustively.  Note: each variant
  carries one or two indices; the implementation picks the first
  one for `oracleMisreported` and `doubleApply` (which carry two).
  This is a deliberate "primary" pick; indexers should consult the
  log entry for the full claim.
* **DisputeWithdraw / Verdict / Rollback (lines 165, 167, 174):**
  emit the corresponding event(s) or empty list.  Correct.
* **RegisterIdentity (line 181):** same `identityRegistered` as
  `replaceKey`.  Indexers must distinguish via prior-registry
  state.
* **Deposit / Withdraw (lines 190, 199):** delta-filtered
  `balanceChanged`.  The semantic events
  (`depositCredited`/`withdrawalRequested`) are emitted by
  `extractEvents`, not here.
* **DeclareLocalPolicy / RevokeLocalPolicy (lines 208, 216):** empty
  list.  Semantic events emitted by `extractEvents`.
* **FaultProofChallenge / FaultProofResolution (lines 222, 229):**
  empty list.  Semantic events emitted by `extractEvents`.
* **Lex-generated fence markers (lines 239–240):** explicit comments
  for the Lex codegen tool to splice in `actionEvents` arms for
  Lex-defined laws.

**Hazard observation:** The Lex codegen fence (lines 239–240) is a
string-marker contract.  If the marker comment is moved, the codegen
tool will fail.  See `Lex/Tools/Codegen.lean` for the matching
side — should be audited together.

**Finding:** The dispatch is exhaustive (Lean would error on a
missing case).  Delta-filtering for kernel-level effects is
consistent; unconditional semantic events for deployment-level
intents (reward, deposit/withdraw, LP, fault-proof) follow a
uniform pattern.

### `extractEvents` (lines 252–308)

Assembles five sub-lists:
* `actEvts` from `actionEvents`
* `bridgeEvts` (deposit/withdraw semantic) — unconditional
* `lpEvts` (LP semantic) — unconditional
* `faultProofEvts` (fault-proof semantic) — unconditional
* `nonceEvt` — single element, always

Concatenated as: `actEvts ++ bridgeEvts ++ lpEvts ++ faultProofEvts ++ nonceEvt`.

The order matters: a downstream replay must observe events in this
order for cross-stack equivalence.

**Hazard observation:** The order is fragile.  Re-ordering the five
sub-lists (e.g. moving `nonceEvt` to the front) would change the
event-list output and break every test that compares
`extractEvents` output to a golden.  Currently locked in by
multiple spot-check theorems below (`extractEvents_freeze_only_nonce`
asserts the freeze case is `[nonceEvt]` only; `extractEvents_deposit_emits_credited`
walks the nested `++` structure).

### Determinism theorem (line 317)

```lean
theorem extractEvents_deterministic
    (preState₁ postState₁ : ExtendedState) (st₁ : SignedAction)
    (preState₂ postState₂ : ExtendedState) (st₂ : SignedAction)
    (h_pre : preState₁ = preState₂) (h_post : postState₁ = postState₂)
    (h_st : st₁ = st₂) :
    extractEvents preState₁ postState₁ st₁ =
    extractEvents preState₂ postState₂ st₂ := by
  rw [h_pre, h_post, h_st]
```

Trivial proof; the function is pure so equal inputs ⇒ equal
output.  The theorem is statement-shaped to match Genesis Plan §8.9.1
verbiage.

**Finding:** Correct.  Note that this is type-level determinism, not
*observational* determinism: a future Lean toolchain bump that
changes the order in which `actionEvents`'s pattern matches reduce
would not break this theorem, but could break an unrelated
observational equivalence with another implementation.

### Spot-check theorems (lines 332–504)

* `extractEvents_nonempty` (line 336): proves the output is never
  empty.  Proof unfolds, congrArg's `List.length`, simplifies via
  `List.length_append`, and the contradiction discharges.
* `extractEvents_freeze_only_nonce` (line 350): for a `freezeResource`
  action, output is `[nonceAdvanced ...]`.  Closed by `rfl`.
* `extractEvents_replaceKey_emits_registration` (line 358): proves
  the two-element output shape.  Closed by `rfl`.
* `extractEvents_deposit_emits_credited` (line 381): membership
  proof via nested `List.mem_append` walks.  Correct.
* `extractEvents_withdraw_emits_requested` (line 402): similar.
* `extractEvents_declareLocalPolicy_emits_localPolicyDeclared`
  (line 432): similar.
* `extractEvents_revokeLocalPolicy_emits_localPolicyRevoked` (line
  449): similar.
* `extractEvents_faultProofChallenge_emits_gameOpened` (line 474):
  similar.
* `extractEvents_faultProofResolution_emits_gameSettled` (line 493):
  similar.

**Finding:** All proofs correct.  The membership proofs walk the
nested `++` structure manually using `List.mem_append` and
`List.mem_singleton`; they would benefit from a custom tactic, but
the current form is robust and inspectable.

**Hazard observation:** The membership proofs are sensitive to the
exact order of sub-list concatenation.  If `bridgeEvts` is moved
before `actEvts`, every membership proof's `Or.inl` / `Or.inr`
pattern would have to change.  Currently no test covers "what if the
order changes"; the test set is `==`-style golden against a fixed
order.

### Module-level findings

* **Correctness:** All event emission paths are well-defined and
  match the documented contract (which the auditor cross-checked
  against the actual code).
* **Determinism:** Type-level via `extractEvents_deterministic`;
  semantic via construction (pure function).
* **No `sorry`, no custom axioms.**
* **Hazards:**
  * Constructor-index drift relies on the encoder for the
    canonical contract; this module's `inductive` declaration is
    not the source of truth.
  * Two dead constructors (`identityRevoked`, `timeRecorded`)
    occupy fixed indices that future PRs must not displace.
  * Sub-list concatenation order in `extractEvents` is brittle to
    refactors; mitigated by the explicit `show _ ∈ ... ++ ...`
    walks in the membership theorems.
  * The Lex codegen fence (`-- BEGIN LEX-GENERATED ... -- END
    LEX-GENERATED`) is a string-marker contract with
    `Lex/Tools/Codegen.lean`.
* **Coverage:** The spot-check theorems cover all the
  "unconditional semantic event" paths.  No spot-check exists for
  the empty cases (`extractEvents_rollback_only_nonce`); this would
  be a useful regression test if a future Lex-generated arm
  accidentally emits an event for rollback.
