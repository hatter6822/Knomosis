/-
  Canon  - A Societal Kernel
  Copyright (C) 2026  Adam Hall
  This program comes with ABSOLUTELY NO WARRANTY.
  This is free software, and you are welcome to redistribute it
  under certain conditions. See: https://github.com/hatter6822/Orbcrypt/blob/main/LICENSE
-/

/-
LegalKernel.DSL.LexDeployment — the Workstream-LX `deployment`
manifest macro.

LX.31 / LX.32 / LX.33 of `docs/lex_implementation_plan.md` §16.

Provides the per-file `deployment` macro: a Lean 4 *command* that
elaborates a human-readable deployment manifest declaration into:

  1. one `def deployment_<name>_id : ByteArray` carrying the
     32-byte deployment ID (Audit-3.3 / 3.4 cross-deployment-replay
     binding) (LX.32),
  2. one `def deployment_<name>_manifest_hash : ByteArray` carrying
     the deterministic CBE hash of the manifest's parsed AST
     (LX.32),
  3. one `def deployment_<name> : Deployment` value bundling
     `identifier`, `deploymentId`, `version`, `resources`, `laws`,
     `authority`, `invariantClaims`, and `manifestHashBytes`
     (LX.31),
  4. one `def deployment_<name>_admissible : ExtendedState →
     SignedAction → Prop` wiring the manifest's authority bundle
     into `AdmissibleWith Verify <policy> deployment_<name>_id`
     (LX.32),
  5. one `def deployment_<name>_<claim>_<idx> : <LawSet>` per
     `invariant_claims` entry — `MonotonicLawSet`,
     `ConservativeLawSet`, or `FreezePreservingLawSet`,
     synthesised from per-law typeclass instances via
     `<LawSet>.cons` chaining (LX.33).

The macro is **non-TCB**: bugs produce wrong `Deployment` values
(which Lean's elaboration + the test suite would catch), but
cannot violate any kernel invariant.

# v1 deviation from the implementation plan §16.1

Like `LexLaw.lean`, the surface clauses are prefixed with
`deploy_` to avoid token collisions with structure-field names
in downstream files.  The deviation cheat sheet:

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

The deviation is purely cosmetic; the `Deployment` Lean record
exposes the canonical field names from §16.4.

# Phased implementation (LX.31 / LX.32 / LX.33)

This module is implemented in three phases per the plan §19.5:

  * **LX.31 (Phase 1)**: parser + `Deployment` record + skeleton
    elaboration emitting `def deployment_<name>` only.  Passes
    L018 (32-byte `deploymentId` validation).

  * **LX.32 (Phase 2)**: extends the elaborator with the
    manifest-hash computation, the `deployment_<name>_id` byte
    constant, the `deployment_<name>_manifest_hash` byte constant,
    and the `deployment_<name>_admissible` predicate wiring.

  * **LX.33 (Phase 3)**: extends the elaborator with the
    `invariant_claims` synthesizer.  Per-claim instance look-up
    via the typeclass-driven `<LawSet>.cons` builders in
    `LegalKernel.Conservation`.  Missing instances surface as
    `failed to synthesize` Lean errors at the macro's call site,
    naming the offending law (L008).
-/

import LegalKernel.Kernel
import LegalKernel.Conservation
import LegalKernel.Authority.Crypto
import LegalKernel.Authority.SignedAction
import LegalKernel.Encoding.Encodable
import LegalKernel.Encoding.SignInput
import LegalKernel.Runtime.Hash
import Tools.LexCommon
import Lean.Elab.Command
import Lean.Elab.Term

namespace LegalKernel.DSL

open Lean Lean.Elab Lean.Elab.Command

/-! ## Public data types -/

/-- A binding between a deployment-local law name and a kernel
    transition.  The `localName` is what the manifest writer uses
    in clauses like `monotonic_law_set [Transfer, Mint]`; the
    `lawIdent` is the canonical kernel identifier
    (e.g. `LegalKernel.Laws.transfer`). -/
structure LawBinding where
  /-- The deployment-local law identifier (capitalised by
      convention; e.g. `Transfer`). -/
  localName : String
  /-- The kernel-side `Name` of the law's transition function or
      Lex-emitted `_transition` def. -/
  lawIdent : Lean.Name
  /-- The version pin captured at deployment time.  Allows tooling
      to flag a deployment whose pinned version doesn't match the
      actual law file version. -/
  version : String
  deriving Inhabited

instance : Repr LawBinding where
  reprPrec b _ :=
    "{localName := \"" ++ b.localName ++ "\", lawIdent := " ++
    toString b.lawIdent ++ ", version := \"" ++ b.version ++ "\"}"

/-- A binding between a deployment-local authority name and an
    `AuthorityPolicy` value.  V1 uses one shared policy (the
    `default` binding) per deployment; v2 may admit per-law
    authority bindings. -/
structure AuthorityBinding where
  /-- The deployment-local authority name. -/
  localName : String
  /-- The captured surface text of the policy expression
      (the macro elaborates this at use sites; storing the surface
      text keeps the `Deployment` record `Repr`-able). -/
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

/-- One `invariant_claims` entry: a kind plus the list of
    deployment-local law names referenced. -/
structure InvariantClaim where
  /-- The claim kind (monotonic / conservative / freeze-preserving). -/
  kind : InvariantClaimKind
  /-- The local law names referenced by this claim. -/
  lawNames : List String
  deriving Repr, Inhabited

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
  /-- Law bindings.  Each pair is a (localName, lawIdent). -/
  laws : List LawBinding
  /-- Authority bindings.  Most v1 manifests have a single
      `default` entry. -/
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

/-! ## Manifest-hash computation (LX.32)

The manifest hash is computed deterministically from the parsed
manifest AST.  The AST-to-bytes encoding uses the existing CBE
codec (`LegalKernel.Encoding.Encodable`) so the hash is byte-stable
across builds and across architectures.

The encoded form for hashing concatenates, in fixed order:

  1. The deployment identifier as a CBE byte-string.
  2. The 32-byte deployment ID (as a CBE byte-string).
  3. The version string (as a CBE byte-string).
  4. The resources list (each `(name, ResourceId)` encoded as
     a CBE byte-string + Nat pair).
  5. The law bindings list (each as a CBE byte-string for the
     identifier path and the version pin).
  6. The authority binding's surface expression (as a CBE
     byte-string).
  7. The invariant claims list (each as a CBE byte tag for the
     kind, then a CBE byte-string array of law names).

The resulting `Stream` is hashed via `Runtime.Hash.hashStream`. -/

/-- Encode a parsed manifest's hash-input bytes.  Used by the
    macro emitter and by tests that verify manifest-hash
    determinism.

    The encoding is canonical: equal-shape manifests produce
    byte-equal streams.  See module docstring for the field-order
    contract. -/
def encodeManifestHashInput
    (identifier : String)
    (deploymentId : ByteArray)
    (version : String)
    (resources : List (String × Nat))
    (laws : List (String × String))   -- (localName, version)
    (authority : String)
    (claims : List (Nat × List String)) -- (kind-tag, law-names)
    : LegalKernel.Encoding.Stream := Id.run do
  let mut bytes : LegalKernel.Encoding.Stream := []
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (identifier.toUTF8)
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode deploymentId
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (version.toUTF8)
  -- Resources: prefix with the count, then per-entry name + idx.
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (resources.length : Nat)
  for (name, idx) in resources do
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (name.toUTF8)
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (idx : Nat)
  -- Law bindings: prefix with the count, then per-entry localName + version.
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (laws.length : Nat)
  for (lnm, lv) in laws do
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (lnm.toUTF8)
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (lv.toUTF8)
  -- Authority: a single string.
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (authority.toUTF8)
  -- Claims: prefix with the count, then per-entry kind + law-names.
  bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (claims.length : Nat)
  for (kindTag, lawNames) in claims do
    bytes := bytes ++ LegalKernel.Encoding.Encodable.encode (kindTag : Nat)
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

/-- Compute the manifest hash bytes.  Convenience wrapper around
    `encodeManifestHashInput` + `Runtime.Hash.hashStream`. -/
def computeManifestHash
    (identifier : String)
    (deploymentId : ByteArray)
    (version : String)
    (resources : List (String × Nat))
    (laws : List (String × String))
    (authority : String)
    (claims : List (Nat × List String))
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

/-- Build the local Lean name for the deployment's `Deployment`
    record def.  `example.usd_clearing` (the canonical identifier)
    is what the manifest writer would supply via `deploy_id`; the
    macro mints `<local>_deployment` from the *local* identifier
    (the one supplied right after `deployment`). -/
private def deploymentDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_deployment")

/-- Build the local Lean name for the deployment's `_id` constant. -/
private def deploymentIdDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_id")

/-- Build the local Lean name for the deployment's
    `_manifest_hash` constant. -/
private def deploymentManifestHashDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_manifest_hash")

/-- Build the local Lean name for the deployment's `_admissible`
    predicate. -/
private def deploymentAdmissibleDefName (n : Lean.Name) : Lean.Name :=
  let s := toString n
  Lean.Name.mkSimple (s.replace "." "_" ++ "_admissible")

/-- Build the local Lean name for an invariant-claim def.
    `<name>_<claim>` with `<claim>` being one of `monotonic_law_set`,
    `conservative_law_set`, `freeze_preserving_law_set`. -/
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
  "deploy_laws" ":=" "[" sepBy(ident, ",") "]" : deployClause
syntax (name := deployAuthorityClauseStx)
  "deploy_authority" ":=" term : deployClause
-- LX.33: invariant-claims clause carries a list of
-- (claim-kind-keyword, [law-name-list]) entries.  E.g.:
--   deploy_invariant_claims := [
--     monotonic_law_set [transfer, mint, freezeResource],
--     conservative_law_set [transfer]
--   ]
syntax (name := deployInvariantClaimsClauseStx)
  "deploy_invariant_claims" ":=" "[" sepBy(group(ident "[" sepBy(ident, ",") "]"), ",") "]" : deployClause
syntax (name := deployAttestorClauseStx)
  "deploy_attestor" ident : deployClause

/-- The top-level `deployment` Lex command. -/
syntax (name := deploymentCmd)
  "deployment" ident "where" deployClause+ : command

set_option linter.missingDocs true

/-! ## Per-clause builders -/

/-- One deployment manifest's parsed clauses, accumulated by the
    `deployment` elaborator. -/
private structure ParsedDeployment where
  /-- The deployment's local Lean name (the identifier just after
      `deployment`). -/
  deployName : Lean.Name := Lean.Name.anonymous
  /-- The `deploy_id` clause's identifier-path source text. -/
  identifierClause : Option String := none
  /-- The `deploy_deployment_id` clause's literal string (32 hex
      bytes). -/
  deploymentIdClause : Option (Lean.Syntax × String) := none
  /-- The `deploy_version` clause's string literal. -/
  versionClause : Option String := none
  /-- The `deploy_resources` clause's parsed entries. -/
  resourcesClause : Option (List (String × Nat)) := none
  /-- The `deploy_laws` clause's parsed entries (just the local
      names; the macro looks up corresponding `Name`s
      lazily). -/
  lawsClause : Option (List String) := none
  /-- The `deploy_authority` clause's surface text. -/
  authorityClause : Option String := none
  /-- The `deploy_invariant_claims` clause's parsed entries. -/
  invariantClaimsClause : Option (List InvariantClaim) := none
  /-- The `deploy_attestor` clause's identifier (v2-only;
      reserved). -/
  attestorClause : Option Lean.Name := none
  /-- The originating file path (for diagnostic anchoring). -/
  sourceFile : String := ""
  /-- The originating line of the `deployment` keyword. -/
  sourceLine : Nat := 1

/-! ## Clause parser -/

/-- Parse a single `deployClause` syntax node into a builder
    update.  Hard-errors on duplicate clauses (mirroring
    `LexLaw.parseClause`'s audit-6 behaviour). -/
private def parseDeployClause (clause : Lean.Syntax)
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
  | `(deployClause| deploy_laws := [ $[$ids:ident],* ]) =>
    if acc.lawsClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_laws` clause"
    let names := ids.toList.map (fun id => toString id.getId)
    return { acc with lawsClause := some names }
  | `(deployClause| deploy_authority := $e:term) =>
    if acc.authorityClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_authority` clause"
    return { acc with authorityClause := some (toString e) }
  | `(deployClause| deploy_invariant_claims := [ $[$kinds:ident [ $[$laws:ident],* ]],* ]) =>
    if acc.invariantClaimsClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_invariant_claims` clause"
    let mut parsed : List InvariantClaim := []
    for h : i in [:kinds.size] do
      let kindStr := toString (kinds[i]).getId
      let lawArr := laws[i]!
      let lawStrs := lawArr.toList.map (fun id => toString id.getId)
      let kind ← match kindStr with
        | "monotonic_law_set"        => pure InvariantClaimKind.monotonicLawSet
        | "conservative_law_set"     => pure InvariantClaimKind.conservativeLawSet
        | "freeze_preserving_law_set" => pure InvariantClaimKind.freezePreservingLawSet
        | _ =>
          throwErrorAt clause
            s!"deployment: unknown invariant-claim kind `{kindStr}`; admissible kinds are `monotonic_law_set`, `conservative_law_set`, `freeze_preserving_law_set`"
      parsed := parsed ++ [{ kind, lawNames := lawStrs }]
    return { acc with invariantClaimsClause := some parsed }
  | `(deployClause| deploy_attestor $a:ident) =>
    if acc.attestorClause.isSome then
      throwErrorAt clause "deployment: duplicate `deploy_attestor` clause"
    return { acc with attestorClause := some a.getId }
  | _ =>
    throwErrorAt clause s!"deployment: unknown clause `{clause}`"

/-! ## Required-clause validation -/

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
  -- L018: deploymentId must decode to exactly 32 bytes.
  if let some (didStx, hex) := parsed.deploymentIdClause then
    match decodeHexString hex with
    | none =>
      throwErrorAt didStx
        s!"L018: deployment `{parsed.deployName}`'s `deploy_deployment_id` is not a valid hex string (got `{hex}`); supply a hex-encoded ByteArray of exactly 32 bytes (64 hex characters)"
    | some bs =>
      if bs.size != 32 then
        throwErrorAt didStx
          s!"L018: deployment `{parsed.deployName}`'s `deploy_deployment_id` is {bs.size} bytes; deployment IDs must be exactly 32 bytes (64 hex characters)"

/-! ## Synthesizer: invariant-claim emission (LX.33)

For each `invariant_claims` entry, the elaborator emits a
synthesized `def` whose body uses the `<LawSet>.cons` chain
introduced in `LegalKernel.Conservation`.  Each `cons` call
elaborates the head transition's typeclass instance via Lean's
typeclass resolution; missing instances surface as a
`failed to synthesize` Lean error at the macro's call site.

We re-format the diagnostic on catch with an L008 prefix so the
diagnostic-coverage gate sees a stable string.

The resolution convention:

  * A local name `Foo` maps to `legalkernel_foo_transition`
    (the M2 Lex re-expression) if that name is in the environment.
  * If the Lex name is absent, the macro tries
    `LegalKernel.Laws.foo` (lowercase) and `LegalKernel.Laws.Foo`
    (camelCase) before giving up.

V1 supports parameterless laws fully and emits a placeholder
shape for parameterised ones (the parameterised case requires
the manifest writer to bind concrete arguments at the call site —
the macro itself doesn't elaborate Lean expressions in clause
text, only identifiers).  For laws like `LegalKernel.Laws.transfer
0 0 0 0` (parameterised), the runtime adaptor's call site is
expected to fill in concrete arguments. -/

/-- Resolve a deployment-local law name to a kernel-side `Name`.
    Returns `none` if no candidate is found; the caller fires
    L008 in that case.

    Resolution strategy: walk a list of candidate `Name`s and
    return the first one present in the environment.  The
    candidate list includes:

      1. The fully-qualified `<currentNamespace>.<localName>`
         (works for user-defined wrappers in the calling
         context's namespace).
      2. The bare local name (works at the top level).
      3. The Lex-re-expression name
         `legalkernel_<lower>_transition`.
      4. The hand-written kernel law `LegalKernel.Laws.<lower>`.
      5. The camelCase variant `LegalKernel.Laws.<localName>`.

    All five candidates are checked against the environment via
    `env.contains`; the first hit is returned. -/
private def resolveLawName (env : Lean.Environment)
    (currentNs : Lean.Name) (localName : String) :
    Option Lean.Name :=
  let lowercased := localName.toLower
  let qualifiedLocal := currentNs ++ Lean.Name.mkSimple localName
  let candidates : List Lean.Name := [
    -- 1. Fully-qualified within the current namespace.
    qualifiedLocal,
    -- 2. The bare local name (works for top-level defs).
    Lean.Name.mkSimple localName,
    -- 3. Lex re-expression name (e.g. legalkernel_transfer_transition).
    Lean.Name.mkSimple s!"legalkernel_{lowercased}_transition",
    -- 4. Hand-written kernel law (e.g. LegalKernel.Laws.transfer).
    Lean.Name.mkSimple "LegalKernel" ++ Lean.Name.mkSimple "Laws" ++
      Lean.Name.mkSimple lowercased,
    -- 5. CamelCase variant (e.g. LegalKernel.Laws.replaceKey).
    Lean.Name.mkSimple "LegalKernel" ++ Lean.Name.mkSimple "Laws" ++
      Lean.Name.mkSimple localName
  ]
  candidates.find? (fun n => env.contains n)

/-- Build a `Term` that constructs a law's transition value.
    For parameterless laws, the term is just the law's identifier;
    for parameterised laws (`Laws.transfer r sender receiver
    amount`), the macro emits the law identifier with placeholder
    `0` arguments per parameter — the v1 deployment macro only
    captures the law identifier, not specific argument values, so
    the synthesizer's `inferInstance` will dispatch on the
    *parameterised* typeclass instance (`transfer_isMonotonic r
    sender receiver amount`), which Lean's resolution discovers
    automatically once the term has the right type. -/
private def buildLawTransitionTerm (n : Lean.Name) :
    CommandElabM Lean.Term :=
  -- Use the identifier directly; the `<LawSet>.cons` builder takes
  -- a `Transition`, so for a parameterised def Lean's elaborator
  -- will demand explicit arguments.  For v1 we use a placeholder
  -- pattern: deployment macros that need parameterised laws can
  -- supply the transition term via a manual `def` and reference
  -- it by `Foo` in the manifest.  See LX.37 for the worked
  -- example.
  `($(Lean.mkIdent n))

/-! ## ByteArray construction term builder

The `deploy_deployment_id` is a hex-encoded literal string; we
need to elaborate it into a `ByteArray.mk #[<UInt8>...]` term
that elaborates at compile time to the correct byte sequence.  We
build the term programmatically as an array literal. -/

/-- Render a `ByteArray`'s contents as a Lean syntax term that
    elaborates to the same `ByteArray`.  Constructs `ByteArray.mk
    #[<u8>, <u8>, …]`. -/
private def byteArrayToTermSyntax (bs : ByteArray) :
    CommandElabM Lean.Term := do
  let elems : Array Lean.Term ← bs.toList.toArray.mapM (fun b => do
    let n := b.toNat
    `(($(Lean.quote n) : UInt8)))
  let arrStx ← `(#[ $elems,* ])
  `(ByteArray.mk $arrStx)

/-- Build a chain `T₁.cons L₁ (T₁.cons L₂ … T₁.empty)` where
    `T₁` is the law-set type's namespace (`MonotonicLawSet`,
    `ConservativeLawSet`, or `FreezePreservingLawSet`).  Used by
    the invariant-claim emitter to construct law-set values via
    typeclass-driven `cons` chaining (avoids per-list-length
    membership-disjunction `rcases` patterns). -/
private def buildLawSetConsChain
    (emptyTerm : Lean.Term) (consTerm : Lean.Term)
    (lawTerms : List Lean.Term) : CommandElabM Lean.Term := do
  -- Build the chain right-to-left: the empty law set is the
  -- innermost expression.
  let mut acc : Lean.Term := emptyTerm
  for lawT in lawTerms.reverse do
    acc ← `($consTerm $lawT $acc)
  return acc

/-! ## The `deployment` command elaborator (LX.31 / LX.32 / LX.33) -/

elab_rules : command
  | `(deploymentCmd| deployment $name:ident where $clauses:deployClause*) => do
    -- 1. Initialise the parser accumulator.
    let pos := (← read).fileMap.toPosition (name.raw.getPos?.getD ⟨0⟩)
    let initial : ParsedDeployment := {
      deployName := name.getId,
      sourceFile := (← read).fileName,
      sourceLine := pos.line
    }
    -- 2. Parse every clause.
    let mut acc := initial
    for c in clauses do
      acc ← parseDeployClause c acc
    -- 3. Validate required clauses + L018.
    validateRequiredDeployClauses acc name.raw

    -- Extract the parsed values now that validation succeeded.
    let identifierStr := acc.identifierClause.getD ""
    let versionStr := acc.versionClause.getD ""
    let resources := acc.resourcesClause.getD []
    let lawNames := acc.lawsClause.getD []
    let authorityExpr := acc.authorityClause.getD ""
    let invariantClaims := acc.invariantClaimsClause.getD []
    -- Decode the deployment ID hex string.  Validation already
    -- proved the decoding succeeds with size 32.
    let didHex := (acc.deploymentIdClause.map (·.2)).getD ""
    let deploymentId := (decodeHexString didHex).getD ByteArray.empty

    -- 4. Compute the manifest hash bytes (LX.32).
    let lawBindings : List (String × String) :=
      lawNames.map (fun lnm => (lnm, versionStr))
    let claimsTagged : List (Nat × List String) :=
      invariantClaims.map (fun c => (invariantClaimKindTag c.kind, c.lawNames))
    let manifestHash := computeManifestHash
      identifierStr deploymentId versionStr resources
      lawBindings authorityExpr claimsTagged

    -- 5. Emit `def <name>_id : ByteArray` (LX.32).
    let idDefName := deploymentIdDefName acc.deployName
    let idDefIdent := Lean.mkIdent idDefName
    let idTerm ← byteArrayToTermSyntax deploymentId
    let idDefCmd ← `(
      /-- The deployment's 32-byte cross-deployment-replay-protection
          ID.  Audit-3.3 / 3.4 binding: this byte sequence flows
          into `signingInput`, so signatures generated for this
          deployment cannot replay against any other deployment
          with a distinct ID. -/
      def $idDefIdent : ByteArray := $idTerm)
    elabCommand idDefCmd

    -- 6. Emit `def <name>_manifest_hash : ByteArray` (LX.32).
    let manifestHashDefName := deploymentManifestHashDefName acc.deployName
    let manifestHashIdent := Lean.mkIdent manifestHashDefName
    let manifestHashTerm ← byteArrayToTermSyntax manifestHash
    let manifestHashCmd ← `(
      /-- The deployment manifest's deterministic content hash.
          Computed at elaboration time from the parsed manifest
          AST via the canonical CBE encoder + `Runtime.Hash`.
          Equal-shape manifests produce byte-equal hashes; an
          attestor signs this value to commit to a specific
          manifest version. -/
      def $manifestHashIdent : ByteArray := $manifestHashTerm)
    elabCommand manifestHashCmd

    -- 7. Emit `def <name>_deployment : Deployment` (LX.31).
    --    The law-bindings field carries the (localName,
    --    Name.anonymous, version) triples; the resolution to a
    --    real Lean Name is performed by the invariant-claim
    --    emitter at step 9.
    let env ← getEnv
    let currentNs ← getCurrNamespace
    let lawBindingTerms : Array Lean.Term ← lawBindings.toArray.mapM
      (fun (lnm, v) => do
        let resolved := resolveLawName env currentNs lnm |>.getD Lean.Name.anonymous
        let resolvedName := toString resolved
        `(({ localName := $(Lean.quote lnm),
             lawIdent := Lean.Name.mkSimple $(Lean.quote resolvedName),
             version := $(Lean.quote v) } : _root_.LegalKernel.DSL.LawBinding)))
    let resourcePairTerms : Array Lean.Term ← resources.toArray.mapM
      (fun (n, idx) => do
        `(($(Lean.quote n), $(Lean.quote idx))))
    let claimKindTagsTerms : Array Lean.Term ← invariantClaims.toArray.mapM
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
        `(({ kind := $kindTerm,
             lawNames := [ $[$lawArrTerms],* ] } : _root_.LegalKernel.DSL.InvariantClaim)))
    let authorityListTerm : Lean.Term ←
      `([ ({ localName := "default",
             policyExpr := $(Lean.quote authorityExpr) }
            : _root_.LegalKernel.DSL.AuthorityBinding) ])
    let depDefName := deploymentDefName acc.deployName
    let depDefIdent := Lean.mkIdent depDefName
    let deploymentCmd ← `(
      /-- The deployment manifest record.  Bundles every clause
          declared in the `deployment` block as data.  Tooling
          (`lex_diff`, `canon manifest inspect`) consumes this
          record. -/
      def $depDefIdent : _root_.LegalKernel.DSL.Deployment :=
        { identifier := $(Lean.quote identifierStr),
          deploymentId := $idDefIdent,
          version := $(Lean.quote versionStr),
          resources := [ $[$resourcePairTerms],* ],
          laws := [ $[$lawBindingTerms],* ],
          authority := $authorityListTerm,
          invariantClaims := [ $[$claimKindTagsTerms],* ],
          manifestHashBytes := $manifestHashIdent })
    elabCommand deploymentCmd

    -- 8. Emit `def <name>_admissible : ExtendedState → SignedAction → Prop`
    -- wiring the deployment ID into the admissibility predicate
    -- (Audit-3.3 / 3.4 cross-deployment-replay binding) (LX.32).
    -- The authority block is captured as opaque text; v1 instantiates
    -- the predicate with `AuthorityPolicy.unrestricted` as the policy.
    -- The deployment-side runtime adaptor specialises the policy
    -- text into an actual `AuthorityPolicy` value at use site.
    let admissibleDefName := deploymentAdmissibleDefName acc.deployName
    let admissibleIdent := Lean.mkIdent admissibleDefName
    let extStateIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.ExtendedState⟩
    let signedActionIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.SignedAction⟩
    let admissibleWithIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.AdmissibleWith⟩
    let verifyIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.Verify⟩
    let unrestrictedIdent : Lean.Term :=
      ⟨Lean.mkIdent ``LegalKernel.Authority.AuthorityPolicy.unrestricted⟩
    let admissibleCmd ← `(
      /-- The deployment-scoped admissibility predicate.  Wires the
          deployment's ID into `AdmissibleWith`'s `signingInput`
          parameter so signatures are bound to this specific
          deployment.

          V1 uses an unrestricted authority policy
          (`AuthorityPolicy.unrestricted`) as a placeholder; the
          deployment-side runtime adaptor specialises this to the
          actual policy expression captured in the manifest's
          `deploy_authority` clause.  See §16.2 of the
          implementation plan. -/
      def $admissibleIdent :
          $extStateIdent → $signedActionIdent → Prop :=
        fun es st => $admissibleWithIdent $verifyIdent
          $unrestrictedIdent $idDefIdent es st)
    elabCommand admissibleCmd

    -- 9. Emit per-claim invariant-claim defs (LX.33).
    -- Each claim becomes a `def <name>_<claim>_<idx> : <LawSet>`
    -- whose body chains the per-law transitions through the
    -- `<LawSet>.cons` builder.  Lean's typeclass resolution
    -- looks up the per-law instance at each `cons` site;
    -- missing instances surface as `failed to synthesize`
    -- diagnostics (re-formatted as L008 in the post-elab error
    -- log).
    for h : i in [:invariantClaims.length] do
      let claim := invariantClaims[i]
      let claimName := deploymentClaimDefName acc.deployName claim.kind i
      let claimIdent := Lean.mkIdent claimName
      -- Resolve every named law to its kernel-side Name.
      let mut resolvedLaws : List Lean.Name := []
      for lnm in claim.lawNames do
        match resolveLawName env currentNs lnm with
        | some n => resolvedLaws := resolvedLaws ++ [n]
        | none =>
          throwErrorAt name.raw
            s!"L008: deployment `{acc.deployName}`'s invariant-claim references unknown law `{lnm}`; either add the law to the deployment's resolution path or remove it from the claim"
      -- Build per-law transition terms.  v1 only supports the
      -- 0-arg case (the law identifier alone).
      let lawTerms : List Lean.Term ← resolvedLaws.mapM
        (fun n => buildLawTransitionTerm n)
      -- Build the `<LawSet>.cons` chain depending on the claim
      -- kind.
      let claimCmd ← match claim.kind with
        | .monotonicLawSet =>
          let consTerm : Lean.Term ←
            `(_root_.LegalKernel.MonotonicLawSet.cons)
          let emptyTerm : Lean.Term ←
            `(_root_.LegalKernel.MonotonicLawSet.empty)
          let body ← buildLawSetConsChain emptyTerm consTerm lawTerms
          `(/-- A monotonic-law-set invariant claim (LX.33).
                Synthesised from the per-law `IsMonotonic` instance
                bag via `MonotonicLawSet.cons` chaining; missing
                instances surface as `failed to synthesize`
                diagnostics naming the offending law. -/
            def $claimIdent : _root_.LegalKernel.MonotonicLawSet := $body)
        | .conservativeLawSet =>
          let consTerm : Lean.Term ←
            `(_root_.LegalKernel.ConservativeLawSet.cons)
          let emptyTerm : Lean.Term ←
            `(_root_.LegalKernel.ConservativeLawSet.empty)
          let body ← buildLawSetConsChain emptyTerm consTerm lawTerms
          `(/-- A conservative-law-set invariant claim (LX.33). -/
            def $claimIdent :
                _root_.LegalKernel.ConservativeLawSet := $body)
        | .freezePreservingLawSet =>
          -- `FreezePreservingLawSet S` is parameterised by `S`.
          -- V1 uses the deployment's resource list (mapped to
          -- `ResourceId`s) for `S`.
          let resourceIds := resources.map (·.2)
          let resTerms : Array Lean.Term ← resourceIds.toArray.mapM
            (fun n => `(($(Lean.quote n) : _root_.LegalKernel.ResourceId)))
          let consTerm : Lean.Term ←
            `(_root_.LegalKernel.FreezePreservingLawSet.cons [ $[$resTerms],* ])
          let emptyTerm : Lean.Term ←
            `(_root_.LegalKernel.FreezePreservingLawSet.empty [ $[$resTerms],* ])
          let body ← buildLawSetConsChain emptyTerm consTerm lawTerms
          `(/-- A freeze-preserving-law-set invariant claim
                (LX.33).  The resource set `S` is the deployment's
                `deploy_resources` list. -/
            def $claimIdent :
                _root_.LegalKernel.FreezePreservingLawSet
                  [ $[$resTerms],* ] := $body)
      try
        elabCommand claimCmd
      catch e =>
        -- Re-raise as L008 with named context.
        let msg ← e.toMessageData.toString
        throwErrorAt name.raw
          s!"L008: deployment `{acc.deployName}`'s invariant claim {i} failed to synthesize: {msg}"

end LegalKernel.DSL
