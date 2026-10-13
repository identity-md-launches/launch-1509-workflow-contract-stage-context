// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameFixture, RejectETH} from "../helpers/GameFixture.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Ponziramid} from "../../src/Ponziramid.sol";
import {StoneVault} from "../../src/StoneVault.sol";
import {PonziRewards} from "../../src/PonziRewards.sol";

contract GameHandler is Test {
    Ponziramid public immutable game;
    StoneVault public immutable vault;
    PonziRewards public immutable rewards;
    LaunchToken public immutable token;
    RejectETH public immutable reject;
    address[] public actors;
    uint256 public stoneDeposited;
    uint256 public stoneReturned;
    uint256 public mortarDeposited;
    uint256 public mortarPaid;
    uint256 public tokensAdded;
    uint256 public tokensPaid;
    uint256 public builds;
    uint256 public withdrawals;
    uint256 public finalizations;
    uint256 public ethClaims;
    uint256 public tokenClaims;

    constructor(Ponziramid game_, LaunchToken token_, address[] memory actors_) {
        game = game_;
        vault = game_.vault();
        rewards = game_.rewards();
        token = token_;
        reject = new RejectETH();
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 100_000 ether);
        }
    }

    function build(uint256 actorSeed) external {
        if (game.paused()) return;
        address player = actors[actorSeed % actors.length];
        uint256 roundId = game.currentRound();
        if (roundId != 0) {
            Ponziramid.Round memory r = game.rounds(roundId);
            if (!r.finalized && (vm.getBlockTimestamp() >= r.expiresAt || r.pharaoh == player)) return;
        }
        uint256 last = game.lastBuildAt(player);
        if (last != 0 && vm.getBlockTimestamp() - last < 60) return;
        (uint256 quoteRound, uint256 price, uint256 stone, uint256 mortar) = game.quote();
        if (player.balance < price || !rewards.canReserveRound()) return;
        vm.prank(player);
        game.build{value: price}(quoteRound, price);
        stoneDeposited += stone;
        mortarDeposited += mortar;
        ++builds;
    }

    function withdraw(uint256 brickSeed) external {
        uint256 id = _brickId(brickSeed);
        if (id == 0) return;
        Ponziramid.Brick memory b = game.bricks(id);
        if (b.withdrawn) return;
        uint256 beforeBalance = b.player.balance;
        vm.prank(b.player);
        vault.withdrawStone(id, payable(b.player));
        assertEq(b.player.balance - beforeBalance, b.stone);
        stoneReturned += b.stone;
        ++withdrawals;
    }

    function claimBrick(uint256 brickSeed) external {
        uint256 id = _brickId(brickSeed);
        if (id == 0) return;
        Ponziramid.Brick memory b = game.bricks(id);
        (uint256 div, uint256 diamond) = game.claimableBrickETH(id);
        bool unsettledDiamond = game.rounds(b.roundId).finalized && !b.exitedBeforeExpiry && !b.diamondClaimed;
        if (div + diamond == 0 && !unsettledDiamond) return;
        uint256 beforeBalance = b.player.balance;
        vm.prank(b.player);
        uint256 paid = game.claimBrickETH(id, payable(b.player));
        assertEq(paid, div + diamond);
        assertEq(b.player.balance - beforeBalance, paid);
        mortarPaid += paid;
        ++ethClaims;
    }

    function claimCredit(uint256 actorSeed) external {
        address player = actors[actorSeed % actors.length];
        uint256 credit = game.ethCredit(player);
        if (credit == 0) return;
        uint256 beforeBalance = player.balance;
        vm.prank(player);
        assertEq(game.claimETH(payable(player)), credit);
        assertEq(player.balance - beforeBalance, credit);
        mortarPaid += credit;
        ++ethClaims;
    }

    function claimToken(uint256 roundSeed, uint256 actorSeed) external {
        uint256 current = game.currentRound();
        if (current == 0) return;
        uint256 roundId = 1 + roundSeed % current;
        address player = actors[actorSeed % actors.length];
        uint256 amount = rewards.claimable(roundId, player);
        if (amount == 0) return;
        uint256 beforeBalance = token.balanceOf(player);
        vm.prank(player);
        assertEq(rewards.claim(roundId, player), amount);
        assertEq(token.balanceOf(player) - beforeBalance, amount);
        tokensPaid += amount;
        ++tokenClaims;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + secondsSeed % (36 hours + 1));
    }

    function finalize() external {
        uint256 current = game.currentRound();
        if (current == 0) return;
        Ponziramid.Round memory r = game.rounds(current);
        if (r.finalized || vm.getBlockTimestamp() < r.expiresAt) return;
        game.finalize();
        ++finalizations;
    }

    function pause(bool paused) external {
        vm.prank(game.owner());
        game.setPaused(paused);
    }

    function fund(uint256 amountSeed) external {
        uint256 amount = 1 + amountSeed % (100 ether);
        if (token.balanceOf(address(this)) < amount) return;
        token.approve(address(rewards), amount);
        rewards.fund(amount);
        tokensAdded += amount;
    }

    function rejectedWithdrawal(uint256 brickSeed) external {
        uint256 id = _brickId(brickSeed);
        if (id == 0) return;
        Ponziramid.Brick memory b = game.bricks(id);
        if (b.withdrawn) return;
        uint256 balance = address(vault).balance;
        bytes32 beforeRound = keccak256(abi.encode(game.rounds(b.roundId)));
        vm.expectRevert(StoneVault.TransferFailed.selector);
        vm.prank(b.player);
        vault.withdrawStone(id, payable(address(reject)));
        assertEq(address(vault).balance, balance);
        assertEq(keccak256(abi.encode(game.rounds(b.roundId))), beforeRound);
        assertEq(keccak256(abi.encode(game.bricks(id))), keccak256(abi.encode(b)));
    }

    function rejectedClaim(uint256 brickSeed) external {
        uint256 id = _brickId(brickSeed);
        if (id == 0) return;
        Ponziramid.Brick memory b = game.bricks(id);
        (uint256 div, uint256 diamond) = game.claimableBrickETH(id);
        if (div + diamond == 0) return;
        bytes32 beforeRound = keccak256(abi.encode(game.rounds(b.roundId)));
        uint256 balance = address(game).balance;
        uint256 seed = game.nextTomb();
        vm.expectRevert(Ponziramid.TransferFailed.selector);
        vm.prank(b.player);
        game.claimBrickETH(id, payable(address(reject)));
        assertEq(address(game).balance, balance);
        assertEq(game.nextTomb(), seed);
        assertEq(keccak256(abi.encode(game.rounds(b.roundId))), beforeRound);
        assertEq(keccak256(abi.encode(game.bricks(id))), keccak256(abi.encode(b)));
    }

    function _brickId(uint256 seed) private view returns (uint256) {
        uint256 count = game.brickCount();
        return count == 0 ? 0 : 1 + seed % count;
    }
}

contract GameInvariantTest is GameFixture {
    GameHandler internal handler;
    address[] internal actors;

    function setUp() public override {
        super.setUp();
        actors.push(alice);
        actors.push(bob);
        actors.push(carol);
        actors.push(outsider);
        actors.push(creator);
        handler = new GameHandler(game, token, actors);
        token.transfer(address(handler), 100_000_000 ether);
        handler.build(0);
        handler.build(1);

        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.build.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.claimBrick.selector;
        selectors[3] = handler.claimCredit.selector;
        selectors[4] = handler.claimToken.selector;
        selectors[5] = handler.advanceTime.selector;
        selectors[6] = handler.finalize.selector;
        selectors[7] = handler.pause.selector;
        selectors[8] = handler.fund.selector;
        selectors[9] = handler.rejectedWithdrawal.selector;
        selectors[10] = handler.rejectedClaim.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_principalIsFullyBackedAndCanOnlyReturnToItsPlayer() public view {
        uint256 outstanding;
        uint256 count = game.brickCount();
        uint256[] memory expectedPlayerStone = new uint256[](actors.length);
        for (uint256 i = 1; i <= count; ++i) {
            Ponziramid.Brick memory b = game.bricks(i);
            (address depositor, uint256 amount) = vault.deposits(i);
            assertEq(depositor, b.player);
            assertEq(amount, b.withdrawn ? 0 : b.stone);
            outstanding += amount;
            for (uint256 j; j < actors.length; ++j) {
                if (actors[j] == b.player) expectedPlayerStone[j] += amount;
            }
        }
        assertEq(vault.totalStone(), outstanding);
        assertEq(address(vault).balance, outstanding);
        assertEq(outstanding, handler.stoneDeposited() - handler.stoneReturned());
        uint256 playerTotals;
        for (uint256 i; i < actors.length; ++i) {
            assertEq(vault.stoneOf(actors[i]), expectedPlayerStone[i]);
            playerTotals += vault.stoneOf(actors[i]);
        }
        assertEq(playerTotals, outstanding);
    }

    function invariant_everyWeiOfMortarHasExactlyOneLiability() public view {
        uint256 liabilities = game.nextTomb() + game.totalCredits();
        for (uint256 i = 1; i <= game.currentRound(); ++i) {
            Ponziramid.Round memory r = game.rounds(i);
            liabilities += r.dividendsRemaining;
            liabilities += r.finalized ? r.diamondRemaining : r.tomb;
        }
        assertEq(address(game).balance, liabilities);
        assertEq(game.accountedETH(), liabilities);
        assertEq(game.totalMortarReceived(), handler.mortarDeposited());
        assertEq(game.totalEthPaid(), handler.mortarPaid());
        assertEq(liabilities, handler.mortarDeposited() - handler.mortarPaid());
        uint256 credits;
        for (uint256 i; i < actors.length; ++i) {
            credits += game.ethCredit(actors[i]);
        }
        assertEq(game.totalCredits(), credits);
    }

    function invariant_brickEarningsAndActiveSnapshotMatchRoundAccounting() public view {
        uint256 roundCount = game.currentRound();
        uint256[] memory active = new uint256[](roundCount + 1);
        uint256[] memory stone = new uint256[](roundCount + 1);
        uint256[] memory dividends = new uint256[](roundCount + 1);
        uint256[] memory diamonds = new uint256[](roundCount + 1);
        uint256[] memory unclaimedDiamondBricks = new uint256[](roundCount + 1);
        uint256[] memory placed = new uint256[](roundCount + 1);
        for (uint256 i = 1; i <= game.brickCount(); ++i) {
            Ponziramid.Brick memory b = game.bricks(i);
            uint256 roundId = b.roundId;
            assertEq(b.indexInRound, placed[roundId]++);
            if (!b.exitedBeforeExpiry) {
                ++active[roundId];
                stone[roundId] += b.stone;
                if (!b.diamondClaimed) ++unclaimedDiamondBricks[roundId];
            }
            (uint256 div, uint256 diamond) = game.claimableBrickETH(i);
            dividends[roundId] += div;
            diamonds[roundId] += diamond;
        }
        for (uint256 i = 1; i <= roundCount; ++i) {
            Ponziramid.Round memory r = game.rounds(i);
            assertEq(r.activeBricks, active[i]);
            assertEq(r.activeStone, stone[i]);
            assertEq(r.placedBricks, placed[i]);
            assertEq(r.dividendsRemaining, dividends[i]);
            assertLe(r.expiresAt, r.startedAt + 7 days);
            if (r.finalized) {
                assertEq(r.diamondClaimsRemaining, unclaimedDiamondBricks[i]);
                assertGe(r.diamondRemaining, diamonds[i]);
                // Each eligible brick truncates less than one wei. Dust stays reserved until all settle.
                assertLe(r.diamondRemaining - diamonds[i], r.activeBricks);
            }
        }
    }

    function invariant_rewardsAreBackedAndOnlyVerifiedClaimsReduceBalances() public view {
        uint256 promised;
        uint256 pending;
        uint256 roundCount = game.currentRound();
        for (uint256 i = 1; i <= roundCount; ++i) {
            (
                bool reserved,
                bool finalized,
                address pharaoh,
                uint256 count,
                uint256 share,
                uint256 remaining
            ) = rewards.rounds(i);
            assertTrue(reserved);
            assertEq(finalized, game.rounds(i).finalized);
            promised += remaining;
            uint256 participants;
            for (uint256 j; j < actors.length; ++j) {
                address actor = actors[j];
                if (rewards.participated(i, actor)) ++participants;
                uint256 claim = rewards.claimable(i, actor);
                if (claim != 0) {
                    assertTrue(rewards.participated(i, actor));
                    assertFalse(rewards.claimed(i, actor));
                    assertEq(claim, share + (actor == pharaoh ? 300_000 ether : 0));
                    pending += claim;
                }
            }
            assertEq(participants, count);
            if (!finalized) pending += 1_000_000 ether;
        }
        assertEq(rewards.committed(), promised);
        assertEq(promised, pending);
        assertGe(token.balanceOf(address(rewards)), promised);
        assertEq(
            token.balanceOf(address(rewards)),
            700_000_000 ether + handler.tokensAdded() - handler.tokensPaid()
        );
        assertEq(rewards.uncommitted() + rewards.committed(), token.balanceOf(address(rewards)));
        assertEq(token.totalSupply(), 1e27);
    }

    /// @dev End every fuzz campaign by exercising an exit for every outstanding obligation.
    function afterInvariant() public {
        handler.pause(false);
        Ponziramid.Round memory r = game.rounds(game.currentRound());
        if (!r.finalized) {
            if (vm.getBlockTimestamp() < r.expiresAt) vm.warp(r.expiresAt);
            handler.finalize();
        }
        for (uint256 i; i < game.brickCount(); ++i) {
            handler.withdraw(i);
            handler.claimBrick(i);
        }
        for (uint256 i; i < actors.length; ++i) {
            handler.claimCredit(i);
            for (uint256 j; j < game.currentRound(); ++j) {
                handler.claimToken(j, i);
            }
        }
        assertEq(address(vault).balance, 0);
        assertEq(vault.totalStone(), 0);
        assertEq(handler.stoneDeposited(), handler.stoneReturned());
        assertEq(address(game).balance, game.nextTomb());
        assertEq(rewards.committed(), 0);
        invariant_everyWeiOfMortarHasExactlyOneLiability();
        invariant_rewardsAreBackedAndOnlyVerifiedClaimsReduceBalances();
    }
}
