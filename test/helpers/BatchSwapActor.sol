// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Executes multiple swaps and settles net amounts within one real unlock transaction.
contract BatchSwapActor is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using SafeERC20 for IERC20;
    IPoolManager public immutable manager;
    address private immutable controller = msg.sender;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function execute(PoolKey memory key, SwapParams[] memory swaps) external returns (BalanceDelta[] memory) {
        require(msg.sender == controller, "controller only");
        return abi.decode(manager.unlock(abi.encode(key, swaps)), (BalanceDelta[]));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (PoolKey memory key, SwapParams[] memory swaps) = abi.decode(data, (PoolKey, SwapParams[]));
        BalanceDelta[] memory deltas = new BalanceDelta[](swaps.length);
        for (uint256 i; i < swaps.length; ++i) {
            deltas[i] = manager.swap(key, swaps[i], "");
        }
        _settle(key.currency0);
        _settle(key.currency1);
        return abi.encode(deltas);
    }

    function _settle(Currency currency) private {
        int256 delta = manager.currencyDelta(address(this), currency);
        if (delta < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransfer(address(manager), uint256(-delta));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, address(this), uint256(delta));
        }
    }
}
