# Audit 03 — `LegalKernel/Laws/*`

Comprehensive line-by-line audit of the 13 law modules under
`/home/user/Canon/LegalKernel/Laws/`. Verified directly against
source; documentation cross-checked but not trusted.

The non-TCB law modules carry the deployment-facing `Transition`
values, their decidable preconditions, per-resource locality
lemmas, the supply equations, and the `IsConservative` /
`IsMonotonic` / `LocalTo` / `FreezePreserving` typeclass
instances (or their negative-witness theorems). The TCB-core
modules — `Kernel.lean`, `RBMapLemmas.lean` — and the typeclass
declarations themselves — `Conservation.lean` — are audited
separately (see `02-conservation.md`).

## Classification at a glance

| Law                  | `IsConservative` | `IsMonotonic` | `LocalTo [r]` | `FreezePreserving [] / S∌r` | Has registry effect |
|----------------------|------------------|---------------|---------------|------------------------------|---------------------|
| `transfer`           | instance         | instance      | instance      | theorem (S∌r) + `[]` inst    | no                  |
| `mint`               | **negated**      | instance      | instance      | theorem + `[]` inst          | no                  |
| `burn`               | **negated**      | **negated**   | instance      | theorem + `[]` inst          | no                  |
| `freezeResource`     | instance         | instance      | instance (any `S`) | instance (any `S`)       | no                  |
| `reward`             | **negated**      | instance      | instance      | theorem + `[]` inst          | no                  |
| `distributeOthers`   | **negated**      | instance      | instance      | theorem + `[]` inst          | no                  |
| `proportionalDilute` | **negated**      | instance      | instance      | theorem + `[]` inst          | no                  |
| `deposit`            | **negated**      | instance      | instance      | theorem + `[]` inst          | no (effect in `applyActionToBridgeState`) |
| `withdraw`           | **negated**      | **negated**   | instance      | theorem + `[]` inst          | no                  |
| `replaceKey` (Lex)   | (compiles to identity) | —       | —             | —                            | yes (`applyActionToRegistry`) |
| `registerIdentity` (Lex) | (compiles to identity) | —   | —             | —                            | yes                 |
| `dispute / disputeWithdraw / verdict / rollback` (Lex) | (all identity) | — | — | —                            | no (effects in dispute pipeline) |
| `declareLocalPolicy / revokeLocalPolicy` (Lex) | (identity) | — | —   | —                            | yes (`applyActionToLocalPolicies`) |

Notes:
- "negated" = an explicit `¬ IsConservative …` / `¬ IsMonotonic
  …` theorem (e.g. `mint_not_conservative`) with a concrete
  state witness.
- Only the four hand-written non-bridge laws (`transfer`,
  `mint`, `burn`, `freezeResource`) plus `reward`,
  `distributeOthers`, `proportionalDilute`, `deposit`, and
  `withdraw` have hand-written `Transition` values. The other
  six (`replaceKey`, `registerIdentity`, four dispute action
  variants, two local-policy variants) are **Lex-only**
  declarations whose `apply_impl` is the identity — their
  observable effect lives in the authority/dispute/local-policy
  layers, not at the kernel `Transition` level.

The §5.3 conservation argument
(`total_supply_global[_via_law_set]` in `Conservation.lean`)
depends on `transfer_isConservative` plus the `freezeResource`
identity-flavour conservative instance. Every other balance-
mutating law (`mint`, `burn`, `reward`, `distributeOthers`,
`proportionalDilute`, `deposit`, `withdraw`) is provably
**outside** the conservative tier.

---

## 1. `LegalKernel/Laws/Transfer.lean` (355 lines)

**Imports** (`Transfer.lean:38-40`):
- `LegalKernel.Kernel`
- `LegalKernel.Conservation`
- `Lex.DSL.Law`

Reasonable: the kernel module supplies `State / Transition /
step_impl / setBalance / getBalance`; Conservation supplies
`TotalSupply / totalSupply_setBalance / IsConservative /
IsMonotonic / LocalTo / FreezePreserving`; `Lex.DSL.Law` enables
the `lexlaw` macro for the LX-M2 re-expression.

**`Transition` value** (`Transfer.lean:60-71`):
```
pre        := fun s => getBalance s r sender ≥ amount ∧ amount > 0
decPre     := fun _ => inferInstance          -- Nat ≥ + Nat >
apply_impl := fun s =>
  let fromBal := getBalance s r sender
  let s1      := setBalance s r sender (fromBal - amount)
  let toBal   := getBalance s1 r receiver       -- READ FROM s1!
  setBalance s1 r receiver (toBal + amount)
```
The self-transfer §4.11 fix is verbatim: `toBal` is read from
`s1`, not `s` (`Transfer.lean:70`). Comment at `Transfer.lean:67-69`
explicitly flags this.

**Lex re-expression** (`Transfer.lean:93-119`):
`lexlaw legalkernel_transfer` with `lex_action_index 0`,
`lex_satisfies := [conservative, monotonic, «local»,
freeze_preserving, nonce_advances, registry_preserving]`. The
`«local»` keyword uses French-quoted form because `local` is
reserved. Byte-equivalence regression at `Transfer.lean:125-127`
closes by `rfl`, so the Lex form is *definitionally equal* to
the hand-written `transfer` — no extra trust.

**Conservation proof** (`transfer_conserves`,
`Transfer.lean:187-217`):
- Lifted to a 6-arg arithmetic lemma `transfer_arithmetic`
  (`Transfer.lean:170-176`) that takes `T0 T1 T2 B R1 amount` and
  the two `totalSupply_setBalance` equations + `hbal : amount ≤
  B`, then discharges by a single `omega` call.
- This lifting is a documented omega-atom-discovery workaround
  (`Transfer.lean:163-169`): omega cannot reliably surface deeply
  nested `TotalSupply (setBalance (setBalance …))` atoms as
  variables, so they are passed in as parameters.
- The main theorem then instantiates the helper with two
  `totalSupply_setBalance` (`RBMapLemmas` / Conservation §8.1)
  applications — one per write — and the precondition's balance
  bound `hpre.left`.
- Proof is uniform over the self-transfer case: no case split on
  `sender = receiver`.

**Cross-resource locality**
(`transfer_other_resource_untouched`, `Transfer.lean:231-248`):
By case split on `hpre`. Legal branch unfolds `setBalance` and
chains *two* `RBMap.find?_insert_other` rewrites (one per
nested insert at the outer `State.balances` level). Rejected
branch is reflexive. The proof relies on the kernel-level
encoding that `setBalance` is `{ s with balances := s.balances.insert r ... }`.

**`IsConservative` instance**
(`transfer_isConservative`, `Transfer.lean:283-290`): conservation
at `r' = r` via `transfer_conserves`; at `r' ≠ r` via
`transfer_conserves_other_resource`. `by_cases hr : r = r'` +
`subst`.

**`IsMonotonic` instance**
(`transfer_isMonotonic`, `Transfer.lean:296-301`): explicit
upgrade from conservation. The comment notes this is redundant
with the global `monotonic_of_conservative` (low-priority)
typeclass but is shipped for stable identifier resolution.

**`LocalTo [r]` instance** (`Transfer.lean:309-320`).
**`FreezePreserving` theorem** (`Transfer.lean:328-341`) over an
arbitrary list `S` of frozen resources, parameterised so it is
not an instance (the typeclass-resolution machinery cannot infer
`S`). Vacuous-case `FreezePreserving []` is an instance
(`Transfer.lean:349-352`).

**Sharp / brittle:** None observed. The two-step omega lift is
the only non-trivial proof move, and it is documented.

**Documentation drift:** None — module docstring matches
shipped code.

---

## 2. `LegalKernel/Laws/Mint.lean` (261 lines)

**Imports** (`Mint.lean:30-32`): same three. Reasonable.

**`Transition` value** (`Mint.lean:47-51`):
```
pre        := fun _ => amount > 0
decPre     := fun _ => inferInstance
apply_impl := fun s => setBalance s r to (getBalance s r to + amount)
```
Note: `pre` does **not** depend on `s` (only `amount > 0`). A
mint of zero is excluded as a no-op-is-the-natural-policy
choice.

**Lex re-expression** (`Mint.lean:67-88`): `lex_action_index 1`;
`lex_satisfies` *correctly omits* `conservative` (comment at
`Mint.lean:79-85` notes this) — the synthesizer `synth_conservative`
would fail L004 on mint, which is mechanically proved by
`mint_not_conservative` below.

**Supply equation** (`totalSupply_after_mint`, `Mint.lean:108-125`):
single `totalSupply_setBalance` instance + `omega`. Post-mint
supply = pre + `amount`.

**Cross-resource locality**
(`mint_other_resource_untouched`, `Mint.lean:138-149`): a single
`RBMap.find?_insert_other` rewrite (only one outer
`s.balances.insert r ...` because mint only writes once). Both
branches of the precondition case split close cleanly.

**`IsConservative` is negated**
(`mint_not_conservative`, `Mint.lean:183-197`):
- Witness: `genesisState` with `pre = hpos : amount > 0`.
- Strategy: instantiate `hcons.conserves r genesisState hpre`,
  rewrite LHS via `totalSupply_after_mint` and RHS via
  `totalSupply_genesis_eq_zero`, derive `0 + amount = 0`, which
  contradicts `Nat.pos_iff_ne_zero.mp hpos`.
- Clean and direct.

**`IsMonotonic` instance** (`mint_isMonotonic`, `Mint.lean:206-216`):
case split on `r = r'`; at `r' = r` via `totalSupply_after_mint`
(strict increase ⇒ `pre ≤ post`); at `r' ≠ r` via
`mint_conserves_other_resource` (equality ⇒ `≤`).

**`LocalTo` / `FreezePreserving`**: same structural shape as
`transfer`. `LocalTo [r]` instance, `FreezePreserving S` theorem
parameterised, `FreezePreserving []` instance.

**Sharp / brittle:** None observed. The witness construction
uses `genesisState` directly (no need for a prior `setBalance`
fixture, unlike `burn`).

**Documentation drift:** None.

---

## 3. `LegalKernel/Laws/Burn.lean` (308 lines)

**Imports** (`Burn.lean:27-29`): same three. Reasonable.

**`Transition` value** (`Burn.lean:45-49`):
```
pre        := fun s => getBalance s r fromActor ≥ amount ∧ amount > 0
decPre     := fun _ => inferInstance
apply_impl := fun s =>
  setBalance s r fromActor (getBalance s r fromActor - amount)
```
The balance lower bound `≥ amount` makes the `Nat` subtraction
total, but the kernel always uses truncated `-` so a missed
precondition couldn't underflow either way.

**Lex re-expression** (`Burn.lean:58-81`): `lex_action_index 2`;
`lex_satisfies` correctly omits **both** `conservative` AND
`monotonic` (comment at `Burn.lean:71-79`). This is the only
balance-mutating hand-written law that is non-monotonic.

**Supply equation** (`totalSupply_after_burn`,
`Burn.lean:104-120`):
- `burn_arithmetic` helper (`Burn.lean:93-98`) lifts `T0 T1 B
  amount` to plain `Nat` and asserts `T1 + amount = T0` from
  `T1 + B = T0 + (B - amount)` and `amount ≤ B`. Same omega-
  atom-discovery workaround as in Transfer.
- Stated in *additive* form (`T1 + amount = T0`) to avoid `Nat`
  truncated-subtraction asymmetry.

**`IsConservative` is negated**
(`burn_not_conservative`, `Burn.lean:173-215`):
- Witness state `s := setBalance genesisState r fromActor amount`,
  i.e. `fromActor` holds *exactly* `amount`.
- Uses `getBalance_setBalance_same` (from RBMapLemmas /
  Conservation) to derive `hread : getBalance s r fromActor =
  amount`; precondition obligation is `Nat.le_refl amount`.
- Pre-burn supply at `s` is shown to be `amount` (via
  `totalSupply_setBalance` + `totalSupply_genesis_eq_zero` +
  `getBalance` reading from empty genesis).
- Post-burn supply + `amount` = pre-burn supply = `amount`
  (`totalSupply_after_burn`), so post = 0.
- Conservation hypothesis would force `0 = amount`, contradiction
  via `Nat.pos_iff_ne_zero.mp hpos`.

**`IsMonotonic` is negated**
(`burn_not_monotonic`, `Burn.lean:229-267`):
- Same fixture as `burn_not_conservative`. Derives `post = 0`
  via Nat additive cancellation `omega`.
- Concludes `amount ≤ 0` from `hmon.monotone`, contradicting
  `hpos`.

**`LocalTo` / `FreezePreserving`**: same structural shape.

**Sharp / brittle:** The fixture-state construction is delicate
but explicit; the `getBalance ({ balances := ∅ } : State) r
fromActor = 0` step is closed by `simp [getBalance]` which
depends on `Option.getD_none` reducing `s.balances[r]?.getD 0
0`. No hidden quantifiers. The additive-form `totalSupply_after_burn`
deliberately sidesteps `Nat` subtraction.

**Documentation drift:** None.

---

## 4. `LegalKernel/Laws/Freeze.lean` (265 lines)

**Imports** (`Freeze.lean:39-44`):
- `LegalKernel.Kernel`
- `LegalKernel.Conservation`
- `LegalKernel.Laws.Transfer`
- `LegalKernel.Laws.Mint`
- `LegalKernel.Laws.Burn`
- `Lex.DSL.Law`

Imports `Transfer / Mint / Burn` because the
`*_preserves_freeze` theorems chain to those laws'
`*_other_resource_untouched` lemmas. The imports are tight (no
gratuitous dependencies).

**`Transition` value** (`Freeze.lean:69-72`):
```
def freezeResource (_r : ResourceId) : Transition where
  pre        := fun _ => True
  decPre     := fun _ => inferInstance
  apply_impl := fun s => s
```
*Parameter is `_r` — deliberately ignored at the kernel level*
(`Freeze.lean:62-68`). The comment makes the policy explicit:
`freezeResource 1` and `freezeResource 2` are *definitionally
equal* `Transition` values; the resource identity lives in the
action layer (`Action.freezeResource r`) only. This is the
deployment-commitment design — the kernel does not enforce
freezes; deployments do via law-set discipline.

**Lex re-expression** (`Freeze.lean:76-99`):
`lex_action_index 3`, `lex_satisfies := [conservative, monotonic,
«local», freeze_preserving, nonce_advances, registry_preserving]`.

**The `FrozenForResource` invariant** (`Freeze.lean:126-128`):
```
def FrozenForResource (r : ResourceId) (snap : Option BalanceMap)
    (s : State) : Prop :=
  s.balances[r]? = snap
```
Compares the per-resource `BalanceMap` to a snapshot. Note: the
snapshot is `Option BalanceMap`, so an *absent* row at `r` (i.e.
`none`) is freeze-compatible only with the snapshot `none`. This
is correct given the kernel's `getBalance ` semantics.

**Identity-preservation lemma**
(`freezeResource_preserves_freeze`, `Freeze.lean:141-145`): the
proof is literally `hI` — every invariant on `s` lifts to
`step_impl s (freezeResource r')` because the latter is
definitionally `s`.

**`IsConservative` / `IsMonotonic` instances**
(`Freeze.lean:160-172`): conservation is by `rfl` for every
`r'`, `s`, `hpre`. Monotonicity follows by `Nat.le_of_eq`. The
comment at `Freeze.lean:153-158` notes this instance was missing
in original Phase 2 (no impact at the time; added so that
`ConservativeLawSet` admits `transfer + freezeResource` law
sets via `inferInstance`).

**Preservation lemmas** (`Freeze.lean:178-215`): one each for
`transfer`, `mint`, `burn`, each parameterised by `r ≠ r'`
(frozen ≠ mutated). All three apply
`*_other_resource_untouched` from the imported modules. Note
the argument-order swap when calling: e.g.
`transfer_other_resource_untouched r' r ... (Ne.symm h)` because
the lemma's first resource is the *transferred* one
(`Freeze.lean:188-190`).

**`LocalTo S` and `FreezePreserving S` instances**
(`Freeze.lean:230-241`): both quantify over arbitrary `S` (not
just `[]` or `[r]`) — the identity transition trivially
satisfies these for any set.

**§10.2 ↔ legacy phrasing equivalence**
(`freezePreserving_iff_FrozenForResource_preserved`,
`Freeze.lean:249-262`): packages the two formulations as an `iff`.
Useful for downstream proofs that want to chain old-style
preservation lemmas through new-style typeclass uses.

**Sharp / brittle:** The `_r` underscore parameter on
`freezeResource` is load-bearing — relaxing it would change the
definitional shape and break the `*_preserves_freeze` theorems.
The module's docstring (`Freeze.lean:62-68`) calls this out.

**Documentation drift:** None.

---

## 5. `LegalKernel/Laws/Reward.lean` (243 lines)

**Imports** (`Reward.lean:36-38`): kernel + Conservation +
`Lex.DSL.Law`. No dependency on `Laws.Mint` despite being a
near-clone.

**`Transition` value** (`Reward.lean:57-61`): byte-identical
shape to `mint`:
```
pre        := fun _ => amount > 0
apply_impl := fun s => setBalance s r to (getBalance s r to + amount)
```
The module docstring (`Reward.lean:20-26`) explains the
duplication: the semantic distinction between `mint` and
`reward` lives in the authority layer (`Action.mint` vs
`Action.reward`), not in the kernel-level `Transition`. The
firewall is therefore at the action-compilation layer, not at
the `Transition` value.

**Lex re-expression** (`Reward.lean:65-85`): `lex_action_index 5`
(note: mint = 1, freezeResource = 3, ???=4 → `replaceKey`,
reward = 5). `lex_satisfies := [monotonic, «local», ...]` (no
`conservative`). Comment at `Reward.lean:77-82` notes the
classification reasoning.

**Supply equation** (`totalSupply_after_reward`,
`Reward.lean:103-114`): identical proof shape to
`totalSupply_after_mint`.

**Cross-resource lemmas** (`Reward.lean:127-160`): symmetric to
the mint ones.

**`IsMonotonic` instance** (`Reward.lean:169-179`): identical to
`mint_isMonotonic`.

**`IsConservative` negated** (`reward_not_conservative`,
`Reward.lean:193-203`): identical proof to
`mint_not_conservative`.

**`LocalTo` / `FreezePreserving`**: identical structural shape.

**Sharp / brittle:** Because the `Transition` value is
definitionally equal to `mint`'s, every theorem in this file is
provable verbatim from the corresponding mint theorem. The
duplication is intentional (separate identifiers for stable
authority-layer references) but is a real maintenance burden — a
later edit to `mint`'s shape would silently desync the two.

**Documentation drift:** None.

---

## 6. `LegalKernel/Laws/DistributeOthers.lean` (422 lines)

**Imports** (`DistributeOthers.lean:37-43`):
```
LegalKernel.Kernel
LegalKernel.Conservation
Lex.DSL.Law
open Std
open scoped Std.TreeMap
```
The two `open` clauses are necessary because the apply_impl
uses `Std.TreeMap.toList` and `mem_toList_iff_getElem?_eq_some`.

**`Transition` value** (`DistributeOthers.lean:62-71`):
```
def distributeOthers (r : ResourceId) (excluded : ActorId) (amount : Amount) :
    Transition where
  pre        := fun _ => amount > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    let bm := s.balances[r]?.getD ∅
    let toReward := bm.toList.filter (fun kv => kv.1 != excluded)
    toReward.foldl
      (fun s' kv => setBalance s' r kv.1 (getBalance s' r kv.1 + amount)) s
```
Key shapes:
- `s.balances[r]?.getD ∅` — if `r` is absent, `bm` is the empty
  map; the filter then yields `[]` and the foldl is `s`.
- `bm.toList.filter (fun kv => kv.1 != excluded)` — iterate over
  every actor *present* in `r`'s `BalanceMap` and skip
  `excluded`. Note: **actors with zero balance that are NOT in
  `bm` receive nothing** (docstring at `DistributeOthers.lean:50-53`
  is explicit about this).
- Iteration order is fixed by `Std.TreeMap.toList` (key order).
  The module docstring (`DistributeOthers.lean:30-32`) calls this
  out and points at `docs/std_dependencies.md`.

**Lex re-expression** (`DistributeOthers.lean:75-104`):
`lex_action_index 6`; comment at `DistributeOthers.lean:93-101`
flags that `proof monotonic := by exact distributeOthers_isMonotonic …`
would be needed for M3 codegen (the synthesizer can't pattern-
match foldl).

**Inductive helpers**
(`DistributeOthers.lean:127-174`):
- `foldl_setBalance_other_resource_untouched` — by induction on
  `xs` generalising `s`, with the inductive step closed by
  `RBMap.find?_insert_other`.
- `foldl_setBalance_excluded_untouched` — by induction on `xs`,
  with the inductive step using `RBMap.find?_insert_self` +
  `RBMap.find?_insert_other` to skip past the head's
  `hd.1 ≠ excluded` insert. The hypothesis `∀ kv ∈ xs, kv.1 ≠
  excluded` propagates through `List.mem_cons.mpr` in both
  directions.

**Cross-resource locality theorems**
(`DistributeOthers.lean:182-213`): all reduce to the foldl
helper via `simp only [distributeOthers]`.

**Excluded-actor preservation theorem**
(`distributeOthers_excluded_unchanged`,
`DistributeOthers.lean:220-237`): applies
`foldl_setBalance_excluded_untouched` with the obligation
`∀ kv ∈ filter (·.1 != excluded) bm.toList, kv.1 ≠ excluded`
discharged via `List.mem_filter.mp`. The proof of the inequality
is via the `BEq` lemma reading `kv.1 != excluded = true` from
`(List.mem_filter.mp hkv).2`, then deriving contradiction via
`simp at h_neq` after `rw [heq]`.

**Supply equation**
(`totalSupply_after_distributeOthers`,
`DistributeOthers.lean:275-286`): bound to a private
`foldl_setBalance_totalSupply` lemma
(`DistributeOthers.lean:246-265`) that proves
`TotalSupply (foldl …) r = TotalSupply s r + amount * xs.length`
by induction with `totalSupply_setBalance` per step (and
`Nat.mul_succ` for the length-grows step).

**`IsMonotonic` instance**
(`distributeOthers_isMonotonic`, `DistributeOthers.lean:293-303`):
case split on `r = r'`; at the distributed resource the supply
equation + `omega` give `pre ≤ pre + amount * k`; at any other
resource, conservation + `omega`.

**`IsConservative` negated**
(`distributeOthers_not_conservative`,
`DistributeOthers.lean:315-381`):
- Constructs a non-excluded actor `non_excluded := if excluded
  = 0 then 1 else 0` — the "swap 0 ↔ 1 trick" because
  `ActorId` is `UInt64` and `excluded + 1 ≠ excluded` doesn't
  follow from `omega` (modular arithmetic).
- Fixture: `s := setBalance genesisState r non_excluded amount`.
- Membership lemma chain: shows
  `(non_excluded, amount) ∈ filter (·.1 != excluded) bm.toList`
  using `Std.TreeMap.mem_toList_iff_getElem?_eq_some` and
  `RBMap.find?_insert_self`.
- Length-of-filter ≥ 1, combined with the supply equation and
  conservation hypothesis, forces `amount * len = 0`. Then
  `Nat.le_mul_of_pos_right` + `len ≥ 1` gives `amount ≤ 0`,
  contradicting `hpos`.

**`LocalTo` / `FreezePreserving`**: same structural shape.

**Sharp / brittle:**
1. The "swap 0 ↔ 1 trick" for `non_excluded` is necessary
   because `ActorId = UInt64`. A reader might assume `excluded
   + 1` is OK but it isn't.
2. `bm := s.balances[r]?.getD ∅` — if `r` is *absent* from the
   map, this is the empty `BalanceMap`, the filter is empty,
   and the foldl is `s`. So at an absent resource,
   `distributeOthers` is a no-op even though `pre := amount >
   0` is `True`. This is correctly captured by the supply
   equation (`amount * 0 = 0`) but is an easy thing to miss when
   reasoning about the action at the action layer.
3. Iteration order is key-determined; any future migration
   away from `Std.TreeMap.toList` to a different traversal
   would have to preserve this. The docstring is explicit.

**Documentation drift:** None.

---

## 7. `LegalKernel/Laws/ProportionalDilute.lean` (518 lines)

**Imports** (`ProportionalDilute.lean:38-43`): same three +
`open Std` / `open scoped Std.TreeMap` (same reasons as
DistributeOthers).

**`Transition` value** (`ProportionalDilute.lean:63-74`):
```
def proportionalDilute
    (r : ResourceId) (excluded : ActorId) (totalReward : Amount) :
    Transition where
  pre        := fun s => totalReward > 0 ∧ sumOthers s r excluded > 0
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    let bm := s.balances[r]?.getD ∅
    let S  := sumOthers s r excluded     -- captured BEFORE foldl
    let toReward := bm.toList.filter (fun kv => kv.1 != excluded)
    toReward.foldl
      (fun s' kv =>
        setBalance s' r kv.1 (getBalance s' r kv.1 + totalReward * kv.2 / S))
      s
```
Key shapes:
- Precondition has **two** decidable conjuncts: `totalReward >
  0` and `sumOthers s r excluded > 0`. The second conjunct
  rules out the divide-by-zero case. `sumOthers` is defined in
  Conservation.lean (line 222).
- `S` is captured *before* the foldl. The comment at
  `ProportionalDilute.lean:60-62` explicitly notes this — `S`
  must remain constant across the iteration even though
  individual balances change.
- Per-step new value is `getBalance s' r kv.1 + totalReward *
  kv.2 / S` where `kv.2` is the **snapshotted balance at the
  start of foldl iteration** (because `kv` comes from
  `bm.toList`, which is the pre-foldl snapshot). This means
  the proportional share is computed against the *original*
  balance, not the running balance — important for the dust
  bound.
- Nat floor division: `totalReward * kv.2 / S`. Dust discarded
  policy (D5) — module docstring explicit
  (`ProportionalDilute.lean:23-27`).

**Lex re-expression** (`ProportionalDilute.lean:78-106`):
`lex_action_index 7`; same monotonic-not-conservative
classification as `distributeOthers`.

**Inductive helpers** (`ProportionalDilute.lean:130-166`):
- `foldl_setBalance_at_r_other_resource_untouched` — generic over
  the per-step new-value function `f : State → ActorId × Nat →
  Nat`.
- `foldl_setBalance_at_r_excluded_untouched` — same generic-`f`
  shape.

**Cross-resource locality** (`ProportionalDilute.lean:172-202`):
applies the generic helpers.

**Excluded-actor preservation theorem**
(`proportionalDilute_excluded_unchanged`,
`ProportionalDilute.lean:207-223`): same shape as
`distributeOthers_excluded_unchanged`.

**Supply equation**
(`totalSupply_after_proportionalDilute`,
`ProportionalDilute.lean:257-268`):
bound to private `foldl_setBalance_proportional_totalSupply`
(`ProportionalDilute.lean:231-252`) — proves
`TotalSupply (foldl …) r = TotalSupply s r + (xs.map (...).sum)`
by induction. The per-step delta is `totalReward * kv.2 / S`
(Nat floor), inserted via `totalSupply_setBalance` + omega.

**Non-decrease lemma**
(`proportionalDilute_supply_nondecreasing`,
`ProportionalDilute.lean:280-286`): `Nat.le_add_right` on the
supply equation. Subsumed by the dust bound, kept for stable
identifier.

**Dust bound (the headline)**
(`proportionalDilute_distributed_le_totalReward`,
`ProportionalDilute.lean:334-351`):
- **Per-element bound** (`list_div_sum_mul_le`,
  `ProportionalDilute.lean:298-316`): proves
  `(xs.map (totalReward * kv.2 / S)).sum * S ≤ totalReward *
  (xs.map (·.2)).sum` by list induction. Step: `Nat.div_mul_le_self`
  per element + omega for the additive combination.
- **State-level bridge** (`state_filter_sum_eq_sumOthers` — in
  `Conservation.lean:466`): connects the filter-sum of
  pre-foldl balances to `sumOthers s r excluded`.
- **Cancellation**: `Nat.le_of_mul_le_mul_right` divides through
  by `S > 0` (which is exactly `hpre.2`).

This is the §4-prelude WU R.14 theorem cited in CLAUDE.md.

**`IsMonotonic` instance** (`ProportionalDilute.lean:359-368`).

**`IsConservative` negated**
(`proportionalDilute_not_conservative`,
`ProportionalDilute.lean:383-475`):
- Same "swap 0 ↔ 1" trick for `non_excluded`.
- Fixture: `s := setBalance genesisState r non_excluded
  totalReward`. So actor `non_excluded` holds exactly
  `totalReward` at `r`.
- Shows `sumOthers s r excluded = totalReward` (via `unfold
  sumOthers` + the supply / get_excluded computations).
- Precondition holds: `totalReward > 0` and `sumOthers > 0`.
- Computes the increment for the singleton entry: `totalReward
  * totalReward / totalReward = totalReward` via
  `Nat.mul_div_cancel _ hpos`.
- Then uses `nat_le_sum_of_mem` (from Conservation.lean:236)
  to bound the mapped sum below by `totalReward`, combined
  with the conservation hypothesis ⇒ `sum = 0`, contradiction.

**`LocalTo` / `FreezePreserving`**: same structural shape.

**Sharp / brittle:**
1. **`S` capture-before-foldl** is load-bearing: if the
   foldl were to recompute `sumOthers s'` per step, the
   monotonicity and dust-bound proofs would break (the
   running balance grows each iteration). Per-element value
   `kv.2` is taken from the pre-foldl `bm.toList`, so it is
   safe — but a refactor that swapped `kv.2` for `getBalance
   s' r kv.1` would silently break the dust bound. Currently
   no comment in source flags this explicitly beyond the
   "captured before" remark at `ProportionalDilute.lean:60-62`.
2. **`Nat.mul_div_cancel`** in the non-conservation proof
   requires `totalReward > 0` (which is `hpos`), not just
   non-zero. The `sumOthers = totalReward` fact is what
   makes the division exact.
3. **Divide-by-zero precondition** correctly forbids
   `sumOthers = 0` — but a deployment that allows
   `proportionalDilute` and then has all non-excluded actors
   with zero balance would see every legal application get
   skipped at the precondition gate (the law would be
   permanently dormant). This is desired behaviour but worth
   noting for runtime-monitoring purposes.

**Documentation drift:** None.

---

## 8. `LegalKernel/Laws/Deposit.lean` (260 lines)

**Imports** (`Deposit.lean:38-41`): kernel + Conservation +
`LegalKernel.Bridge.State` (for `Bridge.DepositId`) + Lex.

**`Transition` value** (`Deposit.lean:58-63`):
```
def deposit (r : ResourceId) (recipient : ActorId) (amount : Amount)
    (_depositId : Bridge.DepositId) : Transition where
  pre        := fun _ => True
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    setBalance s r recipient (getBalance s r recipient + amount)
```
Key:
- `pre := True` — comment at `Deposit.lean:50-54` notes the
  deposit-id-uniqueness check lives at the bridge-admissibility
  level (`applyActionToBridgeState`), not in the kernel
  `Transition.pre`. This is because `Transition.pre` operates on
  `State`, not `BridgeState`.
- `_depositId` is underscored — used only by the bridge-level
  effect, irrelevant to the kernel-level mutation.

**Lex re-expression** (`Deposit.lean:74-93`):
`lex_action_index 13`. Same monotonic-not-conservative class as
`mint`.

**Supply equation** (`totalSupply_after_deposit`,
`Deposit.lean:108-121`): post-deposit supply at `r` = pre +
`amount`. Same shape as `totalSupply_after_mint`. Note that
because `pre := True`, the `hpre := trivial` discharge is
unconditional — `totalSupply_after_deposit` has no `hpre`
argument (vs `totalSupply_after_mint` which threads `hpre`).

**Cross-resource locality** (`Deposit.lean:127-158`): same
shape.

**Cross-actor locality at the same resource**
(`deposit_other_actor_untouched`, `Deposit.lean:165-178`): not
present in `mint`. Uses `getBalance_setBalance_other` (from
RBMapLemmas / Conservation) to derive
`getBalance (setBalance s r recipient ...) r recipient' =
getBalance s r recipient'` when `recipient ≠ recipient'`.

**`IsConservative` negated** (`deposit_not_conservative`,
`Deposit.lean:186-197`): uses `genesisState` directly, with
`hpre := trivial` (precondition is `True`).

**`IsMonotonic` instance** (`Deposit.lean:204-215`): same case-
split shape.

**`LocalTo` / `FreezePreserving`**: same structural shape.

**Sharp / brittle:**
- The trivial precondition means the bridge layer is the *only*
  gate. If a deployment forgets to wire deposit-id uniqueness
  through `applyActionToBridgeState`, replay protection fails.
  This is the design but it's worth flagging for bridge-policy
  audits.
- `_depositId` is unused at the kernel level. The kernel-level
  `Transition` for `deposit r r1 a1 id1` and `deposit r r1 a1
  id2` are definitionally equal — only the bridge-level effect
  distinguishes them.

**Documentation drift:** None.

---

## 9. `LegalKernel/Laws/Withdraw.lean` (285 lines)

**Imports** (`Withdraw.lean:36-40`): kernel + Conservation +
`Bridge.State` + `Bridge.AddressBook` + Lex.

**`Transition` value** (`Withdraw.lean:55-60`):
```
def withdraw (r : ResourceId) (sender : ActorId) (amount : Amount)
    (_recipientL1 : Bridge.EthAddress) : Transition where
  pre        := fun s => getBalance s r sender ≥ amount
  decPre     := fun _ => inferInstance
  apply_impl := fun s =>
    setBalance s r sender (getBalance s r sender - amount)
```
Notable: **the precondition does not require `amount > 0`** — it
only requires sufficient balance. So a withdrawal of 0 is
legal (and a no-op at the kernel level: `getBalance s r sender
- 0 = getBalance s r sender`). This contrasts with `transfer`
and `burn` which both forbid the zero-amount case as policy.
The bridge-admissibility layer is the one enforcing additional
preconditions if needed.

**Lex re-expression** (`Withdraw.lean:64-83`):
`lex_action_index 14`. Same NOT-monotonic NOT-conservative
classification as `burn`.

**Supply equation** (`totalSupply_after_withdraw`,
`Withdraw.lean:114-131`): stated additively (`post + amount =
pre`); same `withdraw_arithmetic` lift as `burn_arithmetic`.

**Cross-resource / cross-actor locality**
(`Withdraw.lean:137-188`): same structural shape.
`withdraw_other_actor_untouched` exists (mirrors
`deposit_other_actor_untouched`).

**`IsMonotonic` negated** (`withdraw_not_monotonic`,
`Withdraw.lean:196-227`): same fixture as `burn_not_monotonic`
(`s := setBalance genesisState r sender amount`).

**`IsConservative` negated** (`withdraw_not_conservative`,
`Withdraw.lean:232-240`): chained off `withdraw_not_monotonic`
via `monotonic_of_conservative` (low-priority instance,
invoked explicitly).

**`LocalTo` / `FreezePreserving`**: same structural shape.

**Sharp / brittle:**
- The zero-amount case is **not** forbidden by precondition.
  `withdraw r sender 0 recipient` would emit a withdrawal event
  with 0 transferred — bridge-layer logic should rule this out.
- The non-conservation proof short-circuits via
  `monotonic_of_conservative`. The CLAUDE.md global
  documentation mentions this instance is low-priority; the
  explicit invocation `exact monotonic_of_conservative` works
  because typeclass synthesis would otherwise need higher
  priority.

**Documentation drift:** None.

---

## 10. `LegalKernel/Laws/ReplaceKey.lean` (91 lines)

**Imports** (`ReplaceKey.lean:44-46`): `Laws.Freeze` (for
`freezeResource`) + `Authority.Crypto` (for `PublicKey`) + Lex.

**No hand-written `replaceKey` def** — the file is a Lex-only
declaration whose `lex_impl := fun s => s` produces a function
`legalkernel_replaceKey_transition` that is definitionally equal
to `Laws.freezeResource 0` (regression at
`ReplaceKey.lean:86-88` closes by `rfl`).

**Authority-layer effect**: registry mutation lives in
`applyActionToRegistry` (Phase 3 / WU 3.10), not in the
compiled `Transition`. The module docstring is explicit
(`ReplaceKey.lean:14-31`).

**`lex_satisfies`** (`ReplaceKey.lean:81-82`):
`[conservative, monotonic, «local», freeze_preserving,
nonce_advances]` — **omits `registry_preserving`** (correctly:
this law mutates the key registry).

**Sharp / brittle:** The kernel-level `Transition` for
`replaceKey` is the *zero-resource* freeze identity. Two
`replaceKey` actions with different `(actor, newKey)` parameters
are definitionally equal at the `Transition` level — only the
action-layer compilation + `applyActionToRegistry` distinguishes
them. This is the Phase 3 design.

**Documentation drift:** The audit reads the
`apply_admissible` reference at `ReplaceKey.lean:75` as the
correct routing point; this matches the kernel's two-tier
architecture.

---

## 11. `LegalKernel/Laws/RegisterIdentity.lean` (64 lines)

**Imports** (`RegisterIdentity.lean:28-30`): same as ReplaceKey.

**Structure**: identical to ReplaceKey but for the first-time
identity-registration constructor. `lex_signed_by` is
`bridge` (not `actor`) because the old key doesn't exist.
`lex_action_index 12`.

**`lex_satisfies`** (`RegisterIdentity.lean:54-55`):
`[conservative, monotonic, «local», freeze_preserving,
nonce_advances]` — **omits `registry_preserving`** (correctly:
mutates the key registry).

**Byte-equivalence regression**
(`RegisterIdentity.lean:59-61`): closes by `rfl`.

**Sharp / brittle:** Same as ReplaceKey. The bridge-actor
signing constraint is enforced via `bridgePolicy`
(`Bridge/BridgeActor.lean`); the Lex declaration only captures
the kernel-level shape.

**Documentation drift:** None.

---

## 12. `LegalKernel/Laws/Dispute.lean` (170 lines)

**Imports** (`Dispute.lean:32-34`): `Laws.Freeze` +
`Disputes.Types` + Lex.

**Four Lex declarations** with action indices 8 / 9 / 10 / 11:
- `dispute` (idx 8) — file a dispute, signed by challenger.
- `disputeWithdraw` (idx 9) — withdraw a filed dispute by log
  index, signed by challenger. Idempotent.
- `verdict` (idx 10) — apply a quorum-signed verdict, signed by
  adjudicator.
- `rollback` (idx 11) — rollback marker recording a
  runtime-applied verdict, signed by adjudicator.

Every one has `lex_pre := fun _ => True`, `lex_impl := fun s =>
s`, and `lex_satisfies := [conservative, monotonic, «local»,
freeze_preserving, nonce_advances, registry_preserving]` — i.e.
they trivially satisfy every kernel-level property because the
`apply_impl` is the identity.

The observable effect (verdict-driven rollback, dispute
filing) lives **outside** `apply_admissible` — in the
`LegalKernel/Disputes/*` modules. Module docstring is explicit
(`Dispute.lean:13-23`).

**Byte-equivalence regressions** at lines 75-77, 105-107,
135-137, 165-167 — all close by `rfl` to `Laws.freezeResource 0`.

**Sharp / brittle:** The `dispute` Lex declaration's
`lex_events := []` is a known M2 placeholder — comments at
`Dispute.lean:64-71` flag that the M3 events-block elaborator
should emit `Event.disputeFiled`, but this is currently
hard-coded in `actionEvents` in `Events/Extract.lean`. So this
metadata is informational rather than load-bearing for runtime
behaviour.

**Documentation drift:** None.

---

## 13. `LegalKernel/Laws/LocalPolicy.lean` (115 lines)

**Imports** (`LocalPolicy.lean:38-40`): `Laws.Freeze` +
`Authority.LocalPolicy` + Lex.

**Two Lex declarations** with action indices 15 / 16:
- `declareLocalPolicy` (idx 15) — signed by signer, mutates the
  `localPolicies` table via `applyActionToLocalPolicies` (LP.5).
- `revokeLocalPolicy` (idx 16) — same shape but for revocation.

Both have `lex_registry_effect localPolicy`, `lex_impl := fun s
=> s`, `lex_satisfies` including `registry_preserving`. The
comment at `LocalPolicy.lean:65-70` notes the subtle point:
**`registry_preserving` refers to the KEY registry**, not the
local-policy table. The `localPolicies` mutation is by-design
routed through `applyActionToLocalPolicies` (separate from
`applyActionToRegistry`), so the *KeyRegistry* is preserved
even though the local-policy table is mutated.

**Byte-equivalence regressions** at `LocalPolicy.lean:76-79` and
`LocalPolicy.lean:109-112` close by `rfl`. The `revokeLocalPolicy`
example has no parameters (the signer's identity determines who is
being revoked).

**Sharp / brittle:** The `registry_preserving` semantic
(preserves KeyRegistry; allows localPolicies mutation) is
subtle and codified via the `RegistryEffectKind.localPolicy`
variant in `Lex/Tools/Common.lean` (per LocalPolicy.lean's
docstring at `LocalPolicy.lean:21-30`). A reviewer should
verify that the codegen pipeline routes `localPolicy` effects
to `applyActionToLocalPolicies` and not to
`applyActionToRegistry`.

**Documentation drift:** None.

---

## Cross-cutting observations

### A. Which laws are in which conservation tier

- **Conservative (subset of §5.3 `total_supply_global` law set):**
  `transfer`, `freezeResource`, plus the six Lex-only
  identity-`apply_impl` laws (`replaceKey`, `registerIdentity`,
  four dispute variants, two local-policy variants). The
  identity-`apply_impl` laws are trivially conservative at the
  kernel level — but their *authority-level effects* (registry
  mutation, dispute pipeline, localPolicies mutation) are not
  tracked by `IsConservative`. A deployment using these still
  satisfies `total_supply_global` because that theorem only
  reasons about `State.balances`, not about `ExtendedState`.

- **Monotonic but not conservative**: `mint`, `reward`,
  `distributeOthers`, `proportionalDilute`, `deposit`.

- **Neither conservative nor monotonic**: `burn`, `withdraw`.

### B. Decidability

Every law uses `decPre := fun _ => inferInstance`. The most
complex precondition is `proportionalDilute`'s `totalReward > 0
∧ sumOthers s r excluded > 0`. `sumOthers` is computed via the
RBMap fold, so its decidability rests on `Std.TreeMap.foldl`
being computable — which it is. No hand-written `Decidable`
derivations, consistent with the §13.6 step 2 discipline in
CLAUDE.md.

### C. Std / RBMap lemma dependencies (cross-resource locality)

The cross-resource locality proofs in every law form a tight
recurring pattern that ultimately reduces to one or two
`RBMap.find?_insert_other` rewrites:

- `transfer_other_resource_untouched` — TWO
  `RBMap.find?_insert_other` (nested debit + credit).
- `mint_other_resource_untouched` — ONE
  `RBMap.find?_insert_other`.
- `burn_other_resource_untouched` — ONE
  `RBMap.find?_insert_other`.
- `reward_other_resource_untouched` — ONE
  `RBMap.find?_insert_other`.
- `deposit_other_resource_untouched` — ONE
  `RBMap.find?_insert_other`.
- `withdraw_other_resource_untouched` — ONE
  `RBMap.find?_insert_other`.
- `distributeOthers_other_resource_untouched` — n
  `RBMap.find?_insert_other` rewrites (one per foldl step),
  packaged via the private `foldl_setBalance_other_resource_untouched`
  helper.
- `proportionalDilute_other_resource_untouched` — same n-step
  pattern, generic over per-step function `f`.

For the **excluded-actor preservation** lemmas in
`distributeOthers` and `proportionalDilute`, the proofs use
`RBMap.find?_insert_self` + `RBMap.find?_insert_other` in a
generalised induction (`foldl_setBalance_excluded_untouched`
and `foldl_setBalance_at_r_excluded_untouched`).

### D. Conservation proofs all depend on `totalSupply_setBalance`

The §5.3 master accounting lemma — defined in
`Conservation.lean` — is the single load-bearing lemma:

- `transfer_conserves` — TWO instances chained via
  `transfer_arithmetic` + omega.
- `totalSupply_after_mint` — ONE instance + omega.
- `totalSupply_after_burn` — ONE instance via
  `burn_arithmetic` + omega.
- `totalSupply_after_reward` — ONE instance + omega.
- `totalSupply_after_deposit` — ONE instance + omega.
- `totalSupply_after_withdraw` — ONE instance via
  `withdraw_arithmetic` + omega.
- `foldl_setBalance_totalSupply` (DistributeOthers) — ONE
  instance *per fold step* via induction.
- `foldl_setBalance_proportional_totalSupply` (ProportionalDilute)
  — ONE instance per fold step via induction.

If `totalSupply_setBalance` were to change shape, every law's
supply equation would need to be re-proven. The
`*_arithmetic` private lemmas (Transfer / Burn / Withdraw) are
the documented workaround for omega's atom-discovery
limitation on deeply nested `TotalSupply (setBalance ...)`
expressions.

### E. The "swap 0 ↔ 1 trick"

Both `distributeOthers_not_conservative` and
`proportionalDilute_not_conservative` use the same fixture
pattern:
```
let non_excluded : ActorId := if excluded = 0 then 1 else 0
```
because `ActorId = UInt64` and `excluded + 1 ≠ excluded` does
not follow from `omega` (modular arithmetic). The proofs of
`h_neq : non_excluded ≠ excluded` are identical case-splits.
This pattern would be a candidate for a shared lemma in
Conservation.lean (`exists_distinct_actor` or similar) — at
present, it is duplicated.

### F. Lex / hand-written consistency

Every hand-written `Transition` has a corresponding `lexlaw`
declaration in the *same file*, with the kernel-level body
re-stated literally inside `lex_pre` / `lex_impl`. A
`example : legalkernel_<name>_transition ... = <name> ... :=
rfl` regression closes by definitional equality. If a future
edit modifies the hand-written form without also editing the
Lex form, the `rfl` regression will fail at elaboration time —
this is a strong forcing-function.

Action-index registry: 0 transfer, 1 mint, 2 burn, 3
freezeResource, 4 replaceKey, 5 reward, 6 distributeOthers, 7
proportionalDilute, 8 dispute, 9 disputeWithdraw, 10 verdict,
11 rollback, 12 registerIdentity, 13 deposit, 14 withdraw, 15
declareLocalPolicy, 16 revokeLocalPolicy. Frozen and
append-only per LX.1 / `Lex/IndexRegistry.txt`.

### G. Missing coverage

None observed for the formal classification claims. Some items
to flag for the record:

1. **`withdraw` permits `amount = 0`** — bridge-level
   authorisation must rule this out if the chain emits an event
   per legal withdrawal.
2. **`deposit` precondition is `True`** — replay protection is
   bridge-level only. This is the documented design but is the
   single hottest review surface for the bridge-stack.
3. **`distributeOthers` is a no-op at absent resources** —
   `pre := amount > 0` always holds; the foldl is trivial when
   the resource is absent. This is correctly tracked by the
   supply equation but is non-obvious.
4. **`proportionalDilute`'s `S` capture** — the fact that
   `sumOthers` is snapshotted before the foldl is what makes
   the dust bound work. A refactor that swapped `kv.2` for
   `getBalance s' r kv.1` would silently break the bound.
   The comment at `ProportionalDilute.lean:60-62` flags this
   subtly; an explicit security-review warning might be wise.

### H. Documentation discipline

Every law file follows the same docstring discipline:
- A module-level `/- ... -/` block naming the Genesis Plan
  section and listing theorem coverage.
- A definition-level `/-- ... -/` docstring for every
  `Transition`, theorem, instance.
- LX-M2 `lexlaw` blocks are uniformly preceded by
  `set_option linter.missingDocs false in` — necessary because
  the macro generates declarations the linter would otherwise
  flag.

No instance of identifier-level provenance leakage observed
(no `wu*`, `phase*`, `audit*`, etc. in `def` / `theorem` /
`instance` names). Process tags appear in docstrings only, per
the CLAUDE.md naming discipline.
