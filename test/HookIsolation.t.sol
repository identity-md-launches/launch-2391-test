// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookTestBase} from "./helpers/HookTestBase.sol";
import {BatchSwapActor} from "./helpers/BatchSwapActor.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {TestHook} from "../src/TestHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ClaimAdversary is IUnlockCallback {
    IPoolManager private immutable manager;
    TestHook private immutable hook;
    address private immutable controller = msg.sender;

    constructor(TestHook hook_) {
        hook = hook_;
        manager = hook_.poolManager();
    }

    function act(uint8 mode, uint256 amount) external returns (bytes memory) {
        require(msg.sender == controller, "controller only");
        return manager.unlock(abi.encode(mode, amount));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 mode, uint256 amount) = abi.decode(data, (uint8, uint256));
        uint256 id = uint256(uint160(hook.IMD()));
        if (mode == 0) {
            // The attacker tries to burn the hook's claim and take its underlying IMD.
            manager.burn(address(hook), id, amount);
            manager.take(Currency.wrap(hook.IMD()), address(this), amount);
        } else if (mode == 1) {
            manager.mint(address(hook), id, amount);
            manager.sync(Currency.wrap(hook.IMD()));
            require(IERC20(hook.IMD()).transfer(address(manager), amount));
            manager.settle();
        } else {
            (bool ok, bytes memory reason) = address(hook).call(abi.encodeCall(TestHook.redeemFees, ()));
            return abi.encode(ok, reason);
        }
        return "";
    }
}

contract HookIsolationTest is HookTestBase {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    function setUp() public {
        _setup(false, true, true);
    }

    function test_constructorRejectsEveryMissingOrAliasedDependency() public {
        vm.expectRevert(TestHook.InvalidDeploymentParameters.selector);
        new TestHook(IPoolManager(address(0)), address(token), address(this));
        vm.expectRevert(TestHook.InvalidDeploymentParameters.selector);
        new TestHook(manager, address(0), address(this));
        vm.expectRevert(TestHook.InvalidDeploymentParameters.selector);
        new TestHook(manager, IMD, address(this));
        vm.expectRevert(TestHook.InvalidDeploymentParameters.selector);
        new TestHook(manager, address(token), address(0));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_everyPoolKeyFieldIsBound(uint8 field) public {
        PoolKey memory wrong = key;
        uint256 choice = field % 5;
        if (choice == 0) wrong.currency0 = Currency.wrap(address(new MockIMD()));
        else if (choice == 1) wrong.currency1 = Currency.wrap(address(new MockIMD()));
        else if (choice == 2) wrong.fee = 3000;
        else if (choice == 3) wrong.tickSpacing = 1;
        else wrong.hooks = IHooks(address(this));
        SwapParams memory params = SwapParams(hook.imdIsCurrency0(), -1 ether, _limit(hook.imdIsCurrency0()));
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.beforeSwap(address(actor), wrong, params, "");
        vm.prank(address(manager));
        vm.expectRevert(TestHook.WrongPool.selector);
        hook.afterSwap(address(actor), wrong, params, BalanceDelta.wrap(0), "");
        assertEq(hook.initializedAt(), opened);
        assertEq(hook.pendingVault() + hook.pendingCompensation(), 0);
    }

    function test_swapCallbacksRejectTheRightPoolBeforeInitialization() public {
        TestHook fresh = _deployHook(manager, address(token), address(this));
        PoolKey memory freshKey = key;
        freshKey.hooks = IHooks(address(fresh));
        SwapParams memory params = SwapParams(fresh.imdIsCurrency0(), -1 ether, _limit(fresh.imdIsCurrency0()));
        vm.prank(address(manager));
        vm.expectRevert(TestHook.NotInitialized.selector);
        fresh.beforeSwap(address(actor), freshKey, params, "");
        vm.prank(address(manager));
        vm.expectRevert(TestHook.NotInitialized.selector);
        fresh.afterSwap(address(actor), freshKey, params, BalanceDelta.wrap(0), "");
        assertFalse(fresh.initialized());
    }

    function test_deferredClaimsCannotBeTransferredOrBurnedByAnotherCaller() public {
        _deferOpeningBuy();
        ClaimAdversary thief = new ClaimAdversary(hook);
        uint256 id = uint256(uint160(IMD));
        assertEq(manager.allowance(address(hook), address(thief), id), 0);
        assertFalse(manager.isOperator(address(hook), address(thief)));
        vm.prank(address(thief));
        vm.expectRevert();
        manager.transferFrom(address(hook), address(thief), id, 1);
        vm.expectRevert();
        thief.act(0, 1);
        assertEq(manager.balanceOf(address(hook), id), 50 ether);
        assertEq(IERC20(IMD).balanceOf(address(thief)), 0);
        _recoverOpeningBuy();
    }

    function test_redemptionDuringAnotherUnlockIsAtomicAndCanBeRetried() public {
        _deferOpeningBuy();
        ClaimAdversary caller = new ClaimAdversary(hook);
        (bool ok, bytes memory reason) = abi.decode(caller.act(2, 0), (bool, bytes));
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(IPoolManager.AlreadyUnlocked.selector));
        assertEq(hook.pendingVault(), 0.75 ether);
        assertEq(hook.pendingCompensation(), 49.25 ether);
        _recoverOpeningBuy();
    }

    function test_unsolicitedClaimGiftCannotIncreaseOrRedirectEntitlements() public {
        _deferOpeningBuy();
        ClaimAdversary donor = new ClaimAdversary(hook);
        MockIMD(IMD).mint(address(donor), 7 ether);
        donor.act(1, 7 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 57 ether);
        assertEq(hook.pendingVault(), 0.75 ether);
        assertEq(hook.pendingCompensation(), 49.25 ether);
        _recoverOpeningBuy();
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 7 ether);
        hook.redeemFees();
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 49.25 ether);
        assertEq(IERC20(IMD).balanceOf(address(donor)), 0);
    }

    function test_multipleSwapsShareOneUnlockAndChargeExactlyOnceEach() public {
        BatchSwapActor batch = _newBatch();
        BalanceDelta[] memory deltas = batch.execute(key, _twoBuys());
        assertEq(_imdDelta(deltas[0]), -100 ether);
        assertEq(_imdDelta(deltas[1]), -100 ether);
        assertGt(_testDelta(deltas[0]), 0);
        assertGt(_testDelta(deltas[1]), 0);
        assertEq(_vaultReceived(), 1.5 ether);
        assertEq(_compensationReceived(), 98.5 ether);
        _assertBatchSettled(batch);
    }

    function test_buyAndSellNetSettleIMDWithinOneUnlock() public {
        BatchSwapActor batch = _newBatch();
        SwapParams[] memory swaps = _twoBuys();
        bool sellZeroForOne = !hook.imdIsCurrency0();
        swaps[1] = SwapParams(sellZeroForOne, 100 ether, _limit(sellZeroForOne));
        BalanceDelta[] memory deltas = batch.execute(key, swaps);
        assertEq(_imdDelta(deltas[0]), -100 ether);
        assertEq(_imdDelta(deltas[1]), 100 ether);
        // 100 IMD net output grosses up by 3/397; no sniper component on the sell.
        assertEq(_vaultReceived(), 0.75 ether + uint256(100 ether) * 3 / 397);
        assertEq(_compensationReceived(), 49.25 ether);
        assertEq(IERC20(IMD).balanceOf(address(batch)), 1_000 ether);
        assertLt(token.balanceOf(address(batch)), 1_000 ether);
        _assertBatchSettled(batch);
    }

    function testFuzz_secondSwapFailureRollsBackPaymentsAndClaims(bool defer) public {
        MockIMD(IMD).reject(VAULT, defer);
        MockIMD(IMD).reject(COMPENSATION, defer);
        BatchSwapActor batch = _newBatch();
        SwapParams[] memory swaps = _twoBuys();
        swaps[1].sqrtPriceLimitX96 = ONE; // Invalid after the first buy moved the price away from ONE.
        uint256 managerBefore = IERC20(IMD).balanceOf(address(manager));
        vm.expectRevert();
        batch.execute(key, swaps);
        assertEq(_vaultReceived(), 0);
        assertEq(_compensationReceived(), 0);
        assertEq(hook.pendingVault() + hook.pendingCompensation(), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 0);
        assertEq(IERC20(IMD).balanceOf(address(manager)), managerBefore);
        assertEq(IERC20(IMD).balanceOf(address(batch)), 1_000 ether);
        assertEq(token.balanceOf(address(batch)), 1_000 ether);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        assertEq(price, ONE);
        _assertBatchSettled(batch);
    }

    function _newBatch() private returns (BatchSwapActor batch) {
        batch = new BatchSwapActor(manager);
        token.transfer(address(batch), 1_000 ether);
        MockIMD(IMD).mint(address(batch), 1_000 ether);
    }

    function _twoBuys() private view returns (SwapParams[] memory swaps) {
        swaps = new SwapParams[](2);
        bool zeroForOne = hook.imdIsCurrency0();
        swaps[0] = SwapParams(zeroForOne, -100 ether, _limit(zeroForOne));
        swaps[1] = SwapParams(zeroForOne, -100 ether, _limit(zeroForOne));
    }

    function _assertBatchSettled(BatchSwapActor batch) private view {
        assertEq(manager.currencyDelta(address(batch), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(batch), Currency.wrap(address(token))), 0);
        _assertSettled();
    }

    function _deferOpeningBuy() private {
        MockIMD(IMD).reject(VAULT, true);
        MockIMD(IMD).reject(COMPENSATION, true);
        _swap(true, true, 100 ether);
    }

    function _recoverOpeningBuy() private {
        MockIMD(IMD).reject(VAULT, false);
        MockIMD(IMD).reject(COMPENSATION, false);
        hook.redeemFees();
        assertEq(_vaultReceived(), 0.75 ether);
        assertEq(_compensationReceived(), 49.25 ether);
        assertEq(hook.pendingVault() + hook.pendingCompensation(), 0);
        _assertSettled();
    }
}
