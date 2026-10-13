// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameFixture} from "../helpers/GameFixture.sol";
import {LaunchToken} from "src/LaunchToken.sol";
import {Ponziramid} from "src/Ponziramid.sol";
import {StoneVault} from "src/StoneVault.sol";
import {PonziRewards} from "src/PonziRewards.sol";

/// @dev Deliberately slow oracle: credits each earlier brick individually on each purchase.
/// It never derives entitlements from claimable(), the on-chain accumulator, or accounting totals.
contract PayoutOracleHandler is Test {
    struct ExpectedBrick {
        address player;
        uint256 roundId;
        uint256 stone;
        uint256 dividend;
        uint256 diamond;
        bool withdrawn;
        bool eligible;
        bool diamondSettled;
    }

    struct ExpectedRound {
        uint256 start;
        uint256 end;
        uint256 price;
        uint256 placed;
        uint256 active;
        uint256 stone;
        uint256 tomb;
        uint256 diamondDust;
        uint256 unsettledDiamonds;
        address pharaoh;
        bool finalized;
    }

    Ponziramid public immutable game;
    StoneVault public immutable vault;
    PonziRewards public immutable rewards;
    LaunchToken public immutable token;
    address[5] public actors;
    ExpectedBrick[] internal bricks;
    mapping(uint256 => ExpectedRound) internal rounds;
    mapping(uint256 => mapping(address => bool)) internal participants;
    mapping(uint256 => mapping(address => uint256)) internal tokenDue;
    mapping(address => uint256) internal credit;
    mapping(address => uint256) internal ethBalance;
    mapping(address => uint256) internal tokenBalance;
    uint256 public roundCount;
    uint256 public expectedNextTomb;
    uint256 public stoneHeld;
    uint256 public mortarHeld;
    uint256 public tokensHeld = 700_000_000 ether;
    uint256 public tokensCommitted;
    uint256 public vaultSurplus;
    uint256 public gameSurplus;
    uint256 public builds;
    uint256 public refunds;
    uint256 public settlements;
    uint256 public finalizedRounds;

    constructor(Ponziramid game_, LaunchToken token_, address[5] memory actors_) {
        game = game_;
        vault = game_.vault();
        rewards = game_.rewards();
        token = token_;
        actors = actors_;
        for (uint256 i; i < actors.length; ++i) {
            vm.deal(actors[i], 1_000_000 ether);
            ethBalance[actors[i]] = 1_000_000 ether;
        }
        bricks.push(); // On-chain brick identifiers start at one.
    }

    function build(uint256 actorSeed) public {
        if (game.paused()) return;
        vm.warp(vm.getBlockTimestamp() + 60);
        ExpectedRound storage current = rounds[roundCount];
        if (roundCount != 0 && !current.finalized && vm.getBlockTimestamp() >= current.end) return;
        bool opening = roundCount == 0 || current.finalized;
        uint256 id = opening ? roundCount + 1 : roundCount;
        address player = actors[actorSeed % actors.length];
        if (!opening && player == current.pharaoh) {
            player = actors[(actorSeed % actors.length + 1) % actors.length];
        }
        uint256 price = opening ? 0.001 ether : current.price;
        vm.prank(player);
        uint256 brickId = game.build{value: price}(id, price);
        assertEq(brickId, bricks.length);
        if (opening) {
            roundCount = id;
            rounds[id].start = vm.getBlockTimestamp();
            rounds[id].tomb = expectedNextTomb;
            expectedNextTomb = 0;
            tokensCommitted += 1_000_000 ether;
        }
        ExpectedRound storage r = rounds[id];
        uint256 stone = price * 9 / 10;
        uint256 mortar = price - stone;
        uint256 distributed;
        if (r.active != 0) {
            uint256 each = (mortar / 2) / r.active;
            for (uint256 i = 1; i < bricks.length; ++i) {
                ExpectedBrick storage earlier = bricks[i];
                if (earlier.roundId == id && earlier.eligible) {
                    earlier.dividend += each;
                    distributed += each;
                }
            }
        }
        credit[game.owner()] += mortar / 10;
        r.tomb += mortar - mortar / 10 - distributed;
        r.active++;
        r.placed++;
        r.stone += stone;
        r.pharaoh = player;
        r.price = price + price / 200;
        r.end = vm.getBlockTimestamp() + 1 days;
        if (r.end > r.start + 7 days) r.end = r.start + 7 days;
        participants[id][player] = true;
        bricks.push(ExpectedBrick(player, id, stone, 0, 0, false, true, false));
        stoneHeld += stone;
        mortarHeld += mortar;
        ethBalance[player] -= price;
        ++builds;
    }

    function withdraw(uint256 brickSeed, uint256 recipientSeed) public {
        uint256 id = 1 + brickSeed % (bricks.length - 1);
        ExpectedBrick storage b = bricks[id];
        if (b.withdrawn) return;
        address recipient = actors[recipientSeed % actors.length];
        vm.prank(b.player);
        vault.withdrawStone(id, payable(recipient));
        b.withdrawn = true;
        stoneHeld -= b.stone;
        ethBalance[recipient] += b.stone;
        ExpectedRound storage r = rounds[b.roundId];
        if (!r.finalized && vm.getBlockTimestamp() < r.end) {
            b.eligible = false;
            --r.active;
            r.stone -= b.stone;
            uint256 left = r.end - vm.getBlockTimestamp();
            r.end = left <= 600 ? vm.getBlockTimestamp() : r.end - 600;
        }
        ++refunds;
    }

    function claimBrick(uint256 brickSeed, uint256 recipientSeed) public {
        uint256 id = 1 + brickSeed % (bricks.length - 1);
        ExpectedBrick storage b = bricks[id];
        ExpectedRound storage r = rounds[b.roundId];
        bool settleDiamond = r.finalized && b.eligible && !b.diamondSettled;
        uint256 due = b.dividend + b.diamond;
        if (due == 0 && !settleDiamond) return;
        address recipient = actors[recipientSeed % actors.length];
        vm.prank(b.player);
        assertEq(game.claimBrickETH(id, payable(recipient)), due, "incorrect brick payout");
        b.dividend = 0;
        b.diamond = 0;
        if (settleDiamond) {
            b.diamondSettled = true;
            if (--r.unsettledDiamonds == 0) {
                expectedNextTomb += r.diamondDust;
                r.diamondDust = 0;
            }
        }
        ethBalance[recipient] += due;
        mortarHeld -= due;
        ++settlements;
    }

    function claimCredit(uint256 actorSeed, uint256 recipientSeed) public {
        address player = actors[actorSeed % actors.length];
        uint256 due = credit[player];
        if (due == 0) return;
        address recipient = actors[recipientSeed % actors.length];
        vm.prank(player);
        assertEq(game.claimETH(payable(recipient)), due, "incorrect Pharaoh or owner payout");
        credit[player] = 0;
        ethBalance[recipient] += due;
        mortarHeld -= due;
        ++settlements;
    }

    function claimToken(uint256 roundSeed, uint256 actorSeed, uint256 recipientSeed) public {
        uint256 id = 1 + roundSeed % roundCount;
        address player = actors[actorSeed % actors.length];
        uint256 due = tokenDue[id][player];
        if (due == 0) return;
        address recipient = actors[recipientSeed % actors.length];
        vm.prank(player);
        assertEq(rewards.claim(id, recipient), due, "incorrect participant reward");
        tokenDue[id][player] = 0;
        tokensHeld -= due;
        tokensCommitted -= due;
        tokenBalance[recipient] += due;
        ++settlements;
    }

    function finalizeAtExpiry() public {
        ExpectedRound storage r = rounds[roundCount];
        if (roundCount == 0 || r.finalized) return;
        if (vm.getBlockTimestamp() < r.end) vm.warp(r.end);
        game.finalize();
        r.finalized = true;
        uint256 prize = r.tomb * 2 / 5;
        credit[r.pharaoh] += prize;
        expectedNextTomb += r.tomb - 2 * prize;
        if (r.active == 0) {
            expectedNextTomb += prize;
        } else {
            uint256 allocated;
            for (uint256 i = 1; i < bricks.length; ++i) {
                ExpectedBrick storage b = bricks[i];
                if (b.roundId == roundCount && b.eligible) {
                    b.diamond = prize * b.stone / r.stone;
                    allocated += b.diamond;
                    ++r.unsettledDiamonds;
                }
            }
            r.diamondDust = prize - allocated;
        }
        uint256 count;
        for (uint256 i; i < actors.length; ++i) {
            if (participants[roundCount][actors[i]]) ++count;
        }
        uint256 each = 700_000 ether / count;
        for (uint256 i; i < actors.length; ++i) {
            address player = actors[i];
            if (participants[roundCount][player]) {
                tokenDue[roundCount][player] = each + (player == r.pharaoh ? 300_000 ether : 0);
            }
        }
        tokensCommitted -= 700_000 ether - each * count;
        ++finalizedRounds;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + bound(secondsSeed, 0, 1 days + 1));
    }

    function pause(bool paused) public {
        vm.prank(game.owner());
        game.setPaused(paused);
    }

    function donate(uint256 amountSeed, uint8 destination) external {
        uint256 amount = bound(amountSeed, 1, 1 ether);
        if (destination % 3 == 0) {
            // Forced ETH affects physical assets, never player entitlements.
            vm.deal(address(vault), address(vault).balance + amount);
            vaultSurplus += amount;
        } else if (destination % 3 == 1) {
            vm.deal(address(game), address(game).balance + amount);
            gameSurplus += amount;
        } else {
            token.transfer(address(rewards), amount);
            tokensHeld += amount;
        }
    }

    function assertModel() public view {
        assertEq(game.brickCount(), bricks.length - 1);
        assertEq(game.currentRound(), roundCount);
        assertEq(game.nextTomb(), expectedNextTomb);
        assertEq(vault.totalStone(), stoneHeld);
        assertEq(address(vault).balance, stoneHeld + vaultSurplus);
        assertEq(game.accountedETH(), mortarHeld);
        assertEq(address(game).balance, mortarHeld + gameSurplus);
        assertEq(token.balanceOf(address(rewards)), tokensHeld);
        assertEq(rewards.committed(), tokensCommitted);
        assertEq(rewards.uncommitted(), tokensHeld - tokensCommitted);
        for (uint256 i; i < actors.length; ++i) {
            address player = actors[i];
            assertEq(player.balance, ethBalance[player], "unexpected ETH movement");
            assertEq(token.balanceOf(player), tokenBalance[player], "unexpected token movement");
            assertEq(game.ethCredit(player), credit[player]);
            uint256 principal;
            for (uint256 j = 1; j < bricks.length; ++j) {
                if (bricks[j].player == player && !bricks[j].withdrawn) principal += bricks[j].stone;
            }
            assertEq(vault.stoneOf(player), principal);
            for (uint256 j = 1; j <= roundCount; ++j) {
                assertEq(rewards.participated(j, player), participants[j][player]);
                assertEq(rewards.claimable(j, player), tokenDue[j][player]);
            }
        }
        for (uint256 i = 1; i < bricks.length; ++i) {
            ExpectedBrick storage expected = bricks[i];
            Ponziramid.Brick memory actual = game.bricks(i);
            assertEq(actual.player, expected.player);
            assertEq(actual.roundId, expected.roundId);
            assertEq(actual.stone, expected.stone);
            assertEq(actual.withdrawn, expected.withdrawn);
            assertEq(actual.exitedBeforeExpiry, !expected.eligible);
            assertEq(actual.diamondClaimed, expected.diamondSettled);
            (address depositor, uint256 stone) = vault.deposits(i);
            assertEq(depositor, expected.player);
            assertEq(stone, expected.withdrawn ? 0 : expected.stone);
            (uint256 dividend, uint256 diamond) = game.claimableBrickETH(i);
            assertEq(dividend, expected.dividend, "dividend differs from per-brick oracle");
            assertEq(diamond, expected.diamond, "diamond differs from weighted oracle");
        }
        for (uint256 i = 1; i <= roundCount; ++i) {
            ExpectedRound storage expected = rounds[i];
            Ponziramid.Round memory actual = game.rounds(i);
            assertEq(actual.startedAt, expected.start);
            assertEq(actual.expiresAt, expected.end);
            assertEq(actual.nextPrice, expected.price);
            assertEq(actual.placedBricks, expected.placed);
            assertEq(actual.activeBricks, expected.active);
            assertEq(actual.activeStone, expected.stone);
            assertEq(actual.tomb, expected.tomb);
            assertEq(actual.pharaoh, expected.pharaoh);
            assertEq(actual.finalized, expected.finalized);
            assertEq(actual.diamondClaimsRemaining, expected.unsettledDiamonds);
        }
    }

    function settleEverything() external {
        finalizeAtExpiry();
        for (uint256 i = 1; i < bricks.length; ++i) {
            withdraw(i - 1, i);
            claimBrick(i - 1, i + 1);
        }
        for (uint256 i; i < actors.length; ++i) {
            claimCredit(i, i + 1);
            for (uint256 j; j < roundCount; ++j) {
                claimToken(j, i, i + 1);
            }
        }
        assertEq(stoneHeld, 0);
        assertEq(mortarHeld, expectedNextTomb);
        assertEq(tokensCommitted, 0);
        assertModel();
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract PayoutOracleInvariantTest is GameFixture {
    PayoutOracleHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[5] memory actors = [alice, bob, carol, outsider, creator];
        handler = new PayoutOracleHandler(game, token, actors);
        token.transfer(address(handler), 1_000_000 ether);
        handler.build(0);
        handler.build(1);
        handler.claimBrick(0, 2);
        handler.build(2);
        handler.withdraw(0, 3);
        handler.build(0);
        handler.assertModel();
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.build.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.claimBrick.selector;
        selectors[3] = handler.claimCredit.selector;
        selectors[4] = handler.claimToken.selector;
        selectors[5] = handler.finalizeAtExpiry.selector;
        selectors[6] = handler.advanceTime.selector;
        selectors[7] = handler.pause.selector;
        selectors[8] = handler.donate.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_everyPlayerEntitlementMatchesIndependentPerBrickAccounting() public view {
        handler.assertModel();
    }

    function test_modelCoversOldClaimsDuringNewRoundsAndDonationsWhilePaused() public {
        handler.finalizeAtExpiry();
        handler.build(4);
        handler.build(1);
        handler.pause(true);
        handler.donate(1, 0);
        handler.donate(1 ether, 1);
        handler.donate(1 ether, 2);
        handler.withdraw(1, 4);
        handler.claimBrick(1, 0);
        handler.claimCredit(2, 1);
        handler.claimToken(0, 0, 4);
        handler.assertModel();
        handler.finalizeAtExpiry();
        handler.settleEverything();
        assertEq(handler.builds(), 6);
        assertEq(handler.refunds(), 6);
        assertEq(handler.finalizedRounds(), 2);
        assertGt(handler.settlements(), 0);
        assertEq(address(vault).balance, 1);
        assertEq(address(game).balance, game.nextTomb() + 1 ether);
        assertEq(rewards.committed(), 0);
    }

    function afterInvariant() public {
        handler.settleEverything();
        assertEq(address(vault).balance, handler.vaultSurplus());
        assertEq(address(game).balance, game.nextTomb() + handler.gameSurplus());
        assertEq(rewards.committed(), 0);
    }
}
