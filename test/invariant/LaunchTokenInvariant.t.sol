// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenHandler is Test {
    LaunchToken public immutable token;
    address[5] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    uint256 public transfers;
    uint256 public delegatedTransfers;
    uint256 public rejectedTransfers;

    constructor(LaunchToken token_, address[5] memory actors_) {
        token = token_;
        actors = actors_;
        expectedBalance[actors[0]] = 1e27;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
        ++transfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 limit = expectedBalance[owner] < allowance ? expectedBalance[owner] : allowance;
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        expectedBalance[owner] -= amount;
        expectedBalance[to] += amount;
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        ++delegatedTransfers;
    }

    function approveAndSpendEntireBalance(uint256 ownerSeed, uint256 spenderSeed, bool infinite) external {
        uint256 source = ownerSeed % actors.length;
        uint256 amount = expectedBalance[actors[source]];
        approve(source, spenderSeed, infinite ? type(uint256).max : amount);
        transferFrom(source, spenderSeed, (source + 1) % actors.length, amount);
        assertEq(expectedBalance[actors[source]], 0);
    }

    function rejectOverspend(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        uint256 balance = expectedBalance[owner];
        uint256 amount = balance + 1;
        approve(ownerSeed, spenderSeed, amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, amount)
        );
        vm.prank(spender);
        token.transferFrom(owner, actors[(ownerSeed % actors.length + 1) % actors.length], amount);
        assertEq(token.allowance(owner, spender), amount, "failed transfer consumed approval");
        ++rejectedTransfers;
    }

    function rejectUnapprovedSpend(uint256 ownerSeed, uint256 spenderSeed, uint256 allowanceSeed) external {
        uint256 allowance = bound(allowanceSeed, 0, 1e27);
        approve(ownerSeed, spenderSeed, allowance);
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, allowance + 1
            )
        );
        vm.prank(spender);
        token.transferFrom(owner, spender, allowance + 1);
        ++rejectedTransfers;
    }

    function rejectZeroReceiver(uint256 ownerSeed, bool delegated) external {
        address owner = actors[ownerSeed % actors.length];
        if (delegated) approve(ownerSeed, ownerSeed, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(owner);
        if (delegated) token.transferFrom(owner, address(0), 0);
        else token.transfer(address(0), 0);
        ++rejectedTransfers;
    }
}

/// @dev Closed actor set: every transfer recipient is tracked, including self transfers.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchToken internal token;
    LaunchTokenHandler internal handler;
    address[5] internal actors;

    function setUp() public {
        token = new LaunchToken();
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("token-actor-", vm.toString(i)));
        }
        token.transfer(actors[0], 1e27);
        handler = new LaunchTokenHandler(token, actors);
        handler.transfer(0, 1, 1);
        handler.approve(0, 2, type(uint256).max);
        handler.transferFrom(0, 2, 3, 1e26);
        handler.rejectOverspend(1, 4);

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.approveAndSpendEntireBalance.selector;
        selectors[4] = handler.rejectOverspend.selector;
        selectors[5] = handler.rejectUnapprovedSpend.selector;
        selectors[6] = handler.rejectZeroReceiver.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_fixedSupplyAndEachHolderBalanceMatchAuthorizedTransfers() public view {
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            uint256 balance = token.balanceOf(actors[i]);
            assertEq(balance, handler.expectedBalance(actors[i]), "holder lost or gained unauthorized tokens");
            sum += balance;
        }
        assertEq(sum, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function invariant_allowancesMatchApprovalsAndSuccessfulFiniteSpending() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]), handler.expectedAllowance(actors[i], actors[j])
                );
            }
        }
    }

    function test_zeroOneAndFullSupplySpendsKeepInfiniteApproval() public {
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(i, 0, handler.expectedBalance(actors[i]));
        }
        handler.approve(0, 1, type(uint256).max);
        handler.transferFrom(0, 1, 2, 0);
        handler.transferFrom(0, 1, 2, 1);
        handler.transfer(2, 0, 1);
        handler.transferFrom(0, 1, 2, 1e27);
        assertEq(token.balanceOf(actors[2]), 1e27);
        assertEq(token.balanceOf(actors[0]), 0);
        assertEq(token.allowance(actors[0], actors[1]), type(uint256).max);
        invariant_fixedSupplyAndEachHolderBalanceMatchAuthorizedTransfers();
        invariant_allowancesMatchApprovalsAndSuccessfulFiniteSpending();
    }

    function test_maximumSpendRevertsWithoutConsumingInfiniteApproval() public {
        uint256 balance = token.balanceOf(actors[0]);
        handler.approve(0, 1, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, actors[0], balance, type(uint256).max
            )
        );
        vm.prank(actors[1]);
        token.transferFrom(actors[0], actors[2], type(uint256).max);
        invariant_fixedSupplyAndEachHolderBalanceMatchAuthorizedTransfers();
        invariant_allowancesMatchApprovalsAndSuccessfulFiniteSpending();
    }

    function afterInvariant() public {
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(i, 0, handler.expectedBalance(actors[i]));
        }
        assertEq(token.balanceOf(actors[0]), 1e27, "entire supply must remain transferable");
        invariant_fixedSupplyAndEachHolderBalanceMatchAuthorizedTransfers();
        invariant_allowancesMatchApprovalsAndSuccessfulFiniteSpending();
    }
}
