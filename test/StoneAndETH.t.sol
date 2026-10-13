// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameFixture, RejectETH, ReenterETH} from "./helpers/GameFixture.sol";
import {Ponziramid} from "../src/Ponziramid.sol";
import {StoneVault} from "../src/StoneVault.sol";

contract StoneAndETHTest is GameFixture {
    function test_withdrawalReturnsAllStoneAndOnlyStopsFutureEarnings() public {
        uint256 a = _build(alice);
        _build(bob);
        (uint256 earned,) = game.claimableBrickETH(a);
        uint256 principal = game.bricks(a).stone;
        uint256 beforeBalance = alice.balance;
        uint256 expiry = game.rounds(1).expiresAt;
        _withdraw(alice, a);
        assertEq(alice.balance - beforeBalance, principal);
        assertEq(vault.stoneOf(alice), 0);
        assertEq(game.rounds(1).expiresAt, expiry - 10 minutes);
        assertEq(game.rounds(1).activeBricks, 1);
        assertTrue(game.bricks(a).exitedBeforeExpiry);
        _build(carol);
        (uint256 afterEarned,) = game.claimableBrickETH(a);
        assertEq(afterEarned, earned);
        assertEq(_claimBrick(alice, a), earned);
        vm.expectRevert(Ponziramid.NothingToClaim.selector);
        vm.prank(alice);
        game.claimBrickETH(a, payable(alice));
        _expireAndFinalize();
        (, uint256 diamond) = game.claimableBrickETH(a);
        assertEq(diamond, 0);
        assertGt(rewards.claimable(1, alice), 0, "withdrawal retains participation");
        _assertSolvent();
    }

    function test_withdrawalNeedsNeitherTokenCodeNorSettlement() public {
        uint256 a = _build(alice);
        vm.prank(creator);
        game.setPaused(true);
        // Simulate a failed outside dependency. Principal release does not call the token/rewards.
        vm.etch(address(token), hex"");
        vm.etch(address(rewards), hex"");
        uint256 principal = game.bricks(a).stone;
        uint256 beforeBalance = alice.balance;
        _withdraw(alice, a);
        assertEq(alice.balance - beforeBalance, principal);
        assertEq(vault.totalStone(), 0);
        assertFalse(game.rounds(1).finalized);
    }

    function test_withdrawalAtExpiryKeepsSnapshotBeforeFinalize() public {
        uint256 a = _build(alice);
        uint256 b = _build(bob);
        Ponziramid.Round memory beforeRound = game.rounds(1);
        vm.warp(beforeRound.expiresAt);
        _withdraw(alice, a);
        assertFalse(game.bricks(a).exitedBeforeExpiry);
        assertEq(game.rounds(1).activeBricks, 2);
        assertEq(game.rounds(1).activeStone, beforeRound.activeStone);
        assertEq(game.rounds(1).expiresAt, beforeRound.expiresAt);
        game.finalize();
        (, uint256 aliceDiamond) = game.claimableBrickETH(a);
        (, uint256 bobDiamond) = game.claimableBrickETH(b);
        uint256 pot = beforeRound.tomb * 40 / 100;
        assertEq(aliceDiamond, pot * game.bricks(a).stone / beforeRound.activeStone);
        assertEq(bobDiamond, pot * game.bricks(b).stone / beforeRound.activeStone);
        assertGt(aliceDiamond, 0);
        _claimBrick(alice, a);
        _withdraw(bob, b);
        _claimBrick(bob, b);
        assertEq(vault.totalStone(), 0);
        assertEq(game.rounds(1).diamondRemaining, 0);
        _assertSolvent();
    }

    function test_bankRunCanEndNowAndExcludesTheTriggeringBrick() public {
        uint256 a = _build(alice);
        uint256 b = _build(bob);
        vm.warp(game.rounds(1).expiresAt - 600);
        _withdraw(alice, a);
        assertEq(game.rounds(1).expiresAt, vm.getBlockTimestamp());
        assertTrue(game.bricks(a).exitedBeforeExpiry);
        // This second withdrawal is at expiry, so Bob is in the diamond-hands snapshot.
        _withdraw(bob, b);
        assertFalse(game.bricks(b).exitedBeforeExpiry);
        game.finalize();
        (, uint256 aDiamond) = game.claimableBrickETH(a);
        (, uint256 bDiamond) = game.claimableBrickETH(b);
        assertEq(aDiamond, 0);
        assertEq(bDiamond, game.rounds(1).diamondPool);
    }

    function test_penaltySaturatesAtNowAndDoesNotRetroactivelyChangeExpiry() public {
        uint256 a = _build(alice);
        vm.warp(game.rounds(1).expiresAt - 1);
        _withdraw(alice, a);
        assertEq(game.rounds(1).expiresAt, vm.getBlockTimestamp());
        game.finalize();
        assertEq(game.rounds(1).diamondPool, 0);
        uint256 tomb = game.rounds(1).tomb;
        assertEq(game.nextTomb(), tomb - tomb * 40 / 100);
        assertEq(game.ethCredit(alice), tomb * 40 / 100, "last builder remains Pharaoh after exit");
        assertEq(rewards.claimable(1, alice), 1_000_000 ether);
    }

    function test_failedStonePaymentRollsBackCreditAndTimerAndCanRetry() public {
        uint256 a = _build(alice);
        uint256 expiry = game.rounds(1).expiresAt;
        uint256 principal = vault.totalStone();
        RejectETH reject = new RejectETH();
        vm.expectRevert(StoneVault.TransferFailed.selector);
        vm.prank(alice);
        vault.withdrawStone(a, payable(address(reject)));
        assertEq(vault.totalStone(), principal);
        assertEq(vault.stoneOf(alice), principal);
        assertEq(address(vault).balance, principal);
        assertEq(game.rounds(1).expiresAt, expiry);
        assertFalse(game.bricks(a).withdrawn);
        assertEq(game.rounds(1).activeBricks, 1);
        vm.prank(alice);
        vault.withdrawStone(a, payable(bob));
        assertEq(vault.totalStone(), 0);
        assertTrue(game.bricks(a).withdrawn);
    }

    function test_unauthorizedAndDuplicateStoneActionsFail() public {
        uint256 a = _build(alice);
        vm.expectRevert(StoneVault.OnlyGame.selector);
        vm.prank(creator);
        vault.deposit{value: 1}(a, creator);
        vm.expectRevert(Ponziramid.OnlyVault.selector);
        vm.prank(creator);
        game.onStoneWithdrawal(a);
        vm.expectRevert(StoneVault.NotDepositor.selector);
        vm.prank(creator);
        vault.withdrawStone(a, payable(creator));
        vm.expectRevert(StoneVault.InvalidAddress.selector);
        vm.prank(alice);
        vault.withdrawStone(a, payable(address(0)));
        _withdraw(alice, a);
        vm.expectRevert(StoneVault.AlreadyWithdrawn.selector);
        vm.prank(alice);
        vault.withdrawStone(a, payable(alice));
    }

    function test_stoneCannotBeWithdrawnTwiceByReentrantOwner() public {
        ReenterETH attacker = new ReenterETH();
        attacker.execute{value: 0.001 ether}(address(game), abi.encodeCall(game.build, (1, 0.001 ether)));
        bytes memory payload = abi.encodeCall(vault.withdrawStone, (1, payable(address(attacker))));
        attacker.arm(address(vault), payload);
        attacker.execute(address(vault), payload);
        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        assertEq(address(attacker).balance, 0.0009 ether);
        assertEq(vault.totalStone(), 0);
        _assertSolvent();
    }

    function test_dividendsClaimableMidRoundWithoutDeactivatingAndNewAccrualContinues() public {
        uint256 a = _build(alice);
        _build(bob);
        uint256 first = _claimBrick(alice, a);
        assertEq(first, 0.00005025 ether);
        assertFalse(game.bricks(a).withdrawn);
        assertEq(game.rounds(1).activeBricks, 2);
        _build(carol);
        uint256 second = _claimBrick(alice, a);
        assertGt(second, 0);
        assertEq(vault.stoneOf(alice), 0.0009 ether);
        _assertSolvent();
    }

    function test_failedETHClaimPreservesDividendAndDiamondAndDustState() public {
        uint256 a = _build(alice);
        _build(bob);
        _expireAndFinalize();
        (uint256 divBefore, uint256 diamondBefore) = game.claimableBrickETH(a);
        uint256 nextBefore = game.nextTomb();
        Ponziramid.Round memory beforeRound = game.rounds(1);
        RejectETH reject = new RejectETH();
        vm.expectRevert(Ponziramid.TransferFailed.selector);
        vm.prank(alice);
        game.claimBrickETH(a, payable(address(reject)));
        (uint256 divAfter, uint256 diamondAfter) = game.claimableBrickETH(a);
        assertEq(divAfter, divBefore);
        assertEq(diamondAfter, diamondBefore);
        assertEq(game.nextTomb(), nextBefore);
        assertEq(game.rounds(1).diamondRemaining, beforeRound.diamondRemaining);
        assertEq(game.rounds(1).diamondClaimsRemaining, beforeRound.diamondClaimsRemaining);
        assertEq(_claimBrick(alice, a), divBefore + diamondBefore);
        vm.expectRevert(Ponziramid.NothingToClaim.selector);
        vm.prank(alice);
        game.claimBrickETH(a, payable(alice));
    }

    function test_failedPharaohAndOwnerCreditPaymentsPreserveCredit() public {
        _build(alice);
        _expireAndFinalize();
        RejectETH reject = new RejectETH();
        uint256 prize = game.ethCredit(alice);
        vm.expectRevert(Ponziramid.TransferFailed.selector);
        vm.prank(alice);
        game.claimETH(payable(address(reject)));
        assertEq(game.ethCredit(alice), prize);
        uint256 fee = game.ethCredit(creator);
        vm.expectRevert(Ponziramid.TransferFailed.selector);
        vm.prank(creator);
        game.claimETH(payable(address(reject)));
        assertEq(game.ethCredit(creator), fee);
        vm.prank(alice);
        assertEq(game.claimETH(payable(bob)), prize);
        vm.prank(creator);
        assertEq(game.claimETH(payable(creator)), fee);
        vm.expectRevert(Ponziramid.NothingToClaim.selector);
        vm.prank(alice);
        game.claimETH(payable(alice));
    }

    function test_reentrantETHClaimCannotSpendTheSameDividendAgain() public {
        ReenterETH attacker = new ReenterETH();
        attacker.execute{value: 0.001 ether}(address(game), abi.encodeCall(game.build, (1, 0.001 ether)));
        _build(bob);
        bytes memory payload = abi.encodeCall(game.claimBrickETH, (1, payable(address(attacker))));
        attacker.arm(address(game), payload);
        attacker.execute(address(game), payload);
        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        assertEq(address(attacker).balance, 0.00005025 ether);
        (uint256 dividends,) = game.claimableBrickETH(1);
        assertEq(dividends, 0);
        _assertSolvent();
    }

    function test_earlierActiveBricksOnlyAndAllRoundingIsRecycled() public {
        uint256 a = _build(alice);
        uint256 b = _build(bob);
        _withdraw(alice, a);
        uint256 c = _build(carol);
        (uint256 aliceDiv,) = game.claimableBrickETH(a);
        (uint256 bobDiv,) = game.claimableBrickETH(b);
        (uint256 carolDiv,) = game.claimableBrickETH(c);
        assertEq(aliceDiv, 50_250_000_000_000);
        assertEq(bobDiv, 50_501_250_000_000);
        assertEq(carolDiv, 0);
        _expireAndFinalize();
        Ponziramid.Round memory r = game.rounds(1);
        (, uint256 bd) = game.claimableBrickETH(b);
        (, uint256 cd) = game.claimableBrickETH(c);
        uint256 seed = game.nextTomb();
        _claimBrick(bob, b);
        assertEq(game.nextTomb(), seed, "unclaimed diamond funds cannot be recycled");
        _claimBrick(carol, c);
        assertEq(game.nextTomb(), seed + r.diamondPool - bd - cd);
        assertEq(game.rounds(1).diamondRemaining, 0);
        assertEq(game.rounds(1).diamondClaimsRemaining, 0);
        _claimBrick(alice, a);
        assertEq(game.rounds(1).dividendsRemaining, 0);
        _assertSolvent();
    }

    function test_oldStoneAndAllClaimsSurviveManyRoundsWithoutAffectingNewTimer() public {
        uint256 oldBrick = _build(alice);
        _build(bob);
        _expireAndFinalize();
        (uint256 oldDiv, uint256 oldDiamond) = game.claimableBrickETH(oldBrick);
        uint256 oldPONZI = rewards.claimable(1, alice);
        _build(carol);
        _expireAndFinalize();
        _build(bob);
        uint256 expiry = game.rounds(3).expiresAt;
        vm.warp(vm.getBlockTimestamp() + 500 days);
        _withdraw(alice, oldBrick);
        assertEq(game.rounds(3).expiresAt, expiry);
        assertEq(_claimBrick(alice, oldBrick), oldDiv + oldDiamond);
        vm.prank(alice);
        assertEq(rewards.claim(1, alice), oldPONZI);
        _assertSolvent();
    }

    function test_finalizeDoesNotPayRejectingPharaohAndNextRoundStillWorks() public {
        ReenterETH builder = new ReenterETH();
        builder.execute{value: 0.001 ether}(address(game), abi.encodeCall(game.build, (1, 0.001 ether)));
        // Etch only this test player's receive behavior to reject all ETH.
        RejectETH reject = new RejectETH();
        vm.etch(address(builder), address(reject).code);
        _expireAndFinalize();
        assertGt(game.ethCredit(address(builder)), 0);
        _build(bob);
        assertEq(game.currentRound(), 2);
        assertGt(rewards.claimable(1, address(builder)), 0);
    }

    function test_unauthorizedETHClaimAndZeroRecipientFail() public {
        uint256 a = _build(alice);
        _build(bob);
        vm.expectRevert(Ponziramid.NotBrickOwner.selector);
        vm.prank(outsider);
        game.claimBrickETH(a, payable(outsider));
        vm.expectRevert(Ponziramid.InvalidAddress.selector);
        vm.prank(alice);
        game.claimBrickETH(a, payable(address(0)));
        vm.expectRevert(Ponziramid.NothingToClaim.selector);
        vm.prank(outsider);
        game.claimETH(payable(outsider));
    }

    function test_crossContractRefundDuringETHClaimCannotBypassGameGuard() public {
        ReenterETH attacker = new ReenterETH();
        attacker.execute{value: 0.001 ether}(address(game), abi.encodeCall(game.build, (1, 0.001 ether)));
        _build(bob);
        attacker.arm(address(vault), abi.encodeCall(vault.withdrawStone, (1, payable(address(attacker)))));
        attacker.execute(address(game), abi.encodeCall(game.claimBrickETH, (1, payable(address(attacker)))));
        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        assertFalse(game.bricks(1).withdrawn);
        assertEq(vault.stoneOf(address(attacker)), 0.0009 ether);
        assertEq(address(attacker).balance, 0.00005025 ether);
        _assertSolvent();
    }

    function test_reentrantCreditClaimCannotSpendPharaohPrizeAgain() public {
        ReenterETH attacker = new ReenterETH();
        attacker.execute{value: 0.001 ether}(address(game), abi.encodeCall(game.build, (1, 0.001 ether)));
        _expireAndFinalize();
        uint256 credit = game.ethCredit(address(attacker));
        bytes memory payload = abi.encodeCall(game.claimETH, (payable(address(attacker))));
        attacker.arm(address(game), payload);
        attacker.execute(address(game), payload);
        assertTrue(attacker.attempted());
        assertFalse(attacker.succeeded());
        assertEq(address(attacker).balance, credit);
        assertEq(game.ethCredit(address(attacker)), 0);
        _assertSolvent();
    }

    function test_forcedSurplusDoesNotCreateClaimsOrChangePrincipal() public {
        uint256 a = _build(alice);
        // Test-only balance injection models forced ETH without adding SELFDESTRUCT to delivered code.
        vm.deal(address(vault), address(vault).balance + 1 ether);
        vm.deal(address(game), address(game).balance + 1 ether);
        assertEq(vault.totalStone(), 0.0009 ether);
        assertEq(game.accountedETH(), 0.0001 ether);
        _withdraw(alice, a);
        assertEq(address(vault).balance, 1 ether);
        assertEq(vault.totalStone(), 0);
        _expireAndFinalize();
        _assertSolvent();
    }
}
