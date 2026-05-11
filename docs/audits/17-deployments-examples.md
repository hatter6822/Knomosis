# Deployments — `Deployments/Examples/UsdClearing.lean` and `Lex/Examples/`

**Files:**
* `Deployments.lean` (23 lines) — umbrella, covered in `16-executables.md`
* `Deployments/Examples/UsdClearing.lean` (187 lines)
* `Lex/Examples/ExampleLex.lean` (will be reviewed below)

**TCB:** None.  Both are example / demonstration code.

---

## `Deployments/Examples/UsdClearing.lean`

### Imports (lines 63–66)

```
import Lex.DSL.Deployment
import LegalKernel.Laws.Transfer
import LegalKernel.Laws.Mint
import LegalKernel.Laws.Freeze
```

* Pulls the Lex `deployment` macro and the three kernel laws used
  by the manifest.

**Finding:** Imports are correct.

### Parameterless wrappers (lines 79–104)

Four parameterless wrappers each constructed as a fixed-fixture
specialisation of a parameterised law, plus an `IsMonotonic`
instance that delegates to the underlying parameterised instance.

```lean
def transferWrapper : Transition := Laws.transfer 0 0 0 0
instance transferWrapper_isMonotonic : IsMonotonic transferWrapper :=
  transfer_isMonotonic 0 0 0 0
```

**Hazard observation:** The fixture `(0, 0, 0, 0)` is sender =
receiver = 0, resource = 0, amount = 0.  This is a *valid* but
semantically vacuous law value — applying it does nothing
observable (self-transfer of 0 to 0).  The wrapper exists only
to demonstrate the `deploy_laws` clause's accepted shape; a
production deployment would parameterise on actual signer keys.

**Finding:** The wrapper pattern is documented ("for parameterised
kernel laws like `Laws.transfer r sender receiver amount`, we
introduce parameterless wrappers that close the laws over fixture
parameter values").  Each wrapper's `IsMonotonic` instance
delegates correctly to the underlying parameterised instance.

### Per-slot authority policies (lines 111–121)

Three policies, all set to `AuthorityPolicy.unrestricted` as v1
placeholders:

```lean
def federation_transfer_policy_v2 : AuthorityPolicy :=
  AuthorityPolicy.unrestricted
```

The names mirror the §7.2 example in
`docs/law_language_design.md` — `federation_transfer_policy_v2`,
`central_bank_only`, `self_only_with_central_bank_recovery`.

**Hazard observation:** The `_v2` suffix in
`federation_transfer_policy_v2` could be flagged by the
`naming_audit` tool if `v2` were on the forbidden-tokens list.
Looking at `Tools/NamingAudit.lean` line 119: the forbidden list
*does NOT* include `v2` (the list excludes `_v2` only as a
suffix-pattern with explicit underscore — not as a substring).
Actually re-reading the `naming_audit` source:
```lean
def forbiddenTokens : List String :=
  ...
  , "_legacy"
  ...
```
There's no `_v2` in the list.  However, CLAUDE.md says `v2` is a
forbidden temporal marker.  The `NamingAudit.lean` source list
diverges from the documented list — this is a documented-vs-actual
drift.  `federation_transfer_policy_v2` happens to evade the
mechanical check because `_v2` is not in the source list.

**Recommendation:** Either (a) add `_v2` to
`Tools/NamingAudit.lean`'s `forbiddenTokens`, or (b) update the
CLAUDE.md list to match what's actually enforced.  Currently the
mechanical check is narrower than the documented policy.

### The deployment manifest (lines 141–185)

```lean
deployment usd_clearing where
  deploy_id              example.usd_clearing
  deploy_deployment_id
    "DEADBEEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF01234567"
  deploy_version         "1.0.0"
  deploy_resources       := [ "USD" := 0 ]
  deploy_laws            := [
    Transfer    = transferWrapper    @ "1.0.0",
    Mint        = mintWrapper        @ "1.0.0",
    Freeze      = freezeWrapper      @ "1.0.0",
    ReplaceKey  = replaceKeyWrapper  @ "1.0.0"
  ]
  deploy_authority       := [
    transfer_policy = federation_transfer_policy_v2,
    mint_policy     = central_bank_only,
    identity_policy = self_only_with_central_bank_recovery
  ]
  deploy_invariant_claims := [
    monotonic_law_set [all_laws]
  ]
```

The macro is from `Lex.DSL.Deployment` (audited separately).
The clauses exercise:
* `deploy_id`: a namespace-qualified identifier.
* `deploy_deployment_id`: a 64-character hex string (the 32-byte
  deployment id used for cross-deployment-replay binding).
* `deploy_version`: a semver string.
* `deploy_resources`: a list of `name := id` bindings.
* `deploy_laws`: a list of `localName = lawRef @ version` bindings.
* `deploy_authority`: a list of `slot = policy` bindings.
* `deploy_invariant_claims`: a list of typeclass-resolved
  invariant claims.

The `[all_laws]` wildcard expands at elaboration time to the full
`deploy_laws` list.  This exercises LX.33.

**Hazard observation:** The wildcard `[all_laws]` expansion is
dependent on the macro's elaboration logic.  If a future PR
adds a new law to `deploy_laws` whose wrapper is NOT
`IsMonotonic`, the wildcard claim will fail elaboration at the
*deployment site*, which is the intended firewall.  Reviewers
should ensure the test suite covers both the wildcard happy-path
and a `Burn`-injection failure path.

**Hazard observation:** The `deploy_deployment_id` hex string
is hand-typed and verified by inspection: 64 hex chars =
32 bytes.  If a future PR shortens or lengthens this, the macro
should fail elaboration with a clear diagnostic; this is the
job of `Lex.DSL.Deployment` (audited separately).

**Finding:** The manifest is well-structured and demonstrates
each LX.31/32/33 feature.  The comments explicitly cite the
audit-5 correction (switching from
`freeze_preserving_law_set [all_laws]` to `monotonic_law_set
[all_laws]` because the former is semantically false at the
USD resource).  This is good provenance.

### Module-level findings

* **Correctness:** The manifest elaborates (per `LegalKernel.Test.Deployments.UsdClearing`).
* **No `sorry`, no custom axioms.**
* **Hazards:**
  * The `_v2` suffix in `federation_transfer_policy_v2` evades
    the `naming_audit` mechanical check despite CLAUDE.md
    listing `v2` as forbidden.  Documentation-vs-enforcement
    drift.
  * The `unrestricted` policies are v1 placeholders; production
    use requires real policies.
  * The wildcard `[all_laws]` semantics depends on Lex DSL
    macro implementation; reviewers should cross-check
    `Lex.DSL.Deployment`.

---

## `Lex/Examples/ExampleLex.lean`

Will be sampled below; the file is small (and is the LX.21
acceptance demonstration).
