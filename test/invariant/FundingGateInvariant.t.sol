// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {Ponziramid} from "src/Ponziramid.sol";
import {PonziRewards} from "src/PonziRewards.sol";

/// @dev Drives a game deployed with a small creator allocation from an empty reward pool. Funding
/// arrives in random chunks through fund() and plain transfers, rounds are started, finished and
/// claimed, and the pool is repeatedly drained and refilled, so the gate, its one-time latch and
/// token conservation are all exercised across the boundary rather than from a pre-funded state.
contract FundingGateHandler is Test {
    uint256 public constant ROUND = 1_000_000 ether;

    Ponziramid public immutable game;
    PonziRewards public immutable rewards;
    LaunchToken public immutable token;
    address[3] public actors;

    uint256 public funded;
    uint256 public donated;
    uint256 public paidOut;
    uint256 public dustRecycled;
    uint256 public peakBalance;
    /// @dev Only fund() and a reservation observe the gate; a plain transfer that reaches it does not latch.
    bool public expectLatched;
    uint256 public roundsReserved;
    uint256 public rejectedForGate;
    uint256 public rejectedForUncommitted;
    uint256 public tokenClaims;
    mapping(uint256 => uint256) public participantsIn;
    mapping(uint256 => mapping(address => bool)) public participated;

    constructor(Ponziramid game_, LaunchToken token_, address[3] memory actors_) {
        game = game_;
        rewards = game_.rewards();
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1_000 ether);
        }
    }

    function fund(uint256 actorSeed, uint256 amountSeed) external {
        uint256 budget = token.balanceOf(address(this));
        if (budget == 0) return;
        uint256 amount = bound(amountSeed, 1, budget < 2 * ROUND ? budget : 2 * ROUND);
        address funder = actors[actorSeed % actors.length];
        token.transfer(funder, amount);
        vm.startPrank(funder);
        token.approve(address(rewards), amount);
        rewards.fund(amount);
        vm.stopPrank();
        funded += amount;
        _observe();
        if (token.balanceOf(address(rewards)) >= rewards.INITIAL_FUNDING()) expectLatched = true;
    }

    function donate(uint256 amountSeed) external {
        uint256 budget = token.balanceOf(address(this));
        if (budget == 0) return;
        uint256 amount = bound(amountSeed, 1, budget < ROUND ? budget : ROUND);
        token.transfer(address(rewards), amount);
        donated += amount;
        _observe();
    }

    function build(uint256 actorSeed) external {
        if (game.paused()) return;
        vm.warp(vm.getBlockTimestamp() + 60);
        (uint256 roundId, uint256 price,,) = game.quote();
        bool opening = roundId != game.currentRound();
        Ponziramid.Round memory current = game.rounds(game.currentRound());
        if (!opening && vm.getBlockTimestamp() >= current.expiresAt) return;
        address player = actors[actorSeed % actors.length];
        if (!opening && player == current.pharaoh) player = actors[(actorSeed + 1) % actors.length];

        if (opening && !rewards.canReserveRound()) {
            bytes4 reason = rewards.isFunded()
                ? PonziRewards.InsufficientUncommittedTokens.selector
                : PonziRewards.InitialFundingRequired.selector;
            uint256 committedBefore = rewards.committed();
            uint256 bricksBefore = game.brickCount();
            bool latchedBefore = rewards.fundingReached();
            vm.expectRevert(reason);
            vm.prank(player);
            game.build{value: price}(roundId, price);
            assertEq(rewards.committed(), committedBefore, "rejected start changed commitments");
            assertEq(game.brickCount(), bricksBefore, "rejected start created a brick");
            assertEq(game.currentRound(), roundId - 1, "rejected start opened a round");
            assertEq(rewards.fundingReached(), latchedBefore, "rejected start moved the latch");
            if (rewards.isFunded()) ++rejectedForUncommitted;
            else ++rejectedForGate;
            return;
        }
        vm.prank(player);
        game.build{value: price}(roundId, price);
        if (opening) {
            ++roundsReserved;
            expectLatched = true;
        }
        if (!participated[roundId][player]) {
            participated[roundId][player] = true;
            ++participantsIn[roundId];
        }
        _observe();
    }

    function finalize() external {
        uint256 roundId = game.currentRound();
        if (roundId == 0) return;
        Ponziramid.Round memory r = game.rounds(roundId);
        if (r.finalized) return;
        if (vm.getBlockTimestamp() < r.expiresAt) vm.warp(r.expiresAt);
        game.finalize();
        uint256 count = participantsIn[roundId];
        dustRecycled += 700_000 ether - (700_000 ether / count) * count;
    }

    function claimToken(uint256 roundSeed, uint256 actorSeed, uint256 recipientSeed) external {
        uint256 rounds = game.currentRound();
        if (rounds == 0) return;
        uint256 roundId = 1 + roundSeed % rounds;
        address player = actors[actorSeed % actors.length];
        uint256 due = rewards.claimable(roundId, player);
        if (due == 0) return;
        address recipient = actors[recipientSeed % actors.length];
        vm.prank(player);
        assertEq(rewards.claim(roundId, recipient), due);
        paidOut += due;
        ++tokenClaims;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 1 days + 1));
    }

    function pause(bool paused) external {
        vm.prank(game.owner());
        game.setPaused(paused);
    }

    function settleEverything() external {
        this.finalize();
        for (uint256 r = 1; r <= game.currentRound(); ++r) {
            for (uint256 i; i < actors.length; ++i) {
                this.claimToken(r - 1, i, i + 1);
            }
        }
    }

    function _observe() private {
        uint256 balance = token.balanceOf(address(rewards));
        if (balance > peakBalance) peakBalance = balance;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract FundingGateInvariantTest is Test {
    /// @dev Small enough that random funding crosses it and random play drains the pool within a run.
    uint256 internal constant GATE = 3_000_000 ether;
    uint256 internal constant ROUND = 1_000_000 ether;

    LaunchToken internal token;
    Ponziramid internal game;
    PonziRewards internal rewards;
    FundingGateHandler internal handler;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        game = new Ponziramid(address(token), makeAddr("gate-owner"), GATE);
        rewards = game.rewards();
        address[3] memory actors = [makeAddr("gate-a"), makeAddr("gate-b"), makeAddr("gate-c")];
        handler = new FundingGateHandler(game, token, actors);
        token.transfer(address(handler), 12 * ROUND);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.build.selector;
        selectors[3] = handler.finalize.selector;
        selectors[4] = handler.claimToken.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.pause.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_gateIsImmutableAndRoundsNeverStartBeforeItIsMet() public view {
        assertEq(rewards.INITIAL_FUNDING(), GATE, "the deployed gate changed");
        bool latched = rewards.fundingReached();
        assertEq(latched, handler.expectLatched(), "latch differs from fund() and reservation observations");
        if (game.currentRound() != 0) assertTrue(latched, "a round started before the gate latched");
        if (latched) {
            assertGe(handler.peakBalance(), GATE, "latched without the pool ever holding the gate");
            assertTrue(rewards.isFunded());
        } else {
            assertEq(rewards.committed(), 0);
            assertEq(handler.roundsReserved(), 0);
            assertEq(game.currentRound(), 0);
            assertEq(rewards.isFunded(), token.balanceOf(address(rewards)) >= GATE);
        }
    }

    function invariant_poolTokensAreConservedAndBackEveryCommitment() public view {
        uint256 balance = token.balanceOf(address(rewards));
        assertEq(
            balance, handler.funded() + handler.donated() - handler.paidOut(), "tokens moved outside claims"
        );
        assertEq(rewards.totalFunded(), handler.funded());
        assertGe(balance, rewards.committed(), "commitments exceed the tokens held");
        assertEq(
            rewards.committed(),
            handler.roundsReserved() * ROUND - handler.paidOut() - handler.dustRecycled(),
            "committed drifted from reservations minus payouts and dust"
        );
        assertLe(
            handler.roundsReserved() * ROUND,
            handler.funded() + handler.donated(),
            "reserved more than deposited"
        );
        assertEq(rewards.uncommitted(), balance - rewards.committed());
    }

    function afterInvariant() public {
        handler.settleEverything();
        assertEq(rewards.committed(), 0, "every reserved token is claimable once rounds finish");
        assertEq(token.balanceOf(address(rewards)), handler.funded() + handler.donated() - handler.paidOut());
    }

    /// @dev Pins one explicit sequence across the gate, through depletion and a refill, so the handler is
    /// known to reach the states the random campaign is meant to cover.
    function test_handlerCrossesTheGateDrainsThePoolAndRefills() public {
        handler.build(0);
        assertEq(handler.rejectedForGate(), 1);
        handler.fund(0, 2 * ROUND);
        handler.fund(1, ROUND - 1);
        assertEq(token.balanceOf(address(rewards)), GATE - 1);
        handler.build(1);
        assertEq(handler.rejectedForGate(), 2);
        assertFalse(rewards.fundingReached());
        handler.donate(1);
        assertTrue(rewards.isFunded());
        assertFalse(rewards.fundingReached());
        handler.build(2);
        assertTrue(rewards.fundingReached());
        assertEq(handler.roundsReserved(), 1);
        for (uint256 i; i < 2; ++i) {
            handler.finalize();
            handler.build(i);
        }
        assertEq(handler.roundsReserved(), 3);
        assertEq(rewards.uncommitted(), 0);
        handler.finalize();
        handler.build(0);
        assertEq(handler.rejectedForUncommitted(), 1);
        handler.settleEverything();
        assertEq(token.balanceOf(address(rewards)), 0);
        assertTrue(rewards.fundingReached());
        handler.build(1);
        assertEq(handler.rejectedForUncommitted(), 2);
        handler.fund(1, ROUND);
        handler.build(1);
        assertEq(handler.roundsReserved(), 4);
        assertEq(game.currentRound(), 4);
        invariant_gateIsImmutableAndRoundsNeverStartBeforeItIsMet();
        invariant_poolTokensAreConservedAndBackEveryCommitment();
    }
}
