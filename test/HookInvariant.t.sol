// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookTestBase} from "./helpers/HookTestBase.sol";
import {PoolActor} from "./helpers/PoolActor.sol";
import {MockIMD} from "./mocks/MockIMD.sol";
import {TestHook} from "../src/TestHook.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract FeeHandler is Test {
    TestHook internal hook;
    PoolActor internal actor;
    PoolKey internal key;
    MockIMD internal imd;
    uint256 public trades;

    constructor(TestHook hook_, PoolActor actor_, PoolKey memory key_) {
        hook = hook_;
        actor = actor_;
        key = key_;
        imd = MockIMD(hook.IMD());
    }

    function trade(bool buy, bool exactInput, uint96 rawAmount) external {
        uint256 amount = bound(uint256(rawAmount), 1, 1_000 ether);
        bool zeroForOne = buy == hook.imdIsCurrency0();
        vm.prank(actor.controller());
        actor.swap(
            key,
            SwapParams(
                zeroForOne,
                exactInput ? -int256(amount) : int256(amount),
                zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            ),
            ""
        );
        ++trades;
    }

    function advance(uint16 elapsed) external {
        vm.warp(block.timestamp + bound(uint256(elapsed), 0, 300));
    }

    function rejectRecipients(bool vault, bool compensation) external {
        imd.reject(hook.SIMD_VAULT(), vault);
        imd.reject(hook.COMPENSATION_VAULT(), compensation);
    }

    function redeem() external {
        hook.redeemFees();
    }
}

contract HookInvariantTest is HookTestBase {
    FeeHandler internal handler;
    uint256 internal initialFunds;

    function setUp() public {
        _setup(false, true, true);
        initialFunds = IERC20(IMD).balanceOf(address(actor)) + IERC20(IMD).balanceOf(address(manager));
        handler = new FeeHandler(hook, actor, key);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = FeeHandler.trade.selector;
        selectors[1] = FeeHandler.advance.selector;
        selectors[2] = FeeHandler.rejectRecipients.selector;
        selectors[3] = FeeHandler.redeem.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allIMDIsConservedAndClaimsAreExactlyBacked() public view {
        assertEq(
            IERC20(IMD).balanceOf(address(actor)) + IERC20(IMD).balanceOf(address(manager)) + _vaultReceived()
                + _compensationReceived(),
            initialFunds
        );
        assertEq(
            manager.balanceOf(address(hook), uint256(uint160(IMD))), hook.pendingVault() + hook.pendingCompensation()
        );
        assertGe(IERC20(IMD).balanceOf(address(manager)), hook.pendingVault() + hook.pendingCompensation());
        assertEq(hook.initializedAt(), opened);
        assertEq(hook.SIMD_VAULT(), VAULT);
        assertEq(hook.COMPENSATION_VAULT(), COMPENSATION);
        _assertSettled();
    }

    function afterInvariant() public {
        MockIMD(IMD).reject(VAULT, false);
        MockIMD(IMD).reject(COMPENSATION, false);
        hook.redeemFees();
        assertEq(hook.pendingVault() + hook.pendingCompensation(), 0);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(IMD))), 0);
        _assertSettled();
    }
}
