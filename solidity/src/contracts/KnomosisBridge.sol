// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {IKnomosisBridge} from "src/interfaces/IKnomosisBridge.sol";
import {IKnomosisMigration} from "src/interfaces/IKnomosisMigration.sol";
import {ILiquityV2TroveManager} from "src/interfaces/ILiquityV2TroveManager.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

import {KnomosisEip712} from "src/lib/KnomosisEip712.sol";
import {SmtVerifier} from "src/lib/SmtVerifier.sol";
import {CBEDecode} from "src/lib/CBEDecode.sol";

/// @title KnomosisBridge
/// @notice The L1 bridge contract.  Hosts deposits, withdrawals,
///         state-root submissions, and the rollback hook.  Per
///         workstream E.1 of the Ethereum integration plan, this
///         contract is deployed immutably: no proxy, no
///         `initialize`, no admin role, no upgrade hook.
///
/// @dev    All five sub-WUs (E.1.1 deposit, E.1.2 state-root
///         submission, E.1.3 withdrawal, E.1.4 circuit breakers,
///         E.1.5 rollback hook) are implemented in this single
///         contract per the plan's organisational discipline.
contract KnomosisBridge is IKnomosisBridge, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------
    // Custom errors
    // ------------------------------------------------------------------

    error NotAttestor();
    error NotDisputeVerifier();
    error AttestationStale();
    error DisputeCooldown();
    error TvlCapReached();
    error MigrationActivated();
    error NonMonotonic();
    error UnknownStateRoot();
    error StateRootReverted();
    error PreFinalisation();
    error AlreadyRedeemed();
    error InvalidProof();
    error InvalidLeafSizeForResource();
    error UnsupportedResource();
    error EthValueMismatch(uint256 expected, uint256 actual);
    error InvariantViolation_DisputeWindowVsRedemption();
    /// @notice Reverts when a withdrawal leaf names `address(0)` as
    ///         the recipient.  Audit-3: defensive check; on most
    ///         L1 forks `Address.sendValue(payable(0), x)` reverts,
    ///         but `safeTransfer(token, address(0), x)` silently
    ///         passes for some non-conforming ERC-20s.  Reject
    ///         early so the leaf hash is not marked redeemed.
    error InvalidRecipient();
    /// @notice Reverts when the bridge's internal `totalLockedValue`
    ///         disagrees with the L2 record at withdrawal time.
    ///         Should be unreachable if the bridge's deposit /
    ///         withdrawal accounting matches the L2 ledger; firing
    ///         it indicates a cross-stack drift bug.
    error BridgeAccountingMismatch(uint256 totalLockedValue, uint256 amountRequested);
    error InvalidSignatureLength();
    /// @notice Reverts when the constructor's resource map maps two
    ///         distinct resourceIds to the same ERC-20 token address
    ///         (audit-2: closes a misconfiguration where the same
    ///         token is double-counted).
    error DuplicateResourceToken(address token);
    /// @notice Reverts when an ERC-20 deposit receives a different
    ///         amount than declared (e.g. fee-on-transfer or
    ///         rebasing tokens).  Audit-2: the bridge cannot accept
    ///         such tokens at all because the L2 credit would
    ///         desync from the L1-locked value.
    error TransferAmountMismatch(uint256 declared, uint256 received);

    // ---- Workstream GP.5.1: user-chosen fee-split deposits ----

    /// @notice Reverts on a zero-value fee-split deposit.  Defends
    ///         against a degenerate-deposit DoS where an attacker
    ///         would otherwise consume the per-depositor `depositNonce`
    ///         indefinitely at zero cost.
    error ZeroDeposit();
    /// @notice Reverts when the user-chosen fee is below the
    ///         deployment's immutable `minFeeBps` floor.
    error FeeBpsBelowMin(uint16 chosenFeeBps);
    /// @notice Reverts when the user-chosen fee is above the
    ///         deployment's immutable `maxFeeBps` ceiling.  The
    ///         boundary check fires before any fee arithmetic, so an
    ///         out-of-range value (e.g. `> 10000`) reverts here rather
    ///         than producing a malformed split.
    error FeeBpsAboveMax(uint16 chosenFeeBps);
    /// @notice Constructor guard: the deployment passed
    ///         `minFeeBps > maxFeeBps`, an empty admissible range.
    error MinFeeBpsExceedsMax(uint16 minFeeBps, uint16 maxFeeBps);
    /// @notice Constructor guard: the deployment passed a `maxFeeBps`
    ///         above the compile-time `MAX_FEE_BPS_CAP`.
    error MaxFeeBpsExceedsCap(uint16 maxFeeBps);
    /// @notice Constructor guard: the deployment passed an exchange
    ///         rate below `MIN_WEI_PER_BUDGET_UNIT`, which would admit
    ///         the degenerate divide-by-zero shape.
    error WeiPerBudgetUnitTooSmall(uint64 weiPerBudgetUnit);

    // ---- Workstream GP.5.4: BOLD-currency fee-split deposits ----

    /// @notice Constructor guard: a BOLD-enabled deployment passed a
    ///         `boldTokenAddress` other than the canonical
    ///         `BOLD_TOKEN_ADDRESS` compile-time pin.  (A deployment
    ///         that does not support BOLD passes `address(0)`, which
    ///         disables the BOLD entry point and skips this check.)
    error BoldTokenAddressMismatch(address provided);
    /// @notice Constructor guard: the pinned BOLD token's `symbol()`
    ///         returned a string other than `EXPECTED_BOLD_SYMBOL`.
    ///         Defence-in-depth secondary check behind the address pin.
    error BoldTokenSymbolMismatch(string actualSymbol);
    /// @notice Constructor guard: the pinned BOLD token's `symbol()`
    ///         call reverted or returned undecodable data.  Treated as
    ///         a "this is not the BOLD token" signal.
    error BoldTokenSymbolUnavailable();
    /// @notice Reverts when a `depositBoldWithFee` measures a different
    ///         received balance delta than the declared `amount` (e.g. a
    ///         hypothetical fee-on-transfer / rebase change in a future
    ///         BOLD upgrade).  Distinct from the generic
    ///         `TransferAmountMismatch` so a BOLD-leg failure is
    ///         unambiguous in the revert reason.
    error BoldTransferAmountMismatch(uint256 expected, uint256 actual);
    /// @notice Reverts when `depositBoldWithFee` is called on a
    ///         deployment that did not opt into BOLD support (i.e. the
    ///         constructor received `boldTokenAddress == address(0)`).
    error BoldNotEnabled();
    /// @notice Constructor guard: on a BOLD-enabled deployment the
    ///         resource map may not register `RESOURCE_ID_BOLD` nor the
    ///         `BOLD_TOKEN_ADDRESS` — both are auto-bound by the
    ///         constructor (the `(RESOURCE_ID_BOLD -> BOLD_TOKEN_ADDRESS)`
    ///         entry is installed automatically), so the deployer's map is
    ///         for OTHER tokens only.
    error BoldResourceReserved();
    /// @notice Reverts when the generic `depositERC20` entry point is
    ///         called for `RESOURCE_ID_BOLD` on a BOLD-enabled deployment.
    ///         BOLD's `(resourceId, token)` is auto-bound at construction
    ///         solely so `withdrawWithProof` can resolve the payout token;
    ///         that binding must NOT also open a fee-bypassing legacy
    ///         deposit path.  BOLD deposits go through `depositBoldWithFee`
    ///         (which may carry a zero fee when `minFeeBps == 0`).
    error BoldDepositViaFeeSplitOnly();

    // ---- Workstream GP.5.5: BOLD-specific safety hardening ----

    /// @notice Reverts when `depositBoldWithFee` is called while the
    ///         per-currency BOLD circuit breaker (`boldCircuitClosed`) is
    ///         closed.  Independent of the four automatic `circuitOpen`
    ///         breakers and of the ETH leg — a closed BOLD circuit halts
    ///         only BOLD deposits.
    error BoldDepositPaused();
    /// @notice Reverts when a BOLD deposit would push the per-currency
    ///         `boldTotalLockedValue` past `boldTvlCap`.  Tighter than
    ///         (and independent of) the global `TvlCapReached` breaker.
    error BoldTvlCapReached();
    /// @notice Reverts when a `boldTvlCap` assignment (constructor initial
    ///         value or `setBoldTvlCap`) exceeds the global `tvlCap`: the
    ///         per-BOLD cap must stay no looser than the deployment's
    ///         overall reserve commitment.
    error BoldTvlCapExceedsGlobal(uint256 boldTvlCap, uint256 tvlCap);
    /// @notice Reverts when a BOLD circuit-breaker toggle is called by an
    ///         address other than the immutable `boldCircuitBreaker` role.
    error NotBoldCircuitBreaker();
    /// @notice Reverts when `setBoldTvlCap` is called by an address other
    ///         than the immutable `boldAdmin` role.
    error NotBoldAdmin();
    /// @notice Constructor guard: a BOLD-enabled deployment passed a zero
    ///         `boldCircuitBreaker`.  The emergency-pause role must be
    ///         operable, so the BOLD safety mechanism cannot be deployed
    ///         as an unreachable no-op.
    error ZeroBoldCircuitBreaker();
    /// @notice Constructor guard: a BOLD-enabled deployment passed a zero
    ///         `boldAdmin`.  The TVL-cap role must be operable.
    error ZeroBoldAdmin();
    /// @notice Constructor guard: a BOLD-enabled deployment passed the
    ///         same address for `boldCircuitBreaker` and `boldAdmin`,
    ///         collapsing the two roles and undermining the
    ///         least-privilege separation (emergency-pause hot key vs.
    ///         cap-tuning cold key).  Roles must be distinct addresses.
    error BoldRolesNotDistinct();
    /// @notice Constructor guard: a BOLD-enabled deployment named the
    ///         bridge itself as a safety role.  Disallowed: the bridge
    ///         must not be able to trigger its own circuit (closes a
    ///         self-call footgun).
    error BoldRoleIsBridge();
    /// @notice Reverts when the permissionless Liquity-V2 depeg
    ///         auto-trigger is called on a deployment that did not opt in
    ///         (`enableLiquityAutoCircuitTrigger == false`).
    error AutoCircuitTriggerDisabled();
    /// @notice Reverts when the Liquity-V2 `TroveManager.shutdownTime()`
    ///         read inside `closeBoldCircuitIfAnyLiquityBranchShutdown`
    ///         reverts, returns the wrong number of bytes, or targets an
    ///         address with no code.  Distinguishes a TroveManager fault
    ///         from a genuine no-shutdown reading so the operator can
    ///         switch to the manual `closeBoldCircuit()` path cleanly.
    error LiquityV2ReadFailed();
    /// @notice Reverts when the auto-trigger reads `shutdownTime == 0` on
    ///         every Liquity V2 branch — no depeg signal, so the circuit
    ///         is left open.
    error NoLiquityBranchShutdown();
    /// @notice Constructor guard: `enableLiquityAutoCircuitTrigger` was set
    ///         on a BOLD-disabled deployment (there is no BOLD deposit path
    ///         for the auto-trigger to defend).
    error AutoTriggerRequiresBold();
    /// @notice Constructor guard: `enableLiquityAutoCircuitTrigger` was set
    ///         but one of the pinned Liquity V2 TroveManager constants has
    ///         no contract code on the deployment chain.  Fails loudly at
    ///         deploy time if Liquity V2 is not deployed on this chain at
    ///         the constitutional pins — operators on non-Liquity chains
    ///         must leave the auto-trigger disabled.  Mirrors the
    ///         BOLD-token code-presence check.  Carries the first missing
    ///         branch's address so the operator can diagnose without
    ///         bisecting.
    error LiquityOracleHasNoCode(address troveManager);
    /// @notice Constructor guard: `enableLiquityAutoCircuitTrigger` was set
    ///         but two of the three `LIQUITY_V2_TROVE_MANAGER_*` constants
    ///         resolve to the same address — defence in depth against a
    ///         source-level drift (the exact bug class where a
    ///         copy-paste duplicate among the three branch pins would
    ///         make the auto-trigger silently miss one branch).  The
    ///         GP.5.2 cap-audit gate also catches this; this runtime
    ///         check fires even if the gate were bypassed.
    error BoldTroveManagersNotDistinct();

    // ------------------------------------------------------------------
    // Constitutional / immutable parameters
    // ------------------------------------------------------------------

    bytes32 public immutable knomosisVersionTag;
    bytes32 public immutable deploymentId;

    address public immutable attestor;
    address public immutable disputeVerifier;
    address public immutable sequencerStake;
    address public immutable migration;

    uint64 public immutable disputeWindowBlocks;
    uint64 public immutable maxRedemptionWindowBlocks;
    uint64 public immutable maxAttestationStaleBlocks;
    uint64 public immutable cooldownBlocks;
    uint256 public immutable tvlCap;

    /// @notice Immutable deployment lower bound on the user-chosen fee
    ///         (basis points).  Typically 0 (allow purely-balance
    ///         deposits) or a small positive value (force a minimum
    ///         pool contribution).  Validated `<= maxFeeBps` in the
    ///         constructor.  Workstream GP.5.1.
    uint16 public immutable minFeeBps;
    /// @notice Immutable deployment upper bound on the user-chosen fee
    ///         (basis points).  Capped above by `MAX_FEE_BPS_CAP`.
    ///         Workstream GP.5.1.
    uint16 public immutable maxFeeBps;
    /// @notice Immutable ETH-leg exchange rate: how many wei of ETH
    ///         pool credit produce one unit of action budget.  Floor
    ///         division by this value yields `budgetGrant`.  Validated
    ///         `>= MIN_WEI_PER_BUDGET_UNIT` in the constructor; bumping
    ///         it requires a KnomosisMigration handoff.  Workstream
    ///         GP.5.1.
    uint64 public immutable weiPerBudgetUnitEth;
    /// @notice Immutable BOLD-leg exchange rate: how many wei of BOLD
    ///         pool credit produce one unit of action budget.  (BOLD is
    ///         18-decimal; the rate is per BOLD-wei.)  Validated
    ///         `>= MIN_WEI_PER_BUDGET_UNIT` in the constructor only when
    ///         BOLD is enabled; on a BOLD-disabled deployment it is
    ///         unconstrained (and unused).  Bumping it requires a
    ///         KnomosisMigration handoff.  Workstream GP.5.4.
    uint64 public immutable weiPerBudgetUnitBold;
    /// @notice Whether this deployment opted into the BOLD entry point.
    ///         `true` iff the constructor received a non-zero
    ///         `boldTokenAddress` (which must then equal the canonical
    ///         `BOLD_TOKEN_ADDRESS` pin and pass the symbol cross-check).
    ///         When `false`, `depositBoldWithFee` reverts `BoldNotEnabled`.
    ///         Workstream GP.5.4.
    bool public immutable boldEnabled;

    /// @notice EIP-712 domain components for state-root attestations.
    string public constant DOMAIN_NAME = "KnomosisBridge";
    string public constant DOMAIN_VERSION = "1";

    /// @notice The resource id 0 is reserved for native ETH; all
    ///         other resource ids are looked up via the immutable
    ///         resource map below.  The runtime adaptor establishes
    ///         the (resourceId → ERC-20 address) bijection at
    ///         deployment time and bakes it into the constructor.
    uint64 public constant RESOURCE_ID_NATIVE_ETH = 0;

    /// @notice ResourceId for BOLD (the Liquity V2 stablecoin).  The
    ///         `depositBoldWithFee` entry point credits the user and the
    ///         gas pool at this resource id.  Workstream GP.5.4.
    /// @dev    When BOLD is enabled the constructor AUTO-BINDS
    ///         `(RESOURCE_ID_BOLD -> BOLD_TOKEN_ADDRESS)` in the resource
    ///         map (and reserves both from the deployer's map), so L1 BOLD
    ///         withdrawals via `withdrawWithProof` — which reads
    ///         `_resourceTokens[resourceId]` — always resolve to the
    ///         canonical BOLD token with no deployer action and no way to
    ///         misconfigure.  The deposit path itself uses the
    ///         constant-pinned `BOLD_TOKEN_ADDRESS` directly.
    uint64 public constant RESOURCE_ID_BOLD = 1;

    // ---- Fee-split compile-time caps (Workstreams GP.5.1 / GP.5.2).
    //      Each cap below is constitutional; its rationale and the
    //      governance constraint live in the per-constant NatSpec. ----

    /// @notice Compile-time hard cap on a deployment's `maxFeeBps`
    ///         constructor argument (5000 bps = 50%).  Past 50% a
    ///         "fee" stops being a reasonable English-language label,
    ///         and a higher cap only widens the footgun: a user
    ///         fat-fingering `chosenFeeBps = 9000` would gift 90% of
    ///         their bridged value to the gas pool.  Deployments
    ///         typically set `maxFeeBps` far lower (e.g. 1000 = 10%)
    ///         for realistic UX.
    /// @dev    Constitutional cap; a change is a Genesis-Plan §13.6
    ///         amendment, pinned in source by
    ///         `scripts/audit_compile_time_caps.sh` and at runtime by
    ///         `BridgeFeeSplit.t.sol::test_compileTimeCaps_pinned`.
    uint16 public constant MAX_FEE_BPS_CAP = 5000;

    /// @notice Compile-time minimum for the budget-unit exchange rate.
    ///         Rules out the degenerate divide-by-zero shape and the
    ///         fractional-unit semantics that a `uint64` cannot
    ///         express.
    /// @dev    Constitutional cap; a change is a Genesis-Plan §13.6
    ///         amendment, pinned in source by
    ///         `scripts/audit_compile_time_caps.sh` and at runtime by
    ///         `BridgeFeeSplit.t.sol::test_compileTimeCaps_pinned`.
    uint64 public constant MIN_WEI_PER_BUDGET_UNIT = 1;

    /// @notice Compile-time per-deposit budget-grant ceiling.  10^12
    ///         budget units is one trillion actions — at one action
    ///         per millisecond, ~31 years of continuous consumption
    ///         from a single deposit.  Sufficient for any realistic
    ///         super-user; far below the 2^63 state-bloat danger
    ///         threshold (the `uint64` boundary with one bit of
    ///         headroom for safety arithmetic).
    /// @dev    Constitutional cap; a change is a Genesis-Plan §13.6
    ///         amendment, pinned in source by
    ///         `scripts/audit_compile_time_caps.sh` and at runtime by
    ///         `BridgeFeeSplit.t.sol::test_compileTimeCaps_pinned`.
    uint64 public constant MAX_BUDGET_PER_DEPOSIT = 1_000_000_000_000;

    // ---- BOLD constitutional pins (Workstream GP.5.4) ----

    /// @notice Compile-time pin on the canonical Liquity V2 BOLD token
    ///         address.  A BOLD-enabled deployment's constructor reverts
    ///         (`BoldTokenAddressMismatch`) if the deployer passes any
    ///         other address; the `depositBoldWithFee` entry point only
    ///         ever pulls from / credits this address.
    /// @dev    Constitutional pin; changing it is a Genesis-Plan §13.6
    ///         amendment (two-reviewer rule) and is pinned at runtime by
    ///         `BridgeFeeSplitBold.t.sol::test_boldConstants_pinned`.
    address public constant BOLD_TOKEN_ADDRESS = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    /// @notice Compile-time pin on the expected BOLD token symbol.  A
    ///         BOLD-enabled deployment's constructor cross-checks
    ///         `BOLD_TOKEN_ADDRESS.symbol()` against this string
    ///         (defence-in-depth behind the address pin).
    /// @dev    Constitutional pin; changing it is a Genesis-Plan §13.6
    ///         amendment (two-reviewer rule) and is pinned at runtime by
    ///         `BridgeFeeSplitBold.t.sol::test_boldConstants_pinned`.
    string public constant EXPECTED_BOLD_SYMBOL = "BOLD";

    // ---- BOLD safety-hardening constants + roles (Workstream GP.5.5) ----

    /// @notice Compile-time pin on the canonical Liquity V2 ETH-branch
    ///         `TroveManager` contract address.  Source of the
    ///         `shutdownTime` reading consumed by
    ///         `closeBoldCircuitIfAnyLiquityBranchShutdown`.
    /// @dev    Constitutional pin; changing it is a Genesis-Plan §13.6
    ///         amendment (two-reviewer rule), pinned in source by
    ///         `scripts/audit_compile_time_caps.sh` and at runtime by
    ///         `BoldCircuitBreaker.t.sol::test_troveManagerConstants_pinned`.
    ///         The `forgefmt: disable-next-line` directive keeps the
    ///         declaration on a single line so the source-level audit
    ///         gate's regex (which matches on single lines) finds it
    ///         even though the full text exceeds the file's
    ///         `line_length = 100` formatting budget.
    // forgefmt: disable-next-line
    address public constant LIQUITY_V2_TROVE_MANAGER_ETH = 0x7bcb64B2c9206a5B699eD43363f6F98D4776Cf5A;
    /// @notice Compile-time pin on the canonical Liquity V2 wstETH-branch
    ///         `TroveManager` contract address.  See
    ///         `LIQUITY_V2_TROVE_MANAGER_ETH`.
    /// @dev    Constitutional pin; same governance as above.
    // forgefmt: disable-next-line
    address public constant LIQUITY_V2_TROVE_MANAGER_WSTETH = 0xA2895d6A3bf110561Dfe4b71cA539d84e1928B22;
    /// @notice Compile-time pin on the canonical Liquity V2 rETH-branch
    ///         `TroveManager` contract address.  See
    ///         `LIQUITY_V2_TROVE_MANAGER_ETH`.
    /// @dev    Constitutional pin; same governance as above.
    // forgefmt: disable-next-line
    address public constant LIQUITY_V2_TROVE_MANAGER_RETH = 0xb2B2ABEb5C357a234363FF5D180912D319e3e19e;

    /// @notice Address authorised to toggle the per-currency BOLD circuit
    ///         breaker (`closeBoldCircuit` / `openBoldCircuit`).  Set in
    ///         the constructor; immutable.  Required non-zero, distinct
    ///         from `boldAdmin`, and distinct from this contract on a
    ///         BOLD-enabled deployment so the emergency-pause path is
    ///         operable and least-privilege-separated; `address(0)`
    ///         (unreachable) when BOLD is disabled.  This role can ONLY
    ///         pause/resume BOLD deposits — it cannot move funds, alter
    ///         state roots, change any immutable, or touch the ETH leg.
    address public immutable boldCircuitBreaker;
    /// @notice Address authorised to adjust the per-currency BOLD TVL cap
    ///         (`setBoldTvlCap`).  Set in the constructor; immutable.
    ///         Required non-zero, distinct from `boldCircuitBreaker`, and
    ///         distinct from this contract on a BOLD-enabled deployment.
    ///         This role can ONLY set `boldTvlCap` within `[0, tvlCap]` —
    ///         strictly tightening (never loosening past the global cap)
    ///         the deployment's overall reserve commitment.
    address public immutable boldAdmin;
    /// @notice Whether the permissionless Liquity-V2 depeg auto-trigger is
    ///         enabled for this deployment.  Set in the constructor;
    ///         immutable.  When `true`, the three `LIQUITY_V2_TROVE_MANAGER_*`
    ///         constants must hold code at construction (`LiquityOracleHasNoCode`
    ///         otherwise) AND `boldEnabled` must be true
    ///         (`AutoTriggerRequiresBold` otherwise).  When `false`,
    ///         `closeBoldCircuitIfAnyLiquityBranchShutdown` reverts
    ///         `AutoCircuitTriggerDisabled` and the operator drives the
    ///         circuit manually via `closeBoldCircuit`.
    bool public immutable enableLiquityAutoCircuitTrigger;

    // ------------------------------------------------------------------
    // Mutable state — only written by proof-gated entry points
    // ------------------------------------------------------------------

    /// @notice Per-depositor counter; ensures `receiptHash`
    ///         determinism within a block.
    mapping(address => uint64) public depositNonce;

    /// @notice State-root ledger keyed by the post-state log index
    ///         of the highest-indexed log entry covered.  The
    ///         `reverted` status is NOT stored here; it is computed
    ///         on-the-fly as `logIndexHigh >= lowestRevertedLogIndexHigh`
    ///         per the O(1) `revertToPriorRoot` discipline.
    struct StateRootRecord {
        bytes32 root;
        uint64 logIndexHigh;
        uint64 submittedAtBlock;
        bool exists;
    }

    mapping(uint64 => StateRootRecord) private _stateRoots;
    uint64 public latestSubmittedLogIndexHigh;
    uint64 public latestStateRootSubmittedAtBlock;
    uint64 public lastUpheldDisputeBlock;

    /// @notice The reverted **range** is `[lowestRevertedLogIndexHigh,
    ///         revertedThroughLogIndexHigh]` (inclusive).  A state
    ///         root at index X is reverted iff
    ///         `lowestRevertedLogIndexHigh <= X <=
    ///         revertedThroughLogIndexHigh`.  Initial state:
    ///         floor = `type(uint64).max`, ceiling = 0 (empty range).
    ///
    ///         `revertToPriorRoot(N)` LOWERS the floor if `N <
    ///         floor` and RAISES the ceiling to
    ///         `latestSubmittedLogIndexHigh` (the highest existing
    ///         state root at the time of the revert).  Future
    ///         submissions land at indices > ceiling and are
    ///         therefore NOT reverted (they post-date the dispute).
    ///
    ///         Audit-2 fix: the previous "floor only" design
    ///         silently broke post-revert submissions because
    ///         `idx >= floor` would auto-mark every future
    ///         submission as reverted.  The (floor, ceiling) pair
    ///         correctly bounds the reverted range to historical
    ///         state.
    uint64 public lowestRevertedLogIndexHigh = type(uint64).max;

    /// @notice The highest index in the currently-reverted range.
    ///         See `lowestRevertedLogIndexHigh`.
    uint64 public revertedThroughLogIndexHigh; // default 0

    /// @notice Tracks redeemed leaves by their canonical
    ///         `keccak256(leafBlob)` so a single PendingWithdrawal
    ///         can never be redeemed twice.
    mapping(bytes32 => bool) public withdrawalLeafRedeemed;

    /// @notice Sum of locked value: deposits − withdrawals.
    uint256 public totalLockedValue;

    // ---- BOLD safety-hardening mutable state (Workstream GP.5.5) ----

    /// @notice Per-currency circuit breaker for the BOLD leg.  When
    ///         `true`, `depositBoldWithFee` reverts `BoldDepositPaused`
    ///         while every other entry point (including BOLD withdrawals
    ///         and the entire ETH leg) is unaffected.  Toggled by the
    ///         `boldCircuitBreaker` role and the permissionless
    ///         depeg auto-trigger.  Defaults to `false` (open).
    bool public boldCircuitClosed;

    /// @notice Per-currency TVL cap for BOLD, independent of (and held
    ///         no looser than) the global `tvlCap`.  Set initially in the
    ///         constructor and adjustable by the `boldAdmin` role via
    ///         `setBoldTvlCap`.  A deployment that leaves it at 0 rejects
    ///         every BOLD deposit (fails closed) until the admin raises it.
    uint256 public boldTvlCap;

    /// @notice Per-currency current BOLD locked value (BOLD deposits −
    ///         BOLD withdrawals), tracked separately from the global
    ///         `totalLockedValue` so the per-BOLD cap composes with the
    ///         global cap.  Only mutated on BOLD-resource deposit /
    ///         withdrawal when BOLD is enabled.
    uint256 public boldTotalLockedValue;

    // ------------------------------------------------------------------
    // Resource map (immutable; resource id → ERC-20 token address)
    // ------------------------------------------------------------------

    /// @notice The per-deployment resource-id → token-address
    ///         bijection.  Set in the constructor and immutable
    ///         thereafter.  resource id 0 is reserved for ETH; ids
    ///         1..N map to ERC-20 tokens via the constructor's
    ///         `_resourceIdsForErc20` / `_erc20Addrs` parallel
    ///         arrays.
    mapping(uint64 => address) private _resourceTokens;
    /// @notice Bookkeeping flag: the resource id is registered
    ///         (true) or unknown (false).  ETH (id 0) is implicit;
    ///         every ERC-20 entry sets this to `true`.
    mapping(uint64 => bool) private _resourceRegistered;

    /// @notice The ERC-20 token bound to `resourceId`, or `address(0)` if
    ///         the id is unregistered (ETH's id 0 is implicit and always
    ///         returns `address(0)`).  Read-only introspection of the
    ///         immutable resource map; also lets off-chain consumers
    ///         confirm the GP.5.4 auto-bound `(RESOURCE_ID_BOLD ->
    ///         BOLD_TOKEN_ADDRESS)` entry on a BOLD-enabled deployment.
    function resourceToken(uint64 resourceId) external view returns (address) {
        return _resourceTokens[resourceId];
    }

    // ------------------------------------------------------------------
    // Open-dispute tracking (consulted by `KnomosisSequencerStake`)
    // ------------------------------------------------------------------

    /// @notice The block of the most-recently-submitted state root
    ///         that has an active (`.open`) dispute against it.
    ///         Updated by the dispute verifier through a side
    ///         channel; for now we compute the predicate `lastUpheldDisputeBlock != 0
    ///         && block.number < lastUpheldDisputeBlock + disputeWindowBlocks`
    ///         as the conservative approximation.  The full
    ///         per-state-root open-dispute index lives in the
    ///         dispute verifier and is queried via that contract.
    function hasOpenDisputeOlderThan(uint64 thresholdBlock) external view returns (bool) {
        // Conservative: any unfinalised state root past
        // `thresholdBlock` is treated as "potentially under
        // dispute".  The dispute verifier maintains the
        // authoritative open-dispute set; this getter is the
        // surface that `KnomosisSequencerStake` consults to lock
        // sequencer stake during the post-submission window.
        if (latestStateRootSubmittedAtBlock == 0) return false;
        if (latestStateRootSubmittedAtBlock <= thresholdBlock) return false;
        return block.number < latestStateRootSubmittedAtBlock + disputeWindowBlocks;
    }

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    struct ConstructorArgs {
        bytes32 knomosisVersionTag;
        address attestor;
        address disputeVerifier;
        address sequencerStake;
        address migration;
        uint64 disputeWindowBlocks;
        uint64 maxRedemptionWindowBlocks;
        uint64 maxAttestationStaleBlocks;
        uint64 cooldownBlocks;
        uint256 tvlCap;
        // Workstream GP.5.1 fee-split parameters.
        uint16 minFeeBps;
        uint16 maxFeeBps;
        uint64 weiPerBudgetUnitEth;
        // Workstream GP.5.4 BOLD parameters.  `boldTokenAddress ==
        // address(0)` opts OUT of BOLD (disables the entry point and
        // skips the BOLD construction checks); any non-zero value must
        // equal the canonical `BOLD_TOKEN_ADDRESS` pin.  `weiPerBudgetUnitBold`
        // is validated (and used) only when BOLD is enabled.
        uint64 weiPerBudgetUnitBold;
        address boldTokenAddress;
        // Workstream GP.5.5 BOLD safety-hardening parameters.  The first
        // three are validated only when BOLD is enabled; the
        // auto-trigger flag is validated whenever set (it BOLD-gates
        // itself).  On a BOLD-disabled deployment the role fields are
        // stored verbatim and inert (the BOLD safety functions are
        // unreachable).  The Liquity V2 TroveManager addresses live in
        // source as constitutional `LIQUITY_V2_TROVE_MANAGER_*` constants
        // (constructor + GP.5.2 cap-audit gate enforce); the auto-trigger
        // reads `shutdownTime()` from each.
        //   * `boldTvlCap`        — initial per-BOLD TVL cap (≤ `tvlCap`).
        //   * `boldCircuitBreaker`— role for the manual circuit toggle.
        //   * `boldAdmin`         — role for `setBoldTvlCap`.
        //   * `enableLiquityAutoCircuitTrigger` — opt into the auto-trigger.
        uint256 boldTvlCap;
        address boldCircuitBreaker;
        address boldAdmin;
        bool enableLiquityAutoCircuitTrigger;
        uint64[] erc20ResourceIds;
        address[] erc20TokenAddrs;
    }

    /// @notice Reverts when the `sequencerStake` constructor
    ///         argument is the zero address.  Audit-2: closes the
    ///         pre-audit gap where missing-zero-check on
    ///         `sequencerStake` allowed misconfigured deployments
    ///         that the test suite would not catch until a slash
    ///         was attempted.
    error ZeroSequencerStake();

    constructor(ConstructorArgs memory args) {
        // ---- Sanity: dispute window must dominate redemption window
        if (args.disputeWindowBlocks < args.maxRedemptionWindowBlocks) {
            revert InvariantViolation_DisputeWindowVsRedemption();
        }
        if (args.attestor == address(0)) revert NotAttestor();
        if (args.disputeVerifier == address(0)) revert NotDisputeVerifier();
        if (args.sequencerStake == address(0)) revert ZeroSequencerStake();

        // ---- Fee-split parameter validation (Workstream GP.5.1) ----
        // All three immutables are validated at deploy time; once past
        // construction every fee-split path computes deterministically
        // from these fixed values.
        if (args.minFeeBps > args.maxFeeBps) {
            revert MinFeeBpsExceedsMax(args.minFeeBps, args.maxFeeBps);
        }
        if (args.maxFeeBps > MAX_FEE_BPS_CAP) {
            revert MaxFeeBpsExceedsCap(args.maxFeeBps);
        }
        if (args.weiPerBudgetUnitEth < MIN_WEI_PER_BUDGET_UNIT) {
            revert WeiPerBudgetUnitTooSmall(args.weiPerBudgetUnitEth);
        }

        // ---- BOLD opt-in validation (Workstream GP.5.4) ----
        // A deployment opts into the BOLD entry point by passing the
        // canonical BOLD_TOKEN_ADDRESS; passing address(0) disables BOLD
        // (so the bridge still deploys on chains without BOLD, and every
        // pre-GP.5.4 ETH-only deployment shape keeps working unchanged).
        // When BOLD is enabled, the address pin is the primary
        // authenticity check and the symbol() cross-check is the
        // secondary defence-in-depth check; both must pass, and the
        // BOLD-leg exchange rate must clear MIN_WEI_PER_BUDGET_UNIT
        // (rules out the divide-by-zero shape).
        //
        // The result is computed into a local and assigned to the
        // `boldEnabled` immutable once, below — Solidity 0.8.20 forbids
        // assigning an immutable inside an `if`.
        bool boldEnabled_ = (args.boldTokenAddress != address(0));
        if (boldEnabled_) {
            if (args.boldTokenAddress != BOLD_TOKEN_ADDRESS) {
                revert BoldTokenAddressMismatch(args.boldTokenAddress);
            }
            if (args.weiPerBudgetUnitBold < MIN_WEI_PER_BUDGET_UNIT) {
                revert WeiPerBudgetUnitTooSmall(args.weiPerBudgetUnitBold);
            }
            // Explicit code-presence check.  Solidity's `try` on a
            // return-value external call reverts WITHOUT data (not via the
            // catch) when the target has no code, so check up front and
            // map the no-code case onto the same `BoldTokenSymbolUnavailable`
            // signal as a reverting / undecodable `symbol()`.
            if (args.boldTokenAddress.code.length == 0) {
                revert BoldTokenSymbolUnavailable();
            }
            // The symbol() call is wrapped in try/catch because an
            // arbitrary token at the pinned address could revert or
            // return undecodable data; any failure is treated as "this
            // is not BOLD".  In production the address pin already
            // guarantees authenticity, so this is belt-and-braces.
            try IERC20Metadata(args.boldTokenAddress).symbol() returns (string memory sym) {
                if (keccak256(bytes(sym)) != keccak256(bytes(EXPECTED_BOLD_SYMBOL))) {
                    revert BoldTokenSymbolMismatch(sym);
                }
            } catch {
                revert BoldTokenSymbolUnavailable();
            }
        }

        // ---- BOLD safety-hardening validation (Workstream GP.5.5) ----
        // A BOLD-enabled deployment must ship operable safety roles and a
        // per-BOLD cap no looser than the global cap, so the depeg defences
        // are real rather than unreachable no-ops.  When BOLD is disabled
        // these are stored verbatim and never consulted, so they are left
        // unvalidated.
        if (boldEnabled_) {
            if (args.boldCircuitBreaker == address(0)) revert ZeroBoldCircuitBreaker();
            if (args.boldAdmin == address(0)) revert ZeroBoldAdmin();
            // Least-privilege: the breaker (hot pause key) MUST NOT be the
            // same address as the admin (cold cap-tuning key).  A single
            // shared key collapses the two-role separation the design
            // depends on.
            if (args.boldCircuitBreaker == args.boldAdmin) revert BoldRolesNotDistinct();
            // The bridge MUST NOT be a safety role for itself.  Without
            // this guard a future `address(this).call(...)` from any new
            // bridge entry point would inadvertently satisfy the role
            // check.  Closes the footgun by construction.
            if (args.boldCircuitBreaker == address(this) || args.boldAdmin == address(this)) {
                revert BoldRoleIsBridge();
            }
            if (args.boldTvlCap > args.tvlCap) {
                revert BoldTvlCapExceedsGlobal(args.boldTvlCap, args.tvlCap);
            }
        }
        // The Liquity-V2 auto-trigger is opt-in.  Validating the
        // `LIQUITY_V2_TROVE_MANAGER_*` pins is gated on the opt-in flag
        // (not on `boldEnabled_`) so a deployment cannot enable the
        // auto-trigger without (a) a BOLD leg for it to defend and (b)
        // a real Liquity V2 deployment on this chain.  The code-presence
        // check fires loudly at deploy time if any branch's TroveManager
        // is absent — operators on non-Liquity chains must leave the
        // auto-trigger disabled.  Mirrors the BOLD-token code check.
        if (args.enableLiquityAutoCircuitTrigger) {
            if (!boldEnabled_) revert AutoTriggerRequiresBold();
            // Defence-in-depth pairwise-distinctness check.  The GP.5.2
            // audit gate already catches a duplicated TM address pin at
            // source-edit time; this runtime check fires even if the
            // gate were bypassed.  Gated on the auto-trigger opt-in
            // because non-Liquity deployments don't consult these pins.
            if (
                LIQUITY_V2_TROVE_MANAGER_ETH == LIQUITY_V2_TROVE_MANAGER_WSTETH
                    || LIQUITY_V2_TROVE_MANAGER_WSTETH == LIQUITY_V2_TROVE_MANAGER_RETH
                    || LIQUITY_V2_TROVE_MANAGER_ETH == LIQUITY_V2_TROVE_MANAGER_RETH
            ) {
                revert BoldTroveManagersNotDistinct();
            }
            // Code-presence check per branch.  Reporting which branch is
            // missing helps operators diagnose without bisecting.
            if (LIQUITY_V2_TROVE_MANAGER_ETH.code.length == 0) {
                revert LiquityOracleHasNoCode(LIQUITY_V2_TROVE_MANAGER_ETH);
            }
            if (LIQUITY_V2_TROVE_MANAGER_WSTETH.code.length == 0) {
                revert LiquityOracleHasNoCode(LIQUITY_V2_TROVE_MANAGER_WSTETH);
            }
            if (LIQUITY_V2_TROVE_MANAGER_RETH.code.length == 0) {
                revert LiquityOracleHasNoCode(LIQUITY_V2_TROVE_MANAGER_RETH);
            }
        }

        // ---- Pin every immutable
        knomosisVersionTag = args.knomosisVersionTag;
        attestor = args.attestor;
        disputeVerifier = args.disputeVerifier;
        sequencerStake = args.sequencerStake;
        migration = args.migration;
        disputeWindowBlocks = args.disputeWindowBlocks;
        maxRedemptionWindowBlocks = args.maxRedemptionWindowBlocks;
        maxAttestationStaleBlocks = args.maxAttestationStaleBlocks;
        cooldownBlocks = args.cooldownBlocks;
        tvlCap = args.tvlCap;
        minFeeBps = args.minFeeBps;
        maxFeeBps = args.maxFeeBps;
        weiPerBudgetUnitEth = args.weiPerBudgetUnitEth;
        // Pinned unconditionally; consulted only on the BOLD path, which
        // is itself gated by `boldEnabled`.  On a BOLD-disabled
        // deployment this is whatever the deployer passed (typically 0).
        weiPerBudgetUnitBold = args.weiPerBudgetUnitBold;
        boldEnabled = boldEnabled_;

        // ---- GP.5.5 safety-hardening roles + initial cap.
        // Roles and opt-in flag are immutable; `boldTvlCap` is the
        // initial value of the mutable cap (the `boldAdmin` adjusts it
        // later via `setBoldTvlCap`).  The Liquity V2 TroveManager
        // addresses live in source as constants (no immutable to pin
        // here).  All validated above when relevant.
        boldCircuitBreaker = args.boldCircuitBreaker;
        boldAdmin = args.boldAdmin;
        enableLiquityAutoCircuitTrigger = args.enableLiquityAutoCircuitTrigger;
        boldTvlCap = args.boldTvlCap;

        deploymentId = keccak256(abi.encode(block.chainid, address(this), args.knomosisVersionTag));

        // ---- Wire the resource map
        // Both arrays must be the same length; resource id 0 is
        // reserved for ETH and cannot be reassigned.
        if (args.erc20ResourceIds.length != args.erc20TokenAddrs.length) {
            revert UnsupportedResource();
        }
        for (uint256 i = 0; i < args.erc20ResourceIds.length; ++i) {
            uint64 rid = args.erc20ResourceIds[i];
            address tok = args.erc20TokenAddrs[i];
            if (rid == RESOURCE_ID_NATIVE_ETH || tok == address(0)) {
                revert UnsupportedResource();
            }
            if (_resourceRegistered[rid]) revert UnsupportedResource();
            // Audit-2: reject duplicate token addresses.  The
            // (resourceId → token) map must be a bijection so the
            // L2 ↔ L1 ledger stays in 1:1 correspondence.  Without
            // this check, two resourceIds could fund the same
            // token, splitting accounting at the L2 level.
            for (uint256 j = 0; j < i; ++j) {
                if (args.erc20TokenAddrs[j] == tok) {
                    revert DuplicateResourceToken(tok);
                }
            }
            // BOLD reserves RESOURCE_ID_BOLD + BOLD_TOKEN_ADDRESS
            // (Workstream GP.5.4).  On a BOLD-enabled deployment both are
            // auto-bound below, so the deployer's map is for OTHER tokens
            // only: registering resourceId 1 (any token) or BOLD at any id
            // is rejected.  This forecloses two divergence classes —
            // resourceId 1 -> non-BOLD (BOLD deposits credit id 1 via the
            // constant path, but `withdrawWithProof` would pay the wrong
            // token) and BOLD -> id != 1 (two ids mapping to BOLD).  (When
            // BOLD is disabled, resourceId 1 is an ordinary ERC-20 slot and
            // this guard is inert.)
            if (boldEnabled_ && (rid == RESOURCE_ID_BOLD || tok == BOLD_TOKEN_ADDRESS)) {
                revert BoldResourceReserved();
            }
            _resourceTokens[rid] = tok;
            _resourceRegistered[rid] = true;
        }

        // Auto-bind BOLD to RESOURCE_ID_BOLD when enabled.  The reserve
        // guard above guarantees the deployer left resourceId 1 free, so
        // this is the sole writer of that slot: BOLD withdrawals via
        // `withdrawWithProof` (which reads `_resourceTokens[resourceId]`)
        // always resolve to the canonical BOLD token, with no deployer
        // action required and no way to misconfigure.
        if (boldEnabled_) {
            _resourceTokens[RESOURCE_ID_BOLD] = BOLD_TOKEN_ADDRESS;
            _resourceRegistered[RESOURCE_ID_BOLD] = true;
        }
    }

    // ------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------

    /// @notice The four §9.1.4 automatic circuit breakers.  Applied
    ///         to every state-shaping entry point.  Pure-state
    ///         predicates; no privileged caller required to
    ///         "trip" them.
    modifier circuitOpen() {
        // (a) AttestationStale
        if (
            latestStateRootSubmittedAtBlock != 0
                && block.number
                    > uint256(latestStateRootSubmittedAtBlock) + uint256(maxAttestationStaleBlocks)
        ) revert AttestationStale();
        // (b) DisputeCooldown
        if (
            lastUpheldDisputeBlock != 0
                && block.number < uint256(lastUpheldDisputeBlock) + uint256(cooldownBlocks)
        ) revert DisputeCooldown();
        // (c) TvlCapReached — tested at deposit-entry below; for
        //     symmetry with the spec we also re-check here so
        //     submitStateRoot rejects when the bridge is over cap.
        if (totalLockedValue > tvlCap) revert TvlCapReached();
        // (d) MigrationActivated
        if (migration != address(0) && IKnomosisMigration(migration).activated()) {
            revert MigrationActivated();
        }
        _;
    }

    /// @notice Withdrawals continue post-migration so users can
    ///         always exit; this modifier intentionally omits the
    ///         `MigrationActivated` and `TvlCapReached` breakers.
    ///         The `reverted` flag on the state-root record is the
    ///         primary correctness gate for withdrawals.
    modifier withdrawalOpen() {
        // Note: no MigrationActivated check (user-exit guarantee).
        _;
    }

    // ---- BOLD safety-hardening modifiers (Workstream GP.5.5) ----

    /// @notice Gates `depositBoldWithFee` on the per-currency BOLD
    ///         circuit breaker.  Independent of the four automatic
    ///         `circuitOpen` breakers; halts only the BOLD deposit path.
    modifier boldCircuitOpen() {
        if (boldCircuitClosed) revert BoldDepositPaused();
        _;
    }

    /// @notice Restricts a BOLD circuit toggle to the immutable
    ///         `boldCircuitBreaker` role.  On a BOLD-disabled deployment
    ///         the role is `address(0)`, so the guarded functions are
    ///         unreachable.
    modifier onlyBoldCircuitBreaker() {
        if (msg.sender != boldCircuitBreaker) revert NotBoldCircuitBreaker();
        _;
    }

    /// @notice Restricts `setBoldTvlCap` to the immutable `boldAdmin`
    ///         role.  On a BOLD-disabled deployment the role is
    ///         `address(0)`, so the guarded function is unreachable.
    modifier onlyBoldAdmin() {
        if (msg.sender != boldAdmin) revert NotBoldAdmin();
        _;
    }

    // ------------------------------------------------------------------
    // E.1.1 Deposit entry points
    // ------------------------------------------------------------------

    event DepositInitiated(
        address indexed depositor,
        uint64 indexed resourceId,
        address token,
        uint256 amount,
        uint64 depositorNonce,
        bytes32 receiptHash
    );

    /// @notice Deposit native ETH.  `msg.value` is the deposit
    ///         amount; the receipt is registered for L2 credit.
    function depositETH() external payable nonReentrant circuitOpen {
        _registerDeposit(RESOURCE_ID_NATIVE_ETH, address(0), msg.value);
    }

    /// @notice Deposit an ERC-20 token.  `amount` is debited from
    ///         `msg.sender` to this contract via `safeTransferFrom`.
    ///         The bridge measures the actual received amount
    ///         (balance-delta) and rejects if it differs from
    ///         `amount` — fee-on-transfer / rebasing / deflationary
    ///         tokens are NOT supported because the L2 credit
    ///         would desync from the L1-locked value.
    function depositERC20(uint64 resourceId, IERC20 token, uint256 amount)
        external
        nonReentrant
        circuitOpen
    {
        // BOLD (the gas-pool resource) is auto-bound at construction so
        // `withdrawWithProof` resolves the payout token; that binding also
        // satisfies the `_resourceRegistered` / `_resourceTokens` checks
        // below, which would otherwise open a fee-bypassing legacy deposit
        // path for BOLD (emitting `DepositInitiated` with no pool credit /
        // budget grant).  BOLD deposits must go through `depositBoldWithFee`
        // — the sole writer of `RESOURCE_ID_BOLD` is the constructor, so
        // gating on the id fully covers the BOLD token (it lives at no other
        // id).  Inert when BOLD is disabled (resourceId 1 is then an
        // ordinary ERC-20 slot).
        if (boldEnabled && resourceId == RESOURCE_ID_BOLD) {
            revert BoldDepositViaFeeSplitOnly();
        }
        if (resourceId == RESOURCE_ID_NATIVE_ETH || !_resourceRegistered[resourceId]) {
            revert UnsupportedResource();
        }
        // Resource-id ↔ token mapping must match.
        if (_resourceTokens[resourceId] != address(token)) {
            revert UnsupportedResource();
        }
        // Balance-delta accounting: measure pre and post balance
        // and assert the actual transfer amount equals `amount`.
        // This rejects fee-on-transfer / rebasing tokens whose
        // received amount differs from the declared amount.
        uint256 balBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = token.balanceOf(address(this));
        // Underflow-safe: balAfter ≥ balBefore is enforced by
        // SafeERC20 on a successful transfer.
        uint256 received;
        unchecked {
            received = balAfter - balBefore;
        }
        if (received != amount) {
            revert TransferAmountMismatch(amount, received);
        }
        _registerDeposit(resourceId, address(token), amount);
    }

    /// @notice Common deposit bookkeeping.  Computes the canonical
    ///         `receiptHash` (matching Lean `DepositId`), bumps the
    ///         per-depositor counter, increments TVL, and emits.
    function _registerDeposit(uint64 resourceId, address token, uint256 amount) internal {
        // Reject deposits that would push us past the TVL cap.
        // Checked-arithmetic prevents wraparound.
        uint256 newTvl = totalLockedValue + amount;
        if (newTvl > tvlCap) revert TvlCapReached();
        totalLockedValue = newTvl;

        uint64 nonce = depositNonce[msg.sender];
        bytes32 receiptHash =
            keccak256(abi.encode(deploymentId, msg.sender, resourceId, token, amount, nonce));
        unchecked {
            depositNonce[msg.sender] = nonce + 1;
        }
        emit DepositInitiated(msg.sender, resourceId, token, amount, nonce, receiptHash);
    }

    // ------------------------------------------------------------------
    // GP.5.1 Fee-split deposit entry points
    // ------------------------------------------------------------------

    /// @notice Emitted by the fee-split deposit entry points
    ///         (`depositETHWithFee` for ETH at `RESOURCE_ID_NATIVE_ETH`;
    ///         `depositBoldWithFee` for BOLD at `RESOURCE_ID_BOLD`).  The
    ///         L2 ingestor reconstructs a `Bridge.DepositRecord` from
    ///         `(userAmount, poolAmount, budgetGrant)`: `userAmount` is
    ///         credited to the recipient, `poolAmount` to the gas-pool
    ///         actor, and `budgetGrant` action-budget units to the
    ///         recipient at the admission layer.
    /// @dev    `receiptHash` binds the `deploymentId` plus every other
    ///         emitted field, so an L2 ingestor that recomputes the
    ///         hash cannot be tricked by a replayed event with
    ///         modified fields (Genesis-Plan / unified-gas-pool plan
    ///         §22.7b), and the same deposit replayed against a
    ///         different deployment produces a different hash
    ///         (deployment-replay resistance, mirroring
    ///         `_registerDeposit`).
    event DepositWithFeeInitiated(
        address indexed sender,
        uint64 indexed resourceId,
        address indexed token,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant,
        uint64 depositorNonce,
        bytes32 receiptHash
    );

    /// @notice Deposit native ETH with a user-chosen fee split.  The
    ///         caller picks `chosenFeeBps` within the deployment's
    ///         immutable `[minFeeBps, maxFeeBps]` range; the fee
    ///         (`poolAmount`) accrues to the gas pool and the remainder
    ///         (`userAmount`) is credited to the caller on L2.  The
    ///         pool credit is converted to an action-budget grant at
    ///         the `weiPerBudgetUnitEth` exchange rate, clamped at
    ///         `MAX_BUDGET_PER_DEPOSIT`.
    /// @param  chosenFeeBps The fee in basis points (1/10000).  Must
    ///         lie in `[minFeeBps, maxFeeBps]`.
    function depositETHWithFee(uint16 chosenFeeBps) external payable nonReentrant circuitOpen {
        if (msg.value == 0) revert ZeroDeposit();
        if (chosenFeeBps < minFeeBps) revert FeeBpsBelowMin(chosenFeeBps);
        if (chosenFeeBps > maxFeeBps) revert FeeBpsAboveMax(chosenFeeBps);

        uint256 v = msg.value;

        // Floor division.  poolAmount = floor(v * chosenFeeBps / 10000)
        // <= floor(v * maxFeeBps / 10000) <= floor(v * 5000 / 10000)
        // = floor(v / 2) <= v, because maxFeeBps <= MAX_FEE_BPS_CAP =
        // 5000 (constructor-enforced) and chosenFeeBps <= maxFeeBps
        // (checked above).  Hence userAmount = v - poolAmount >= 0, so
        // the subtraction is safe under `unchecked`.  The checked
        // multiply v * chosenFeeBps cannot overflow for any realistic
        // msg.value (ETH supply ~ 2^87 wei); a hypothetical overflow
        // reverts rather than wrapping silently.
        uint256 poolAmount = (v * uint256(chosenFeeBps)) / 10_000;
        uint256 userAmount;
        unchecked {
            userAmount = v - poolAmount;
        }

        // Budget grant at the ETH-leg exchange rate.  rawBudgetGrant =
        // poolAmount / weiPerBudgetUnitEth <= poolAmount <= v, so no
        // uint256 overflow (weiPerBudgetUnitEth >= 1 is
        // constructor-enforced).  The uint64 cast is gated by the
        // explicit clamp at MAX_BUDGET_PER_DEPOSIT (= 10^12 < 2^63),
        // so the only value ever cast lies in [0, 10^12].
        uint256 rawBudgetGrant = poolAmount / uint256(weiPerBudgetUnitEth);
        uint64 budgetGrant;
        if (rawBudgetGrant > uint256(MAX_BUDGET_PER_DEPOSIT)) {
            budgetGrant = MAX_BUDGET_PER_DEPOSIT;
        } else {
            // casting to `uint64` is safe: this branch is reached only
            // when rawBudgetGrant <= MAX_BUDGET_PER_DEPOSIT = 10^12 <
            // 2^63, so the value always fits a uint64 with no truncation.
            // forge-lint: disable-next-line(unsafe-typecast)
            budgetGrant = uint64(rawBudgetGrant);
        }

        _registerDepositWithFee(
            RESOURCE_ID_NATIVE_ETH, address(0), userAmount, poolAmount, budgetGrant
        );
    }

    /// @notice Deposit BOLD with a user-chosen fee split — the BOLD-leg
    ///         mirror of `depositETHWithFee`.  The caller picks
    ///         `chosenFeeBps` within the same immutable
    ///         `[minFeeBps, maxFeeBps]` range; the fee (`poolAmount`)
    ///         accrues to the gas pool at `RESOURCE_ID_BOLD` and the
    ///         remainder (`userAmount`) is credited to the caller on L2.
    ///         The pool credit converts to an action-budget grant at the
    ///         `weiPerBudgetUnitBold` exchange rate, clamped at
    ///         `MAX_BUDGET_PER_DEPOSIT`.
    /// @param  amount       The BOLD-wei deposit amount, pulled from the
    ///         caller via `transferFrom` — the caller must have approved
    ///         this contract for at least `amount` first.
    /// @param  chosenFeeBps The fee in basis points (1/10000).  Must lie
    ///         in `[minFeeBps, maxFeeBps]`.
    /// @dev    Requires `boldEnabled` (set at construction).  Reuses the
    ///         resource-generic `_registerDepositWithFee` verbatim, so the
    ///         BOLD receipt is byte-identical in shape to the ETH receipt
    ///         save for `resourceId = RESOURCE_ID_BOLD` and
    ///         `token = BOLD_TOKEN_ADDRESS`.  Carries `nonReentrant` +
    ///         `circuitOpen` + the per-currency `boldCircuitOpen` breaker
    ///         (GP.5.5), and `_registerDepositWithFee` additionally enforces
    ///         the per-BOLD `boldTvlCap`.
    function depositBoldWithFee(uint256 amount, uint16 chosenFeeBps)
        external
        nonReentrant
        circuitOpen
        boldCircuitOpen
    {
        if (!boldEnabled) revert BoldNotEnabled();
        if (amount == 0) revert ZeroDeposit();
        if (chosenFeeBps < minFeeBps) revert FeeBpsBelowMin(chosenFeeBps);
        if (chosenFeeBps > maxFeeBps) revert FeeBpsAboveMax(chosenFeeBps);

        // Pull `amount` BOLD-wei from the caller and verify the actual
        // received balance delta equals `amount`.  BOLD is a standard
        // ERC-20 (no fee-on-transfer, no rebase), so `received == amount`
        // always holds; the delta check is defence-in-depth that fails
        // loudly rather than under-accounting if BOLD ever changes
        // semantics.  SafeERC20 normalises non-bool-returning / reverting
        // transfers.  This transfer is the only external call and is
        // guarded by `nonReentrant`; it precedes every state mutation
        // (mirroring `depositERC20`).
        IERC20 bold = IERC20(BOLD_TOKEN_ADDRESS);
        uint256 balBefore = bold.balanceOf(address(this));
        bold.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balAfter = bold.balanceOf(address(this));
        // Underflow-safe: a successful `safeTransferFrom` credits this
        // contract, so `balAfter >= balBefore`.
        uint256 received;
        unchecked {
            received = balAfter - balBefore;
        }
        if (received != amount) {
            revert BoldTransferAmountMismatch(amount, received);
        }

        uint256 v = amount;

        // Identical fee-split arithmetic to `depositETHWithFee`.
        // poolAmount = floor(v * chosenFeeBps / 10000) <= floor(v / 2) <= v
        // (maxFeeBps <= MAX_FEE_BPS_CAP = 5000 and chosenFeeBps <=
        // maxFeeBps), so userAmount = v - poolAmount >= 0 is safe under
        // `unchecked`.
        uint256 poolAmount = (v * uint256(chosenFeeBps)) / 10_000;
        uint256 userAmount;
        unchecked {
            userAmount = v - poolAmount;
        }

        // Budget grant at the BOLD-leg rate.  rawBudgetGrant =
        // poolAmount / weiPerBudgetUnitBold <= poolAmount <= v, so no
        // uint256 overflow (weiPerBudgetUnitBold >= 1 is enforced for an
        // enabled deployment).  The uint64 cast is gated by the explicit
        // clamp at MAX_BUDGET_PER_DEPOSIT (= 10^12 < 2^63).
        uint256 rawBudgetGrant = poolAmount / uint256(weiPerBudgetUnitBold);
        uint64 budgetGrant;
        if (rawBudgetGrant > uint256(MAX_BUDGET_PER_DEPOSIT)) {
            budgetGrant = MAX_BUDGET_PER_DEPOSIT;
        } else {
            // casting to `uint64` is safe: this branch is reached only
            // when rawBudgetGrant <= MAX_BUDGET_PER_DEPOSIT = 10^12 < 2^63,
            // so the value always fits a uint64 with no truncation.
            // forge-lint: disable-next-line(unsafe-typecast)
            budgetGrant = uint64(rawBudgetGrant);
        }

        _registerDepositWithFee(
            RESOURCE_ID_BOLD, BOLD_TOKEN_ADDRESS, userAmount, poolAmount, budgetGrant
        );
    }

    /// @notice Shared fee-split deposit bookkeeping.  Resource-generic
    ///         so the BOLD entry point (GP.5.4) can reuse it verbatim.
    ///         Enforces the TVL cap on the FULL deposit
    ///         (`userAmount + poolAmount`), bumps the per-depositor
    ///         nonce, computes the canonical `receiptHash`, and emits
    ///         `DepositWithFeeInitiated`.  Makes no external calls.
    function _registerDepositWithFee(
        uint64 resourceId,
        address token,
        uint256 userAmount,
        uint256 poolAmount,
        uint64 budgetGrant
    ) internal {
        // The TVL cap fires on the FULL deposit value
        // (userAmount + poolAmount), independent of the fee split, so
        // fee manipulation cannot bypass it.  Checked arithmetic
        // prevents wraparound.
        uint256 amount = userAmount + poolAmount;
        uint256 newTvl = totalLockedValue + amount;
        if (newTvl > tvlCap) revert TvlCapReached();
        totalLockedValue = newTvl;

        // Per-currency BOLD TVL cap (Workstream GP.5.5).  Tracked on the
        // FULL deposit value, exactly like the global cap, so a BOLD
        // depositor cannot manipulate the fee split to evade the per-BOLD
        // limit.  Reached only via `depositBoldWithFee`, which requires
        // `boldEnabled`; the `boldEnabled &&` guard is belt-and-braces and
        // keeps the increment symmetric with the withdrawal-side decrement.
        // ETH deposits (resourceId 0) never touch `boldTotalLockedValue`.
        if (boldEnabled && resourceId == RESOURCE_ID_BOLD) {
            uint256 newBoldTvl = boldTotalLockedValue + amount;
            if (newBoldTvl > boldTvlCap) revert BoldTvlCapReached();
            boldTotalLockedValue = newBoldTvl;
        }

        uint64 nonce = depositNonce[msg.sender];
        bytes32 receiptHash = keccak256(
            abi.encode(
                deploymentId,
                msg.sender,
                resourceId,
                token,
                userAmount,
                poolAmount,
                budgetGrant,
                nonce
            )
        );
        unchecked {
            depositNonce[msg.sender] = nonce + 1;
        }
        emit DepositWithFeeInitiated(
            msg.sender, resourceId, token, userAmount, poolAmount, budgetGrant, nonce, receiptHash
        );
    }

    // ------------------------------------------------------------------
    // E.1.2 State-root submission
    // ------------------------------------------------------------------

    event StateRootSubmitted(
        bytes32 indexed root,
        uint64 indexed logIndexHigh,
        address indexed signer,
        uint64 submittedAtBlock
    );

    function submitStateRoot(bytes32 root, uint64 logIndexHigh, bytes calldata attestorSig)
        external
        circuitOpen
    {
        if (logIndexHigh <= latestSubmittedLogIndexHigh) revert NonMonotonic();
        if (attestorSig.length != 65) revert InvalidSignatureLength();

        // Recover the signer from the EIP-712 wrap of (root, logIndexHigh, deploymentId).
        bytes32 ds = KnomosisEip712.domainSeparator(
            DOMAIN_NAME, DOMAIN_VERSION, block.chainid, uint256(0), address(this)
        );
        bytes32 sh = keccak256(
            abi.encode(
                keccak256("StateRoot(bytes32 root,uint64 logIndexHigh,bytes32 deploymentId)"),
                root,
                uint256(logIndexHigh),
                deploymentId
            )
        );
        bytes32 digest = KnomosisEip712.digest(ds, sh);
        address recovered = ECDSA.recover(digest, attestorSig);
        if (recovered != attestor) revert NotAttestor();

        latestSubmittedLogIndexHigh = logIndexHigh;
        latestStateRootSubmittedAtBlock = uint64(block.number);
        _stateRoots[logIndexHigh] = StateRootRecord({
            root: root,
            logIndexHigh: logIndexHigh,
            submittedAtBlock: uint64(block.number),
            exists: true
        });

        emit StateRootSubmitted(root, logIndexHigh, recovered, uint64(block.number));
    }

    /// @notice Whether `logIndexHigh` falls in the reverted range
    ///         `[lowestRevertedLogIndexHigh, revertedThroughLogIndexHigh]`.
    ///         Computed in O(1) from the (floor, ceiling) pair —
    ///         no per-record state.
    function isStateRootReverted(uint64 logIndexHigh) public view returns (bool) {
        return
            logIndexHigh >= lowestRevertedLogIndexHigh
                && logIndexHigh <= revertedThroughLogIndexHigh;
    }

    /// @inheritdoc IKnomosisBridge
    function stateRootAt(uint64 logIndexHigh) external view returns (bytes32, uint64, bool) {
        StateRootRecord storage rec = _stateRoots[logIndexHigh];
        return (rec.root, rec.submittedAtBlock, isStateRootReverted(logIndexHigh));
    }

    /// @inheritdoc IKnomosisBridge
    function isStateRootFinalised(uint64 logIndexHigh) public view returns (bool) {
        StateRootRecord storage rec = _stateRoots[logIndexHigh];
        if (!rec.exists) return false;
        if (isStateRootReverted(logIndexHigh)) return false;
        return block.number >= uint256(rec.submittedAtBlock) + uint256(disputeWindowBlocks);
    }

    // ------------------------------------------------------------------
    // E.1.3 Withdrawal redemption
    // ------------------------------------------------------------------

    event WithdrawalRedeemed(
        bytes32 indexed leafHash,
        address indexed recipient,
        uint64 indexed resourceId,
        uint256 amount,
        uint64 atLogIndexHigh
    );

    /// @notice Decoded leaf shape — must mirror Lean's
    ///         `Bridge.PendingWithdrawal.encode`.  Layout:
    ///           CBE uint   resourceId   (9 bytes)
    ///           CBE bytes  recipientL1  (29 bytes; 1 tag + 8 length + 20 payload)
    ///           CBE uint   amount       (9 bytes)
    ///           CBE uint   l2LogIndex   (9 bytes)
    ///         Total: 56 bytes per the audit-2 lossless 20-byte
    ///         address encoding.
    struct PendingWithdrawal {
        uint64 resourceId;
        address recipientL1;
        uint256 amount;
        uint64 l2LogIndex;
    }

    /// @notice The proof shape mirrors Lean's `WithdrawalProof`:
    ///         variable-size leaf bytes + index + 64 variable-size
    ///         siblings (root-to-leaf ordered).  Audit-2 fix: leaf
    ///         and siblings are `bytes` (variable), NOT `bytes32`,
    ///         so the dense-pair case (where the leaf-adjacent
    ///         sibling is itself a ~56-byte raw leaf) is encodable.
    struct WithdrawalProof {
        bytes leaf;
        uint64 index;
        bytes[] siblings;
    }

    function withdrawWithProof(
        uint64 atLogIndexHigh,
        bytes calldata proofBlob,
        bytes calldata leafBlob
    ) external nonReentrant withdrawalOpen returns (bool) {
        // ---- Check phase ----
        // (a) Decode the leaf into a structured PendingWithdrawal.
        PendingWithdrawal memory wd = _decodePendingWithdrawal(leafBlob);
        // Audit-3: reject zero-recipient leaves explicitly.  Defensive;
        // catches cross-stack drift where the L2 ledger admits an
        // invalid recipient.
        if (wd.recipientL1 == address(0)) revert InvalidRecipient();

        // (b) Look up the state root.
        if (!isStateRootFinalised(atLogIndexHigh)) {
            StateRootRecord storage rec = _stateRoots[atLogIndexHigh];
            if (!rec.exists) revert UnknownStateRoot();
            if (isStateRootReverted(atLogIndexHigh)) revert StateRootReverted();
            revert PreFinalisation();
        }
        bytes32 root = _stateRoots[atLogIndexHigh].root;

        // (c) Reject double-spend (key by canonical hash of leafBlob).
        bytes32 leafHash = keccak256(leafBlob);
        if (withdrawalLeafRedeemed[leafHash]) revert AlreadyRedeemed();

        // (d) Decode the proof and verify against the root.
        // Audit-2 fix: the proof's `leaf` field is variable-size
        // bytes (matching Lean's `WithdrawalProof.leaf : ByteArray`).
        // Cross-check that the proof's leaf bytes equal the
        // separately-supplied leafBlob (binds the proof to the
        // payment-determining leafBlob).
        (bytes memory proofLeaf, uint64 proofIndex, bytes[] memory siblings) =
            _decodeWithdrawalProof(proofBlob);
        // The keccak256 equality check is sufficient — under
        // collision-resistance, equal hashes imply equal bytes
        // (and equal lengths).  Audit-3: removed the redundant
        // length comparison that the keccak check already
        // subsumes.
        if (keccak256(proofLeaf) != leafHash) revert InvalidProof();
        if (proofIndex != wd.l2LogIndex) revert InvalidProof();
        if (!SmtVerifier.verifyProof(uint256(proofIndex), proofLeaf, siblings, root)) {
            revert InvalidProof();
        }

        // ---- Effect phase: mark redeemed before any external call ----
        withdrawalLeafRedeemed[leafHash] = true;
        // Underflow safeguard — should be unreachable if the
        // bridge's accounting matches the L2 record.  This
        // catches a class of cross-stack drift bugs early.
        if (totalLockedValue < wd.amount) {
            revert BridgeAccountingMismatch(totalLockedValue, wd.amount);
        }
        unchecked {
            totalLockedValue = totalLockedValue - wd.amount;
        }

        // Mirror the per-currency BOLD counter (Workstream GP.5.5): a BOLD
        // withdrawal frees per-BOLD TVL room so later BOLD deposits can
        // refill it, keeping `boldTotalLockedValue` equal to net BOLD
        // (deposits − withdrawals).  Gated on `boldEnabled` so a
        // BOLD-disabled deployment — where resourceId 1 is an ordinary
        // ERC-20 that never incremented this counter — does not underflow.
        // The defensive underflow guard mirrors the global one above and
        // should be unreachable when the L1/L2 ledgers agree.
        if (boldEnabled && wd.resourceId == RESOURCE_ID_BOLD) {
            if (boldTotalLockedValue < wd.amount) {
                revert BridgeAccountingMismatch(boldTotalLockedValue, wd.amount);
            }
            unchecked {
                boldTotalLockedValue = boldTotalLockedValue - wd.amount;
            }
        }

        // ---- Interaction phase ----
        if (wd.resourceId == RESOURCE_ID_NATIVE_ETH) {
            // Native ETH: forward all gas via Address.sendValue.
            Address.sendValue(payable(wd.recipientL1), wd.amount);
        } else {
            address tok = _resourceTokens[wd.resourceId];
            if (tok == address(0)) revert UnsupportedResource();
            IERC20(tok).safeTransfer(wd.recipientL1, wd.amount);
        }

        emit WithdrawalRedeemed(leafHash, wd.recipientL1, wd.resourceId, wd.amount, atLogIndexHigh);
        return true;
    }

    function _decodePendingWithdrawal(bytes calldata leafBlob)
        internal
        pure
        returns (PendingWithdrawal memory wd)
    {
        uint256 off = 0;
        (wd.resourceId, off) = CBEDecode.readUint(leafBlob, off);
        (wd.recipientL1, off) = CBEDecode.readAddressExact(leafBlob, off);
        uint64 amount64;
        (amount64, off) = CBEDecode.readUint(leafBlob, off);
        wd.amount = uint256(amount64);
        (wd.l2LogIndex, off) = CBEDecode.readUint(leafBlob, off);
        CBEDecode.assertFullyConsumed(leafBlob, off);
    }

    function _decodeWithdrawalProof(bytes calldata proofBlob)
        internal
        pure
        returns (bytes memory leaf, uint64 index, bytes[] memory siblings)
    {
        uint256 off = 0;
        // Layout: CBE-encoded WithdrawalProof:
        //   leaf      : bytes      (variable; matches Lean's
        //                            `leafBytes wd` ≈ 56 bytes for
        //                            populated, 32 bytes for sentinel)
        //   index     : uint64
        //   siblings  : array<bytes>(64)  (each variable; typically
        //                            32-byte default-hash values, but
        //                            the leaf-adjacent sibling can
        //                            itself be a 56-byte raw leaf in
        //                            the dense-pair case).
        (leaf, off) = CBEDecode.readBytes(proofBlob, off);
        (index, off) = CBEDecode.readUint(proofBlob, off);
        uint64 count;
        (count, off) = CBEDecode.readArrayHead(proofBlob, off);
        if (count != SmtVerifier.SMT_HEIGHT) revert InvalidProof();

        siblings = new bytes[](SmtVerifier.SMT_HEIGHT);
        for (uint256 i = 0; i < SmtVerifier.SMT_HEIGHT; ++i) {
            (siblings[i], off) = CBEDecode.readBytes(proofBlob, off);
        }
        CBEDecode.assertFullyConsumed(proofBlob, off);
    }

    // ------------------------------------------------------------------
    // E.1.5 Rollback hook
    // ------------------------------------------------------------------

    /// @notice Emitted on every `revertToPriorRoot` call, carrying
    ///         the (floor, ceiling) bounds of the reverted range.
    ///         Audit-2: replaces the floor-only event;
    ///         post-revert submissions at indices > ceiling are
    ///         NOT auto-reverted.
    event StateRootRangeReverted(
        uint64 indexed disputedLogIndexHigh, uint64 newRevertedFloor, uint64 newRevertedCeiling
    );

    function revertToPriorRoot(uint64 disputedLogIndexHigh) external {
        if (msg.sender != disputeVerifier) revert NotDisputeVerifier();

        // O(1) reversion: track the (floor, ceiling) pair.
        //   - floor lowers monotonically (only decreases).
        //   - ceiling rises to the current `latestSubmittedLogIndexHigh`
        //     so all already-submitted state roots at idx ≥ floor
        //     are marked reverted.
        // Future submissions land at idx > current latest, hence
        // > ceiling, hence NOT reverted.  This closes the audit-2
        // gap where the floor-only design silently auto-reverted
        // every post-revert submission.
        bool changed = false;
        if (disputedLogIndexHigh < lowestRevertedLogIndexHigh) {
            lowestRevertedLogIndexHigh = disputedLogIndexHigh;
            changed = true;
        }
        if (latestSubmittedLogIndexHigh > revertedThroughLogIndexHigh) {
            revertedThroughLogIndexHigh = latestSubmittedLogIndexHigh;
            changed = true;
        }
        // Idempotent in the (floor, ceiling) sense: if neither the
        // floor nor the ceiling moves, no event is emitted but the
        // cooldown still trips.
        if (changed) {
            emit StateRootRangeReverted(
                disputedLogIndexHigh, lowestRevertedLogIndexHigh, revertedThroughLogIndexHigh
            );
        }

        // Trip the DisputeCooldown breaker for the next
        // `cooldownBlocks` blocks (called every time, not just on
        // a fresh-floor revert, so multiple disputes within the
        // window each refresh the cooldown).
        lastUpheldDisputeBlock = uint64(block.number);
    }

    // ------------------------------------------------------------------
    // GP.5.5 BOLD-specific safety hardening — circuit breaker + TVL cap
    // ------------------------------------------------------------------

    /// @notice Emitted when the BOLD circuit is closed by the operator's
    ///         `boldCircuitBreaker` role.
    event BoldCircuitClosed(uint256 timestamp);
    /// @notice Emitted when the BOLD circuit is reopened by the operator's
    ///         `boldCircuitBreaker` role.
    event BoldCircuitOpened(uint256 timestamp);
    /// @notice Emitted when the permissionless Liquity-V2 depeg
    ///         auto-trigger closes the BOLD circuit, carrying the first
    ///         Liquity branch detected in shutdown and that branch's
    ///         `shutdownTime`.  `shutdownBranch` is `indexed` so monitors
    ///         can filter by branch.
    event BoldCircuitClosedByAutoTrigger(
        uint256 timestamp, address indexed shutdownBranch, uint256 branchShutdownTime
    );
    /// @notice Emitted when the `boldAdmin` role updates the per-BOLD TVL
    ///         cap via `setBoldTvlCap`.
    event BoldTvlCapUpdated(uint256 newCap);

    /// @notice Operator-triggered: close the BOLD circuit when a depeg or
    ///         other BOLD-specific incident is detected.  Halts only
    ///         `depositBoldWithFee`; BOLD (and ETH) withdrawals and the
    ///         ETH deposit leg keep working — the standard "deposits
    ///         halted, withdrawals continue" posture during an incident.
    function closeBoldCircuit() external onlyBoldCircuitBreaker {
        boldCircuitClosed = true;
        emit BoldCircuitClosed(block.timestamp);
    }

    /// @notice Operator-triggered: reopen the BOLD circuit once the
    ///         incident resolves and BOLD is confirmed back in its peg
    ///         band (see the reopening procedure in
    ///         `docs/gas_pool_runbook.md`).
    function openBoldCircuit() external onlyBoldCircuitBreaker {
        boldCircuitClosed = false;
        emit BoldCircuitOpened(block.timestamp);
    }

    /// @notice Permissionless depeg auto-trigger: close the BOLD circuit
    ///         if ANY Liquity V2 collateral-branch `TroveManager` reports
    ///         a non-zero `shutdownTime` (the canonical on-chain signal
    ///         that a branch has been wound down — oracle failure,
    ///         governance vote, etc.).  Opt-in per deployment
    ///         (`enableLiquityAutoCircuitTrigger`); anyone may call it.
    /// @dev    Idempotent — returns without state change if the circuit
    ///         is already closed, so it is safe to call repeatedly.  The
    ///         only state mutation is the monotonic `boldCircuitClosed =
    ///         true`.  The three branch reads short-circuit on the first
    ///         non-zero `shutdownTime` (saves gas on the close path and
    ///         records the FIRST-detected branch in the event); only the
    ///         no-shutdown path reads all three.  Each read goes through
    ///         a low-level `staticcall` with explicit `success` /
    ///         `returndata.length` checks (rather than a typed
    ///         `try`/`catch`), so EVERY TroveManager fault degrades
    ///         uniformly to `LiquityV2ReadFailed`: a revert, a no-code
    ///         target, AND a hypothetical Liquity-V2 ABI change that
    ///         returns the wrong number of bytes.  The staticcall
    ///         context additionally forbids any SSTORE in the inner
    ///         frame, so a (practically impossible) re-entrant
    ///         TroveManager cannot corrupt bridge state by EVM
    ///         construction.  The operator gets one clean signal to
    ///         fall back to the manual `closeBoldCircuit` path.
    function closeBoldCircuitIfAnyLiquityBranchShutdown() external {
        if (!enableLiquityAutoCircuitTrigger) revert AutoCircuitTriggerDisabled();
        if (boldCircuitClosed) return; // idempotent — no-op when already closed

        // Order: ETH first (most common collateral), then wstETH, then
        // rETH.  Early-return on the first non-zero `shutdownTime` so
        // the close path costs one staticcall when the first-checked
        // branch is in shutdown; the no-shutdown (revert) path reads
        // all three.  Flat early-return chain so each branch is a
        // standalone block — easier to audit and to extend if Liquity
        // V2 ever adds another collateral branch.
        uint256 t = _readLiquityShutdownTime(LIQUITY_V2_TROVE_MANAGER_ETH);
        if (t != 0) {
            boldCircuitClosed = true;
            emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_V2_TROVE_MANAGER_ETH, t);
            return;
        }
        t = _readLiquityShutdownTime(LIQUITY_V2_TROVE_MANAGER_WSTETH);
        if (t != 0) {
            boldCircuitClosed = true;
            emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_V2_TROVE_MANAGER_WSTETH, t);
            return;
        }
        t = _readLiquityShutdownTime(LIQUITY_V2_TROVE_MANAGER_RETH);
        if (t != 0) {
            boldCircuitClosed = true;
            emit BoldCircuitClosedByAutoTrigger(block.timestamp, LIQUITY_V2_TROVE_MANAGER_RETH, t);
            return;
        }
        revert NoLiquityBranchShutdown();
    }

    /// @notice Read `shutdownTime()` from a Liquity V2 `TroveManager` via
    ///         low-level `staticcall`.  Reverts `LiquityV2ReadFailed` on
    ///         every fault class (revert, no code, wrong-shape return)
    ///         AND prevents any state mutation by the callee since
    ///         staticcall forbids SSTORE.  Returns the raw `shutdownTime`
    ///         value; the caller compares to zero.
    /// @dev    The staticcall is gas-bounded by `LIQUITY_ORACLE_READ_GAS`
    ///         (100 000) — a hardened limit that comfortably fits a
    ///         normal public-storage getter (`shutdownTime` is a `uint256
    ///         public` field on Liquity V2's TroveManager, costing ~3-5k
    ///         gas in practice) while bounding the worst-case griefing
    ///         vector: an adversarial TroveManager (e.g. a hypothetical
    ///         buggy Liquity-V2 upgrade) that consumes all forwarded gas
    ///         in a failed SSTORE under the staticcall context.  Without
    ///         this cap the EVM's 63/64-rule forwards ~all-but-1/64 of
    ///         the caller's gas, so a malicious TM could burn ~30M gas
    ///         per call on a normal transaction.  With the cap, the
    ///         worst case is ~300k total across all three branches.
    function _readLiquityShutdownTime(address troveManager) private view returns (uint256) {
        (bool ok, bytes memory data) = troveManager.staticcall{gas: LIQUITY_ORACLE_READ_GAS}(
            abi.encodeWithSelector(ILiquityV2TroveManager.shutdownTime.selector)
        );
        if (!ok || data.length != 32) revert LiquityV2ReadFailed();
        return abi.decode(data, (uint256));
    }

    /// @notice Gas forwarded to each Liquity-V2 TroveManager `shutdownTime`
    ///         read in `_readLiquityShutdownTime`.  Generous for a public
    ///         storage getter (~3-5k in practice); bounds the
    ///         malicious-TroveManager griefing surface.  Constitutional
    ///         tuning constant; pinned by the GP.5.2 audit gate (source
    ///         tripwire) AND at runtime by
    ///         `BoldCircuitBreaker.t.sol::test_liquityOracleReadGas_pinned`.
    ///         `public` so off-chain monitors / keeper bots can query it
    ///         programmatically without having to read the source.
    uint256 public constant LIQUITY_ORACLE_READ_GAS = 100_000;

    /// @notice Operator-set: adjust the per-BOLD TVL cap.  Bounded above
    ///         by the global `tvlCap` so the per-currency cap can only
    ///         tighten — never loosen past — the deployment's overall
    ///         reserve commitment.
    function setBoldTvlCap(uint256 newCap) external onlyBoldAdmin {
        if (newCap > tvlCap) revert BoldTvlCapExceedsGlobal(newCap, tvlCap);
        boldTvlCap = newCap;
        emit BoldTvlCapUpdated(newCap);
    }

    // ------------------------------------------------------------------
    // ETH receive — only via depositETH; reject bare transfers
    // ------------------------------------------------------------------

    /// @notice Reject bare ETH transfers; users must call
    ///         `depositETH()` so the receipt is registered.
    receive() external payable {
        revert("KnomosisBridge: bare ETH transfers not allowed; use depositETH()");
    }
}
