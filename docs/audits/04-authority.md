# Authority modules — `LegalKernel/Authority/*`

**Files audited (seven, ~3058 lines total):**

| File                                       | Lines | TCB? |
|--------------------------------------------|-------|------|
| `LegalKernel/Authority/Crypto.lean`        | 163   | No   |
| `LegalKernel/Authority/Action.lean`        | 570   | No   |
| `LegalKernel/Authority/Identity.lean`      | 320   | No   |
| `LegalKernel/Authority/Nonce.lean`         | 235   | No   |
| `LegalKernel/Authority/LocalPolicy.lean`   | 269   | No   |
| `LegalKernel/Authority/LocalPolicySemantics.lean` | 296 | No |
| `LegalKernel/Authority/SignedAction.lean`  | 1205  | No   |

None of these files are TCB-core (per `Tools.Common.tcbCoreFiles`,
TCB is just `Kernel.lean` + `RBMapLemmas.lean`).  Bugs here can
weaken deployment-level authority claims (replay protection,
authorisation), but cannot violate any kernel invariant.

The §8.2 trust path: the kernel's `apply_admissible` accepts a
`SignedAction` only with an `Admissible` witness; the construction
of that witness on the runtime side rests on EUF-CMA security of
the `Verify` opaque (`Crypto.lean:138`) and collision-resistance of
`hashBytes` (cited only indirectly here, through `signingInput`'s
CBE-encoded payload).

---

## `LegalKernel/Authority/Crypto.lean` (163 lines)

### Imports

None — pure Lean core types only.  This is the right posture for
a primitive interface module.

### Public surface

* `PublicKey : Type := ByteArray` (line 52) — `abbrev`.  Keeps the
  kernel scheme-agnostic.
* `Signature : Type := ByteArray` (line 56).  Same comments.
* `instance : Repr PublicKey` (lines 62–64) — emits the string
  `"PublicKey:bytes(N)"` where `N` is the byte length.  Does NOT
  emit content bytes; a `deriving Repr` on `Action` would otherwise
  pull in `ByteArray.toString` (which Lean core does not ship).
  **Finding (minor):** the chosen representation loses content, so
  test-failure messages cannot disambiguate two distinct keys of
  the same length.  Acceptable for an opaque type.
* `instance : DecidableEq PublicKey` (lines 70–74) — defined via
  `inferInstanceAs (Decidable (b₁ = b₂))`.  Workaround for the
  Lean elaborator sometimes losing `ByteArray.DecidableEq` through
  the `abbrev` indirection.
* `Nonce : Type := Nat` (line 85) — `abbrev`.  Unbounded `Nat`
  rather than `UInt64`; overflow absence is a theorem.
* `opaque Verify (pk : PublicKey) (msg : ByteArray) (sig : Signature) : Bool` (line 138).
  Placeholder body returns `false`.
* `SigningInput : Type := ByteArray` (line 160) — `abbrev`.

### Sharp points

1. `Verify` is `opaque`, not `axiom`.  The module docstring states
   this is so that `#print axioms` of theorems that reach `Verify`
   does NOT pick up a custom axiom.  Verified: an opaque adds to
   the *opaque dependencies* of a term but not the axiom set
   (`Crypto.lean:111–119`).
2. The "Determinism" bullet in the section docstring at line 100
   says "automatic since `Verify` is a Lean `axiom`" — but the
   declaration is `opaque`, not `axiom`.  Determinism is in fact
   inherited from `opaque`'s well-definedness as a pure
   declaration.  **Minor doc drift** (line 16 also says "Lean
   `axiom`"; lines 91, 99–102 say `opaque`).  The implementation
   uses `opaque`.  Not a correctness issue.
3. `Verify`'s placeholder body `false` is documented as never used
   in deployment because the runtime adaptor rewires the symbol;
   at the Lean level `Verify pk msg sig` does NOT reduce.  This is
   essential for test code that wants to construct admissibility
   witnesses — see `AdmissibleWith` in `SignedAction.lean:290`.

---

## `LegalKernel/Authority/Action.lean` (570 lines)

### Imports

`LegalKernel.Kernel`, `LegalKernel.Conservation`, every law module
(`Transfer`, `Mint`, `Burn`, `Freeze`, `Reward`, `DistributeOthers`,
`ProportionalDilute`, `Deposit`, `Withdraw`), `Crypto`,
`LocalPolicy`, `Bridge.AddressBook`, `Bridge.State`, `Disputes.Types`.
This is a heavy import set but reasonable: `Action`'s constructors
each need the corresponding law's `Transition` to compile against,
plus the bridge / dispute / local-policy types used as constructor
parameters.  No Mathlib / batteries.

The `Action.compileTransition` total-coverage requirement is the
forcing function for this import surface: every `Action` constructor
must reduce to a known `Transition`.

### Public surface

* `inductive Action` (lines 131–321) — nineteen constructors:
  1. `transfer r s r' a`
  2. `mint r to a`
  3. `burn r fr a`
  4. `freezeResource r`
  5. `replaceKey actor newKey`
  6. `reward r to a`
  7. `distributeOthers r e a`
  8. `proportionalDilute r e tr`
  9. `dispute d`
  10. `disputeWithdraw idx`
  11. `verdict v`
  12. `rollback targetIdx`
  13. `registerIdentity actor pk`
  14. `deposit r recipient amount depositId`
  15. `withdraw r sender amount recipientL1`
  16. `declareLocalPolicy policy`
  17. `revokeLocalPolicy`
  18. `faultProofChallenge bindingHash startIdx endIdx commit`
  19. `faultProofResolution bindingHash gameId winner revertFromIdx`

  (A reserved Lex sentinel-marker region sits between the
  hand-written constructors and the `deriving` line; it is a
  comment fence, not a 20th constructor, and is empty in M1.)

  `deriving Repr, DecidableEq` at line 321.  The "Append-only
  constructor discipline" docstring at line 119 is enforced *only*
  by review discipline plus the LP.2 codec's tag-dispatch failing
  at build time.  No mechanical check at this file's level.

* `def Action.compileTransition : Action → Transition` (line 345)
  — total pattern match across all 19 constructors.  Notable choices:
  - `replaceKey`, `registerIdentity`, all four dispute-pipeline
    actions, both local-policy meta-actions, and both fault-proof
    actions all compile to `Laws.freezeResource 0` (an identity on
    `State.balances`).  This is the load-bearing design choice: the
    authority-layer effect (registry mutation, dispute filing, etc.)
    lives in `apply_admissible`, not in the kernel transition.

* `structure CompiledAction` (lines 403–410) — `(source : Action,
  transition : Transition)` pair.  Carries the originating `Action`
  so that compile-injectivity is a one-line `congrArg`.

* `def Action.compile (a : Action) : CompiledAction` (line 419) —
  the `(a, compileTransition a)` pair.

* `theorem Action.compile_injective : Function.Injective Action.compile`
  (line 454) — one-line `congrArg CompiledAction.source h`.  No
  hidden case analysis; no decidability dependency.

* `theorem Action.compile_eq_iff` (line 460) — `compile` is an
  `Iff` on equality.

* `theorem Action.compile_ne_of_ne` (line 468) — contrapositive.

* `def CompiledAction.kernelTransition` (line 477) — projector.
  Marked `@[inline]`.

* `def Action.pre`, `instance Action.decPre`, `def Action.apply_impl`
  (lines 482–493) — three one-liners that lift the underlying
  `Transition`'s precondition / decidability / state-mutator to the
  `Action` layer.  All `@[inline]`.

* Lines 502–567: nineteen `example` smoke-checks, one per
  constructor, confirming `(Action.compile c).source = c` for each
  constructor shape by `rfl`.  Elaboration-time guard against a
  hypothetical refactor that drops the `source` field.

### Sharp points

1. **Non-injectivity at the `compileTransition` level is by design**
   (docstring `Action.lean:339–344`).  Multiple `Action`
   constructors collapse to identical `Transition` values
   (`Laws.freezeResource 0` covers eight constructors).  Anyone
   reasoning about "two distinct admissible signed actions cannot
   produce the same on-chain state mutation" at the
   `Transition` level alone is mistaken; the `CompiledAction.source`
   field is what carries the distinction.
2. **Constructor-index freezing is unenforced at this file's level.**
   The "append-only" rule is documented (lines 119–126) but no
   mechanical check fails if a reviewer reorders constructors.
   The downstream LP.2 codec's tag-dispatch and `Action.tag`
   projection (in `LocalPolicySemantics.lean:64`) would silently
   misalign with `Encoding/Action.lean`'s inductive-index-based
   encoder, which would then silently re-tag deployed actions.
   Mitigation: there are smoke checks (`LocalPolicySemantics.lean:281–293`)
   that pin specific tags (transfer = 0, withdraw = 14,
   declareLocalPolicy = 15, revokeLocalPolicy = 16) but only at
   four indices, not all 19.
3. **Lex sentinel regions** (lines 319–320, 389–390) contain only
   comments; M1 doesn't add any Lex-generated constructors.  When
   M2+ lands a Lex-generated constructor, the comment fence is the
   *only* mechanism keeping the codegen out of the hand-edited
   region.  No syntactic guard.
4. **Import cycle avoidance** is non-obvious: `Action.lean` imports
   `LocalPolicy.lean` for the `LocalPolicy` type that the
   `declareLocalPolicy` constructor carries; the semantic
   `LocalPolicy.permits` predicate lives in
   `LocalPolicySemantics.lean` which imports `Action.lean`.  This
   split is documented in `LocalPolicySemantics.lean:20–24`.
5. **Linter pressure.**  Module documents 19 `example`s and an
   `inductive` with `Repr, DecidableEq`; with `autoImplicit := false`
   and `linter.missingDocs := true`, every constructor needs a
   `/-- ... -/` docstring.  Verified: every constructor has one.

---

## `LegalKernel/Authority/Identity.lean` (320 lines)

### Imports

`Kernel`, `RBMapLemmas`, `Authority.Crypto`, `Authority.Action`.
The dependency on `Action` is necessary because `AuthorityPolicy.authorized`
has type `ActorId → Action → Prop`.

### Public surface

* `structure Identity { id : ActorId, key : PublicKey }` (line 58)
  — `deriving Repr`.  Note: NOT `DecidableEq`; no caller needs it.
* `abbrev KeyRegistry : Type := TreeMap ActorId PublicKey compare`
  (line 72).
* `KeyRegistry.empty`, `register`, `revoke`, `lookup` (lines 75–91)
  — thin wrappers over `TreeMap.empty / insert / erase / find?`.

#### Semantic lemmas (lines 102–129)

* `lookup_register_self` (line 102) — `congrArg`-free; closes via
  `RBMap.find?_insert_self` (an alias from `RBMapLemmas`).
* `lookup_register_other` (line 108) — analogously uses
  `RBMap.find?_insert_other`.  Both rely on `LawfulEqCmp.eq_of_compare`
  for `compare`-derived inequality.
* `lookup_revoke_self` (line 116) — proof uses
  `TreeMap.getElem?_erase_self` directly.
* `lookup_revoke_other` (line 123) — has a `compare id₁ id₂ ≠ .eq`
  derivation via `LawfulEqCmp.eq_of_compare`.  This pattern recurs
  in `LocalPolicy.lookup_revoke_other` — both reach `simp [this]`.

* `def KeyRegistry.mergeLeftBiased` (line 141) — left-biased merge
  via `kr₂.foldl (fun acc k v => if acc.contains k then acc else
  acc.insert k v) kr₁`.  No theorems about it are proved in this
  file (callers operate on it only by `foldl`).  **Sharp point:**
  this combinator is intended to mirror Genesis-Plan §8.2's
  `RBMap.mergeLeftBiased`; correctness is asserted by docstring
  only.  There is no test that, e.g., `mergeLeftBiased a b ≠
  mergeLeftBiased b a` in general.

#### `AuthorityPolicy` (lines 156–222)

* `structure AuthorityPolicy { authorized, decAuth }` (line 156).
  `decAuth` is a per-input `Decidable` *witness*, not a typeclass
  instance — but is re-exposed as `instance` at line 167–169.
* Six combinators: `empty`, `unrestricted`, `union`, `intersect`,
  `singleton`.  Each uses an explicit `@instDecidableOr / @instDecidableAnd`
  call to wire `decAuth` together.
* `singleton`'s `decAuth` uses `decEq a a₀ ∧ decEq act act₀`, which
  requires `DecidableEq Action` — satisfied by `Action`'s
  `deriving DecidableEq`.

#### Combinator semantics (lines 231–287)

Six `Iff.rfl`-proved lemmas: `empty_authorized`, `unrestricted_authorized`,
`union_authorized`, `intersect_authorized`, `singleton_authorized`,
plus algebraic `union_comm`, `union_empty`, `intersect_unrestricted`.

The non-`Iff.rfl` ones (`union_comm` at line 266, `union_empty` at line 274,
`intersect_unrestricted` at line 282) all close via `unfold` + `simp`
or `unfold` + `Or.comm`.  No decidability hazards.

#### Smoke checks (lines 289–317)

Five `example`s.  The last two unfold `KeyRegistry.empty`,
`KeyRegistry.register`, `KeyRegistry.lookup` and discharge via the
RB-map insert lemmas.  These confirm the wiring of the alias
`abbrev`-defined types to the TreeMap implementation.

### Sharp points

1. **`AuthorityPolicy` is intentionally state-independent**
   (`authorized : ActorId → Action → Prop`).  State-dependent
   authorisation must live in the law's precondition.  This split
   is what allows admissibility's static portion to be cached.
2. **`mergeLeftBiased`** has no semantic lemmas in this file.  Not
   a correctness issue — no theorem in `SignedAction.lean` calls
   it — but the combinator is exported and a deployment can wire
   it into `ExtendedState.empty`-derived constructions.  No
   `mergeLeftBiased_emptyc` / `mergeLeftBiased_emptyc_left` lemmas
   exist; a deployment that needs them must prove them.
3. **`union_comm` is up-to-iff, not strict equality.**  The
   docstring (lines 264–265) flags this explicitly.  Two
   `AuthorityPolicy` values can have logically-equivalent
   `authorized` predicates but distinct `decAuth` witnesses; in
   `Lean, `AuthorityPolicy.union P₁ P₂ ≠ AuthorityPolicy.union P₂ P₁`
   under intensional equality, but the *behaviour* is symmetric.
4. **`instance` redefinition for `decAuth`** (line 167) is a
   convenience instance; it can shadow the `decAuth` field of a
   given `AuthorityPolicy` in unrelated elaboration contexts.  No
   correctness issue noted.

---

## `LegalKernel/Authority/Nonce.lean` (235 lines)

### Imports

`Kernel`, `RBMapLemmas`, `Authority.Crypto`, `Authority.Identity`,
`Authority.LocalPolicy`, `Bridge.State`.  The `LocalPolicy` import
is because `ExtendedState` carries a `LocalPolicies` field (LP.3);
the `Bridge.State` import is because it also carries a
`BridgeState` field (Workstream C.1.2).  Both are *defaulted*
fields, so the dependency is structural-only.

### Public surface

* `structure NonceState { next : TreeMap ActorId Nonce compare }`
  (line 68) — `deriving Repr`.  Wrapper around the underlying
  TreeMap so callers can refer to "the nonce ledger" by structure.
* `NonceState.empty` (line 74) — `{ next := ∅ }`.

* `structure ExtendedState` (lines 98–141) — five fields:
  - `base : State` (kernel state)
  - `nonces : NonceState`
  - `registry : KeyRegistry`
  - `bridge : Bridge.BridgeState := Bridge.BridgeState.empty` (defaulted)
  - `localPolicies : LocalPolicies := LocalPolicies.empty` (defaulted)

  `deriving Repr`.  The two defaulted fields are documented as
  additive / backwards-compatible extensions — pre-bridge /
  pre-LP `ExtendedState` literals still elaborate.

* `ExtendedState.empty` (line 148) — explicit construction of the
  genesis state with empty everything.

* `def expectsNonce (es : ExtendedState) (a : ActorId) : Nonce`
  (line 160) — `(es.nonces.next[a]?.getD 0)`.  Missing entries
  default to 0.

* `def advanceNonce (es : ExtendedState) (a : ActorId) : ExtendedState`
  (line 165) — increments the signer's slot by 1 via
  `{ es with nonces := { next := es.nonces.next.insert a (expectsNonce es a + 1) } }`.

### Theorems (lines 178–233)

* `expectsNonce_strict_mono` (line 178) — closes via `show … = …` rewrite
  to expose the underlying TreeMap insert, then `RBMap.find?_insert_self`,
  then `rfl`.  No tactic gymnastics.  Headline §8.5 theorem.

* `expectsNonce_advance_other` (line 187) — analogous, uses
  `RBMap.find?_insert_other`.

* `advanceNonce_base` (line 197) — pure `rfl`.
* `advanceNonce_registry` (line 202) — pure `rfl`.

* `expectsNonce_after_advance_gt_old` (line 212) — uses
  `Nat.lt_succ_self`.  Strict inequality `expectsNonce (advanceNonce
  es a) a > expectsNonce es a`.

* `expectsNonce_after_advance_ne_old` (line 223) — the
  one-step-ahead corollary: for any `n ≤ expectsNonce es a`,
  `expectsNonce (advanceNonce es a) a ≠ n`.  Closes via
  `Nat.not_succ_le_self`.  This is the algebraic core of
  `replay_impossible`.

### Sharp points

1. **Unbounded `Nat` for nonce** is deliberate (line 20).  At the
   Lean level there is no overflow; at the runtime / encoding
   boundary, Phase 4's CBE encoding marshals `Nat → UInt64`.
   Anyone proving "no replay" at the Lean level gets unconditional
   coverage; anyone running the runtime encoder past 2^64 actions
   per actor would (in principle) hit the marshalling bound.  Not
   exercised in the current test suite.
2. **`ExtendedState` defaulted fields** (lines 127, 140) preserve
   backwards compatibility of literal construction but slightly
   weaken type-level discipline: a forgotten field assignment in
   a deployment fixture silently becomes the empty default.  The
   `bridge` field's default is documented at length; the
   `localPolicies` default is similarly safe (empty policy =
   unrestricted = back-compat).
3. **`advanceNonce` does not touch `localPolicies` or `bridge`**,
   only `nonces`.  This is essential for the
   `expectsNonce_after_apply_admissible_other` proof in
   `SignedAction.lean:604` — both fields are preserved by structure
   eta, so the proof reduces to the `advanceNonce` case alone.

---

## `LegalKernel/Authority/LocalPolicy.lean` (269 lines)

### Imports

`Kernel`, `RBMapLemmas`.  Pure data layer; no `Action` dependency
(documented; LP.1 split rationale).

### Public surface

#### Bounds (lines 83–97)

Four `Nat` constants:
* `MAX_CLAUSES_PER_POLICY := 64` (line 83)
* `MAX_TAGS_PER_DENY := 64` (line 86)
* `MAX_RECIPIENTS_PER_REQUIRE := 64` (line 89)
* `MAX_POLICY_ENCODE_BYTES := 16_384` (line 97)

These are *single source of truth* for the LP DoS bounds; the LP.2
encoder enforces them at decode time.  Not enforced at this file's
type level (a `LocalPolicy` value with 65 clauses elaborates fine
in this module).

#### Data types (lines 122–157)

* `inductive LocalPolicyClause` (line 122) — three constructors:
  1. `denyTags (tags : List Nat)`
  2. `requireRecipientIn (resource : ResourceId) (allowed : List ActorId)`
  3. `capAmount (resource : ResourceId) (max : Amount)`

  `deriving Repr, DecidableEq` (line 141).  Append-only ctor index
  discipline is documented (line 41–48) and enforced *only* by
  LP.2 codec's tag-dispatch.

* `structure LocalPolicy { clauses : List LocalPolicyClause }`
  (line 151) — `deriving Repr, DecidableEq`.
* `LocalPolicy.empty := { clauses := [] }` (line 157).

#### Table type (lines 173–193)

* `abbrev LocalPolicies := TreeMap ActorId LocalPolicy compare`.
* `LocalPolicies.empty := ∅`.
* `lookup` defaults missing entries to `LocalPolicy.empty`.
* `declare` and `revoke` wrap `insert / erase`.

#### Semantic lemmas (lines 205–249)

Inside `namespace LocalPolicies`:
* `lookup_declare_self` (line 205) — `unfold` + `RBMap.find?_insert_self`
  + `rfl`.
* `lookup_declare_other` (line 213) — analogous with `_insert_other`.
* `lookup_revoke_self` (line 223) — `show` + `TreeMap.getElem?_erase_self`
  + `rfl`.
* `lookup_revoke_other` (line 232) — uses `TreeMap.getElem?_erase`
  with `compare a₁ a₂ ≠ .eq` discharge via `LawfulEqCmp.eq_of_compare`.
  Same shape as `Identity.lean:123`.
* `empty_lookup` (line 244) — `show` + `TreeMap.getElem?_emptyc`
  + `rfl`.

#### Smoke checks (lines 256–267)

Three `example`s exercising empty-policy lookup, empty-policy clause
list, and structural distinction from a non-empty policy.

### Sharp points

1. **The DoS bound constants are not used at this file's type
   level.**  They exist for documentation + downstream codec
   consumption only.  A deployment that constructs a 100-clause
   `LocalPolicy` directly (not via the decoder) would type-check
   here but fail at the LP.2 encode step.
2. **`LocalPolicyClause`'s ctors take `List Nat` / `List ActorId`**
   — both potentially unbounded.  At the type level a clause can
   carry an arbitrarily large `tags` or `allowed` list.  Bounds
   live in the encoder.  This is consistent with the codebase's
   "decode-time enforcement" pattern.
3. **`LocalPolicies.empty := ∅`** (line 177) uses the implicit
   `Std.TreeMap.empty` via the `EmptyCollection` typeclass.  No
   ordering or hashing implications — `compare : ActorId → ActorId
   → Ordering` is supplied by the type alias.
4. **`deriving DecidableEq` on `LocalPolicy`** requires `DecidableEq`
   on `List LocalPolicyClause` which in turn requires it on the
   clause inductive; both are derivable because the clause fields
   are `List Nat`, `List ActorId`, `ResourceId`, `Amount`, all of
   which have `DecidableEq`.

---

## `LegalKernel/Authority/LocalPolicySemantics.lean` (296 lines)

### Imports

`Authority.Action`, `Authority.LocalPolicy`.  The split is documented
in the module header.

### Public surface

* `def Action.tag : Action → Nat` (line 64) — 19-case pattern match
  assigning constructor-index integers 0..18.  **Sharp point:**
  this projection is *parallel* to (not derived from) the inductive
  index used by `LegalKernel/Encoding/Action.lean` and by LP.2's
  CBE codec.  If a contributor reorders `Action` constructors, the
  two parallel mappings will silently diverge until a downstream
  smoke check at `LocalPolicySemantics.lean:281–293` (or LP.4's
  `tag_matches_encode_tag`) fires at build time.  There is no
  *single-source-of-truth* mechanism here — only mechanical CI checks.

* `def LocalPolicyClause.permits (_signer : ActorId) (action : Action) : LocalPolicyClause → Prop`
  (line 110) — three branches:
  - `denyTags tags` ⇒ `Action.tag action ∉ tags`
  - `requireRecipientIn r allowed` ⇒ inner-`match action` with
    four positive arms (transfer, mint, reward, deposit) and a
    catch-all `True`.
  - `capAmount r max` ⇒ inner-`match action` with seven positive
    arms (transfer, mint, burn, reward, distributeOthers, deposit,
    withdraw) and a catch-all `True`.

* `instance instDecidableLocalPolicyClausePermits` (line 134) —
  three-way case-split:
  - `denyTags`: reduces to `Action.tag action ∉ tags`, dispatched
    by `inferInstance` (`Nat ∉ List Nat` is decidable).
  - `requireRecipientIn`: case-splits on the action and invokes
    `infer_instance` per case; each arm is either `True` (vacuous
    catch-all) or `r' ≠ r ∨ field ∈ allowed`.
  - `capAmount`: analogous.

  **Sharp point:** `cases action <;> infer_instance` works only
  because every `Action` constructor's arm reduces to either a
  decidable disjunction or `True`.  Adding an `Action` constructor
  that breaks this would silently regress to a non-decidable
  instance — but only if the new constructor's arm uses
  non-decidable shape (e.g. an unbounded quantifier).  No such
  constructor exists today.

* `def LocalPolicy.permits` (line 217) — `∀ c ∈ p.clauses, c.permits
  signer action`.
* `instance instDecidableLocalPolicyPermitsList` (line 223) — via
  `List.decidableBAll` (Std).  This is *the* decidability hazard
  to watch: `decidableBAll` is `O(|clauses|)` worth of decidability
  resolution.  Combined with the `permits` per-clause cost and the
  `MAX_CLAUSES_PER_POLICY := 64` deployment bound, this is bounded.

#### Per-clause semantic theorems (lines 157–207)

Six lemmas all proved by `Iff.rfl`:
* `denyTags_permits_iff`
* `requireRecipientIn_permits_transfer`
* `requireRecipientIn_permits_freezeResource`
* `capAmount_permits_transfer`
* `capAmount_permits_freezeResource`
* `capAmount_permits_proportionalDilute`

All directly check the reduction shape of the `match action with`
branches; the choice of *which* constructors to enumerate
explicitly is partial.  Notable omission: there's no
`requireRecipientIn_permits_burn`, `_mint`, `_withdraw`, etc.
The lemmas here are spot-checks; downstream callers needing
"requireRecipientIn permits a `mint`" must unfold manually.

#### Whole-policy theorems (lines 233–246)

* `empty_permits_all` (line 233) — `unfold` + `intro _ h` + `cases h`.
  Vacuous over the empty list.
* `permits_extends_to_clauses` (line 243) — `Iff.rfl` exposing
  the definition.

#### Smoke checks (lines 257–293)

Five `example`s.  The `decide` at line 277 exercises the
`Decidable` instance to confirm `0 ∉ [1]` reduces.  Lines 281–293
pin specific `Action.tag` values: `transfer = 0`, `withdraw = 14`,
`declareLocalPolicy = 15`, `revokeLocalPolicy = 16`.

### Sharp points

1. **`Action.tag` enumeration risk.**  The 19-case pattern match
   is parallel to (and must agree with) `Encoding/Action.lean`'s
   CBE encoder's tag assignment.  If a future Lex codegen pass or
   manual edit reorders any `Action` constructor, both mappings
   need to update; only four are pinned with smoke checks here
   (transfer = 0, withdraw = 14, declareLocalPolicy = 15,
   revokeLocalPolicy = 16).  Indices 1..13, 17, 18 are unpinned.
2. **The `_signer` argument is unused** (line 111).  Documented as
   intentional: future clauses (e.g. `requireSelfSigned`) will
   read it; the parameter is in the signature to avoid a
   type-level break later.
3. **`capAmount` deliberately skips `proportionalDilute`** (line 198):
   `proportionalDilute`'s `totalReward` is a *pool*, not an
   individual amount.  Capping it requires a distinct clause
   variant.  Documented; not a bug.
4. **The `denyTags` clause does NOT consult `Action.tag`'s correctness
   directly** — it just checks `Action.tag action ∉ tags`.  A
   deployment that uses `denyTags` with stale indices (set before
   a constructor reorder) will deny the wrong actions.  No
   sentinel value or version field on `denyTags`.

---

## `LegalKernel/Authority/SignedAction.lean` (1205 lines)

### Imports

`Kernel`, `Authority.Crypto`, `Authority.Action`, `Authority.Identity`,
`Authority.LocalPolicy`, `Authority.LocalPolicySemantics`,
`Authority.Nonce`, `Encoding.Action`.  Pulls in CBE encoding via
`Encoding.Action` (for `Encodable.encode` on `Action`), plus all
of Authority.  No Mathlib / batteries.

### Public surface

#### `SignedAction` (lines 74–88)

`structure SignedAction { action, signer, nonce, sig }` with
`deriving Repr` (line 88).  Does NOT `deriving DecidableEq` — but
all fields are decidable-eq-able (`Action`, `ActorId`, `Nat`,
`ByteArray`), so deployments can derive it locally.

#### Signing-input encoding (lines 131–183)

* `def signedActionDomain : String := "legalkernel/v1/signedaction"`
  (line 139).  **Sharp point:** *also* defined at
  `Encoding/SignInput.lean:63` with the same value.  The two are
  separate string literals, not a single shared constant.  If a
  refactor changes one and not the other, the kernel's
  admissibility-check `signingInput` (which uses this file's
  domain) and the Phase-4 `Encoding.signInput` (which uses
  `Encoding/SignInput.lean`'s) will produce different bytes for
  the same `(action, signer, nonce, deploymentId)` tuple — a
  silent cross-stack divergence.  No automated equality check.

* `def signingInput (action signer nonce deploymentId) : SigningInput`
  (line 171).  Layout: CBE-encoded domain prefix
  (`cborHeadEncode cbeTagBytes len ++ utf8`) ++ `Encodable.encode
  deploymentId` ++ `Encodable.encode action` ++ `Encodable.encode
  signer.toNat` ++ `Encodable.encode nonce`.  Result is a
  `ByteArray`.  The header docstring at line 121–129 acknowledges
  that an earlier revision shipped a `ByteArray.empty` stub here.

#### Admissibility predicates (lines 238–311)

* `def isMetaPolicyAction : Action → Bool` (line 238) — `true` for
  the two LP-meta constructors, `false` otherwise.  Two-line
  inductive recursion.
* `def localPolicyPermits (es signer action) : Prop` (line 259):
  `isMetaPolicyAction action = true ∨
   (es.localPolicies.lookup signer).permits signer action`.
* `instance instDecidableLocalPolicyPermits` (line 271) — closes
  via `unfold + inferInstance`.

* `def AdmissibleWith (verify P d es st) : Prop` (line 290) — the
  five (six, post-LP.7) §8.2 conjuncts in this order:
  1. `P.authorized st.signer st.action`
  2. `st.nonce = expectsNonce es st.signer`
  3. `∃ pk, es.registry[st.signer]? = some pk ∧ verify pk msg sig = true`
  4. `(Action.compile st.action).transition.pre es.base`
  5. `localPolicyPermits es st.signer st.action`

  (Conditions 1 + 3 from the Genesis-Plan numbering are *packed*
  into the third conjunct here — see lines 207–217.)

* `def Admissible := AdmissibleWith Verify P ByteArray.empty`
  (line 326) — back-compat alias.

#### Field extractors (lines 343–432)

Six theorems: `admissible_authorized`, `admissible_nonce`,
`admissible_signer_registered_and_signed`, `admissibleWith_signer_registered_and_signed`,
`admissible_pre`, `admissible_localPolicy`,
`admissibleWith_localPolicy`, `admissible_signer_registered`.  All
proved by `obtain ⟨ ... ⟩ := h; exact ...` — pure tuple-destructuring.
The header docstring at line 339–342 flags that this pattern is
LP.7-robust (`obtain` survives the addition of a new conjunct).

#### Authority-layer effects (lines 465–508)

* `def applyActionToRegistry : KeyRegistry → Action → KeyRegistry`
  (line 465) — two positive arms (`replaceKey`, `registerIdentity`)
  and a catch-all.  Lex-sentinel region at 473–474 (empty in M1).
* `def applyActionToLocalPolicies : LocalPolicies → ActorId → Action → LocalPolicies`
  (line 504) — two positive arms (`declareLocalPolicy`,
  `revokeLocalPolicy`) using the signer's `ActorId`, plus a
  catch-all.

#### `apply_admissible` (lines 536–570)

* `def apply_admissible_with` (line 536) — five-step body:
  1. `let t := (Action.compile st.action).transition`
  2. `let s' := t.apply_impl es.base`
  3. `let es' := { es with base := s' }`
  4. `let es'' := advanceNonce es' st.signer`
  5. `let es''' := { es'' with registry := applyActionToRegistry es''.registry st.action }`
  6. Final: `{ es''' with localPolicies := applyActionToLocalPolicies es'''.localPolicies st.signer st.action }`

  The `Admissible` witness is consumed as `_h` (unused) — just
  forces the call site to discharge admissibility.

* `def apply_admissible` (line 566) — `apply_admissible_with Verify
  ByteArray.empty`.

#### Properties (lines 582–720)

* `apply_admissible_base` (line 582) — `rfl`.
* `apply_admissible_registry` (line 592) — `rfl`.
* `expectsNonce_after_apply_admissible_other` (line 604) — closes
  via `unfold` + `show` rewriting + `expectsNonce_advance_other`
  + `rfl`.  Cross-actor isolation.
* `expectsNonce_after_apply_admissible` (line 623) — closes via
  `unfold` + `show` rewriting + `expectsNonce_strict_mono` + `rfl`.

* `admissible_nonce_eq` (line 651) — alias for `admissible_nonce`
  in the older arity-explicit form.

#### Headline replay-protection theorems (lines 664–703)

* `theorem nonce_uniqueness` (line 664) — three-line proof:
  extract both nonces via `admissible_nonce_eq`, rewrite with
  `hsame`, conclude by `.trans`.  No decidability hazard, no axiom
  reach.

* `theorem replay_impossible` (line 686) — six-line proof:
  1. `h_post := expectsNonce_after_apply_admissible P es st h`
  2. `h_eq := admissible_nonce_eq … h'` (post-state nonce match)
  3. `h_pre := admissible_nonce_eq P es st h`
  4. `rw [h_post, ← h_pre] at h_eq` to get `st.nonce = st.nonce + 1`
  5. `exact absurd h_eq (Nat.ne_of_lt (Nat.lt_succ_self _))`

  No `decide`, no classical reach.  Uses only Std `Nat` lemmas
  (`lt_succ_self`, `ne_of_lt`).  **Soundness depends on**
  `admissible_nonce_eq` correctly extracting the nonce-match
  conjunct (verified by inspection of `Admissible`'s structure)
  and on `expectsNonce_after_apply_admissible` being correct
  (depends on `expectsNonce_strict_mono`, a 4-line proof in
  `Nonce.lean:178` going through `RBMap.find?_insert_self`).

#### Registry-update theorems (lines 728–858)

* `replaceKey_updates_registry` (line 728) — `unfold +` show + `RBMap.find?_insert_self`.
* `non_registry_mutating_preserves_registry` (line 752) — case-split
  over 19 action constructors; `replaceKey` and `registerIdentity`
  arms discharged via `absurd hact (hneReplace …)` / `(hneRegister …)`;
  all other arms close by `rfl`.  Lex sentinel at 788–789.
* `non_replaceKey_preserves_registry` (line 797) — back-compat
  alias for the above.
* `replaceKey_other_actor_untouched` (line 808) — uses
  `RBMap.find?_insert_other`.
* `registerIdentity_updates_registry` (line 829) — mirrors
  `replaceKey_updates_registry`.
* `registerIdentity_other_actor_untouched` (line 846) — mirrors
  `replaceKey_other_actor_untouched`.

#### LP.7 headline theorems (lines 882–923)

* `localPolicy_meta_action_independent` (line 894) — closes by
  `Iff.intro (fun _ => Or.inl h_meta) (fun _ => Or.inl h_meta)`.
  Structural lockout-prevention: for meta-actions, the `permits`
  iff collapses to "is meta", independent of which `LocalPolicies`
  table is plugged in.  **Headline of LP.7.**
* `localPolicyPermits_no_policy` (line 911) — discharge via
  `unfold + rw + simp + Or.inr (LocalPolicy.empty_permits_all …)`.

#### Local-policy mutation theorems (lines 935–1048)

Five theorems mirroring the WU 3.10 family for the `localPolicies`
field:
* `declareLocalPolicy_updates_localPolicies` (line 935) — uses
  `LocalPolicies.lookup_declare_self`.
* `revokeLocalPolicy_clears_localPolicies` (line 953) — uses
  `LocalPolicies.lookup_revoke_self`.
* `non_meta_preserves_localPolicies` (line 969) — 19-way case
  split.
* `localPolicies_other_actor_untouched` (line 1002) — 19-way case
  split.  The `declareLocalPolicy` arm closes via
  `LocalPolicies.lookup_declare_other`; `revokeLocalPolicy` arm via
  `lookup_revoke_other`.
* `apply_admissible_localPolicies` (line 1044) — `rfl` projection.

#### `RegistryPreserving` typeclass + 17 instances (lines 1087–1202)

* `class RegistryPreserving (a : Action) : Prop` (line 1087) — single
  field `preserves : ∀ kr, applyActionToRegistry kr a = kr`.
* Instances for the 17 non-`replaceKey` non-`registerIdentity`
  constructors (transfer, mint, burn, freezeResource, reward,
  distributeOthers, proportionalDilute, dispute, disputeWithdraw,
  verdict, rollback, deposit, withdraw, declareLocalPolicy,
  revokeLocalPolicy, faultProofChallenge, faultProofResolution).
  Each proves `preserves := fun _ => rfl`.

  The "deliberate absences" (`replaceKey`, `registerIdentity`) are
  documented at line 1081–1086: `inferInstance` failure is the
  type-level negative witness.

### Sharp points

1. **`signedActionDomain` duplication.**  Defined at
   `SignedAction.lean:139` AND `Encoding/SignInput.lean:63`.  Same
   value, but no shared constant — a refactor could change one
   without the other.  Tests in `Test/Disputes/Verdict.lean:326`
   and `Test/Authority/SignedAction.lean:516–523` assert specific
   bytes; if those tests are aligned with one but not the other
   they would catch divergence by smoke check, not by structural
   equality.

2. **`signingInput` body uses raw `Encoding.cborHeadEncode` rather
   than `Encoding.signInput`.**  Comparing the two:
   - This file's `signingInput` (line 171): manually concatenates
     domain-byte-string + deploymentId + action + signer + nonce.
   - `Encoding/SignInput.lean:96`'s `signInput`: same layout, also
     using `cborHeadEncode cbeTagBytes` for the domain prefix.

   These are documented as "matching modulo deploymentId scoping".
   Reading both carefully, the *byte layouts* match: both prepend
   the domain via `cborHeadEncode cbeTagBytes signedActionDomain.toUTF8.size ++ utf8`,
   then `Encodable.encode deploymentId`, then `encode action`,
   then `encode signer.toNat`, then `encode nonce`.  This is good
   — but it's hand-verified, not theorem-proved.  No
   `signingInput_eq_encoding_signInput` lemma.

3. **`Admissible` conjunct order.**  The five `obtain ⟨a, b, c, d, e⟩
   := h` patterns rely on the exact order: `authorized, nonce, sig,
   pre, lp`.  Reordering the `def Admissible` body would silently
   reshuffle all six field-extractor theorems (line 343 onwards).
   The `obtain` pattern is somewhat self-documenting (`obtain ⟨_, _,
   hSig, _, _⟩`), but a reviewer reorders conjuncts at their peril.

4. **`expectsNonce_after_apply_admissible` proof depth.**  This
   proof (line 623) is structurally sensitive: the body of
   `apply_admissible_with` chains three nested updates (`base`,
   `nonces`, `registry`, `localPolicies`).  The proof relies on
   the fact that `expectsNonce` projects only `nonces.next`, and
   that none of the *other* updates touch `nonces.next` — verified
   by structure-eta reduction at `rfl` (line 645).  Sensitive to
   the order of the chained `{ ... with ... }` rebuildings.

5. **19-way case splits.**  Three theorems
   (`non_registry_mutating_preserves_registry`,
   `non_meta_preserves_localPolicies`,
   `localPolicies_other_actor_untouched`) explicitly enumerate
   every `Action` constructor.  Adding a new `Action` constructor
   (Lex codegen included) without updating these three theorems
   silently produces a "missing case" elaboration error — caught
   at build time, not silently — which is the desired posture.
   The Lex-sentinel comments at lines 788–789 reserve a region
   for codegen extension, but the proofs are not yet
   programmatically extensible: each new ctor needs a one-line `rfl`
   arm.

6. **`apply_admissible_with` accepts the `_h` admissibility witness
   but does not pattern-match on it.**  The body is purely
   computational — it ignores `_h` (underscore-prefixed).  The
   dependent argument serves only to make the type signature
   require an admissibility proof at the call site.  This is the
   intended design: the *proof* that the precondition holds is
   what enables the underlying `t.apply_impl` to behave correctly,
   but the computation itself is deterministic regardless of the
   witness's content.  Soundness depends on the kernel's
   `impl_noop_if_not_pre` theorem (TCB) — if the witness is
   invalid (e.g. constructed via `sorry`), `apply_impl` would
   return the unchanged state.

7. **No `apply_admissible` injectivity theorem.**  Two distinct
   `SignedAction`s with the same signer but different nonces are
   each admissible at distinct `ExtendedState`s — but there is no
   theorem that the *output* of `apply_admissible` is injective in
   the signed action.  Compositional reasoning at the action-history
   level relies on logging and replay, not on type-level injectivity.

8. **`RegistryPreserving` instances cover only the 17 ctors that
   exist today.**  Future Lex-generated constructors that mutate
   the registry would silently lack an instance; future
   Lex-generated constructors that *don't* mutate it would need an
   explicit one-line instance.  The Lex-sentinel at 468–474 is in
   `applyActionToRegistry`'s body, not in the `instance` block —
   so the codegen partition for new instances is unclear.

---

## Cross-file findings

### Doc drift summary

* `Crypto.lean:16` says `Verify` is a "Lean `axiom`"; actually it's
  `opaque` (verified at line 138).  The rest of the file's
  docstring at 91–119 correctly uses `opaque`.  Cosmetic.

### Trust assumptions

The Authority modules' security guarantees rest on **two** trust
anchors:

1. **`Verify` is EUF-CMA secure** (Crypto.lean:138, opaque).
2. **CBE encoder injectivity** (signingInput's body, line 171, via
   `Encoding.Encodable.encode` and `cborHeadEncode`).  Distinct
   `(action, signer, nonce, deploymentId)` quadruples must produce
   distinct `signingInput` bytes.  Proved at `Encoding/SignInput.lean`
   level (`signInput_injective`); the kernel's `signingInput` here
   mirrors that body byte-for-byte but does not have its own
   injectivity theorem.

### Constructor-index discipline

Three places reference inductive indices for `Action`:
1. `Authority/LocalPolicySemantics.lean:64` (`Action.tag`).
2. `Encoding/Action.lean` (CBE constructor tag).
3. Phase-6 dispute tooling that scans the log for specific tags.

These three are *parallel*, not derived.  A reviewer reordering
`Action` constructors must update all three.  Smoke checks at
`LocalPolicySemantics.lean:281–293` pin four indices (0, 14, 15,
16); the other 15 are unpinned.

### Decidability summary

| Predicate / Type                                  | Decidable? | Mechanism                                       |
|---------------------------------------------------|------------|-------------------------------------------------|
| `PublicKey = PublicKey`                           | Yes        | `inferInstanceAs` via `ByteArray.DecidableEq`   |
| `Action = Action`                                 | Yes        | `deriving DecidableEq` on the inductive          |
| `LocalPolicyClause = LocalPolicyClause`           | Yes        | `deriving DecidableEq`                          |
| `LocalPolicy = LocalPolicy`                       | Yes        | `deriving DecidableEq`                          |
| `AuthorityPolicy.authorized`                      | Yes        | `decAuth` field witness                          |
| `LocalPolicyClause.permits`                       | Yes        | named `instance`; case-split + `inferInstance`  |
| `LocalPolicy.permits`                             | Yes        | `List.decidableBAll` over `MAX=64` clauses      |
| `localPolicyPermits`                              | Yes        | `inferInstance` after `unfold`                  |
| `Admissible P es st`                              | No (uses ∃ pk) | Only operationally decidable (check registry → verify) |

The unbounded existential in `Admissible`'s third conjunct (∃ pk)
is deliberate (line 211): packing conditions 1+3 forces the same
`pk` to be used for both, but makes the predicate non-decidable in
the pure-`Prop` sense.  Operational decidability is supplied by
the runtime (lookup `registry[signer]?` → match `some pk` → call
`Verify pk msg sig`).  This is the right level of abstraction for
the §8.2 kernel-level statement, but it does mean call sites
cannot `decide (Admissible …)`.

### Test-friction note

Because `Verify` is `opaque` (returning `false` in its placeholder
body but never reducing at the Lean level), value-level
`Admissible` witnesses cannot be constructed at the Lean level for
the *production* `Verify`.  This is why `AdmissibleWith` is
parameterised over `verify`: test code uses a deterministic
`mockVerify` (in `LegalKernel/Test/MockCrypto.lean`, per the
CLAUDE.md note) to exercise admissibility.  The headline
theorems (`nonce_uniqueness`, `replay_impossible`) operate on
`Admissible` directly because they only reason about the *nonce*
conjunct, which is `Verify`-independent.  This is why those
two theorems can be value-level-tested in
`Test/Authority/SignedAction.lean` while `apply_admissible` itself
requires `mockVerify`.

### Missing coverage

1. **No `mergeLeftBiased` semantic lemmas** (Identity.lean:141).
   Deployments that need them must prove them; not a correctness
   issue.
2. **No `signingInput_injective` lemma at this file's level.**
   `Encoding/SignInput.lean` has the analogous lemma; verifying
   that `Authority.signingInput = Encoding.signInput` at the byte
   level is hand-verified only.
3. **No tag-pinning smoke checks for 15 of 19 `Action`
   constructors** in `LocalPolicySemantics.lean`.
4. **`apply_admissible` injectivity** in `(P, es, st)` is not
   stated.  Replay protection at the action level is `replay_impossible`;
   at the global level it is enforced by log discipline (Phase 5).

---

## Verdict

The Authority modules form a clean, layered authorisation surface
with the kernel's TCB invariants intact.  Headline theorems
(`nonce_uniqueness`, `replay_impossible`, `replaceKey_updates_registry`,
`localPolicy_meta_action_independent`) close cleanly with proofs
that pattern-destructure the admissibility witness and reach the
appropriate Std `Nat` / `RBMap` lemma.

The principal cross-file risk is **constructor-index discipline**:
three independent enumerations of `Action`'s 19 constructors
(`Action.tag`, the CBE encoder's inductive-index tag, and the LP.2
codec's dispatch table) must stay synchronized.  Smoke checks pin
four of the 19 tags; the other 15 rely on the codegen/lint
discipline plus manual review.

The principal forcing-function risk is **`Verify` opacity at test
time**: production-`Verify` cannot construct value-level
admissibility witnesses, so test-vs-production divergence is
mediated by `AdmissibleWith` + `MockCrypto`.  This is a real
design strength, but means any change to `Admissible`'s structure
must be mirrored in both the `Verify`-parameterised form
(`AdmissibleWith`) and the back-compat default (`Admissible`).

No defects identified.  Two cosmetic doc-drift items
(`Crypto.lean:16`, `axiom`/`opaque` typo) and one duplicated
constant (`signedActionDomain` defined in both `SignedAction.lean`
and `Encoding/SignInput.lean`) are noted for future cleanup.
