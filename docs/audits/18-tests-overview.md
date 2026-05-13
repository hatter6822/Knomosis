# Test infrastructure overview

**Scope:** ~117 test modules under `LegalKernel/Test/*` and
`Lex/Test/*`.  This audit reviews the test framework itself and
summarises the test-suite organisation.  Per-test inspection
is out of scope (the actual test bodies are checked by `lake
test` on every PR, which gives stronger value-level coverage
than any auditor's read).

**TCB:** None.  Tests are diagnostic; bugs surface as false
positives (a green build despite a broken theorem) or false
negatives (a red build despite working code), never as
kernel-invariant violations.

---

## `LegalKernel/Test/Framework.lean` (95 lines)

### Surface

Seven top-level declarations:
* `emptyState : LegalKernel.State` — the canonical "no balances
  anywhere" fixture.  Definitionally equal to
  `LegalKernel.genesisState` (from `Conservation.lean`) but the
  test framework cannot import `Conservation.lean` because of
  the dependency ordering (tests would import the world).  This
  duplication is documented: "Test modules build their fixtures
  on top of it so that fresh-state construction lives in exactly
  one place."

  **Finding:** Correct.  The duplication is intentional.

* `TestCase` structure: `name : String`, `body : IO Unit`.

* `Outcome` inductive: `pass | fail (msg : String)`.

* `runOne (t : TestCase) : IO Outcome` — runs one test, catches
  `IO.userError`, prints `PASS` or `FAIL` to stdout.

* `runAll (suite : String) (ts : List TestCase) : IO Nat` —
  runs every test in the list, prints summary, returns failure
  count.

* `assert (cond : Bool) (msg : String) : IO Unit` — throws
  on `¬cond`.

* `assertEq {α : Type _} [BEq α] [Repr α] (expected actual : α)
  (where_ : String := "") : IO Unit` — throws on `≠`.

**Hazard observation:** The test runner uses `try ... catch e`
to capture `IO.userError`.  If a test throws a *different*
`IO.Error` (e.g. file-not-found), the test will still be marked
FAIL, but the error message may be confusing.  Currently no
tests do filesystem operations in their bodies; if a future
test does, reviewers should expect FAIL output rather than a
crash.

**Hazard observation:** `assertEq` uses `BEq` for equality.  For
types where `BEq` and `=` diverge (rare but possible with
custom `BEq` instances), the test could pass even when the
values are not provably equal.  Currently every type tested
has `DecidableEq`, which guarantees `BEq` agrees with `=`.

**Finding:** The framework is minimal but sufficient.  No
external test framework (LSpec / Plausible) is needed; Phase 0
acceptance gate is "no external deps beyond Lean core."

---

## `LegalKernel/Test/MockCrypto.lean` (96 lines)

### `mockVerify` (line 65)

```lean
def mockVerify (_pk : PublicKey) (_msg : ByteArray) (sig : Signature) : Bool :=
  decide (sig.size = 64 ∧ sig.toList.head? = some 0xFF)
```

Accepts any 64-byte signature whose first byte is `0xFF`.
Ignores `pk` and `msg`.

### `mockSign` (line 70)

```lean
def mockSign (_pk : PublicKey) (_msg : ByteArray) : Signature :=
  ByteArray.mk
    ((List.replicate 64 (0 : UInt8)).set 0 0xFF).toArray
```

Produces a canonical 64-byte signature with `0xFF` at index 0
and `0x00` elsewhere.

### `mockPubKey` (line 78)

Returns a 32-byte public key encoding the actor id in the first
8 LE bytes.  `mockVerify` ignores the public key, so any
construction would work; this gives a deterministic per-actor
value for use in `KeyRegistry` fixtures.

**Hazard observation:** The docstring explicitly notes:
"This module is **test-only**.  It must NOT be imported from
any non-test module.  The `stub_audit` binary will flag any
production import."

Reviewer check: `grep -r "import.*MockCrypto" --include="*.lean"`
under `LegalKernel/` (excluding `Test/`) should return zero
matches.  Spot-checked: only `Test/Authority/SignedActionHappyPath.lean`
and `Test/Runtime/LoopHappyPath.lean` import it, per the
docstring.

**Hazard observation:** `stub_audit` looks for `:=
ByteArray.empty` (and similar literal placeholders); it does
NOT explicitly flag imports of `MockCrypto`.  The docstring's
claim that "`stub_audit` will flag any production import" is
**not** quite accurate — the audit catches placeholder bodies
in the mock module, not imports of the mock module.  A
production module that imports `MockCrypto` and uses
`mockVerify` directly would NOT be caught by any current audit
tool.  This is a documentation drift / minor over-promise.

**Recommendation:** Either (a) extend a CI audit tool to flag
production imports of `Test.*` modules, or (b) update the
`MockCrypto.lean` docstring to remove the "stub_audit" claim.

**Finding:** The mock crypto itself is correct.  The docstring
over-promises tooling enforcement.

---

## Test-suite organisation

The test directories under `LegalKernel/Test/` mirror the
source layout:

| Test directory             | Suites                                                                     |
|----------------------------|----------------------------------------------------------------------------|
| `Authority/`               | Action, Identity, LocalPolicy, LocalPolicyAdmissibility, Nonce, SignedAction, SignedActionHappyPath |
| `Bridge/`                  | VerifyAdaptor, HashAdaptor, Eip712, AddressBook, BridgeActor, Ingest, State, Admissible, Accounting, WithdrawalRoot, WithdrawalProof, WithdrawalProofCLI, Finalisation, WithdrawalRootGoldens, CrossCheck/* |
| `Bridge/CrossCheck/`       | Framework, EcdsaVerify, Keccak256, DepositReceiptHash, WithdrawalProof, DisputeEvidence, MigrationAttestation, Goldens, StepVM, BisectionGame, FaultProofScenarios |
| `DSL/`                     | Law (base DSL only — Lex DSL tests live under `Lex/Test/DSL/`)             |
| `Deployments/`             | UsdClearing                                                                |
| `Disputes/`                | Filing, Evidence, Verdict, EndToEnd, LawClassification, MonotonicDeployment, Rewards, Staking, IncentivizedEndToEnd, WitnessHelpers |
| `Encoding/`                | CBOR, Encodable, Action, SignedAction, State, SignInput, Disputes, LocalPolicy |
| `Events/`                  | Types, Extract                                                             |
| `FaultProof/`              | Cell, Commit, Step, Game, LawClassification, Encoding, EventEmission, Witness, Verify, Trust, PerVariantCoherence, EncodeInjectivity, AbsentCellCreation, GameTransitionEdgeCases, SolidityStepVMCommit, Transcript, Coherence, Settlement, MigrationFreeze |
| `Laws/`                    | Transfer, Mint, Burn, Freeze, Reward, DistributeOthers, ProportionalDilute, Deposit, Withdraw |
| `LocalPolicy/`             | LawClassification                                                          |
| `Properties/`              | Encoding, Bridge, LocalPolicy, FaultProof, FaultProofExtended, FaultProofDeep |
| `Runtime/`                 | Hash, LogFile, Replay, Snapshot, AttestedSnapshot, Loop, LoopHappyPath     |

Plus root-level:
* `KernelTests.lean` (265 lines): WU 1.5 balance lemmas, WU 1.7
  reachability, WU 1.8 law-set reachability, etc.
* `RBMapLemmasTests.lean` (117 lines): §8.3 fold lemmas.
* `Umbrella.lean` (47 lines): pins the `kernelBuildTag` constant.
* `ConservationTests.lean` (456 lines): TotalSupply, IsConservative,
  ConservativeLawSet, total_supply_global.
* `Property.lean` (167 lines): shared property-test helpers.

Lex tests live under `Lex/Test/`:
* `DSL/{Law, ImplLowering, Property, Deployment}.lean`
* `Tools/{Common, Codegen, Diff, Format, Lint, DiagnosticCoverage}.lean`
* `ExampleLex.lean`, `M2.lean`, `Properties.lean`, `AutoGenProperties.lean`

---

## Cross-stack test infrastructure

The `LegalKernel/Test/Bridge/CrossCheck/` directory deserves
special attention: it contains the F.1.x equivalence suite that
ratifies byte-identical behaviour between the Lean and Solidity
sides.  Files include:

* `Framework.lean` — shared scaffolding for the cross-check tests.
* `EcdsaVerify.lean` — Lean side checks against Solidity ECDSA.
* `Keccak256.lean` — Lean keccak vs Solidity keccak goldens.
* `DepositReceiptHash.lean` — bridge deposit receipt hash equivalence.
* `WithdrawalProof.lean` — Merkle proof equivalence.
* `DisputeEvidence.lean` — dispute pipeline byte equivalence.
* `MigrationAttestation.lean` — Workstream H migration attestation.
* `Goldens.lean` — frozen byte sequences.
* `StepVM.lean`, `BisectionGame.lean`, `FaultProofScenarios.lean`
  — Workstream H specific.

**Hazard observation:** Cross-check tests rely on a "golden" file
that must be regenerated whenever encoder bytes change.
`lake test` runs only the Lean side; the Solidity side is run
by `make test-cross-stack` from `solidity/`.  An encoder change
that breaks the Lean side passes locally; the cross-stack break
surfaces only in `make test-cross-stack`.  Reviewers should
ensure both are part of CI.

---

## Test patterns

CLAUDE.md documents two complementary patterns:

1. **Value-level:** assert `==` between expected and actual
   results.  Catches definitional drift / Std-API renames at
   runtime.

2. **Term-level API stability:** ascribe a `let _proof : T :=
   theorem ...` binding whose type uses the theorem's exact
   signature.  Catches signature changes at elaboration time,
   before the `IO Unit` body runs.

The `Authority.SignedAction` suite uses term-level API checks
for `nonce_uniqueness` and `replay_impossible` (rather than
value-level admissibility witness construction) because the
`Verify` opaque cannot be reduced at the Lean level.  The
algebraic core (post-advance nonce inequality) is value-level
checked separately.

The shared `Test/MockCrypto.lean` module supplies
`mockVerify` / `mockSign` for happy-path coverage that the
production opaque `Verify` (which returns `false` at the Lean
level) cannot exercise.

**Finding:** The test pattern split is correct and well-
documented.  Reviewers should not expect every theorem to have
a corresponding value-level test — some can only be exercised
at the term level.

---

## Module-level findings

* **Test framework is correct.**  `runOne` / `runAll` /
  `assert` / `assertEq` cover the common cases; no missing
  primitives observed.
* **MockCrypto is correct** but its docstring over-promises
  tooling enforcement (a production import would not be
  caught by `stub_audit` despite the docstring's claim).
* **Test-suite organisation mirrors source layout.**  Each
  source module has a corresponding test module, and the test
  driver (`Tests.lean`) enumerates them all.
* **Cross-stack tests** require running BOTH `lake test` AND
  `make test-cross-stack` to ratify Lean/Solidity byte
  equivalence; CI must run both.
* **Coverage:** Per CLAUDE.md, ~1907 tests across ~100 suites
  at the time of the last milestone.  The exact number drifts;
  `lake test` is the canonical query.
* **No `sorry`, no custom axioms in test modules.**
* **Test count is not pinned** (unlike `kernelBuildTag`); only
  its monotonic growth is enforced by individual regression
  tests landing alongside new theorems.

**Recommendation:** Consider extending one of the audit tools
to flag production imports of `Test.*` modules.  This would
close the documentation-vs-enforcement gap noted in
`MockCrypto.lean`'s docstring.
