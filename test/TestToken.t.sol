// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract TokenRecipient {
    function pay(TestToken token, address recipient, uint256 amount) external {
        token.transfer(recipient, amount);
    }
}

contract TokenFactoryFixture {
    function deploy() external returns (TestToken) {
        return new TestToken();
    }
}

contract TestTokenTest is Test {
    TestToken private token;
    address private factory;
    uint256 private constant SUPPLY = 1_000_000_000 ether;

    function setUp() public {
        TokenFactoryFixture deployer = new TokenFactoryFixture();
        factory = address(deployer);
        token = deployer.deploy();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "Test");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(factory), SUPPLY);
    }

    function test_factorySplitsSupplyAndContractsPayWithoutTransferTax() public {
        TokenRecipient pool = new TokenRecipient();
        TokenRecipient distributor = new TokenRecipient();
        address compensation = 0x9f4419712cc22f615e393cC846b927BE3d7D802c;
        vm.startPrank(factory);
        token.transfer(address(pool), SUPPLY * 80 / 100);
        token.transfer(address(distributor), SUPPLY / 10);
        token.transfer(compensation, SUPPLY / 10);
        vm.stopPrank();
        assertEq(token.balanceOf(factory), 0);
        assertEq(token.balanceOf(address(pool)), SUPPLY * 80 / 100);
        assertEq(token.balanceOf(address(distributor)), SUPPLY / 10);
        assertEq(token.balanceOf(compensation), SUPPLY / 10);
        address holder = makeAddr("holder");
        pool.pay(token, holder, 17 ether);
        distributor.pay(token, holder, 23 ether);
        assertEq(token.balanceOf(holder), 40 ether);
        vm.prank(holder);
        token.transfer(address(pool), 40 ether);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_noMintAdminPauseBlacklistOrUpgradeEvenForFactory() public {
        string[9] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "pause()",
            "blacklist(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "setMinter(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], factory, 1 ether);
            vm.prank(factory);
            (bool ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
            (ok,) = address(token).call(data);
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        vm.prank(factory);
        token.transfer(address(this), 1 ether);
        assertEq(token.balanceOf(address(this)), 1 ether);
    }

    function test_transferFromRequiresConsentAndConsumesExactAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(this), 0, 1));
        token.transferFrom(factory, address(this), 1);
        vm.prank(factory);
        token.approve(address(this), 5 ether);
        token.transferFrom(factory, address(this), 5 ether);
        assertEq(token.balanceOf(address(this)), 5 ether);
        assertEq(token.allowance(factory, address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferPreservesSupplyAndCannotOverdraw(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        vm.prank(factory);
        token.transfer(address(this), amount);
        assertEq(token.balanceOf(address(this)), amount);
        assertEq(token.balanceOf(factory), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, address(this), amount, amount + 1)
        );
        token.transfer(factory, amount + 1);
    }
}
