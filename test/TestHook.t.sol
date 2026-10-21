// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {HookAdversarialTests} from "./HookAdversarial.t.sol";
import {TestHook} from "../src/TestHook.sol";
import {TestToken} from "../src/TestToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
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
import {MockIMD} from "./mocks/MockIMD.sol";

/// @dev The same economics suite executes locally and against the real IMD token on a fork.
abstract contract HookEconomicTests is HookAdversarialTests {
    using StateLibrary for IPoolManager;

    function test_initializationAndPermissions() public view {
        assertTrue(hook.initialized());
        assertEq(hook.initializedAt(), opened);
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertTrue(HookFlags.matches(address(hook), 0x20cc));
        Hooks.validateHookPermissions(IHooks(address(hook)), hook.getHookPermissions());
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12_500);
    }

    function test_buyAtOpeningCharges50PercentAndSplitsIMD() public {
        BalanceDelta delta = _swap(true, true, 100 ether);
        assertEq(_imdDelta(delta), -100 ether);
        assertGt(_testDelta(delta), 0);
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 49.25 ether);
        assertEq(token.balanceOf(VAULT), 0);
        assertEq(token.balanceOf(COMPENSATION), 0);
        _assertSettled();
    }

    function test_buyAt900SecondsCharges25Point375Percent() public {
        vm.warp(opened + 900);
        _swap(true, true, 100 ether);
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 24.625 ether);
        _assertSettled();
    }

    function test_buyAt1800SecondsChargesOnlyStandingFee() public {
        vm.warp(opened + 1800);
        _swap(true, true, 100 ether);
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 0);
        _assertSettled();
    }

    function test_buyAfter1800SecondsKeepsStandingFee() public {
        vm.warp(opened + 365 days);
        _swap(true, true, 100 ether);
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 0);
    }

    function test_lastAntiSniperSecondAndBoundary() public {
        vm.warp(opened + 1799);
        _swap(true, true, 1800 ether);
        assertEq(_vaultReceived(), 13.5 ether);
        assertEq(_compensationReceived(), 0.4925 ether);
        vm.warp(opened + 1800);
        _swap(true, true, 1800 ether);
        assertEq(_vaultReceived(), 27 ether);
        assertEq(_compensationReceived(), 0.4925 ether);
        _assertSettled();
    }

    function test_sellsAtOpeningNeverPayAntiSniper() public {
        BalanceDelta delta = _swap(false, true, 100 ether);
        assertEq(_testDelta(delta), -100 ether);
        uint256 received = uint256(uint128(_imdDelta(delta)));
        _assertFeeFraction(_vaultReceived(), received + _vaultReceived(), 7_500, 1_000_000);
        assertEq(_compensationReceived(), 0);
        assertGt(received, 0);
        _assertSettled();
    }

    function test_exactOutputSellDeliversRequestedNetIMD() public {
        BalanceDelta delta = _swap(false, false, 100 ether);
        assertEq(_imdDelta(delta), 100 ether);
        assertLt(_testDelta(delta), 0);
        _assertFeeFraction(_vaultReceived(), 100 ether + _vaultReceived(), 7_500, 1_000_000);
        assertEq(_compensationReceived(), 0);
        _assertSettled();
    }

    function test_exactOutputBuyDeliversRequestedTESTIncludingAtOpening() public {
        BalanceDelta delta = _swap(true, false, 100 ether);
        uint256 paid = uint256(-int256(_imdDelta(delta)));
        assertEq(_testDelta(delta), 100 ether);
        _assertFeeFraction(_vaultReceived(), paid, 7_500, 1_000_000);
        _assertFeeFraction(_vaultReceived() + _compensationReceived(), paid, 1, 2);
        _assertSettled();
    }

    function test_exactOutputBuyAfterLaunchHasOnlyStandingFee() public {
        vm.warp(opened + 1800);
        BalanceDelta delta = _swap(true, false, 100 ether);
        assertEq(_testDelta(delta), 100 ether);
        _assertFeeFraction(_vaultReceived(), uint256(-int256(_imdDelta(delta))), 7_500, 1_000_000);
        assertEq(_compensationReceived(), 0);
        _assertSettled();
    }

    function test_partialExactInputBuyChargesOnlyExecutedIMD() public {
        bool zeroForOne = hook.imdIsCurrency0();
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-60) : int24(60));
        uint256 budget = 100_000 ether;
        BalanceDelta delta = actor.swap(key, SwapParams(zeroForOne, -int256(budget), limit), "");
        uint256 paid = uint256(-int256(_imdDelta(delta)));
        assertGt(paid, 0);
        assertLt(paid, budget);
        _assertFeeFraction(_vaultReceived(), paid, 7_500, 1_000_000);
        _assertFeeFraction(_vaultReceived() + _compensationReceived(), paid, 1, 2);
        (uint160 actualPrice,,,) = manager.getSlot0(key.toId());
        assertEq(actualPrice, limit);
        _assertSettled();
    }

    function test_partialExactOutputSellChargesOnlyExecutedIMD() public {
        bool zeroForOne = !hook.imdIsCurrency0();
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? int24(-60) : int24(60));
        BalanceDelta delta = actor.swap(key, SwapParams(zeroForOne, 100_000 ether, limit), "");
        uint256 received = uint256(uint128(_imdDelta(delta)));
        assertGt(received, 0);
        assertLt(received, 100_000 ether);
        _assertFeeFraction(_vaultReceived(), received + _vaultReceived(), 7_500, 1_000_000);
        assertEq(_compensationReceived(), 0);
        _assertSettled();
    }

    function test_emptyPoolTradeDoesNotPayARequestBasedFee() public {
        actor.modify(key, -600, 600, -LIQUIDITY);
        BalanceDelta delta = _swap(true, true, 100 ether);
        assertEq(BalanceDelta.unwrap(delta), 0);
        assertEq(_vaultReceived(), 0);
        assertEq(_compensationReceived(), 0);
        _assertSettled();
    }

    function test_tinyBuysAndSellsDoNotRevertFromFeeRounding() public {
        _swap(true, true, 1);
        _swap(false, true, 1);
        assertEq(_vaultReceived(), 0);
        assertEq(_compensationReceived(), 0);
        _assertSettled();
    }

    function test_noOneCanRedirectOrChangeTheFees() public {
        string[9] memory calls = [
            "setVault(address)",
            "setRecipient(address)",
            "setFee(uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "pause()",
            "setCompensationVault(address)",
            "initialize(address)"
        ];
        address attacker = makeAddr("fee thief");
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(attacker);
            (bool success,) = address(hook).call(abi.encodeWithSignature(calls[i], attacker));
            assertFalse(success, calls[i]);
            (success,) = address(hook).call(abi.encodeWithSignature(calls[i], attacker));
            assertFalse(success, "factory cannot change it either");
        }
        // Arbitrary router-supplied data cannot choose the recipient or bypass the fee.
        bool zeroForOne = hook.imdIsCurrency0();
        actor.swap(key, SwapParams(zeroForOne, -100 ether, _limit(zeroForOne)), abi.encode(attacker, 0));
        assertEq(IERC20(IMD).balanceOf(attacker), 0);
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 49.25 ether);
    }

    function test_factoryCanCollectLPFeesAndRemoveLiquidity() public {
        _swap(true, true, 100 ether);
        _swap(false, true, 100 ether);
        uint256 vault = _vaultReceived();
        uint256 compensation = _compensationReceived();
        BalanceDelta collected = actor.modify(key, -600, 600, 0);
        assertGe(collected.amount0(), 0);
        assertGe(collected.amount1(), 0);
        assertTrue(collected.amount0() > 0 || collected.amount1() > 0);
        actor.modify(key, -600, 600, -LIQUIDITY);
        assertEq(_vaultReceived(), vault);
        assertEq(_compensationReceived(), compensation);
        _assertSettled();
    }

    function testFuzz_allSwapModesConserveFundsAndPayCorrectFee(
        bool buy,
        bool exactInput,
        uint96 rawAmount,
        uint32 rawElapsed
    ) public {
        uint256 amount = bound(uint256(rawAmount), 1e9, 1_000 ether);
        uint256 elapsed = bound(uint256(rawElapsed), 0, 3600);
        vm.warp(opened + elapsed);
        uint256 traderBefore = IERC20(IMD).balanceOf(address(actor));
        uint256 managerBefore = IERC20(IMD).balanceOf(address(manager));
        BalanceDelta delta = _swap(buy, exactInput, amount);
        uint256 vault = _vaultReceived();
        uint256 extra = _compensationReceived();
        uint256 gross = buy ? uint256(-int256(_imdDelta(delta))) : uint256(uint128(_imdDelta(delta))) + vault;
        uint256 rate = 13_500_000;
        if (buy && elapsed < 1800) rate += 492_500 * (1800 - elapsed);
        _assertFeeFraction(vault, gross, 7_500, 1_000_000);
        _assertFeeFraction(vault + extra, gross, rate, 1_800_000_000);
        if (!buy || elapsed >= 1800) assertEq(extra, 0);
        assertEq(
            traderBefore + managerBefore,
            IERC20(IMD).balanceOf(address(actor)) + IERC20(IMD).balanceOf(address(manager)) + vault + extra
        );
        if (exactInput) assertEq(buy ? -int256(_imdDelta(delta)) : -int256(_testDelta(delta)), int256(amount));
        else assertEq(buy ? int256(_testDelta(delta)) : int256(_imdDelta(delta)), int256(amount));
        _assertSettled();
    }

    function testFuzz_partialFillsAcrossAllSwapModes(
        bool buy,
        bool exactInput,
        uint16 rawTickDistance,
        uint16 rawElapsed
    ) public {
        uint256 elapsed = bound(uint256(rawElapsed), 0, 2000);
        vm.warp(opened + elapsed);
        int24 ticks = int24(int256(bound(uint256(rawTickDistance), 1, 599)));
        bool zeroForOne = buy == hook.imdIsCurrency0();
        uint160 limit = TickMath.getSqrtPriceAtTick(zeroForOne ? -ticks : ticks);
        BalanceDelta delta =
            actor.swap(key, SwapParams(zeroForOne, exactInput ? -100_000 ether : int256(100_000 ether), limit), "");
        uint256 vault = _vaultReceived() + hook.pendingVault();
        uint256 extra = _compensationReceived() + hook.pendingCompensation();
        uint256 gross = buy ? uint256(-int256(_imdDelta(delta))) : uint256(uint128(_imdDelta(delta))) + vault;
        uint256 rate = 13_500_000;
        if (buy && elapsed < 1800) rate += 492_500 * (1800 - elapsed);
        _assertFeeFraction(vault, gross, 7_500, 1_000_000);
        _assertFeeFraction(vault + extra, gross, rate, 1_800_000_000);
        assertLt(
            exactInput
                ? uint256(-int256(buy ? _imdDelta(delta) : _testDelta(delta)))
                : uint256(uint128(buy ? _testDelta(delta) : _imdDelta(delta))),
            100_000 ether
        );
        (uint160 actualPrice,,,) = manager.getSlot0(key.toId());
        assertEq(actualPrice, limit);
        hook.redeemFees();
        assertEq(_vaultReceived(), vault);
        assertEq(_compensationReceived(), extra);
        assertEq(hook.pendingVault() + hook.pendingCompensation(), 0);
        _assertSettled();
    }

    function _assertFeeFraction(uint256 fee, uint256 gross, uint256 numerator, uint256 denominator) internal pure {
        assertLe(fee * denominator, gross * numerator);
        assertGt((fee + 1) * denominator, gross * numerator);
    }
}

contract TestHookToken0Test is HookEconomicTests {
    function setUp() public {
        _setup(false, true, true);
    }
}

contract TestHookToken1Test is HookEconomicTests {
    function setUp() public {
        _setup(false, false, true);
    }
}

contract TestHookFailureTest is HookTestBase {
    function setUp() public {
        _setup(false, true, true);
    }

    function test_allEnabledCallbacksRejectForgedCalls() public {
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, ONE);
        SwapParams memory params = SwapParams(false, -1 ether, TickMath.MAX_SQRT_PRICE - 1);
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(actor), key, params, "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.afterSwap(address(actor), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(TestHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(TestHook.OnlySelf.selector);
        hook.quoteSwap(key, params);
    }

    function test_initializationCannotBeResetOrUsedForAnotherPool() public {
        vm.prank(address(manager));
        vm.expectRevert(TestHook.AlreadyInitialized.selector);
        hook.beforeInitialize(address(this), key, ONE);
        vm.prank(address(manager));
        vm.expectRevert(TestHook.OnlyFactory.selector);
        hook.beforeInitialize(makeAddr("stranger"), key, ONE);
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.beforeInitialize(address(this), wrong, ONE);
        wrong = key;
        wrong.tickSpacing = 1;
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.beforeInitialize(address(this), wrong, ONE);
        assertEq(hook.initializedAt(), opened);
    }

    function test_deploymentTimeDoesNotStartTheAntiSniperClock() public {
        TestToken secondToken = new TestToken();
        TestHook secondHook = _deployHook(manager, address(secondToken), address(this));
        vm.expectRevert(TestHook.NotInitialized.selector);
        secondHook.feeNumerator(true);
        vm.warp(opened + 7 days);
        bool imdFirst = IMD < address(secondToken);
        PoolKey memory secondKey = PoolKey(
            Currency.wrap(imdFirst ? IMD : address(secondToken)),
            Currency.wrap(imdFirst ? address(secondToken) : IMD),
            12_500,
            60,
            IHooks(address(secondHook))
        );
        manager.initialize(secondKey, ONE);
        assertEq(secondHook.initializedAt(), opened + 7 days);
        assertEq(secondHook.feeNumerator(true), 900_000_000);
        assertEq(secondHook.feeNumerator(false), 13_500_000);
    }

    function test_wrongFactoryCannotInitializeThroughRealManager() public {
        TestHook secondHook = _deployHook(manager, address(token), makeAddr("another factory"));
        PoolKey memory secondKey = key;
        secondKey.hooks = IHooks(address(secondHook));
        vm.expectRevert();
        manager.initialize(secondKey, ONE);
        assertFalse(secondHook.initialized());
    }

    function test_constructorNeedsNoExternalCodeAndHasNoOwner() public {
        TestHook emptyChainHook = _deployHook(
            IPoolManager(makeAddr("manager not deployed yet")), makeAddr("token not deployed yet"), address(this)
        );
        assertFalse(emptyChainHook.initialized());
        (bool ok,) = address(emptyChainHook).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    function test_hookAndTokenRuntimeHaveNoUpgradeOrDestructionOpcodes() public view {
        _assertFinalRuntime(address(hook));
        _assertFinalRuntime(address(token));
    }

    function _assertFinalRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        bool reachable = true;
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x5b) reachable = true;
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            if (reachable) assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
            if (op == 0x00 || op == 0x56 || op == 0xf3 || op == 0xfd || op == 0xfe || op == 0xff) reachable = false;
        }
    }

    function test_failedVaultTransferDoesNotRevertSwapAndAnyoneCanRedeem() public {
        MockIMD(IMD).reject(VAULT, true);
        _swap(true, true, 100 ether);
        assertEq(_vaultReceived(), 0);
        assertEq(_compensationReceived(), 49.25 ether);
        assertEq(hook.pendingVault(), 0.75 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 0.75 ether);
        _assertSettled();

        hook.redeemFees(); // Still blocked: leaves the claim intact, without affecting the other vault.
        assertEq(hook.pendingVault(), 0.75 ether);
        MockIMD(IMD).reject(VAULT, false);
        vm.prank(makeAddr("permissionless keeper"));
        hook.redeemFees();
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(hook.pendingVault(), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 0);
        hook.redeemFees(); // Idempotent; cannot redeem twice.
        assertEq(_vaultReceived(), 0.75 ether);
        _assertSettled();
    }

    function test_failedCompensationTransferDoesNotRevertSwapOrRedirectFunds() public {
        MockIMD(IMD).reject(COMPENSATION, true);
        _swap(true, false, 10 ether);
        assertGt(_vaultReceived(), 0);
        assertEq(_compensationReceived(), 0);
        uint256 owed = hook.pendingCompensation();
        assertGt(owed, 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), owed);
        _swap(false, true, 10 ether);
        assertEq(hook.pendingCompensation(), owed);
        MockIMD(IMD).reject(COMPENSATION, false);
        hook.redeemFees();
        assertEq(_compensationReceived(), owed);
        assertEq(hook.pendingCompensation(), 0);
        _assertSettled();
    }

    function test_bothRecipientsCanFailAndRecoverIndependently() public {
        MockIMD(IMD).reject(VAULT, true);
        MockIMD(IMD).reject(COMPENSATION, true);
        _swap(true, true, 100 ether);
        assertEq(hook.pendingVault(), 0.75 ether);
        assertEq(hook.pendingCompensation(), 49.25 ether);
        MockIMD(IMD).reject(COMPENSATION, false);
        hook.redeemFees();
        assertEq(hook.pendingVault(), 0.75 ether);
        assertEq(hook.pendingCompensation(), 0);
        assertEq(_compensationReceived(), 49.25 ether);
        _assertSettled();
    }

    function test_invalidPriceLimitStillRevertsWithNoFeeOrStateChange() public {
        SwapParams memory params = SwapParams(hook.imdIsCurrency0(), -100 ether, ONE);
        vm.expectRevert();
        actor.swap(key, params, "");
        assertEq(_vaultReceived(), 0);
        assertEq(_compensationReceived(), 0);
        assertEq(hook.pendingVault(), 0);
        assertEq(hook.pendingCompensation(), 0);
    }

    function test_unfundedTraderRollsBackAllFeePayments() public {
        deal(IMD, address(actor), 0);
        bool zeroForOne = hook.imdIsCurrency0();
        SwapParams memory params = SwapParams(zeroForOne, -100 ether, _limit(zeroForOne));
        vm.expectRevert();
        actor.swap(key, params, "");
        assertEq(_vaultReceived(), 0);
        assertEq(_compensationReceived(), 0);
        _assertSettled();
    }
}

contract TestHookFreshManagerTest is HookTestBase {
    function setUp() public {
        _setup(false, true, false);
        // TEST is currency0, so this position starts entirely in TEST with no IMD in the manager.
        actor.modify(key, 60, 600, LIQUIDITY);
        assertEq(IERC20(IMD).balanceOf(address(manager)), 0);
    }

    function test_firstBuyOnTokenOnlySeedDefersIMDThenRedeemsAfterSettlement() public {
        BalanceDelta delta = _swap(true, true, 100 ether);
        assertGt(_testDelta(delta), 0);
        assertEq(_imdDelta(delta), -100 ether);
        assertEq(_vaultReceived(), 0);
        assertEq(_compensationReceived(), 0);
        assertEq(hook.pendingVault(), 0.75 ether);
        assertEq(hook.pendingCompensation(), 49.25 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 50 ether);
        _assertSettled();
        hook.redeemFees();
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 49.25 ether);
        assertEq(hook.pendingVault() + hook.pendingCompensation(), 0);
        _assertSettled();
    }

    function test_firstExactOutputBuyOnTokenOnlySeedSucceeds() public {
        BalanceDelta delta = _swap(true, false, 100 ether);
        assertEq(_testDelta(delta), 100 ether);
        uint256 paid = uint256(-int256(_imdDelta(delta)));
        assertEq(hook.pendingVault() + hook.pendingCompensation(), paid / 2);
        hook.redeemFees();
        assertEq(_vaultReceived() + _compensationReceived(), paid / 2);
        _assertSettled();
    }
}
