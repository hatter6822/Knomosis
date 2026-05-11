/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
Lex.DSL.Deployment — the Workstream-LX `deployment`
manifest macro.

LX.31 / LX.32 / LX.33 of `docs/lex_implementation_plan.md` §16.

Implements the full §16 surface (post-M3-completion):

  1. one `def deployment_<name>_id : ByteArray` (LX.32) — the
     32-byte deployment ID flowing into `signingInput` for
     cross-deployment-replay protection.
  2. one `def deployment_<name>_manifest_hash : ByteArray`
     (LX.32) — the deterministic CBE hash of the manifest's
     parsed AST.
  3. one `def deployment_<name>_authority_policy : AuthorityPolicy`
     (LX.32) — the user's authority bindings folded via
     `AuthorityPolicy.intersect` (or `unrestricted` if empty).
     This is the policy that `_admissible` consumes.
  4. one `def deployment_<name>_deployment : Deployment` (LX.31)
     — the full record bundling identifier, deploymentId, version,
     resources, laws, authority, invariantClaims,
     manifestHashBytes.
  5. one `def deployment_<name>_admissible : ExtendedState →
     SignedAction → Prop` (LX.32) — the deployment-scoped
     admissibility predicate: `AdmissibleWith Verify
     deployment_<name>_authority_policy deployment_<name>_id`.
  6. one `def deployment_<name>_<claim>_<idx> : <LawSet>` per
     `invariant_claims` entry (LX.33) — synthesised via the
     `<LawSet>.cons` builders in `LegalKernel.Conservation`.

# Surface syntax (post-M3)

The `deployment` macro accepts both the pre-M3-completion
single-binding form and the spec-faithful multi-binding form:

  ## `deploy_authority` (LX.32)

  ```
  -- Spec-faithful multi-binding form (preferred).
  deploy_authority := [
    transfer_policy = federation.transfer_policy_v2,
    mint_policy     = central_bank_only,
    identity_policy = self_only_with_central_bank_recovery
  ]

  -- Single-policy form (also accepted).
  deploy_authority := AuthorityPolicy.unrestricted
  ```

  The multi-binding form folds into a single
  `deployment_<name>_authority_policy : AuthorityPolicy` via
  `AuthorityPolicy.intersect` (all bindings must agree to
  authorise an action).  The single-policy form passes the
  expression through directly.

  ## `deploy_laws` (LX.37)

  ```
  -- Spec-faithful @-version-pin form (preferred).
  deploy_laws := [
    Transfer = legalkernel.transfer @ "1.0.0",
    Mint     = legalkernel.mint     @ "1.0.0"
  ]

  -- Bare-identifier form (also accepted).
  deploy_laws := [transferWrapper, mintWrapper]
  ```

  The `@`-version-pin form binds a local name to a kernel-side
  identifier and a captured version pin (used by
  `Deployment.laws.LawBinding.version`).  The bare form uses
  the deployment's `deploy_version` for every binding.

  ## `deploy_invariant_claims` (LX.33)

  ```
  -- Wildcard expansion (LX.33).
  deploy_invariant_claims := [
    monotonic_law_set [Transfer, Mint, Freeze],
    freeze_preserving_law_set [* @ {*}]
  ]
  ```

  The `[* @ {*}]` wildcard expands at elaboration time to all
  laws in the deployment's `deploy_laws` list, with the
  resource set `S` set to `deploy_resources`.

# Phased implementation (LX.31 / LX.32 / LX.33)

  * **LX.31 (Phase 1)**: parser + `DeploymentDecl` (parser-time
    intermediate) + public `Deployment` record + skeleton
    elaboration.  L018 (32-byte `deploymentId`) firing at the
    `deploy_deployment_id` clause.

  * **LX.32 (Phase 2)**: manifest-hash computation via the
    canonical CBE encoder + `Runtime.Hash`; emission of
    `_id`, `_manifest_hash`, `_authority_policy`, and
    `_admissible` defs.

  * **LX.33 (Phase 3)**: `invariant_claims` synthesizer with
    `synth_monotonic_law_set` / `synth_conservative_law_set` /
    `synth_freeze_preserving_law_set` named functions.  Wildcard
    `[* @ {*}]` expansion.  Missing instances surface as L008
    diagnostics.

# v1 deviation from §16.1 — clause-keyword spelling

Clauses are prefixed with `deploy_` to avoid token collisions
with downstream structure-field names:

  | Plan keyword       | v1 spelling           |
  |--------------------|-----------------------|
  | `identifier`       | `deploy_id`           |
  | `deployment_id`    | `deploy_deployment_id`|
  | `version`          | `deploy_version`      |
  | `resources`        | `deploy_resources`    |
  | `laws`             | `deploy_laws`         |
  | `authority`        | `deploy_authority`    |
  | `invariant_claims` | `deploy_invariant_claims` |
  | `attestor`         | `deploy_attestor`     |

The `Deployment` Lean record exposes the canonical field names
from §16.4 verbatim.
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.Identity
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.Encodable
import LegalKernel.Encoding.SignInput
import LegalKernel.Runtime.Hash
import Lex.Tools.Common
import Lean.Elab.Command
import Lean.Elab.Term

namespace LegalKernel.DSL

open Lean Lean.Elab Lean.Elab.Command

/-! ## Public data types -/

/-- A binding between a deployment-local law name and a kernel
    transition.  The `localName` is what the manifest writer uses
    in clauses like `monotonic_law_set [Transfer, Mint]`; the
    `lawIdent` is the canonical kernel identifier
    (e.g. `LegalKernel.Laws.transfer`); the `version` is the
    `@`-version-pin captured at deployment time. -/
structure LawBinding where
  /-- The deployment-local law identifier (capitalised by
      convention; e.g. `Transfer`). -/
  localName : String
  /-- The kernel-side `Name` of the law's transition function or
      Lex-emitted `_transition` def. -/
  lawIdent : Lean.Name
  /-- The `@`-version-pin captured at deployment time
      (e.g. `"1.0.0"`).  Allows tooling to flag a deployment
      whose pinned version doesn't match the actual law file
      version. -/
  version : String
  deriving Inhabited

instance : Repr LawBinding where
  reprPrec b _ :=
    "{localName := \"" ++ b.localName ++ "\", lawIdent := " ++
    toString b.lawIdent ++ ", version := \"" ++ b.version ++ "\"}"

/-- A binding between a deployment-local authority slot name and
    an `AuthorityPolicy` value.  The §16.1 grammar admits multiple
    bindings (e.g. `transfer_policy = ..., mint_policy = ...`);
    the macro folds them via `AuthorityPolicy.intersect`. -/
structure AuthorityBinding where
  /-- The deployment-local authority slot name (e.g.
      `transfer_policy`, `mint_policy`, `identity_policy`). -/
  localName : String
  /-- The captured surface text of the policy expression
      (preserved as data; the macro elaborates the expression
      into a real `AuthorityPolicy` value at use site). -/
  policyExpr : String
  deriving Repr, Inhabited

/-- The kind of an `invariant_claims` entry.  Each kind maps to a
    distinct law-set structure in `LegalKernel.Conservation`. -/
inductive InvariantClaimKind where
  /-- `monotonic_law_set` — every named law has `IsMonotonic`. -/
  | monotonicLawSet
  /-- `conservative_law_set` — every named law has `IsConservative`. -/
  | conservativeLawSet
  /-- `freeze_preserving_law_set` — every named law has
      `FreezePreserving S` for the deployment's resource set `S`. -/
  | freezePreservingLawSet
  deriving Repr, DecidableEq, Inhabited

/-- The "scope" of an invariant claim's law list.  Either an
    explicit list of local law names, or the wildcard form
    `[* @ {*}]` (LX.33) which expands at elaboration time to
    the full deployment's `deploy_laws` list with the deployment's
    `deploy_resources` as the resource set. -/
inductive InvariantClaimScope where
  /-- Explicit list of local law names. -/
  | explicit (lawNames : List String)
  /-- Wildcard: `[* @ {*}]`.  Expands to all laws in the deployment's
      `deploy_laws` list, with `deploy_resources` as the resource
      set `S` (only meaningful for `freeze_preserving_law_set`). -/
  | wildcard
  deriving Repr, Inhabited

/-- One `invariant_claims` entry: a kind plus a scope. -/
structure InvariantClaim where
  /-- The claim kind (monotonic / conservative / freeze-preserving). -/
  kind : InvariantClaimKind
  /-- The claim's law-name scope (explicit list or wildcard). -/
  scope : InvariantClaimScope
  deriving Repr, Inhabited

/-- Backwards-compat: extract law names if the scope is explicit;
    return an empty list for the wildcard form (the macro expands
    wildcards before this is consulted). -/
def InvariantClaim.lawNames (c : InvariantClaim) : List String :=
  match c.scope with
  | .explicit names => names
  | .wildcard       => []

/-- The `Deployment` record (§16.4).

    A non-TCB structured handle for tooling (`lex_diff`, future
    LSP integrations, future `canon manifest inspect` CLI).  Equal
    `Deployment` values produce byte-equal `manifestHashBytes` via
    the deterministic CBE encoder. -/
structure Deployment where
  /-- Canonical identifier (e.g. `"example.usd_clearing"`). -/
  identifier : String
  /-- The 32-byte deployment ID.  Validated at elaboration time
      to be exactly 32 bytes; rejection fires L018. -/
  deploymentId : ByteArray
  /-- Semver-shaped version (e.g. `"1.0.0"`). -/
  version : String
  /-- Resource list: pairs of (canonical name, ResourceId). -/
  resources : List (String × Nat)
  /-- Law bindings.  Each is a (localName, lawIdent, version) triple. -/
  laws : List LawBinding
  /-- Authority bindings.  Multi-binding manifests have one entry
      per slot (`transfer_policy`, `mint_policy`, etc.); single-
      binding manifests have one `"default"` entry. -/
  authority : List AuthorityBinding
  /-- Invariant claims, preserved as data so that downstream
      tooling can introspect the claim structure without
      re-parsing the source. -/
  invariantClaims : List InvariantClaim
  /-- The manifest hash bytes (32-byte BLAKE3 / FNV-1a-64
      placeholder) — computed deterministically from the parsed
      AST.  See §16.2 #3. -/
  manifestHashBytes : ByteArray
  deriving Inhabited

/-- The parser-time intermediate representation (LX.31 §LX.31).
    Holds every parsed clause as data BEFORE the macro emits the
    Lean defs.  Public so tooling can consume the parsed shape
    (e.g. for `lex_diff`'s manifest-level diff or the future LSP
    integration). -/
structure DeploymentDecl where
  /-- The deployment's local Lean name (the identifier just after
      `deployment`). -/
  deployName : Lean.Name
  /-- The originating file path (for diagnostic anchoring;
      recorded as repo-relative when possible). -/
  sourceFile : String
  /-- The originating line of the `deployment` keyword. -/
  sourceLine : Nat
  /-- Parsed `deploy_id` clause's identifier-path source text. -/
  identifier : String
  /-- Parsed `deploy_deployment_id` hex string + the decoded
      32-byte ByteArray. -/
  deploymentId : ByteArray
  /-- Parsed `deploy_version` string literal. -/
  version : String
  /-- Parsed `deploy_resources` entries. -/
  resources : List (String × Nat)
  /-- Parsed `deploy_laws` bindings. -/
  laws : List LawBinding
  /-- Parsed `deploy_authority` bindings. -/
  authority : List AuthorityBinding
  /-- Parsed `deploy_invariant_claims` entries. -/
  invariantClaims : List InvariantClaim
  /-- Parsed `deploy_attestor` identifier (v2-only; reserved). -/
  attestor : Option Lean.Name
  /-- Manifest source bytes for hash computation.  Captured as
      the canonical CBE encoding of the parsed AST. -/
  manifestSourceBytes : LegalKernel.Encoding.Stream
  deriving Inhabited

/-! ## Manifest-hash computation (LX.32) -/

/-- Encode a parsed manifest's hash-input bytes.  Used by the
    macro emitter and by tests that verify manifest-hash
    determinism.

    The encoding is canonical: equal-shape manifests produce
    byte-equal streams.  Field-order contract:

      1. Identifier (CBE byte-string).
      2. Deployment ID (CBE byte-string).
      3. Version (CBE byte-string).
      4. Resources list (count-prefixed; per-entry name + idx).
      5. Law bindings (count-prefixed; per-entry localName +
         lawIdent + version).  Including the resolved
         `lawIdent` is essential — two manifests with the same
         localName + version but different bound laws would
         otherwise hash equal.
      6. Authority bindings (count-prefixed; per-entry localName
         + policyExpr).  The `policyExpr` is the surface text of
         the user's `AuthorityPolicy` expression.
      7. Invariant claims (count-prefixed; per-entry kind-tag +
         scope-tag + law-names).
    -/
def encodeManifestHashInput
    (identifier : String)
    (deploymentId : ByteArray)
    (version : String)
    (resources : List (String × Nat))
    (laws : List (String × String × String))   -- (localName, lawIdent, version)
    (authority : List (String × String))        -- (localName, policyExpr)
    (claims : List (Nat × Nat × List String))   -- (kind-tag, scope-tag, law-names)
    : LegalKernel.Encoding.Stream := Id.run do
  -- Audit-3 canonicalisation: sort lists to make hash
  -- order-insensitive (matches `computeManifestDiff`'s set-
  -- semantic interpretation per spec §10.2: "the set of laws").
  -- Without this, reordering laws/authority/claims at the source
  -- level would change the manifest hash even though
  -- `computeManifestDiff` correctly says "no semantic change" —
  -- a discrepancy that would break attestor signatures on
  -- no-op reorderings.
  let sortedResources :=
    resources.toArray.qsort (fun a b => a.1 < b.1) |>.toList
  let sortedLaws :=
    laws.toArray.qsort (fun a b => a.1 < b.1) |>.toList
  let sortedAuthority :=
    authority.toArray.qsort (fun a b => a.1 < b.1) |>.toList
  let claimsCanonicalised : List (Nat × Nat × List String) :=
    claims.map (fun (kt, st, lns) =>
      (kt, st, lns.toArray.qsort (· < ·) |>.toList))
  -- Audit-5 (HIGH-1): structural lexicographic comparator on
  -- the law-names list — replaces the prior `intercalate ","`
  -- form, which collapsed `["foo,bar"]` and `["foo","bar"]` to
  -- the same sort key `"foo,bar"`.  Under qsort instability,
  -- two such claims could re-order non-deterministically and
  -- produce different manifest hashes across runs even with
  -- equal input.  Lean identifiers admit commas via the
  -- French-quoted `«…»` form, so a future law identifier
  -- like `«foo,bar»` would silently exhibit the bug.  The
  -- structural comparator avoids the collision class
  -- entirely.
  let rec lexicographicListCompare (xs ys : List String) : Bool :=
    match xs, ys with
    | [], [] => false  -- equal: not strictly less than
    | [], _ :: _ => true  -- shorter list is less
    | _ :: _, [] => false  -- longer list is greater
    | x :: xtl, y :: ytl =>
      if x < y then true
      else if x > y then false
      else lexicographicListCompare xtl ytl
  let sortedClaims := claimsCanonicalised.toArray.qsort
    (fun a b =>
      if a.1 < b.1 then true
      else if a.1 > b.1 then false
      else if a.2.1 < b.2.1 then true
      else if a.2.1 > b.2.1 then false
      else lexicographicListCompare a.2.2 b.2.2)
    |>.toList
  let mut bytes : LegalKernel.Encoding.Stream := []
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (identifier.toUTF8)
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode deploymentId
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (version.toUTF8)
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (sortedResources.length : Nat)
  for (name, idx) in sortedResources do
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (name.toUTF8)
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (idx : Nat)
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (sortedLaws.length : Nat)
  for (lnm, lid, lv) in sortedLaws do
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (lnm.toUTF8)
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (lid.toUTF8)
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (lv.toUTF8)
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (sortedAuthority.length : Nat)
  for (slot, expr) in sortedAuthority do
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (slot.toUTF8)
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (expr.toUTF8)
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (sortedClaims.length : Nat)
  for (kindTag, scopeTag, lawNames) in sortedClaims do
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (kindTag : Nat)
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (scopeTag : Nat)
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (lawNames.length : Nat)
    for lnm in lawNames do
      bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (lnm.toUTF8)
  pure bytes

/-- Map an `InvariantClaimKind` to its canonical numeric tag for
    manifest-hash computation. -/
def invariantClaimKindTag : InvariantClaimKind → Nat
  | .monotonicLawSet        => 0
  | .conservativeLawSet     => 1
  | .freezePreservingLawSet => 2

/-- Map an `InvariantClaimScope` to its canonical numeric tag for
    manifest-hash computation. -/
def invariantClaimScopeTag : InvariantClaimScope → Nat
  | .explicit _ => 0
  | .wildcard   => 1

/-- Compute the manifest hash bytes.  Convenience wrapper around
    `encodeManifestHashInput` + `Runtime.Hash.hashStream`. -/
def computeManifestHash
    (identifier : String)
    (deploymentId : ByteArray)
    (version : String)
    (resources : List (String × Nat))
    (laws : List (String × String × String))
    (authority : List (String × String))
    (claims : List (Nat × Nat × List String))
    : ByteArray :=
  let stream := encodeManifestHashInput
    identifier deploymentId version resources laws authority claims
  LegalKernel.Runtime.hashStream stream

/-! ## Hex-decoding utilities for `deploy_deployment_id` -/

/-- Convert a hex character (`'0'..'9'` / `'a'..'f'` / `'A'..'F'`)
    to its 0..15 nibble value, or `none` if non-hex. -/
private def hexCharToNibble (c : Char) : Option Nat :=
  if c ≥ '0' && c ≤ '9' then some (c.toNat - '0'.toNat)
  else if c ≥ 'a' && c ≤ 'f' then some (10 + c.toNat - 'a'.toNat)
  else if c ≥ 'A' && c ≤ 'F' then some (10 + c.toNat - 'A'.toNat)
  else none

/-- Decode a hex string (no `0x` prefix; even-length; lowercase
    or uppercase) into a `ByteArray`.  Returns `none` on any
    non-hex character or odd length. -/
def decodeHexString (s : String) : Option ByteArray := Id.run do
  let cs := s.toList
  if cs.length % 2 != 0 then return none
  let mut bytes : List UInt8 := []
  let mut idx : Nat := 0
  let csA := cs.toArray
  while idx < cs.length do
    let hi := hexCharToNibble (csA[idx]!)
    let lo := hexCharToNibble (csA[idx + 1]!)
    match hi, lo with
    | some h, some l =>
      bytes := bytes ++ [(h * 16 + l).toUInt8]
      idx := idx + 2
    | _, _ => return none
  return some (ByteArray.mk bytes.toArray)

/-! ## Helpers for naming -/

/-- `<n>_deployment` — the `Deployment` record def. -/
private def deploymentDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_deployment")

/-- `<n>_id` — the 32-byte deployment ID constant. -/
private def deploymentIdDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_id")

/-- `<n>_manifest_hash` — the manifest content hash constant. -/
private def deploymentManifestHashDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_manifest_hash")

/-- `<n>_authority_policy` — the combined `AuthorityPolicy`
    value (LX.32 fix). -/
private def deploymentAuthorityPolicyDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_authority_policy")

/-- `<n>_admissible` — the deployment-scoped admissibility
    predicate. -/
private def deploymentAdmissibleDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_admissible")

/-- `<n>_<claim>_<idx>` — the per-claim invariant law-set def. -/
private def deploymentClaimDefName (n : Lean.Name)
    (claim : InvariantClaimKind) (idx : Nat) : Lean.Name :=
  let s := toString n
  let suffix : String := match claim with
    | .monotonicLawSet        => "_monotonic_law_set"
    | .conservativeLawSet     => "_conservative_law_set"
    | .freezePreservingLawSet => "_freeze_preserving_law_set"
  Lean.Name.mkSimple (s.replace "." "_" ++ suffix ++ s!"_{idx}")

/-! ## Surface syntax declarations (LX.31) -/

set_option linter.missingDocs false

/-- An authority binding entry: `<slot>:ident = <expr>:term`. -/
declare_syntax_cat authorityBindingEntry
syntax (name := authBindingStx) ident "=" term : authorityBindingEntry

/-- A law binding entry: spec form `<localName>:ident = <lawIdent>:ident @ <version>:str`,
    OR legacy form `<lawIdent>:ident`.  The `<lawIdent>` is
    constrained to `ident` (which admits hierarchical names like
    `legalkernel.transfer`) to avoid the `term @ str` ambiguity
    where Lean's parser would interpret `@` as a term-level
    operator. -/
declare_syntax_cat lawBindingEntry
syntax (name := lawBindingPinnedStx)
  ident "=" ident "@" str : lawBindingEntry
syntax (name := lawBindingBareStx)
  ident : lawBindingEntry

/-- An invariant-claim scope: `[<lawNames>]` (explicit) or
    the wildcard form `[all_laws]` (LX.33).  We use the keyword
    `all_laws` rather than the design-doc's `[* @ {*}]` notation
    because `*` is reserved as a multiplication operator in
    Lean's parser; the spec's mathematical wildcard notation is
    not expressible as a custom syntax extension without
    parser-priority gymnastics. -/
declare_syntax_cat invariantClaimScopeStx
syntax (name := invClaimScopeExplicitStx)
  "[" sepBy(ident, ",") "]" : invariantClaimScopeStx
syntax (name := invClaimScopeWildcardStx)
  "[" "all_laws" "]" : invariantClaimScopeStx

/-- A deployment-manifest clause.  Each concrete clause variant
    extends this category. -/
declare_syntax_cat deployClause

syntax (name := deployIdClauseStx) "deploy_id" ident : deployClause
syntax (name := deployDeploymentIdClauseStx)
  "deploy_deployment_id" str : deployClause
syntax (name := deployVersionClauseStx)
  "deploy_version" str : deployClause
syntax (name := deployResourcesClauseStx)
  "deploy_resources" ":=" "[" sepBy(group(str ":=" num), ",") "]" : deployClause
syntax (name := deployLawsClauseStx)
  "deploy_laws" ":=" "[" sepBy(lawBindingEntry, ",") "]" : deployClause
syntax (name := deployAuthorityClauseStx)
  "deploy_authority" ":=" "[" sepBy(authorityBindingEntry, ",") "]" : deployClause
syntax (name := deployInvariantClaimsClauseStx)
  "deploy_invariant_claims" ":=" "[" sepBy(group(ident invariantClaimScopeStx), ",") "]" : deployClause
syntax (name := deployAttestorClauseStx)
  "deploy_attestor" ident : deployClause

/-- The top-level `deployment` Lex command. -/
syntax (name := deploymentCmd)
  "deployment" ident "where" deployClause+ : command

set_option linter.missingDocs true

/-! ## Per-clause builders -/

/-- The macro's parser-time accumulator.  Kept private; the
    public surface for parsed manifests is `DeploymentDecl`
    (built by `parseDeployment`).

    Key design choice: `authorityClause` stores the user's
    policy *as a `Syntax` node* (not a string) so it can be
    spliced directly into the emitted `def`'s body via
    `$expr` macro quotation.  This avoids the round-trip
    through `toString` (which produces the syntax-tree dump,
    not re-parseable Lean source) — a defect that affected
    the prior implementation. -/
private structure ParsedDeployment where
  deployName : Lean.Name := Lean.Name.anonymous
  identifierClause : Option String := none
  deploymentIdClause : Option (Lean.Syntax × String) := none
  versionClause : Option String := none
  resourcesClause : Option (List (String × Nat)) := none
  /-- Each entry: `(localName, lawIdentSurfaceText, lawIdentResolvedName, version)`. -/
  lawsClause : Option (List (String × String × Lean.Name × String)) := none
  /-- Each entry: `(slotName, policyExprSyntax)`.  The `Syntax`
      is the raw user-supplied term, which the macro splices
      directly into the emitted `_authority_policy` def. -/
  authorityClause : Option (List (String × Lean.Syntax)) := none
  invariantClaimsClause : Option (List InvariantClaim) := none
  attestorClause : Option Lean.Name := none
  sourceFile : String := ""
  sourceLine : Nat := 1
  deriving Inhabited

/-! ## Law-name resolution (used at parse time + claim emission)

The kernel naming convention exposes laws under
`LegalKernel.Laws.<name>` (hand-written) or
`legalkernel_<lower>_transition` (Lex re-expression).  The
manifest's `<lawIdent>` may be an unqualified ident (`Transfer`),
a dotted path (`legalkernel.transfer`), or any user-defined
identifier in scope.  This function tries common conventions
in order. -/

/-- Resolve a deployment-local law-identifier surface text to a
    kernel-side `Name`.  Tries (in order):
      1. The fully-qualified `<currentNs>.<text>`.
      2. The text itself (works for top-level defs).
      3. The dotted-path-as-name (e.g. `legalkernel.transfer`).
      4. The Lex re-expression `legalkernel_<lower>_transition`.
      5. The hand-written `LegalKernel.Laws.<lower>`.
      6. The camelCase variant `LegalKernel.Laws.<text>`.

    Returns `none` if none resolve. -/
def resolveLawName (env : Lean.Environment)
    (currentNs : Lean.Name) (text : String) :
    Option Lean.Name :=
  let lowercased := text.toLower
  -- Convert dotted path "legalkernel.transfer" into a Name.
  let dottedAsName : Lean.Name :=
    text.splitOn "." |>.foldl
      (fun acc seg => acc ++ Lean.Name.mkSimple seg) Lean.Name.anonymous
  let qualifiedLocal := currentNs ++ Lean.Name.mkSimple text
  let candidates : List Lean.Name := [
    qualifiedLocal,
    Lean.Name.mkSimple text,
    dottedAsName,
    Lean.Name.mkSimple s!"legalkernel_{lowercased}_transition",
    -- For dotted-paths like "legalkernel.transfer", also try
    -- "legalkernel_transfer_transition".
    Lean.Name.mkSimple s!"legalkernel_{text.replace "." "_"}_transition",
    Lean.Name.mkSimple "LegalKernel" ++ Lean.Name.mkSimple "Laws" ++
      Lean.Name.mkSimple lowercased,
    Lean.Name.mkSimple "LegalKernel" ++ Lean.Name.mkSimple "Laws" ++
      Lean.Name.mkSimple text,
    -- Final attempt: "legalkernel.transfer" -> "Laws.transfer"
    Lean.Name.mkSimple "LegalKernel" ++ Lean.Name.mkSimple "Laws" ++
      Lean.Name.mkSimple (text.splitOn "." |>.getLast?.getD text)
  ]
  candidates.find? (fun n => env.contains n)

/-! ## Clause parser -/

/-- Parse a single law-binding entry into a tuple
    `(localName, lawIdentSurfaceText, resolvedName, version)`. -/
private def parseLawBindingEntry (env : Lean.Environment)
    (currentNs : Lean.Name) (defaultVersion : String)
    (entry : Lean.Syntax) :
    CommandElabM (String × String × Lean.Name × String) := do
  match entry with
  | `(lawBindingEntry| $lid:ident = $lid2:ident @ $ver:str) =>
    let localName := toString lid.getId
    let lawText := toString lid2.getId
    let resolved :=
      resolveLawName env currentNs lawText |>.getD Lean.Name.anonymous
    return (localName, lawText, resolved, ver.getString)
  | `(lawBindingEntry| $lid:ident) =>
    let localName := toString lid.getId
    let resolved :=
      resolveLawName env currentNs localName |>.getD Lean.Name.anonymous
    return (localName, localName, resolved, defaultVersion)
  | _ =>
    throwErrorAt entry "deployment: malformed law binding entry"

/-- Render a `Syntax` node back to its source text in a
    re-parseable form.  Uses `Lean.Syntax.reprint` (the canonical
    "syntax → source" function), falling back to `toString` if
    `reprint` returns `none` (no source-position info available).
    This is more reliable than `toString` alone, which produces a
    syntax-tree dump (e.g. `(Term.paren ...)`) when source info
    is missing. -/
private def syntaxToSourceText (s : Lean.Syntax) : String :=
  match s.reprint with
  | some text => text
  | none      => toString s

/-- Parse a list of `authorityBindingEntry` syntax nodes into
    `(slotName, policyExprSyntax)` pairs.  The syntax is
    captured directly for splicing into the emitted code. -/
private def parseAuthorityBindings
    (entries : Array (Lean.TSyntax `authorityBindingEntry)) :
    CommandElabM (List (String × Lean.Syntax)) := do
  let mut parsed : List (String × Lean.Syntax) := []
  for entry in entries do
    match entry with
    | `(authorityBindingEntry| $lid:ident = $expr:term) =>
      parsed := parsed ++ [(toString lid.getId, expr.raw)]
    | _ =>
      throwErrorAt entry "deployment: malformed authority binding"
  return parsed

/-- Parse a single `deployClause` into a builder update. -/
private def parseDeployClause (env : Lean.Environment)
    (currentNs : Lean.Name) (clause : Lean.Syntax)
    (acc : ParsedDeployment) :
    CommandElabM ParsedDeployment := do
  match clause with
  | `(deployClause| deploy_id $id:ident) =>
    if acc.identifierClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_id` clause"
    return { acc with identifierClause := some (toString id.getId) }
  | `(deployClause| deploy_deployment_id $s:str) =>
    if acc.deploymentIdClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_deployment_id` clause"
    return { acc with deploymentIdClause := some (s.raw, s.getString) }
  | `(deployClause| deploy_version $s:str) =>
    if acc.versionClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_version` clause"
    return { acc with versionClause := some s.getString }
  | `(deployClause| deploy_resources := [ $[$ress:str := $idxs:num],* ]) =>
    if acc.resourcesClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_resources` clause"
    let pairs := ress.toList.zip idxs.toList
    let parsed := pairs.map (fun (s, n) => (s.getString, n.getNat))
    return { acc with resourcesClause := some parsed }
  | `(deployClause| deploy_laws := [ $[$entries:lawBindingEntry],* ]) =>
    if acc.lawsClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_laws` clause"
    let defaultVersion := acc.versionClause.getD ""
    let mut parsed : List (String × String × Lean.Name × String) := []
    for entry in entries do
      let result ← parseLawBindingEntry env currentNs defaultVersion entry
      parsed := parsed ++ [result]
    return { acc with lawsClause := some parsed }
  | `(deployClause| deploy_authority := [ $[$entries:authorityBindingEntry],* ]) =>
    if acc.authorityClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_authority` clause"
    let parsed ← parseAuthorityBindings entries
    return { acc with authorityClause := some parsed }
  | `(deployClause| deploy_invariant_claims := [ $[$kinds:ident $scopes:invariantClaimScopeStx],* ]) =>
    if acc.invariantClaimsClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_invariant_claims` clause"
    let mut parsed : List InvariantClaim := []
    for h : i in [:kinds.size] do
      let kindStr := toString (kinds[i]).getId
      let scope := scopes[i]!
      let parsedScope : InvariantClaimScope ←
        match scope with
        | `(invariantClaimScopeStx| [ $[$ids:ident],* ]) =>
          pure (.explicit (ids.toList.map (fun id => toString id.getId)))
        | `(invariantClaimScopeStx| [ all_laws ]) =>
          pure .wildcard
        | _ =>
          throwErrorAt scope
            "deployment: malformed invariant-claim scope (expected `[...]` or `[all_laws]`)"
      let kind ← match kindStr with
        | "monotonic_law_set"        => pure InvariantClaimKind.monotonicLawSet
        | "conservative_law_set"     => pure InvariantClaimKind.conservativeLawSet
        | "freeze_preserving_law_set" => pure InvariantClaimKind.freezePreservingLawSet
        | _ =>
          throwErrorAt clause
            s!"deployment: unknown invariant-claim kind `{kindStr}`; admissible kinds are `monotonic_law_set`, `conservative_law_set`, `freeze_preserving_law_set`"
      parsed := parsed ++ [{ kind, scope := parsedScope }]
    return { acc with invariantClaimsClause := some parsed }
  | `(deployClause| deploy_attestor $a:ident) =>
    if acc.attestorClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_attestor` clause"
    return { acc with attestorClause := some a.getId }
  | _ =>
    throwErrorAt clause s!"deployment: unknown clause `{clause}`"

/-- Validate that every required clause has been supplied and that
    `deployment_id` decodes to exactly 32 bytes (L018). -/
private def validateRequiredDeployClauses (parsed : ParsedDeployment)
    (ref : Lean.Syntax) : CommandElabM Unit := do
  if parsed.identifierClause.isNone then
    throwErrorAt ref s!"L001: deployment `{parsed.deployName}` is missing the `deploy_id` clause"
  if parsed.deploymentIdClause.isNone then
    throwErrorAt ref s!"L001: deployment `{parsed.deployName}` is missing the `deploy_deployment_id` clause"
  if parsed.versionClause.isNone then
    throwErrorAt ref s!"L001: deployment `{parsed.deployName}` is missing the `deploy_version` clause"
  if parsed.resourcesClause.isNone then
    throwErrorAt ref s!"L001: deployment `{parsed.deployName}` is missing the `deploy_resources` clause"
  if parsed.lawsClause.isNone then
    throwErrorAt ref s!"L001: deployment `{parsed.deployName}` is missing the `deploy_laws` clause"
  if parsed.authorityClause.isNone then
    throwErrorAt ref s!"L009: deployment `{parsed.deployName}` is missing the `deploy_authority` clause"
  if let some (didStx, hex) := parsed.deploymentIdClause then
    match decodeHexString hex with
    | none =>
      throwErrorAt didStx
        s!"L018: deployment `{parsed.deployName}`'s `deploy_deployment_id` is not a valid hex string (got `{hex}`); supply a hex-encoded ByteArray of exactly 32 bytes (64 hex characters)"
    | some bs =>
      if bs.size != 32 then
        throwErrorAt didStx
          s!"L018: deployment `{parsed.deployName}`'s `deploy_deployment_id` is {bs.size} bytes; deployment IDs must be exactly 32 bytes (64 hex characters)"

/-! ## Public `parseDeployment` function (LX.31 named-API) -/

/-- Parse a `deployment <name> where ...` syntax tree into a
    public `DeploymentDecl`.  Used by the macro elaborator AND
    by tooling that wants to inspect a manifest without
    elaborating it (e.g. `lex_diff`'s manifest-level diff).

    The function runs in `CommandElabM` because clause parsing
    can fire diagnostics; on success returns `.ok decl`. -/
def parseDeployment (env : Lean.Environment) (currentNs : Lean.Name)
    (sourceFile : String) (sourceLine : Nat)
    (deployName : Lean.Name)
    (clauses : Array Lean.Syntax)
    (diagAnchor : Option Lean.Syntax := none) :
    CommandElabM DeploymentDecl := do
  let initial : ParsedDeployment := {
    deployName, sourceFile, sourceLine
  }
  let mut acc := initial
  for c in clauses do
    acc ← parseDeployClause env currentNs c acc
  -- Audit-5: prefer the caller-supplied anchor (the macro path
  -- supplies `name.raw` for diagnostics anchored at the
  -- `deployment <name>` keyword).  Fall back to `clauses[0]!`
  -- (or `Syntax.missing` if no clauses) for tooling callers.
  let anchor := diagAnchor.getD
    (if clauses.isEmpty then Lean.Syntax.missing else clauses[0]!)
  validateRequiredDeployClauses acc anchor
  -- Safe extraction: `validateRequiredDeployClauses` has already
  -- thrown if `deploymentIdClause` is `none` or its decoded
  -- payload is not 32 bytes.  Use safe `Option.elim` to avoid
  -- relying on `.get!` invariants in case external callers
  -- somehow reach this code path with invalidated state.
  let deploymentId : ByteArray ← match acc.deploymentIdClause with
    | none =>
      throwErrorAt anchor
        s!"deployment `{acc.deployName}`: internal error: validation passed but deploymentIdClause is none"
    | some (didStx, hex) =>
      match decodeHexString hex with
      | none =>
        throwErrorAt didStx
          s!"deployment `{acc.deployName}`: internal error: validation passed but hex `{hex}` failed to decode"
      | some bs => pure bs
  let lawBindings : List LawBinding :=
    (acc.lawsClause.getD []).map (fun (lnm, _surface, ident, ver) =>
      ({ localName := lnm, lawIdent := ident, version := ver } : LawBinding))
  let authBindings : List AuthorityBinding :=
    (acc.authorityClause.getD []).map (fun (slot, exprStx) =>
      ({ localName := slot,
         policyExpr := syntaxToSourceText exprStx } : AuthorityBinding))
  let claims := acc.invariantClaimsClause.getD []
  let identifier := acc.identifierClause.getD ""
  let version := acc.versionClause.getD ""
  let resources := acc.resourcesClause.getD []
  let lawsForHash : List (String × String × String) :=
    (acc.lawsClause.getD []).map (fun (lnm, surface, _, ver) => (lnm, surface, ver))
  let authForHash : List (String × String) :=
    authBindings.map (fun b => (b.localName, b.policyExpr))
  let claimsForHash : List (Nat × Nat × List String) :=
    claims.map (fun c =>
      (invariantClaimKindTag c.kind,
       invariantClaimScopeTag c.scope,
       c.lawNames))
  let manifestSourceBytes := encodeManifestHashInput
    identifier deploymentId version resources lawsForHash authForHash
    claimsForHash
  return {
    deployName := acc.deployName,
    sourceFile := acc.sourceFile,
    sourceLine := acc.sourceLine,
    identifier,
    deploymentId,
    version,
    resources,
    laws := lawBindings,
    authority := authBindings,
    invariantClaims := claims,
    attestor := acc.attestorClause,
    manifestSourceBytes
  }

/-! ## ByteArray construction term builder -/

/-- Render a `ByteArray`'s contents as a Lean syntax term that
    elaborates to the same `ByteArray`. -/
private def byteArrayToTermSyntax (bs : ByteArray) :
    CommandElabM Lean.Term := do
  let elems : Array Lean.Term ← bs.toList.toArray.mapM (fun b => do
    let n := b.toNat
    `(($(Lean.quote n) : UInt8)))
  let arrStx ← `(#[ $elems,* ])
  `(ByteArray.mk $arrStx)

/-- Build a chain `T₁.cons L₁ (T₁.cons L₂ … T₁.empty)` for the
    typeclass-driven law-set construction. -/
private def buildLawSetConsChain
    (emptyTerm : Lean.Term) (consTerm : Lean.Term)
    (lawTerms : List Lean.Term) : CommandElabM Lean.Term := do
  let mut acc : Lean.Term := emptyTerm
  for lawT in lawTerms.reverse do
    acc ← `($consTerm $lawT $acc)
  return acc

/-! ## `synth_*` named functions (LX.33 named-API)

These are the spec-named synthesizer functions called for in
LX.33: per-claim-kind term builders that take a list of resolved
law `Name`s and emit the corresponding `<LawSet>` value via
`<LawSet>.cons` chaining. -/

/-- Synthesise a `MonotonicLawSet` value-level term from a list
    of law transition `Name`s.  Each law's `IsMonotonic`
    instance is resolved at elaboration time via
    `MonotonicLawSet.cons`; missing instances fail with a
    `failed to synthesize` diagnostic. -/
def synth_monotonic_law_set (lawNames : List Lean.Name) :
    CommandElabM Lean.Term := do
  let lawTerms : List Lean.Term ← lawNames.mapM
    (fun n => `($(Lean.mkIdent n)))
  let consTerm : Lean.Term ←
    `(_root_.LegalKernel.MonotonicLawSet.cons)
  let emptyTerm : Lean.Term ←
    `(_root_.LegalKernel.MonotonicLawSet.empty)
  buildLawSetConsChain emptyTerm consTerm lawTerms

/-- Synthesise a `ConservativeLawSet` term. -/
def synth_conservative_law_set (lawNames : List Lean.Name) :
    CommandElabM Lean.Term := do
  let lawTerms : List Lean.Term ← lawNames.mapM
    (fun n => `($(Lean.mkIdent n)))
  let consTerm : Lean.Term ←
    `(_root_.LegalKernel.ConservativeLawSet.cons)
  let emptyTerm : Lean.Term ←
    `(_root_.LegalKernel.ConservativeLawSet.empty)
  buildLawSetConsChain emptyTerm consTerm lawTerms

/-- Synthesise a `FreezePreservingLawSet S` term, where `S` is
    captured as a list of `ResourceId` literal terms. -/
def synth_freeze_preserving_law_set
    (resourceIds : List Nat) (lawNames : List Lean.Name) :
    CommandElabM Lean.Term := do
  let lawTerms : List Lean.Term ← lawNames.mapM
    (fun n => `($(Lean.mkIdent n)))
  let resTerms : Array Lean.Term ← resourceIds.toArray.mapM
    (fun n => `(($(Lean.quote n) : _root_.LegalKernel.ResourceId)))
  let consTerm : Lean.Term ←
    `(_root_.LegalKernel.FreezePreservingLawSet.cons [ $[$resTerms],* ])
  let emptyTerm : Lean.Term ←
    `(_root_.LegalKernel.FreezePreservingLawSet.empty [ $[$resTerms],* ])
  buildLawSetConsChain emptyTerm consTerm lawTerms

/-! ## The `deployment` command elaborator -/

elab_rules : command
  | `(deploymentCmd| deployment $name:ident where $clauses:deployClause*) => do
    let env ← getEnv
    let currentNs ← getCurrNamespace
    let pos := (← read).fileMap.toPosition (name.raw.getPos?.getD ⟨0⟩)
    -- 1. Parse all clauses internally (captures Syntax nodes).
    -- The `acc` here carries the raw user-supplied Syntax for
    -- authority bindings, which the macro splices directly into
    -- the emitted `AuthorityPolicy` fold (so we can avoid the
    -- round-trip through `toString`).  The public
    -- `DeploymentDecl` carries policy expressions as strings,
    -- not Syntax, so we need both representations.
    let initial : ParsedDeployment :=
      { deployName := name.getId,
        sourceFile := (← read).fileName,
        sourceLine := pos.line }
    let mut acc := initial
    for c in clauses do
      acc ← parseDeployClause env currentNs c acc
    -- Audit-5 (Spec-M1): pass `(some name.raw)` so the public
    -- API has access to a precise diagnostic anchor.  We accept
    -- the 2x parse cost as a tradeoff for keeping `acc`
    -- (with raw Syntax) and `decl` (public string-form) both
    -- available; restructuring `DeploymentDecl` to carry the
    -- raw Syntax would couple the public type to elaborator
    -- internals.  `parseDeployClause` is side-effect-free
    -- (no IO, no sidecar emission) so the duplication is safe.
    validateRequiredDeployClauses acc name.raw
    -- 2. Build a public `DeploymentDecl` for tooling consumption.
    let decl ← parseDeployment env currentNs (← read).fileName pos.line
                                name.getId clauses (some name.raw)
    -- 3. Compute the manifest hash bytes (LX.32).
    let manifestHash := LegalKernel.Runtime.hashStream decl.manifestSourceBytes

    -- 3. Emit `def <name>_id : ByteArray` (LX.32).
    let idDefName := deploymentIdDefName decl.deployName
    let idDefIdent := Lean.mkIdent idDefName
    let idTerm ← byteArrayToTermSyntax decl.deploymentId
    let idDefCmd ← `(
      /-- The deployment's 32-byte cross-deployment-replay-protection
          ID (LX.32).  Audit-3.3 / 3.4 binding: this byte sequence
          flows into `signingInput`, so signatures generated for
          this deployment cannot replay against any other
          deployment with a distinct ID. -/
      def $idDefIdent : ByteArray := $idTerm)
    elabCommand idDefCmd

    -- 4. Emit `def <name>_manifest_hash : ByteArray` (LX.32).
    let manifestHashDefName := deploymentManifestHashDefName decl.deployName
    let manifestHashIdent := Lean.mkIdent manifestHashDefName
    let manifestHashTerm ← byteArrayToTermSyntax manifestHash
    let manifestHashCmd ← `(
      /-- The deployment manifest's deterministic content hash
          (LX.32).  Computed at elaboration time from the parsed
          manifest AST via the canonical CBE encoder + `Runtime.Hash`.
          Equal-shape manifests produce byte-equal hashes; an
          attestor signs this value to commit to a specific
          manifest version. -/
      def $manifestHashIdent : ByteArray := $manifestHashTerm)
    elabCommand manifestHashCmd

    -- 5. Emit `def <name>_authority_policy : AuthorityPolicy`
    -- (LX.32).  Folds the user's authority bindings via
    -- `AuthorityPolicy.intersect` (or `unrestricted` if empty).
    let authPolicyDefName :=
      deploymentAuthorityPolicyDefName decl.deployName
    let authPolicyIdent := Lean.mkIdent authPolicyDefName
    let authIntersectIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.AuthorityPolicy.intersect⟩
    let authUnrestrictedIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.AuthorityPolicy.unrestricted⟩
    -- Splice each binding's `Syntax` directly into the emitted
    -- code.  Captured at parse time as raw user-supplied terms;
    -- spliced into the combined policy expression below.  This
    -- avoids the round-trip through `toString` (which produces
    -- a syntax-tree dump, not re-parseable Lean source) — the
    -- prior implementation's defect.
    let policyTerms : List Lean.Term :=
      (acc.authorityClause.getD []).map (fun (_, exprStx) => ⟨exprStx⟩)
    let combinedPolicy : Lean.Term ←
      match policyTerms with
      | [] => pure authUnrestrictedIdent
      | [p] => pure p
      | p :: rest =>
        rest.foldlM
          (fun acc next => `($authIntersectIdent $acc $next))
          p
    let authPolicyCmd ← `(
      /-- The deployment-scoped authority policy (LX.32).  Folded
          from the user's `deploy_authority` bindings via
          `AuthorityPolicy.intersect`: a signed action must be
          authorised under EVERY binding to be admissible.  An
          empty / unrestricted authority block produces
          `AuthorityPolicy.unrestricted`. -/
      def $authPolicyIdent :
          _root_.LegalKernel.Authority.AuthorityPolicy :=
        $combinedPolicy)
    elabCommand authPolicyCmd

    -- 6. Emit `def <name>_admissible : ExtendedState → SignedAction → Prop`
    -- (LX.32 fix).  Wires the user's authority policy into
    -- `AdmissibleWith` along with the deployment ID.
    let admissibleDefName := deploymentAdmissibleDefName decl.deployName
    let admissibleIdent := Lean.mkIdent admissibleDefName
    let extStateIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.ExtendedState⟩
    let signedActionIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.SignedAction⟩
    let admissibleWithIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.AdmissibleWith⟩
    let verifyIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.Verify⟩
    let admissibleCmd ← `(
      /-- The deployment-scoped admissibility predicate (LX.32).
          Wires the deployment's ID into `AdmissibleWith`'s
          `signingInput` parameter so signatures are bound to this
          specific deployment, AND uses the deployment's
          `_authority_policy` (folded from the user's
          `deploy_authority` bindings) for authorisation
          decisions. -/
      def $admissibleIdent :
          $extStateIdent → $signedActionIdent → Prop :=
        fun es st => $admissibleWithIdent $verifyIdent
          $authPolicyIdent $idDefIdent es st)
    elabCommand admissibleCmd

    -- 7. Emit `def <name>_deployment : Deployment` (LX.31).
    let lawBindingTerms : Array Lean.Term ← decl.laws.toArray.mapM
      (fun b => do
        let resolvedName := toString b.lawIdent
        `(({ localName := $(Lean.quote b.localName),
             lawIdent := Lean.Name.mkSimple $(Lean.quote resolvedName),
             version := $(Lean.quote b.version) } : _root_.LegalKernel.DSL.LawBinding)))
    let resourcePairTerms : Array Lean.Term ← decl.resources.toArray.mapM
      (fun (n, idx) => do
        `(($(Lean.quote n), $(Lean.quote idx))))
    let claimKindTagsTerms : Array Lean.Term ← decl.invariantClaims.toArray.mapM
      (fun c => do
        let lawArrTerms := c.lawNames.toArray.map Lean.quote
        let kindTerm : Lean.Term ←
          match c.kind with
          | .monotonicLawSet =>
            `(_root_.LegalKernel.DSL.InvariantClaimKind.monotonicLawSet)
          | .conservativeLawSet =>
            `(_root_.LegalKernel.DSL.InvariantClaimKind.conservativeLawSet)
          | .freezePreservingLawSet =>
            `(_root_.LegalKernel.DSL.InvariantClaimKind.freezePreservingLawSet)
        let scopeTerm : Lean.Term ←
          match c.scope with
          | .explicit _ =>
            `(_root_.LegalKernel.DSL.InvariantClaimScope.explicit
                [ $[$lawArrTerms],* ])
          | .wildcard =>
            `(_root_.LegalKernel.DSL.InvariantClaimScope.wildcard)
        `(({ kind := $kindTerm,
             scope := $scopeTerm } : _root_.LegalKernel.DSL.InvariantClaim)))
    let authBindingTerms : Array Lean.Term ← decl.authority.toArray.mapM
      (fun b => do
        `(({ localName := $(Lean.quote b.localName),
             policyExpr := $(Lean.quote b.policyExpr) }
            : _root_.LegalKernel.DSL.AuthorityBinding)))
    let depDefName := deploymentDefName decl.deployName
    let depDefIdent := Lean.mkIdent depDefName
    let deploymentCmd ← `(
      /-- The deployment manifest record (LX.31).  Bundles every
          clause declared in the `deployment` block as data.
          Tooling (`lex_diff`, future `canon manifest inspect`
          CLI) consumes this record. -/
      def $depDefIdent : _root_.LegalKernel.DSL.Deployment :=
        { identifier := $(Lean.quote decl.identifier),
          deploymentId := $idDefIdent,
          version := $(Lean.quote decl.version),
          resources := [ $[$resourcePairTerms],* ],
          laws := [ $[$lawBindingTerms],* ],
          authority := [ $[$authBindingTerms],* ],
          invariantClaims := [ $[$claimKindTagsTerms],* ],
          manifestHashBytes := $manifestHashIdent })
    elabCommand deploymentCmd

    -- 8. Emit per-claim invariant-claim defs (LX.33).
    -- Each claim becomes a `def <name>_<claim>_<idx> : <LawSet>`.
    let resourceIds := decl.resources.map (·.2)
    -- Build a map: localName → resolved Name (from law bindings).
    let lawsToList : List (String × Lean.Name) :=
      decl.laws.map (fun b => (b.localName, b.lawIdent))
    let resolveLocalLaw (lnm : String) : CommandElabM Lean.Name := do
      match lawsToList.find? (fun (n, _) => n == lnm) with
      | some (_, resolvedName) =>
        if resolvedName == Lean.Name.anonymous then
          throwErrorAt name.raw
            s!"L008: deployment `{decl.deployName}`'s invariant-claim references law `{lnm}` whose `lawIdent` did not resolve at parse time; check the `deploy_laws` binding for typos"
        return resolvedName
      | none =>
        match resolveLawName env currentNs lnm with
        | some n => return n
        | none =>
          throwErrorAt name.raw
            s!"L008: deployment `{decl.deployName}`'s invariant-claim references unknown law `{lnm}`; either add it to `deploy_laws` or remove it from the claim"
    for h : i in [:decl.invariantClaims.length] do
      let claim := decl.invariantClaims[i]
      let claimName := deploymentClaimDefName decl.deployName claim.kind i
      let claimIdent := Lean.mkIdent claimName
      -- Resolve the claim's law list (handling wildcard).
      let effectiveNames : List String ←
        match claim.scope with
        | .explicit names => pure names
        | .wildcard       =>
          -- Wildcard expansion (LX.33): the law list is the
          -- deployment's full `deploy_laws` localName list.
          pure (decl.laws.map (·.localName))
      let mut resolvedLaws : List Lean.Name := []
      for lnm in effectiveNames do
        let n ← resolveLocalLaw lnm
        resolvedLaws := resolvedLaws ++ [n]
      let claimCmd ← match claim.kind with
        | .monotonicLawSet =>
          let body ← synth_monotonic_law_set resolvedLaws
          `(/-- A monotonic-law-set invariant claim (LX.33).
                Synthesised from the per-law `IsMonotonic`
                instance bag via `MonotonicLawSet.cons` chaining;
                missing instances surface as `failed to
                synthesize` diagnostics naming the offending
                law. -/
            def $claimIdent : _root_.LegalKernel.MonotonicLawSet := $body)
        | .conservativeLawSet =>
          let body ← synth_conservative_law_set resolvedLaws
          `(/-- A conservative-law-set invariant claim (LX.33). -/
            def $claimIdent :
                _root_.LegalKernel.ConservativeLawSet := $body)
        | .freezePreservingLawSet =>
          let body ← synth_freeze_preserving_law_set resourceIds resolvedLaws
          let resTerms : Array Lean.Term ← resourceIds.toArray.mapM
            (fun n => `(($(Lean.quote n) : _root_.LegalKernel.ResourceId)))
          `(/-- A freeze-preserving-law-set invariant claim (LX.33).
                The resource set `S` is the deployment's
                `deploy_resources` list (or, under wildcard,
                expanded from `[* @ {*}]`). -/
            def $claimIdent :
                _root_.LegalKernel.FreezePreservingLawSet
                  [ $[$resTerms],* ] := $body)
      try
        elabCommand claimCmd
      catch e =>
        let msg ← e.toMessageData.toString
        throwErrorAt name.raw
          s!"L008: deployment `{decl.deployName}`'s invariant claim {i} failed to synthesize: {msg}"

end LegalKernel.DSL
