// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TestToken} from "../../src/TestToken.sol";
import {TestHook} from "../../src/TestHook.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {MockIMD} from "../mocks/MockIMD.sol";
import {PoolActor} from "./PoolActor.sol";

abstract contract HookTestBase is Test {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    address internal constant IMD = 0x5F7Bb59365ce557C26dbcAa4EE9d39A4b95B7127;
    address internal constant VAULT = 0xbBa92992309C61E1c483ab630d0530F2C9edEDE7;
    address internal constant COMPENSATION = 0x9f4419712cc22f615e393cC846b927BE3d7D802c;
    uint160 internal constant ONE = 79228162514264337593543950336;
    uint256 internal constant FUNDS = 100_000_000 ether;
    int256 internal constant LIQUIDITY = 1_000_000 ether;

    IPoolManager internal manager;
    TestToken internal token;
    TestHook internal hook;
    PoolActor internal actor;
    PoolKey internal key;
    uint256 internal opened;
    uint256 internal initialVault;
    uint256 internal initialCompensation;

    function _setup(bool forked, bool tokenFirst, bool seed) internal {
        manager = IPoolManager(address(new PoolManager(address(this))));
        if (!forked) {
            MockIMD implementation = new MockIMD();
            vm.etch(IMD, address(implementation).code);
        }
        // Choose a real CREATE2 deployment on either side of IMD; no etched TEST implementation.
        bytes32 tokenHash = keccak256(type(TestToken).creationCode);
        for (uint256 salt;; ++salt) {
            address predicted = vm.computeCreate2Address(bytes32(salt), tokenHash, address(this));
            if ((predicted < IMD) == tokenFirst) {
                token = new TestToken{salt: bytes32(salt)}();
                break;
            }
        }
        hook = _deployHook(manager, address(token), address(this));
        key = PoolKey({
            currency0: Currency.wrap(tokenFirst ? address(token) : IMD),
            currency1: Currency.wrap(tokenFirst ? IMD : address(token)),
            fee: 12_500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        opened = block.timestamp;
        manager.initialize(key, ONE);
        actor = new PoolActor(manager);
        token.transfer(address(actor), FUNDS);
        if (forked) deal(IMD, address(actor), FUNDS);
        else MockIMD(IMD).mint(address(actor), FUNDS);
        initialVault = IERC20(IMD).balanceOf(VAULT);
        initialCompensation = IERC20(IMD).balanceOf(COMPENSATION);
        if (seed) actor.modify(key, -600, 600, LIQUIDITY);
    }

    function _deployHook(IPoolManager manager_, address token_, address factory_) internal returns (TestHook result) {
        bytes memory args = abi.encode(manager_, token_, factory_);
        bytes32 initHash = keccak256(abi.encodePacked(type(TestHook).creationCode, args));
        for (uint256 salt; salt < 200_000; ++salt) {
            address predicted = vm.computeCreate2Address(bytes32(salt), initHash, address(this));
            if (!HookFlags.matches(predicted, HookFlags.TEST_HOOK)) continue;
            if (predicted.code.length != 0) continue;
            return new TestHook{salt: bytes32(salt)}(manager_, token_, factory_);
        }
        revert("no hook salt found");
    }

    function _swap(bool buy, bool exactInput, uint256 amount) internal returns (BalanceDelta) {
        bool zeroForOne = buy == hook.imdIsCurrency0();
        return
            actor.swap(
                key, SwapParams(zeroForOne, exactInput ? -int256(amount) : int256(amount), _limit(zeroForOne)), ""
            );
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _imdDelta(BalanceDelta delta) internal view returns (int128) {
        return hook.imdIsCurrency0() ? delta.amount0() : delta.amount1();
    }

    function _testDelta(BalanceDelta delta) internal view returns (int128) {
        return hook.imdIsCurrency0() ? delta.amount1() : delta.amount0();
    }

    function _vaultReceived() internal view returns (uint256) {
        return IERC20(IMD).balanceOf(VAULT) - initialVault;
    }

    function _compensationReceived() internal view returns (uint256) {
        return IERC20(IMD).balanceOf(COMPENSATION) - initialCompensation;
    }

    function _assertSettled() internal view {
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(hook), Currency.wrap(address(token))), 0);
        assertEq(manager.currencyDelta(address(actor), Currency.wrap(IMD)), 0);
        assertEq(manager.currencyDelta(address(actor), Currency.wrap(address(token))), 0);
        assertEq(manager.getNonzeroDeltaCount(), 0);
        assertEq(IERC20(IMD).balanceOf(address(hook)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}
