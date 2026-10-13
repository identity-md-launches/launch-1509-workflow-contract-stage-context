// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameFixture} from "./helpers/GameFixture.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {Ponziramid} from "src/Ponziramid.sol";
import {StoneVault} from "src/StoneVault.sol";
import {PonziRewards} from "src/PonziRewards.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract AdversarialBuildTest is GameFixture {
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_rejectedQuoteLeavesAllCustodyAndRoundStateUntouched(
        uint256 discrepancy,
        uint8 failure,
        bool started
    ) public {
        if (started) _build(alice);
        (uint256 roundId, uint256 price,,) = game.quote();
        uint256 delta = bound(discrepancy, 1, 100 ether);
        bytes32 beforeState = _state();
        uint256 beforeBalance = bob.balance;
        bytes4 reason = failure % 3 == 0 ? Ponziramid.StaleRound.selector : Ponziramid.IncorrectPrice.selector;
        vm.expectRevert(reason);
        vm.prank(bob);
        if (failure % 3 == 0) game.build{value: price}(roundId + delta, price);
        else if (failure % 3 == 1) game.build{value: price}(roundId, price + delta);
        else game.build{value: price + delta}(roundId, price);
        assertEq(_state(), beforeState, "rejected build mutated accounting");
        assertEq(bob.balance, beforeBalance, "rejected payment retained ETH");
    }

    function test_zeroPaymentAndMaximumQuoteCannotStartOrReserveRound() public {
        bytes32 beforeState = _state();
        vm.expectRevert(Ponziramid.IncorrectPrice.selector);
        vm.prank(alice);
        game.build(1, 0.001 ether);
        vm.expectRevert(Ponziramid.IncorrectPrice.selector);
        vm.prank(alice);
        game.build{value: 0.001 ether}(1, type(uint256).max);
        vm.expectRevert(Ponziramid.StaleRound.selector);
        vm.prank(alice);
        game.build{value: 0.001 ether}(0, 0.001 ether);
        assertEq(_state(), beforeState);
    }

    function test_firstBuildAtTimestampZeroStillEnforcesCooldown() public {
        vm.warp(0);
        _build(alice);
        _build(bob);
        (, uint256 price,,) = game.quote();
        vm.warp(59);
        bytes32 beforeState = _state();
        vm.expectRevert(Ponziramid.Cooldown.selector);
        vm.prank(alice);
        game.build{value: price}(1, price);
        assertEq(_state(), beforeState);
        vm.warp(60);
        assertEq(_build(alice), 3);
    }

    function test_firstPlacementAfterPauseUsesItsOwnTimestamp() public {
        vm.prank(creator);
        game.setPaused(true);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.expectRevert(Ponziramid.Paused.selector);
        vm.prank(alice);
        game.build{value: 0.001 ether}(1, 0.001 ether);
        assertEq(game.currentRound(), 0);
        assertEq(rewards.committed(), 0);
        vm.prank(creator);
        game.setPaused(false);
        _build(alice);
        assertEq(game.rounds(1).startedAt, vm.getBlockTimestamp());
        assertEq(game.rounds(1).expiresAt, vm.getBlockTimestamp() + 1 days);
    }

    function test_pauseDoesNotFreezeClockOrAllowExpiredRoundToResume() public {
        _build(alice);
        uint256 expiry = game.rounds(1).expiresAt;
        vm.prank(creator);
        game.setPaused(true);
        vm.warp(expiry + 30 days);
        vm.prank(creator);
        game.setPaused(false);
        (, uint256 price,,) = game.quote();
        vm.expectRevert(Ponziramid.RoundExpired.selector);
        vm.prank(bob);
        game.build{value: price}(1, price);
        assertEq(game.rounds(1).expiresAt, expiry);
        game.finalize();
        _build(bob);
        assertEq(game.rounds(2).startedAt, vm.getBlockTimestamp());
        assertEq(game.bricks(2).stone, 0.0009 ether);
    }

    function test_nonexistentBrickAndEmptyCreditsCannotPayAnyone() public {
        _build(alice);
        uint256[3] memory ids = [uint256(0), uint256(2), type(uint256).max];
        bytes32 beforeState = _state();
        for (uint256 i; i < ids.length; ++i) {
            (uint256 dividend, uint256 diamond) = game.claimableBrickETH(ids[i]);
            assertEq(dividend + diamond, 0);
            vm.expectRevert(Ponziramid.NotBrickOwner.selector);
            vm.prank(alice);
            game.claimBrickETH(ids[i], payable(alice));
            vm.expectRevert(StoneVault.NotDepositor.selector);
            vm.prank(alice);
            vault.withdrawStone(ids[i], payable(alice));
        }
        vm.expectRevert(Ponziramid.InvalidAddress.selector);
        vm.prank(creator);
        game.claimETH(payable(address(0)));
        vm.expectRevert(Ponziramid.NothingToClaim.selector);
        vm.prank(alice);
        game.claimBrickETH(1, payable(alice));
        assertEq(_state(), beforeState);
    }

    function _state() private view returns (bytes32) {
        bytes32 gameState = keccak256(
            abi.encode(
                game.currentRound(),
                game.brickCount(),
                game.rounds(1),
                game.rounds(2),
                game.totalMortarReceived(),
                game.totalEthPaid(),
                game.totalCredits(),
                game.nextTomb(),
                game.lastBuildAt(bob),
                game.ethCredit(creator)
            )
        );
        return keccak256(
            abi.encode(
                gameState,
                vault.totalStone(),
                vault.stoneOf(bob),
                rewards.committed(),
                rewards.fundingReached(),
                rewards.participated(1, bob),
                address(game).balance,
                address(vault).balance,
                token.balanceOf(address(rewards))
            )
        );
    }
}

contract FundingExhaustionTest is GameFixture {
    function test_lastReservedRoundCanFinishAndOldClaimsSurviveFundingExhaustion() public {
        // Exercise depletion through the real game, with no privileged game impersonation or storage edits.
        for (uint256 roundId = 1; roundId <= 700; ++roundId) {
            assertEq(_build(alice), roundId);
            if (roundId != 700) _expireAndFinalize();
        }
        assertEq(rewards.uncommitted(), 0);
        assertEq(rewards.committed(), 700_000_000 ether);
        assertFalse(rewards.canReserveRound());

        // A reservation funds the whole round, including later builders when no new round can be funded.
        uint256 lastBrick = _build(bob);
        assertEq(lastBrick, 701);
        assertEq(game.currentRound(), 700);
        _expireAndFinalize();
        uint256 seed = game.nextTomb();
        uint256 bobBefore = bob.balance;
        vm.expectRevert(PonziRewards.InsufficientUncommittedTokens.selector);
        vm.prank(bob);
        game.build{value: 0.001 ether}(701, 0.001 ether);
        assertEq(bob.balance, bobBefore);
        assertEq(game.nextTomb(), seed);
        assertEq(game.currentRound(), 700);
        assertEq(game.brickCount(), 701);
        assertEq(game.rounds(701).startedAt, 0);
        (bool reserved,,,,,) = rewards.rounds(701);
        assertFalse(reserved);

        uint256 principal = vault.totalStone();
        _withdraw(alice, 1);
        assertEq(vault.totalStone(), principal - 0.0009 ether);
        assertGt(_claimBrick(alice, 1), 0);
        vm.prank(alice);
        assertEq(rewards.claim(1, alice), 1_000_000 ether);
        assertEq(rewards.uncommitted(), 0, "paying a liability must not free uncommitted tokens");

        token.approve(address(rewards), 1_000_000 ether);
        rewards.fund(1_000_000 ether - 1);
        vm.expectRevert(PonziRewards.InsufficientUncommittedTokens.selector);
        vm.prank(bob);
        game.build{value: 0.001 ether}(701, 0.001 ether);
        rewards.fund(1);
        assertEq(_build(bob), 702);
        assertEq(game.currentRound(), 701);
        assertEq(game.rounds(701).tomb, seed + 0.00009 ether);
        assertEq(rewards.uncommitted(), 0);
        assertEq(rewards.claimable(2, alice), 1_000_000 ether);
        assertEq(rewards.claimable(700, bob), 650_000 ether);
        _assertSolvent();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fundingWithInsufficientAllowanceRollsBack(uint256 amountSeed, uint256 allowanceSeed)
        public
    {
        uint256 amount = bound(amountSeed, 1, token.balanceOf(address(this)));
        uint256 allowance = bound(allowanceSeed, 0, amount - 1);
        token.approve(address(rewards), allowance);
        uint256 beforePool = token.balanceOf(address(rewards));
        uint256 beforeFunder = token.balanceOf(address(this));
        uint256 beforeFunded = rewards.totalFunded();
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(rewards), allowance, amount
            )
        );
        rewards.fund(amount);
        assertEq(token.balanceOf(address(rewards)), beforePool);
        assertEq(token.balanceOf(address(this)), beforeFunder);
        assertEq(rewards.totalFunded(), beforeFunded);
        assertEq(token.allowance(address(this), address(rewards)), allowance);
    }

    function test_fundingWithoutBalanceRollsBackConsumedAllowance() public {
        vm.prank(outsider);
        token.approve(address(rewards), 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, outsider, 0, 1)
        );
        vm.prank(outsider);
        rewards.fund(1);
        assertEq(token.allowance(outsider, address(rewards)), 1);
        assertEq(rewards.totalFunded(), 700_000_000 ether);
        assertEq(token.balanceOf(address(rewards)), 700_000_000 ether);
    }
}

contract StoneVaultBoundaryTest is Test {
    StoneVault internal vault;
    address internal player;
    uint256 internal observedId;
    bool internal rejectCallback;

    function setUp() public {
        vault = new StoneVault(address(this));
        player = makeAddr("vault-depositor");
    }

    function onStoneWithdrawal(uint256 brickId) external {
        require(msg.sender == address(vault));
        require(!rejectCallback, "observer rejects");
        observedId = brickId;
    }

    function test_invalidDepositsDoNotCreatePrincipal() public {
        vm.expectRevert(StoneVault.InvalidDeposit.selector);
        vault.deposit{value: 1}(0, player);
        vm.expectRevert(StoneVault.InvalidDeposit.selector);
        vault.deposit(1, player);
        vm.expectRevert(StoneVault.InvalidAddress.selector);
        vault.deposit{value: 1}(1, address(0));
        assertEq(vault.totalStone(), 0);
        assertEq(vault.stoneOf(player), 0);
        assertEq(address(vault).balance, 0);
    }

    function test_depositIdentifierCannotBeReusedEvenAfterRefund() public {
        vault.deposit{value: 1}(type(uint256).max, player);
        vm.expectRevert(StoneVault.InvalidDeposit.selector);
        vault.deposit{value: 2}(type(uint256).max, player);
        vm.prank(player);
        vault.withdrawStone(type(uint256).max, payable(player));
        vm.expectRevert(StoneVault.InvalidDeposit.selector);
        vault.deposit{value: 2}(type(uint256).max, player);
        (address depositor, uint256 remaining) = vault.deposits(type(uint256).max);
        assertEq(depositor, player);
        assertEq(remaining, 0);
        assertEq(player.balance, 1);
        assertEq(observedId, type(uint256).max);
        assertEq(vault.totalStone(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_fullPrincipalCanBeRedirectedWithoutCreatingRecipientCredit(uint256 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, type(uint128).max);
        vm.deal(address(this), amount);
        vault.deposit{value: amount}(1, player);
        address recipient = makeAddr("refund-recipient");
        vm.prank(player);
        vault.withdrawStone(1, payable(recipient));
        assertEq(recipient.balance, amount);
        assertEq(player.balance, 0);
        assertEq(vault.stoneOf(recipient), 0);
        assertEq(vault.stoneOf(player), 0);
        assertEq(vault.totalStone(), 0);
        assertEq(address(vault).balance, 0);
        vm.expectRevert(StoneVault.NotDepositor.selector);
        vm.prank(recipient);
        vault.withdrawStone(1, payable(recipient));
        vm.expectRevert(StoneVault.AlreadyWithdrawn.selector);
        vm.prank(player);
        vault.withdrawStone(1, payable(player));
    }

    function test_revertingObserverPreservesEveryPrincipalLedgerForRetry() public {
        vault.deposit{value: 1 ether}(1, player);
        rejectCallback = true;
        vm.expectRevert(bytes("observer rejects"));
        vm.prank(player);
        vault.withdrawStone(1, payable(player));
        (address depositor, uint256 amount) = vault.deposits(1);
        assertEq(depositor, player);
        assertEq(amount, 1 ether);
        assertEq(vault.stoneOf(player), 1 ether);
        assertEq(vault.totalStone(), 1 ether);
        assertEq(address(vault).balance, 1 ether);
        assertEq(observedId, 0);
        rejectCallback = false;
        vm.prank(player);
        vault.withdrawStone(1, payable(player));
        assertEq(player.balance, 1 ether);
        assertEq(vault.totalStone(), 0);
    }
}
