// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable IMD fees for exactly one TEST/IMD pool. No administration or asset conversion.
/// @dev IMD must be a standard, non-rebasing ERC-20. All amounts are in its smallest units.
contract TestHook is IUnlockCallback {
    using SafeCast for uint256;

    address public constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address public constant SIMD_VAULT = 0xbBa92992309C61E1c483ab630d0530F2C9edEDE7;
    address public constant COMPENSATION_VAULT = 0x9f4419712cc22f615e393cC846b927BE3d7D802c;
    uint24 public constant LP_FEE = 12_500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant BASE_FEE_PPM = 7_500;
    uint256 public constant INITIAL_BUY_FEE_PPM = 500_000;
    uint256 public constant ANTI_SNIPER_DURATION = 1800;
    // Keeping the time factor in the denominator avoids rounding the per-second rate to whole ppm.
    uint256 public constant FEE_DENOMINATOR = 1_000_000 * ANTI_SNIPER_DURATION;

    IPoolManager public immutable poolManager;
    address public immutable token;
    address public immutable factory;
    PoolId public immutable poolId;
    bool public immutable imdIsCurrency0;

    bool public initialized;
    uint256 public initializedAt;
    uint256 public pendingVault;
    uint256 public pendingCompensation;

    error OnlyPoolManager();
    error OnlyFactory();
    error OnlySelf();
    error InvalidDeploymentParameters();
    error WrongPool();
    error AlreadyInitialized();
    error NotInitialized();
    error SwapQuote(int128 imdDelta);
    error InvalidQuote();

    event PoolOpened(PoolId indexed id, uint256 timestamp);
    event FeeAccrued(bool indexed buy, uint256 grossIMD, uint256 vaultFee, uint256 compensationFee);
    event FeePaid(address indexed recipient, uint256 amount);
    event FeeDeferred(address indexed recipient, uint256 amount);

    constructor(IPoolManager manager_, address token_, address factory_) {
        if (address(manager_) == address(0) || token_ == address(0) || token_ == IMD || factory_ == address(0)) {
            revert InvalidDeploymentParameters();
        }
        poolManager = manager_;
        token = token_;
        factory = factory_;
        imdIsCurrency0 = IMD < token_;
        poolId = PoolKey({
            currency0: Currency.wrap(IMD < token_ ? IMD : token_),
            currency1: Currency.wrap(IMD < token_ ? token_ : IMD),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        }).toId();
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != factory) revert OnlyFactory();
        _checkPool(key);
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        initializedAt = block.timestamp;
        emit PoolOpened(poolId, block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice The exact current rate is feeNumerator(buy) / FEE_DENOMINATOR.
    function feeNumerator(bool buy) public view returns (uint256) {
        uint256 base = BASE_FEE_PPM * ANTI_SNIPER_DURATION;
        if (!buy) return base;
        if (!initialized) revert NotInitialized();
        uint256 elapsed = block.timestamp - initializedAt;
        if (elapsed >= ANTI_SNIPER_DURATION) return base;
        return base + (INITIAL_BUY_FEE_PPM - BASE_FEE_PPM) * (ANTI_SNIPER_DURATION - elapsed);
    }

    /// @dev IMD is specified for exact-input buys and exact-output sells. A rollback-only quote
    /// determines the executed amount before returning the specified fee delta; partial fills
    /// therefore pay on the actual trade, not on an unspent budget or an unfilled output request.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkSwapPool(key);
        bool buy = params.zeroForOne == imdIsCurrency0;
        bool exactInput = params.amountSpecified < 0;
        if (buy != exactInput) return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);

        uint256 rate = feeNumerator(buy);
        uint256 requested = _abs(params.amountSpecified);
        uint256 fee;
        SwapParams memory quoted = params;
        if (buy) {
            fee = FullMath.mulDiv(requested, rate, FEE_DENOMINATOR);
            quoted.amountSpecified = -int256(requested - fee);
        } else {
            fee = FullMath.mulDiv(requested, rate, FEE_DENOMINATOR - rate);
            quoted.amountSpecified = params.amountSpecified + fee.toInt256();
        }

        uint256 executed = _quoteIMD(key, quoted);
        uint256 gross;
        if (buy) {
            if (executed != requested - fee) {
                fee = FullMath.mulDiv(executed, rate, FEE_DENOMINATOR - rate);
            }
            gross = executed + fee;
        } else {
            gross = executed;
            fee = FullMath.mulDiv(gross, rate, FEE_DENOMINATOR);
        }
        _distribute(buy, gross, fee);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @dev IMD is unspecified for exact-output buys and exact-input sells. Use the actual delta.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkSwapPool(key);
        bool buy = params.zeroForOne == imdIsCurrency0;
        if (buy == (params.amountSpecified < 0)) return (IHooks.afterSwap.selector, 0);
        uint256 imdAmount = _abs(int256(imdIsCurrency0 ? delta.amount0() : delta.amount1()));
        uint256 rate = feeNumerator(buy);
        uint256 fee = FullMath.mulDiv(imdAmount, rate, buy ? FEE_DENOMINATOR - rate : FEE_DENOMINATOR);
        _distribute(buy, buy ? imdAmount + fee : imdAmount, fee);
        return (IHooks.afterSwap.selector, fee.toInt128());
    }

    /// @dev Only a self-call from beforeSwap can enter. Always reverts, rolling back the nested
    /// PoolManager swap, its token deltas and events. v4 skips this hook on its own nested swap.
    function quoteSwap(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this)) revert OnlySelf();
        BalanceDelta delta = poolManager.swap(key, params, "");
        revert SwapQuote(imdIsCurrency0 ? delta.amount0() : delta.amount1());
    }

    /// @notice Anyone may retry deferred IMD delivery. Destinations cannot be supplied or changed.
    /// @dev Call outside a PoolManager unlock. A failed delivery retains its claim and can be retried.
    function redeemFees() external {
        poolManager.unlock("");
    }

    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        uint256 vault = pendingVault;
        uint256 compensation = pendingCompensation;
        // A single v4 delta is int128 even when claims have accumulated over many transactions.
        uint256 cap = uint256(uint128(type(int128).max));
        if (vault > cap) vault = cap;
        if (compensation > cap) compensation = cap;
        pendingVault -= vault;
        pendingCompensation -= compensation;
        if (!_redeem(SIMD_VAULT, vault)) pendingVault += vault;
        if (!_redeem(COMPENSATION_VAULT, compensation)) pendingCompensation += compensation;
        return "";
    }

    function _quoteIMD(PoolKey calldata key, SwapParams memory params) private returns (uint256) {
        try this.quoteSwap(key, params) {
            revert InvalidQuote();
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != SwapQuote.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            int128 imdDelta;
            assembly ("memory-safe") {
                imdDelta := mload(add(reason, 36))
            }
            return _abs(int256(imdDelta));
        }
    }

    function _distribute(bool buy, uint256 gross, uint256 totalFee) private {
        uint256 base = FullMath.mulDiv(gross, BASE_FEE_PPM, 1_000_000);
        uint256 extra = totalFee - base;
        if (!_pay(SIMD_VAULT, base)) pendingVault += base;
        if (!_pay(COMPENSATION_VAULT, extra)) pendingCompensation += extra;
        emit FeeAccrued(buy, gross, base, extra);
    }

    function _pay(address recipient, uint256 amount) private returns (bool) {
        if (amount == 0) return true;
        try poolManager.take(Currency.wrap(IMD), recipient, amount) {
            emit FeePaid(recipient, amount);
            return true;
        } catch {
            poolManager.mint(address(this), uint256(uint160(IMD)), amount);
            emit FeeDeferred(recipient, amount);
            return false;
        }
    }

    function _redeem(address recipient, uint256 amount) private returns (bool) {
        if (amount == 0) return true;
        poolManager.burn(address(this), uint256(uint160(IMD)), amount);
        // On failure, _pay re-mints the burned claim, leaving the manager's net delta at zero.
        return _pay(recipient, amount);
    }

    function _checkPool(PoolKey calldata key) private view {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    function _checkSwapPool(PoolKey calldata key) private view {
        _checkPool(key);
        if (!initialized) revert NotInitialized();
    }

    function _abs(int256 amount) private pure returns (uint256) {
        // The unsigned magnitude also represents type(int256).min without signed negation overflow.
        unchecked {
            return amount < 0 ? uint256(-(amount + 1)) + 1 : uint256(amount);
        }
    }
}
