// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {TestHook} from "../src/TestHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Inherited by both local currency orderings and both Robinhood fork suites.
abstract contract HookAdversarialTests is HookTestBase {
    using StateLibrary for IPoolManager;

    /// @dev An independent canonical pool is the oracle for price movement, output and LP fees.
    /// The hook's rollback quote must not execute a second trade or accrue LP fees twice.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_quoteRollbackMatchesCanonicalPool(
        bool buy,
        bool exactInput,
        bool dust,
        uint96 rawAmount,
        uint16 rawElapsed
    ) public {
        uint256 amount = dust ? bound(uint256(rawAmount), 1, 2_000) : bound(uint256(rawAmount), 1e9, 1_000 ether);
        vm.warp(opened + bound(uint256(rawElapsed), 0, 3600));
        _compareCanonical(buy, exactInput, amount);
    }

    function _compareCanonical(bool buy, bool exactInput, uint256 amount) private {
        PoolKey memory control = key;
        control.hooks = IHooks(address(0)); // A deliberately hookless reference pool, not a deployment input.
        manager.initialize(control, ONE);
        actor.modify(control, -600, 600, LIQUIDITY);

        BalanceDelta actual = _swap(buy, exactInput, amount);
        uint256 total = _vaultReceived() + _compensationReceived();
        {
            uint256 gross = buy ? uint256(-int256(_imdDelta(actual))) : uint256(int256(_imdDelta(actual))) + total;
            _assertExpectedFees(buy, gross, _vaultReceived(), _compensationReceived());
        }

        // Only the specified IMD leg is adjusted; TEST and the LP fee stay unchanged.
        uint256 ammAmount = amount;
        if (buy && exactInput) ammAmount -= total;
        if (!buy && !exactInput) ammAmount += total;
        bool zeroForOne = buy == hook.imdIsCurrency0();
        BalanceDelta expected = actor.swap(
            control, SwapParams(zeroForOne, exactInput ? -int256(ammAmount) : int256(ammAmount), _limit(zeroForOne)), ""
        );
        assertEq(_testDelta(actual), _testDelta(expected), "hook changed the TEST leg");
        assertEq(int256(_imdDelta(actual)), int256(_imdDelta(expected)) - int256(total), "wrong IMD delta");
        _assertSamePoolState(key.toId(), control.toId());
        _assertSettled();
    }

    /// @dev Small amounts exercise both sides of fee rounding, including exact-output modes.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_smallUnitsChargeOnlyIMD(bool buy, bool exactInput, uint16 rawAmount, uint16 rawElapsed) public {
        uint256 amount = bound(uint256(rawAmount), 1, 5_000);
        vm.warp(opened + bound(uint256(rawElapsed), 0, 1801));
        uint256 imdBefore = IERC20(IMD).balanceOf(address(actor));
        uint256 testBefore = token.balanceOf(address(actor));
        BalanceDelta delta = _swap(buy, exactInput, amount);
        assertEq(int256(IERC20(IMD).balanceOf(address(actor))) - int256(imdBefore), int256(_imdDelta(delta)));
        assertEq(int256(token.balanceOf(address(actor))) - int256(testBefore), int256(_testDelta(delta)));
        uint256 base = _vaultReceived();
        uint256 extra = _compensationReceived();
        uint256 gross = buy ? uint256(-int256(_imdDelta(delta))) : uint256(int256(_imdDelta(delta))) + base + extra;
        _assertExpectedFees(buy, gross, base, extra);
        if (!exactInput) assertEq(buy ? int256(_testDelta(delta)) : int256(_imdDelta(delta)), int256(amount));
        assertEq(token.balanceOf(VAULT), 0);
        assertEq(token.balanceOf(COMPENSATION), 0);
        assertEq(hook.pendingVault() + hook.pendingCompensation(), 0);
        _assertSettled();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_hookDataCannotWaiveOrRedirectFees(bytes calldata data, bool buy, bool exactInput) public {
        vm.warp(opened + 900);
        bool zeroForOne = buy == hook.imdIsCurrency0();
        BalanceDelta delta = actor.swap(
            key, SwapParams(zeroForOne, exactInput ? -100 ether : int256(100 ether), _limit(zeroForOne)), data
        );
        uint256 base = _vaultReceived();
        uint256 extra = _compensationReceived();
        uint256 gross = buy ? uint256(-int256(_imdDelta(delta))) : uint256(int256(_imdDelta(delta))) + base + extra;
        _assertExpectedFees(buy, gross, base, extra);
        _assertSettled();
    }

    function test_zeroSwapCannotPayOrCreateFees() public {
        bytes32 beforeState = _stateDigest();
        SwapParams memory params = SwapParams(hook.imdIsCurrency0(), 0, _limit(hook.imdIsCurrency0()));
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        actor.swap(key, params, "");
        assertEq(_stateDigest(), beforeState);
        _assertSettled();
    }

    function test_minimumSignedBuyBudgetChargesOnlyItsPartialFill() public {
        bool zeroForOne = hook.imdIsCurrency0();
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-60) : int24(60));
        BalanceDelta delta = actor.swap(key, SwapParams(zeroForOne, type(int256).min, limit), "");
        uint256 paid = uint256(-int256(_imdDelta(delta)));
        assertGt(_testDelta(delta), 0);
        assertGt(paid, 0);
        assertLt(paid, 10_000 ether, "charged the unexecuted budget");
        _assertExpectedFees(true, paid, _vaultReceived(), _compensationReceived());
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, limit);
        _assertSettled();
    }

    function test_blockCountCannotExpireTheTimestampBasedCurve() public {
        vm.roll(block.number + 100_000);
        _swap(true, true, 100 ether);
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 49.25 ether);
        // Timestamp moves without requiring another block-number change.
        vm.warp(opened + 1800);
        _swap(true, true, 100 ether);
        assertEq(_vaultReceived(), 1.5 ether);
        assertEq(_compensationReceived(), 49.25 ether);
        assertEq(hook.initializedAt(), opened);
    }

    function test_failedPoolInitializationDoesNotStartTheClock() public {
        TestHook fresh = _deployHook(manager, address(token), address(this));
        PoolKey memory freshKey = key;
        freshKey.hooks = IHooks(address(fresh));
        vm.expectRevert(abi.encodeWithSelector(TickMath.InvalidSqrtPrice.selector, uint160(0)));
        manager.initialize(freshKey, 0);
        assertFalse(fresh.initialized(), "failed manager initialization persisted hook state");
        assertEq(fresh.initializedAt(), 0);
        vm.warp(opened + 1 days);
        manager.initialize(freshKey, ONE);
        assertEq(fresh.initializedAt(), opened + 1 days);
        assertEq(fresh.feeNumerator(true), 900_000_000);
    }

    function _assertExpectedFees(bool buy, uint256 gross, uint256 base, uint256 extra) internal view {
        uint256 elapsed = block.timestamp - opened;
        // Specification expressed as exact rational percentages, independent of hook getters.
        uint256 numerator = 13_500_000;
        if (buy && elapsed < 1800) numerator += 492_500 * (1800 - elapsed);
        assertEq(base, gross * 3 / 400, "standing 0.75% fee");
        assertEq(base + extra, gross * numerator / 1_800_000_000, "buy curve / sell fee");
        if (!buy || elapsed >= 1800) assertEq(extra, 0, "anti-sniper charged outside its window");
    }

    function _assertSamePoolState(PoolId actual, PoolId control) private view {
        (uint160 priceA, int24 tickA, uint24 protocolA, uint24 feeA) = manager.getSlot0(actual);
        (uint160 priceB, int24 tickB, uint24 protocolB, uint24 feeB) = manager.getSlot0(control);
        assertEq(priceA, priceB, "quote changed price");
        assertEq(tickA, tickB, "quote changed tick");
        assertEq(protocolA, protocolB);
        assertEq(feeA, feeB);
        assertEq(feeA, 12_500);
        (uint256 growthA0, uint256 growthA1) = manager.getFeeGrowthGlobals(actual);
        (uint256 growthB0, uint256 growthB1) = manager.getFeeGrowthGlobals(control);
        assertEq(growthA0, growthB0, "quote accrued extra currency0 LP fees");
        assertEq(growthA1, growthB1, "quote accrued extra currency1 LP fees");
    }

    function _stateDigest() internal view returns (bytes32) {
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        return keccak256(
            abi.encode(
                price,
                tick,
                _vaultReceived(),
                _compensationReceived(),
                hook.pendingVault(),
                hook.pendingCompensation(),
                IERC20(IMD).balanceOf(address(actor)),
                IERC20(IMD).balanceOf(address(manager)),
                token.balanceOf(address(actor)),
                token.balanceOf(address(manager)),
                hook.initializedAt()
            )
        );
    }
}
