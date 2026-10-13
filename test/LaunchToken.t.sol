// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal holder;

    function setUp() public {
        token = new LaunchToken();
        holder = makeAddr("holder");
    }

    function test_factoryReceivesExactFixedSupplyAndMetadata() public view {
        assertEq(token.name(), "PONZIRAMID");
        assertEq(token.symbol(), "PONZIRAM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_transferHasNoFeeAndConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, token.totalSupply());
        assertTrue(token.transfer(holder, amount));
        assertEq(token.balanceOf(holder), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_transferFromRequiresAndConsumesApproval() public {
        token.approve(holder, 10 ether);
        vm.prank(holder);
        token.transferFrom(address(this), holder, 4 ether);
        assertEq(token.allowance(address(this), holder), 6 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder, 6 ether, 7 ether)
        );
        vm.prank(holder);
        token.transferFrom(address(this), holder, 7 ether);
    }

    function test_rejectsZeroRecipientAndOverspending() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, 0, 1));
        vm.prank(holder);
        token.transfer(address(this), 1);
    }

    function test_noMintOrAdministrationEvenForDeployer() public {
        string[9] memory selectors = [
            "mint(address,uint256)",
            "burn(uint256)",
            "pause()",
            "setFee(uint256)",
            "setMinter(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "blacklist(address)"
        ];
        for (uint256 i; i < selectors.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(selectors[i], holder, uint256(1)));
            assertFalse(ok, selectors[i]);
        }
        assertEq(token.totalSupply(), 1e27);
    }
}
