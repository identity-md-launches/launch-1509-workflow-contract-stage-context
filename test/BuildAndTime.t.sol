// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GameFixture} from "./helpers/GameFixture.sol";
import {Ponziramid} from "../src/Ponziramid.sol";
import {PonziRewards} from "../src/PonziRewards.sol";

contract BuildAndTimeTest is GameFixture {
    function test_firstBuildStartsFundedRoundAndSeparatesPrincipal() public {
        uint256 beforeAlice = alice.balance;
        uint256 id = _build(alice);
        Ponziramid.Round memory r = game.rounds(1);
        assertEq(id, 1);
        assertEq(r.startedAt, vm.getBlockTimestamp());
        assertEq(r.expiresAt, vm.getBlockTimestamp() + 1 days);
        assertEq(r.pharaoh, alice);
        assertEq(r.activeBricks, 1);
        assertEq(r.activeStone, 0.0009 ether);
        assertEq(alice.balance, beforeAlice - 0.001 ether);
        assertEq(address(vault).balance, 0.0009 ether);
        assertEq(vault.stoneOf(alice), 0.0009 ether);
        assertEq(address(game).balance, 0.0001 ether);
        assertEq(r.tomb, 0.00009 ether);
        assertEq(game.ethCredit(creator), 0.00001 ether);
        assertEq(rewards.committed(), 1_000_000 ether);
        assertTrue(rewards.participated(1, alice));
        assertEq(game.bricks(id).indexInRound, 0);
        _assertSolvent();
    }

    function test_unfundedAndPartiallyFundedGameCannotStart() public {
        Ponziramid unfunded = new Ponziramid(address(token), creator, CREATOR_ALLOCATION);
        PonziRewards pool = unfunded.rewards();
        vm.expectRevert(PonziRewards.InitialFundingRequired.selector);
        vm.prank(alice);
        unfunded.build{value: 0.001 ether}(1, 0.001 ether);
        token.approve(address(pool), 1_000_000 ether);
        pool.fund(1_000_000 ether);
        vm.expectRevert(PonziRewards.InitialFundingRequired.selector);
        vm.prank(alice);
        unfunded.build{value: 0.001 ether}(1, 0.001 ether);
        assertEq(unfunded.currentRound(), 0);
        assertEq(unfunded.brickCount(), 0);
        assertEq(pool.committed(), 0);
        assertEq(address(unfunded.vault()).balance, 0);
    }

    function test_exactPriceAndRoundQuoteRequired() public {
        vm.expectRevert(Ponziramid.StaleRound.selector);
        vm.prank(alice);
        game.build{value: 0.001 ether}(2, 0.001 ether);
        vm.expectRevert(Ponziramid.IncorrectPrice.selector);
        vm.prank(alice);
        game.build{value: 0.001 ether + 1}(1, 0.001 ether);
        _build(alice);
        vm.expectRevert(Ponziramid.IncorrectPrice.selector);
        vm.prank(bob);
        game.build{value: 0.001 ether}(1, 0.001 ether);
        assertEq(game.brickCount(), 1);
    }

    function test_cooldownIsPerWalletAndAcrossRounds() public {
        _build(alice);
        _build(bob);
        (, uint256 price,,) = game.quote();
        vm.warp(vm.getBlockTimestamp() + 59);
        vm.expectRevert(Ponziramid.Cooldown.selector);
        vm.prank(alice);
        game.build{value: price}(1, price);
        vm.warp(vm.getBlockTimestamp() + 1);
        _build(alice);
        // End a round immediately after a build using a late withdrawal, then preserve cooldown.
        vm.warp(game.rounds(1).expiresAt - 1);
        _withdraw(bob, 2);
        game.finalize();
        _build(alice);
        assertEq(game.currentRound(), 2);
        _build(bob);
        (, price,,) = game.quote();
        vm.expectRevert(Ponziramid.Cooldown.selector);
        vm.prank(alice);
        game.build{value: price}(2, price);
    }

    function test_currentPharaohCannotBuildConsecutivelyEvenAfterWithdrawing() public {
        uint256 id = _build(alice);
        _withdraw(alice, id);
        vm.warp(vm.getBlockTimestamp() + 60);
        (, uint256 price,,) = game.quote();
        vm.expectRevert(Ponziramid.ConsecutivePharaoh.selector);
        vm.prank(alice);
        game.build{value: price}(1, price);
        _build(bob);
        assertEq(game.rounds(1).pharaoh, bob);
    }

    function test_placementExtendsOneDayButNeverPastSevenDays() public {
        _build(alice);
        uint256 started = game.rounds(1).startedAt;
        for (uint256 i = 1; i <= 8; ++i) {
            vm.warp(started + i * 20 hours);
            _build(i % 2 == 0 ? alice : bob);
            uint256 expected = vm.getBlockTimestamp() + 1 days;
            if (expected > started + 7 days) expected = started + 7 days;
            assertEq(game.rounds(1).expiresAt, expected);
        }
        vm.warp(started + 7 days);
        (, uint256 price,,) = game.quote();
        vm.expectRevert(Ponziramid.RoundExpired.selector);
        vm.prank(bob);
        game.build{value: price}(1, price);
        game.finalize();
    }

    function test_exactExpiryBlocksBuildingAndAllowsPermissionlessFinalization() public {
        _build(alice);
        (, uint256 price,,) = game.quote();
        vm.warp(game.rounds(1).expiresAt - 1);
        vm.expectRevert(Ponziramid.NotExpired.selector);
        game.finalize();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(Ponziramid.RoundExpired.selector);
        vm.prank(bob);
        game.build{value: price}(1, price);
        vm.prank(outsider);
        game.finalize();
        vm.expectRevert(Ponziramid.AlreadyFinalized.selector);
        game.finalize();
        (, price,,) = game.quote();
        vm.expectRevert(Ponziramid.StaleRound.selector);
        vm.prank(bob);
        game.build{value: price}(1, price);
        _build(bob);
        assertEq(game.bricks(2).indexInRound, 0);
        assertEq(game.bricks(2).roundId, 2);
    }

    function test_pauseOnlyOwnerAndOnlyStopsBuilding() public {
        uint256 id = _build(alice);
        vm.expectRevert(Ponziramid.OnlyOwner.selector);
        vm.prank(outsider);
        game.setPaused(true);
        vm.prank(creator);
        game.setPaused(true);
        (, uint256 price,,) = game.quote();
        vm.expectRevert(Ponziramid.Paused.selector);
        vm.prank(bob);
        game.build{value: price}(1, price);
        _withdraw(alice, id);
        _expireAndFinalize();
        vm.prank(alice);
        rewards.claim(1, alice);
        vm.prank(alice);
        game.claimETH(payable(alice));
        vm.prank(creator);
        game.claimETH(payable(creator));
        vm.prank(creator);
        game.setPaused(false);
        _build(bob);
        _assertSolvent();
    }

    function test_finalizeCannotRunWithoutRound() public {
        vm.expectRevert(Ponziramid.NoRound.selector);
        game.finalize();
    }

    function test_fullBankRunEndsRoundAndDoesNotResetWalletCooldown() public {
        // 144 refunds deduct exactly 24 hours from the most recent placement's timer.
        for (uint256 i; i < 144; ++i) {
            vm.warp(vm.getBlockTimestamp() + 60);
            _build(i % 2 == 0 ? alice : bob);
        }
        for (uint256 id = 1; id <= 144; ++id) {
            _withdraw(game.bricks(id).player, id);
        }
        assertEq(game.rounds(1).expiresAt, vm.getBlockTimestamp());
        assertEq(game.rounds(1).activeBricks, 0);
        assertEq(vault.totalStone(), 0);
        game.finalize();
        vm.expectRevert(Ponziramid.Cooldown.selector);
        vm.prank(bob);
        game.build{value: 0.001 ether}(2, 0.001 ether);
        assertEq(game.currentRound(), 1);
        assertEq(rewards.committed(), 1_000_000 ether);
        vm.warp(vm.getBlockTimestamp() + 60);
        _build(bob);
        assertEq(game.currentRound(), 2);
        _assertSolvent();
    }

    function testFuzz_priceAndWeiSplits(uint8 count) public {
        uint256 n = bound(count, 1, 60);
        uint256 expectedPrice = 0.001 ether;
        uint256 expectedStone;
        uint256 expectedMortar;
        uint256 expectedTomb;
        uint256 expectedOwner;
        uint256 expectedDividends;
        for (uint256 i; i < n; ++i) {
            vm.warp(vm.getBlockTimestamp() + 60);
            (uint256 roundId, uint256 price, uint256 stone, uint256 mortar) = game.quote();
            assertEq(roundId, 1);
            assertEq(price, expectedPrice);
            assertEq(stone, price * 9 / 10);
            assertEq(mortar, price - stone);
            uint256 distributed = i == 0 ? 0 : (mortar / 2 / i) * i;
            expectedStone += stone;
            expectedMortar += mortar;
            expectedOwner += mortar / 10;
            expectedTomb += mortar - mortar / 10 - distributed;
            expectedDividends += distributed;
            uint256 id = _build(i % 2 == 0 ? alice : bob);
            assertEq(game.bricks(id).indexInRound, i);
            expectedPrice = expectedPrice * 1005 / 1000;
        }
        Ponziramid.Round memory r = game.rounds(1);
        assertEq(r.tomb, expectedTomb);
        assertEq(r.dividendsRemaining, expectedDividends);
        assertEq(game.ethCredit(creator), expectedOwner);
        assertEq(address(vault).balance, expectedStone);
        assertEq(address(game).balance, expectedMortar);
        assertEq(expectedTomb + expectedDividends + expectedOwner, expectedMortar);
        _assertSolvent();
    }
}
