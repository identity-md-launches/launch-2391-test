// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookEconomicTests} from "./TestHook.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @dev Opt in with --fork-url and --fork-block-number; no environment reads or network in default tests.
contract RobinhoodToken0ForkTest is HookEconomicTests {
    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 4663, "fork must be Robinhood Chain");
        assertGt(IMD.code.length, 0, "real IMD missing from fork");
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        _setup(true, true, true);
    }
}

contract RobinhoodToken1ForkTest is HookEconomicTests {
    function setUp() public {
        try vm.activeFork() returns (uint256) {}
        catch {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 4663, "fork must be Robinhood Chain");
        assertGt(IMD.code.length, 0, "real IMD missing from fork");
        assertEq(IERC20Metadata(IMD).symbol(), "IMD");
        assertEq(IERC20Metadata(IMD).decimals(), 18);
        _setup(true, false, true);
    }
}
