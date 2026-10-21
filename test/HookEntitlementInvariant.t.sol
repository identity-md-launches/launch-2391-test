// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {TestHook} from "../src/TestHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Ghost entitlements are computed from executed swaps, never from FeeAccrued or pending counters.
contract EntitlementHandler is Test {
    bytes32 private constant SWAP = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");
    TestHook private immutable hook;
    PoolActor private immutable actor;
    IPoolManager private immutable manager;
    MockIMD private immutable imd;
    uint256 private immutable opened;
    PoolKey private key;
    uint256 public expectedVault;
    uint256 public expectedCompensation;
    uint256 public trades;

    constructor(TestHook hook_, PoolActor actor_, PoolKey memory key_) {
        hook = hook_;
        actor = actor_;
        key = key_;
        manager = hook_.poolManager();
        imd = MockIMD(hook_.IMD());
        opened = hook_.initializedAt();
    }

    function trade(bool buy, bool exactInput, uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, 100 ether);
        bool zeroForOne = buy == hook.imdIsCurrency0();
        SwapParams memory params = SwapParams(
            zeroForOne,
            exactInput ? -int256(amount) : int256(amount),
            zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        vm.recordLogs();
        vm.prank(actor.controller());
        BalanceDelta delta = actor.swap(key, params, abi.encode(address(this), rawAmount));
        int128 rawIMD = _executedIMD(vm.getRecordedLogs());
        int128 traderIMD = hook.imdIsCurrency0() ? delta.amount0() : delta.amount1();
        uint256 gross = buy ? uint256(-int256(traderIMD)) : uint256(int256(rawIMD));
        uint256 base = gross * 3 / 400;
        uint256 elapsed = block.timestamp - opened;
        uint256 rate = 13_500_000;
        if (buy && elapsed < 1800) rate += 492_500 * (1800 - elapsed);
        uint256 total = gross * rate / 1_800_000_000;
        expectedVault += base;
        expectedCompensation += total - base;
        assertEq(int256(traderIMD), int256(rawIMD) - int256(total), "trader did not pay precisely the hook fee");
        ++trades;
    }

    function advance(uint16 rawElapsed) external {
        vm.warp(block.timestamp + bound(uint256(rawElapsed), 0, 1801));
    }

    function rejectRecipients(bool vault, bool compensation) external {
        imd.reject(hook.SIMD_VAULT(), vault);
        imd.reject(hook.COMPENSATION_VAULT(), compensation);
    }

    function redeem() external {
        hook.redeemFees();
    }

    function attemptRedirection(uint8 who) external {
        address caller = who % 3 == 0 ? hook.factory() : who % 3 == 1 ? hook.SIMD_VAULT() : address(this);
        vm.prank(caller);
        (bool success,) = address(hook).call(abi.encodeWithSignature("setVault(address)", address(this)));
        assertFalse(success, "a caller acquired fee authority");
        (success,) = address(hook).call(abi.encodeCall(TestHook.unlockCallback, (bytes(""))));
        assertFalse(success, "forged callback accepted");
    }

    function _executedIMD(Vm.Log[] memory logs) private view returns (int128 amount) {
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(manager) || entry.topics.length != 3 || entry.topics[0] != SWAP) continue;
            if (entry.topics[1] != PoolId.unwrap(key.toId())) continue;
            // recordLogs may observe reverted nested calls; the quote's caller is the hook, not the trader.
            if (entry.topics[2] != bytes32(uint256(uint160(address(actor))))) continue;
            (int128 amount0, int128 amount1,,,, uint24 lpFee) =
                abi.decode(entry.data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(lpFee, 12_500);
            amount = hook.imdIsCurrency0() ? amount0 : amount1;
            ++count;
        }
        assertEq(count, 1, "missing or duplicated executed swap");
    }
}

abstract contract HookEntitlementInvariantBase is HookTestBase {
    EntitlementHandler internal handler;
    uint256 private initialFunds;
    uint256 private initialTestFunds;

    function _setupInvariant(bool tokenFirst) internal {
        _setup(false, tokenFirst, true);
        initialFunds = IERC20(IMD).balanceOf(address(actor)) + IERC20(IMD).balanceOf(address(manager));
        initialTestFunds = token.balanceOf(address(actor)) + token.balanceOf(address(manager));
        handler = new EntitlementHandler(hook, actor, key);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = EntitlementHandler.trade.selector;
        selectors[1] = EntitlementHandler.advance.selector;
        selectors[2] = EntitlementHandler.rejectRecipients.selector;
        selectors[3] = EntitlementHandler.redeem.selector;
        selectors[4] = EntitlementHandler.attemptRedirection.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_eachVaultOwnsExactlyItsEarnedFees() public view {
        assertEq(_vaultReceived() + hook.pendingVault(), handler.expectedVault(), "SIMD Vault entitlement");
        assertEq(
            _compensationReceived() + hook.pendingCompensation(), handler.expectedCompensation(), "refund entitlement"
        );
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(IMD))), hook.pendingVault() + hook.pendingCompensation()
        );
        assertGe(IERC20(IMD).balanceOf(address(manager)), hook.pendingVault() + hook.pendingCompensation());
        assertEq(
            IERC20(IMD).balanceOf(address(actor)) + IERC20(IMD).balanceOf(address(manager)) + _vaultReceived()
                + _compensationReceived(),
            initialFunds
        );
        assertEq(token.balanceOf(address(actor)) + token.balanceOf(address(manager)), initialTestFunds);
        assertEq(hook.initializedAt(), opened);
        assertEq(hook.SIMD_VAULT(), VAULT);
        assertEq(hook.COMPENSATION_VAULT(), COMPENSATION);
        _assertSettled();
    }

    function afterInvariant() public {
        MockIMD(IMD).reject(VAULT, false);
        MockIMD(IMD).reject(COMPENSATION, false);
        hook.redeemFees();
        assertEq(_vaultReceived(), handler.expectedVault());
        assertEq(_compensationReceived(), handler.expectedCompensation());
        assertEq(hook.pendingVault() + hook.pendingCompensation(), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 0);
        _assertSettled();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HookToken0EntitlementInvariantTest is HookEntitlementInvariantBase {
    function setUp() public {
        _setupInvariant(true);
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract HookToken1EntitlementInvariantTest is HookEntitlementInvariantBase {
    function setUp() public {
        _setupInvariant(false);
    }
}
