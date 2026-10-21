// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Test-only prefunded trader/LP. Settles only its own funds; never decodes a third-party payer.
contract PoolActor is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;
    address public immutable controller = msg.sender;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        return
            BalanceDelta.wrap(abi.decode(manager.unlock(abi.encode(true, key, abi.encode(params, hookData))), (int256)));
    }

    function modify(PoolKey memory key, int24 lower, int24 upper, int256 liquidity) external returns (BalanceDelta) {
        require(msg.sender == controller, "controller only");
        ModifyLiquidityParams memory params = ModifyLiquidityParams(lower, upper, liquidity, bytes32(0));
        return BalanceDelta.wrap(abi.decode(manager.unlock(abi.encode(false, key, abi.encode(params))), (int256)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (bool isSwap, PoolKey memory key, bytes memory action) = abi.decode(data, (bool, PoolKey, bytes));
        BalanceDelta delta;
        if (isSwap) {
            (SwapParams memory params, bytes memory hookData) = abi.decode(action, (SwapParams, bytes));
            delta = manager.swap(key, params, hookData);
        } else {
            ModifyLiquidityParams memory params = abi.decode(action, (ModifyLiquidityParams));
            (delta,) = manager.modifyLiquidity(key, params, "");
        }
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(BalanceDelta.unwrap(delta));
    }

    function _settle(Currency currency, int128 delta) private {
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), uint256(-int256(delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(uint128(delta)));
        }
    }
}
