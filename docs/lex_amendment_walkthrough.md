# Lex Law Amendment Workflow Walkthrough

LX.37 of `docs/lex_implementation_plan.md`.

This document walks through a concrete amendment scenario: bumping
`legalkernel.transfer` from `1.0.0` to `1.1.0` to add an upper
bound on `amount`.  It demonstrates how the M3 governance tools
(`lex_diff`, `lex_format`, the `deployment` macro) combine to
support per-PR review with mechanical safety checks.

## Scenario

The deployment operator wants to refine the `transfer` law to
add a deployment-specific upper bound: `amount ≤ 2^32`.  This
is a *minor* version bump per §14.2:

  * `pre` strengthens (adds a new conjunct).
  * `impl` is unchanged.
  * `satisfies` is unchanged.

A minor bump requires a refinement proof (per L016).  The proof
demonstrates that the new (stronger) precondition admits a
subset of states the old precondition admitted — i.e., the new
form *refines* the old form.

## Pre-bump state

Before the amendment, the law's surface is:

```lean
lexlaw transfer where
  lex_id              legalkernel.transfer
  lex_version         "1.0.0"
  lex_action_index    0
  lex_intent          "Move balance between actors at a resource."
  lex_signed_by       sender
  lex_authorized_by   (fun _ _ => True)
  lex_params          (r : ResourceId) (sender receiver : ActorId)
                      (amount : Amount)
  lex_pre             := fun s => amount > 0 ∧ getBalance s r sender ≥ amount
  lex_impl            := fun s =>
                          let s' := setBalance s r sender (getBalance s r sender - amount)
                          setBalance s' r receiver (getBalance s' r receiver + amount)
  lex_satisfies       := [conservative, monotonic, «local»,
                          freeze_preserving, registry_preserving]
  lex_events          := []
```

The codegen-input JSON sidecar at
`LegalKernel/_lex_inputs/legalkernel_transfer.json` reflects this
surface.

## Step 1 — Author Edits

The author edits the `lex_pre` clause to add the upper bound:

```lean
  lex_pre             := fun s =>
                          amount > 0 ∧ amount ≤ 2^32 ∧
                          getBalance s r sender ≥ amount
```

And bumps the version:

```lean
  lex_version         "1.1.0"
```

Re-running `lake build LegalKernel.Laws.Transfer` regenerates the
JSON sidecar (`atomicWriteIfChanged` no-ops if the bytes match,
or atomically replaces the file otherwise).

## Step 2 — Lint Runs

The CI gate first runs:

```bash
lake exe lex_lint
```

`lex_lint` checks the registry + codegen-input cross-consistency:

  * The registry's `legalkernel.transfer` entry is unchanged
    (action_index 0 reserved).
  * The JSON sidecar's `action_index` matches.
  * The new JSON sidecar parses cleanly.

`lex_lint` exits 0 if everything is consistent.

## Step 3 — Codegen Check

```bash
lake exe lex_codegen --check
```

Verifies that the four cross-module artefacts (`Authority/Action.lean`,
`Encoding/Action.lean`, `Events/Extract.lean`, `Authority/SignedAction.lean`)
match what `lex_codegen` would emit from the current set of JSON
sidecars.  For an in-place bump (no new constructors added), the
fences are unchanged and `--check` passes.

## Step 4 — Semantic Diff

The reviewer runs:

```bash
# Extract the JSON sidecars from the two refs into temporary
# directories.  In a CI script, this is:
mkdir -p /tmp/before /tmp/after
git show <base-ref>:LegalKernel/_lex_inputs/legalkernel_transfer.json \
  > /tmp/before/legalkernel_transfer.json
git show <head-ref>:LegalKernel/_lex_inputs/legalkernel_transfer.json \
  > /tmp/after/legalkernel_transfer.json

# Then diff:
lake exe lex_diff /tmp/before /tmp/after
```

The output identifies the changed law and classifies the bump:

```
== Deployment Diff ==
Laws modified:
legalkernel.transfer:
  version: 1.0.0 → 1.1.0   (minor)
  pre: amount > 0 ∧ getBalance s r sender ≥ amount → amount > 0 ∧ amount ≤ 2^32 ∧ getBalance s r sender ≥ amount
  refinement_proof: MISSING (L016)
```

## Step 5 — Refinement Proof Required

`lex_diff` correctly identified the bump as `minor`, but the
"refinement_proof: MISSING (L016)" line shows the CI gate will
fail until the author supplies a proof.

Per the convention `refinement_v<MAJ>_<MIN>` for the OLD version
(here: `refinement_v1_0` for `1.0.x`), the author adds:

```lean
  lex_proof refinement_v1_0 := by
    -- Refinement: every state admitted by the new pre is also
    -- admitted by the old pre.  Concretely: a > 0 ∧ a ≤ 2^32 ∧
    -- balance ≥ a → a > 0 ∧ balance ≥ a.
    intro s hpre
    exact ⟨hpre.1, hpre.2.2⟩
```

(The `lex_proof` clause is captured by the macro and recorded
in the JSON sidecar's `proof_overrides` field.)

## Step 6 — Re-Run Diff

After committing the proof:

```bash
lake exe lex_diff /tmp/before /tmp/after
```

The output now confirms the refinement proof is present:

```
== Deployment Diff ==
Laws modified:
legalkernel.transfer:
  version: 1.0.0 → 1.1.0   (minor)
  pre: ... → ...
  proof_overrides:  → refinement_v1_0
  refinement_proof: PRESENT
```

`lex_diff` exits 0; the CI gate accepts the change.

## Step 7 — PR Review Proceeds

The PR reviewer reads the `lex_diff` output as part of the PR
description.  The classification (`minor`) tells them the change
is a refinement — strictly safety-preserving.  The `pre` diff
shows exactly what condition was strengthened.  The presence of
`refinement_v1_0` in `proof_overrides` is a mechanical guarantee
that the kernel-level refinement obligation has been discharged.

## Step 8 — Manifest Hash Stability Check

If the deployment ships a manifest, the manifest's
`<name>_manifest_hash` constant changes only when one of the
manifest fields (`identifier`, `deploymentId`, `version`,
`resources`, `laws`, `authority`, `invariantClaims`) changes.

A `transfer` law's internal upgrade does NOT change the manifest's
fields directly (the manifest still references `Transfer = legalkernel.transfer @ "1.0.0"` if pinned at `1.0.0`).  To
upgrade the manifest's pinned version, the operator edits the
manifest:

```lean
deployment usd_clearing where
  ...
  deploy_laws := [
    transferWrapper,  -- now closes over the new transfer
    ...
  ]
  ...
```

And rebuilds.  The manifest-hash will change to reflect the
new pinned version, and the attestor (V2) re-signs the new
manifest hash.

## Manifest Hash Stability Record

For long-term stability tracking, the example manifest's `manifest_hash`
at v1.0.0 is recorded here:

  * **Deployment**: `example.usd_clearing`
  * **Manifest version**: `1.0.0`
  * **Manifest hash** (FNV-1a-64; first 8 bytes are the hash, rest zero-padded
    until production BLAKE3 lands; see `Runtime/Hash.lean`):
    `cd7f3e2dd117087e000000000000000000000000000000000000000000000000`

    *(Hash recomputed after audit-5 wildcard-demo amendment: the
    `deploy_invariant_claims` clause now uses `monotonic_law_set
    [all_laws]` (the LX.33 wildcard form) instead of the prior
    explicit `monotonic_law_set [Transfer, Mint, Freeze, ReplaceKey]`.
    The wildcard expands semantically to the same law list, but the
    canonical encoding stores it as a wildcard scope (empty
    `lawNames` list) — producing a distinct hash byte sequence.
    Prior recorded values: audit-3 = `f9182604d6417760...`;
    pre-audit-3 = `1919db5de8cacee10...`.  Both are superseded.
    Reordering laws or authority bindings in the manifest source no
    longer changes the hash; only semantic content does.)*

To verify the hash hasn't drifted:

```
lake build Deployments.Examples.UsdClearing
lake env lean --run /tmp/get_hash.lean    # see Phase-6 docs for the helper
```

A change to this hash signals a manifest-level edit (e.g.,
adding/removing a law, changing an authority binding, bumping
`deploy_version`).  The audit-tools `lex_diff` will produce a
detailed per-clause breakdown of what changed.

## Acceptance Gate Summary

After Steps 1–8 complete:

  * ✓ `lake build` succeeds (JSON sidecar regenerates atomically).
  * ✓ `lake test` passes (regression `example`s still elaborate).
  * ✓ `lake exe count_sorries` = 0.
  * ✓ `lake exe tcb_audit` passes.
  * ✓ `lake exe stub_audit` passes.
  * ✓ `lake exe lex_lint` passes (registry + codegen-input cross-check).
  * ✓ `lake exe lex_codegen --check` passes.
  * ✓ `lake exe lex_diff <base> <head>` exits 0.
  * ✓ The PR description includes the `lex_diff` output.

## Example commit pair

For a real-world example of this workflow, see the test fixtures
in `LegalKernel/Test/Tools/LexDiff.lean`'s `classifyMinorOnPreOnly`
case, which exercises the per-clause diff + classifier on a
hand-built `LawDecl` pair.

## Notes

  * The walkthrough assumes the operator runs `lex_diff` with
    pre-extracted JSON directories.  In a real CI script, the
    extraction step uses `git show <ref>:<path>` (one call per
    sidecar file).  V2 may add a `lex_diff <ref-a> <ref-b>` form
    that performs the extraction internally.
  * The refinement proof's `tacticBlock` is captured as opaque
    text in the codegen-input JSON.  V2 may execute the proof
    at codegen time to verify it discharges the obligation
    mechanically (currently the obligation is the law writer's
    responsibility, with the L016 gate ensuring the proof
    exists; M4 may close the verification loop).

## Cross-references

  * §6 of `docs/lex_implementation_plan.md`: the `lex_law` macro
    and codegen-input format.
  * §14 of `docs/lex_implementation_plan.md`: `lex_diff` /
    `lex_format`.
  * §13.1 of `docs/lex_implementation_plan.md`: the registry
    discipline.
  * §16 of `docs/lex_implementation_plan.md`: the `deployment`
    macro and manifest-hash protection.
