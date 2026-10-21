// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";

contract TokenLedgerHandler is Test {
    TestToken private immutable token;
    address[4] public holders;
    uint256[4] public expectedBalance;
    uint256[4][4] public expectedAllowance;

    constructor(TestToken token_) {
        token = token_;
        holders = [address(this), makeAddr("token holder A"), makeAddr("token holder B"), makeAddr("token spender")];
        expectedBalance[0] = token_.totalSupply();
    }

    function transfer(uint8 fromSeed, uint8 toSeed, uint256 rawAmount) external {
        uint256 from = fromSeed % 4;
        uint256 to = toSeed % 4;
        uint256 amount = bound(rawAmount, 0, expectedBalance[from]);
        vm.prank(holders[from]);
        assertTrue(token.transfer(holders[to], amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function approve(uint8 ownerSeed, uint8 spenderSeed, uint256 amount) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        vm.prank(holders[owner]);
        assertTrue(token.approve(holders[spender], amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint8 ownerSeed, uint8 spenderSeed, uint8 toSeed, uint256 rawAmount) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 to = toSeed % 4;
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner] < allowance ? expectedBalance[owner] : allowance;
        uint256 amount = bound(rawAmount, 0, available);
        vm.prank(holders[spender]);
        assertTrue(token.transferFrom(holders[owner], holders[to], amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
    }

    function overdraw(uint8 ownerSeed, uint8 toSeed) external {
        uint256 owner = ownerSeed % 4;
        vm.prank(holders[owner]);
        (bool ok,) =
            address(token).call(abi.encodeCall(token.transfer, (holders[toSeed % 4], expectedBalance[owner] + 1)));
        assertFalse(ok, "overdraw succeeded");
    }

    function exceedAllowance(uint8 ownerSeed, uint8 spenderSeed) external {
        uint256 owner = ownerSeed % 4;
        uint256 spender = spenderSeed % 4;
        uint256 allowance = expectedAllowance[owner][spender];
        if (allowance == type(uint256).max) return;
        vm.prank(holders[spender]);
        (bool ok,) =
            address(token).call(abi.encodeCall(token.transferFrom, (holders[owner], holders[spender], allowance + 1)));
        assertFalse(ok, "unapproved spending succeeded");
    }

    function assertLedger() external view {
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            assertEq(token.balanceOf(holders[i]), expectedBalance[i], "tax, seizure or balance mismatch");
            sum += token.balanceOf(holders[i]);
            for (uint256 j; j < 4; ++j) {
                assertEq(token.allowance(holders[i], holders[j]), expectedAllowance[i][j], "allowance mismatch");
            }
        }
        assertEq(sum, 1_000_000_000 ether);
        assertEq(token.totalSupply(), sum, "supply changed");
    }
}

contract TokenInvariantTest is Test {
    TokenLedgerHandler private handler;

    function setUp() public {
        TestToken token = new TestToken();
        handler = new TokenLedgerHandler(token);
        token.transfer(address(handler), token.totalSupply());
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = TokenLedgerHandler.transfer.selector;
        selectors[1] = TokenLedgerHandler.approve.selector;
        selectors[2] = TokenLedgerHandler.transferFrom.selector;
        selectors[3] = TokenLedgerHandler.overdraw.selector;
        selectors[4] = TokenLedgerHandler.exceedAllowance.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 64
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_fixedSupplyAndConsentedUntaxedTransfers() public view {
        handler.assertLedger();
    }
}
