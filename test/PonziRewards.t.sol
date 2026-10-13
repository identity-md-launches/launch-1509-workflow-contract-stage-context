// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GameFixture} from "./helpers/GameFixture.sol";
import {PonziRewards} from "../src/PonziRewards.sol";
import {Ponziramid} from "../src/Ponziramid.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract RewardIntegrationTest is GameFixture {
    function test_creatorDepositIsWholeAllocationAndRecordedAsPermanentFunding() public view {
        assertEq(token.balanceOf(creator), 0);
        assertEq(rewards.INITIAL_FUNDING(), CREATOR_ALLOCATION);
        assertEq(token.balanceOf(address(rewards)), 700_000_000 ether);
        assertEq(rewards.totalFunded(), 700_000_000 ether);
        assertEq(rewards.committed(), 0);
        assertEq(rewards.uncommitted(), 700_000_000 ether);
        assertTrue(rewards.isFunded());
        assertTrue(rewards.canReserveRound());
        assertEq(token.allowance(creator, address(rewards)), 0);
    }

    /// @dev A launch whose policy pays the funding wallet less than 70% still starts once that wallet
    ///      deposits its entire balance, because the gate is the deployed allocation argument.
    function test_gameDeployedWithASmallerAllocationStartsOnTheWalletsEntireBalance() public {
        address funder = makeAddr("smaller-share-funder");
        Ponziramid smallerGame = new Ponziramid(address(token), creator, 100_000_000 ether);
        PonziRewards smallerPool = smallerGame.rewards();
        token.transfer(funder, 100_000_000 ether);
        vm.startPrank(funder);
        token.approve(address(smallerPool), token.balanceOf(funder));
        smallerPool.fund(token.balanceOf(funder));
        vm.stopPrank();
        assertEq(token.balanceOf(funder), 0);
        assertTrue(smallerPool.isFunded());
        assertTrue(smallerPool.canReserveRound());
        vm.prank(alice);
        smallerGame.build{value: 0.001 ether}(1, 0.001 ether);
        assertEq(smallerGame.currentRound(), 1);
        assertEq(smallerPool.committed(), 1_000_000 ether);
        assertEq(smallerPool.uncommitted(), 99_000_000 ether);
    }

    function test_distinctParticipantsPharaohParticipationWithdrawalAndDust() public {
        uint256 a = _build(alice);
        _build(bob);
        vm.warp(vm.getBlockTimestamp() + 60);
        _build(alice);
        _build(carol);
        _withdraw(alice, a);
        vm.expectRevert(PonziRewards.RoundNotFinalized.selector);
        vm.prank(alice);
        rewards.claim(1, alice);
        _expireAndFinalize();
        uint256 share = uint256(700_000 ether) / 3;
        uint256 dust = 700_000 ether - share * 3;
        assertEq(rewards.claimable(1, alice), share);
        assertEq(rewards.claimable(1, bob), share);
        assertEq(rewards.claimable(1, carol), share + 300_000 ether);
        assertEq(rewards.committed(), 1_000_000 ether - dust);
        assertEq(rewards.uncommitted(), 699_000_000 ether + dust);
        vm.prank(carol);
        rewards.claim(1, carol);
        vm.prank(alice);
        rewards.claim(1, alice);
        vm.prank(bob);
        rewards.claim(1, bob);
        assertEq(rewards.committed(), 0);
        assertEq(token.balanceOf(alice), share);
        assertEq(token.balanceOf(carol), 300_000 ether + share);
        assertEq(token.balanceOf(address(rewards)), 699_000_000 ether + dust);
        vm.expectRevert(PonziRewards.AlreadyClaimed.selector);
        vm.prank(alice);
        rewards.claim(1, alice);
        // Falling below the original 700M after paying rewards does not relock future rounds.
        _build(bob);
        assertEq(game.currentRound(), 2);
        assertEq(rewards.committed(), 1_000_000 ether);
    }

    function test_onlyGameCanVerifyPlayersReserveOrSetThePharaoh() public {
        vm.startPrank(creator);
        vm.expectRevert(PonziRewards.OnlyGame.selector);
        rewards.reserveRound(1);
        vm.expectRevert(PonziRewards.OnlyGame.selector);
        rewards.recordParticipant(1, creator);
        vm.expectRevert(PonziRewards.OnlyGame.selector);
        rewards.finalizeRound(1, creator);
        vm.stopPrank();
        _build(alice);
        _expireAndFinalize();
        vm.expectRevert(PonziRewards.NotParticipant.selector);
        vm.prank(creator);
        rewards.claim(1, creator);
        vm.expectRevert(PonziRewards.NotParticipant.selector);
        vm.prank(outsider);
        rewards.claim(1, outsider);
        assertEq(rewards.claimable(1, outsider), 0);
    }

    function test_claimantMayChooseRecipientButOutsiderCannotClaimForThem() public {
        _build(alice);
        _expireAndFinalize();
        vm.expectRevert(PonziRewards.NotParticipant.selector);
        vm.prank(outsider);
        rewards.claim(1, alice);
        vm.expectRevert(PonziRewards.InvalidAddress.selector);
        vm.prank(alice);
        rewards.claim(1, address(0));
        vm.prank(alice);
        rewards.claim(1, bob);
        assertEq(token.balanceOf(bob), 1_000_000 ether);
        assertEq(token.balanceOf(alice), 0);
        assertTrue(rewards.claimed(1, alice));
    }

    function test_noAdministrativeOrFunderExitPathsExistAndConstantsStayFixed() public {
        bytes[] memory attempts = new bytes[](11);
        attempts[0] = abi.encodeWithSignature("withdraw(uint256)", uint256(1));
        attempts[1] = abi.encodeWithSignature("withdraw(address,uint256)", creator, uint256(1));
        attempts[2] = abi.encodeWithSignature("transfer(address,uint256)", creator, uint256(1));
        attempts[3] = abi.encodeWithSignature("approve(address,uint256)", creator, type(uint256).max);
        attempts[4] = abi.encodeWithSignature("recoverERC20(address,uint256)", address(token), uint256(1));
        attempts[5] = abi.encodeWithSignature(
            "rescueTokens(address,address,uint256)", address(token), creator, uint256(1)
        );
        attempts[6] = abi.encodeWithSignature("upgradeTo(address)", creator);
        attempts[7] = abi.encodeWithSignature("setGame(address)", creator);
        attempts[8] = abi.encodeWithSignature("setRoundReward(uint256)", uint256(2));
        attempts[9] = abi.encodeWithSignature("setToken(address)", creator);
        attempts[10] = abi.encodeWithSignature(
            "execute(address,bytes)", address(token), abi.encodeCall(token.transfer, (creator, 1))
        );
        address[3] memory callers = [creator, address(game), outsider];
        for (uint256 i; i < callers.length; ++i) {
            for (uint256 j; j < attempts.length; ++j) {
                vm.prank(callers[i]);
                (bool ok,) = address(rewards).call(attempts[j]);
                assertFalse(ok);
            }
        }
        assertEq(rewards.ROUND_REWARD(), 1_000_000 ether);
        assertEq(rewards.PHARAOH_REWARD(), 300_000 ether);
        assertEq(rewards.PARTICIPANT_REWARD(), 700_000 ether);
        assertEq(rewards.INITIAL_FUNDING(), 700_000_000 ether);
        assertEq(token.balanceOf(address(rewards)), 700_000_000 ether);
        assertEq(token.allowance(address(rewards), creator), 0);
        assertEq(token.balanceOf(creator), 0);
    }
}

contract PonziRewardsUnitTest is Test {
    LaunchToken internal token;
    PonziRewards internal rewards;
    address internal player;

    function setUp() public {
        token = new LaunchToken();
        // This test contract is the authorized game for isolated reservation/claim failure cases.
        rewards = new PonziRewards(address(token), address(this), 700_000_000 ether);
        player = makeAddr("player");
    }

    /// @dev The gate is whatever the launch pays the funding wallet, not a compiled-in 700M guess.
    function test_thresholdFollowsTheConstructorAllocationForASmallerPayerShare() public {
        PonziRewards smaller = new PonziRewards(address(token), address(this), 100_000_000 ether);
        assertEq(smaller.INITIAL_FUNDING(), 100_000_000 ether);
        token.approve(address(smaller), 100_000_000 ether);
        smaller.fund(100_000_000 ether - 1);
        assertFalse(smaller.isFunded());
        vm.expectRevert(PonziRewards.InitialFundingRequired.selector);
        smaller.reserveRound(1);
        smaller.fund(1);
        assertTrue(smaller.isFunded());
        assertTrue(smaller.canReserveRound());
        smaller.reserveRound(1);
        assertEq(smaller.committed(), 1_000_000 ether);
        assertEq(smaller.uncommitted(), 99_000_000 ether);
        // The 700M figure is not special to a pool configured with a different allocation.
        assertFalse(smaller.INITIAL_FUNDING() == rewards.INITIAL_FUNDING());
    }

    function _fund() internal {
        token.approve(address(rewards), 700_000_000 ether);
        rewards.fund(700_000_000 ether);
    }

    function test_initialThresholdExactlyOneWeiShortCannotReserve() public {
        token.approve(address(rewards), 700_000_000 ether);
        rewards.fund(700_000_000 ether - 1);
        assertFalse(rewards.isFunded());
        assertFalse(rewards.canReserveRound());
        vm.expectRevert(PonziRewards.InitialFundingRequired.selector);
        rewards.reserveRound(1);
        rewards.fund(1);
        assertTrue(rewards.isFunded());
        rewards.reserveRound(1);
        assertEq(rewards.committed(), 1_000_000 ether);
    }

    function test_directTokenDonationsCountTowardFundingAndStayPermanent() public {
        token.transfer(address(rewards), 700_000_000 ether);
        assertTrue(rewards.isFunded());
        assertFalse(rewards.fundingReached());
        rewards.reserveRound(1);
        assertTrue(rewards.fundingReached());
        assertEq(rewards.totalFunded(), 0, "fund() events are distinct from direct transfers");
        assertEq(rewards.uncommitted(), 699_000_000 ether);
    }

    function test_reservationsCannotSpendUnclaimedRewardsAndExhaustionNeedsNewFunding() public {
        _fund();
        for (uint256 i = 1; i <= 700; ++i) {
            rewards.reserveRound(i);
            rewards.recordParticipant(i, player);
            rewards.finalizeRound(i, player);
        }
        assertEq(rewards.committed(), token.balanceOf(address(rewards)));
        assertEq(rewards.uncommitted(), 0);
        assertFalse(rewards.canReserveRound());
        vm.expectRevert(PonziRewards.InsufficientUncommittedTokens.selector);
        rewards.reserveRound(701);
        vm.prank(player);
        rewards.claim(1, player);
        assertEq(rewards.uncommitted(), 0, "claiming old liabilities creates no new funding");
        vm.expectRevert(PonziRewards.InsufficientUncommittedTokens.selector);
        rewards.reserveRound(701);
        token.approve(address(rewards), 1_000_000 ether);
        rewards.fund(1_000_000 ether);
        rewards.reserveRound(701);
        assertEq(rewards.uncommitted(), 0);
        assertEq(rewards.claimable(2, player), 1_000_000 ether);
    }

    function test_invalidRoundTransitionsAndZeroFundingFail() public {
        _fund();
        vm.expectRevert(PonziRewards.InvalidAmount.selector);
        rewards.fund(0);
        vm.expectRevert(PonziRewards.InvalidRound.selector);
        rewards.reserveRound(0);
        vm.expectRevert(PonziRewards.RoundNotOpen.selector);
        rewards.recordParticipant(1, player);
        rewards.reserveRound(1);
        vm.expectRevert(PonziRewards.RoundAlreadyReserved.selector);
        rewards.reserveRound(1);
        vm.expectRevert(PonziRewards.NotParticipant.selector);
        rewards.finalizeRound(1, player);
        rewards.recordParticipant(1, player);
        rewards.recordParticipant(1, player);
        rewards.finalizeRound(1, player);
        assertEq(rewards.claimable(1, player), 1_000_000 ether);
        vm.expectRevert(PonziRewards.RoundNotOpen.selector);
        rewards.finalizeRound(1, player);
        vm.expectRevert(PonziRewards.RoundNotOpen.selector);
        rewards.recordParticipant(1, address(this));
    }

    function testFuzz_participantShareDustRemainsUncommitted(uint8 count) public {
        _fund();
        uint256 n = bound(count, 1, 64);
        rewards.reserveRound(1);
        for (uint256 i; i < n; ++i) {
            rewards.recordParticipant(1, address(uint160(10_000 + i)));
        }
        address pharaoh = address(uint160(10_000 + n - 1));
        rewards.finalizeRound(1, pharaoh);
        uint256 allocated = 300_000 ether + (700_000 ether / n) * n;
        assertEq(rewards.committed(), allocated);
        for (uint256 i; i < n; ++i) {
            address participant = address(uint160(10_000 + i));
            vm.prank(participant);
            rewards.claim(1, participant);
        }
        assertEq(rewards.committed(), 0);
        assertEq(token.balanceOf(address(rewards)), 700_000_000 ether - allocated);
        assertEq(rewards.uncommitted(), token.balanceOf(address(rewards)));
    }
}

contract AdversarialToken is ERC20 {
    bool public failTransfers;
    bool public chargeFee;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSucceeded;
    bool public callbackAttempted;

    constructor() ERC20("TEST ONLY", "TEST") {
        _mint(msg.sender, 1_000_000_000 ether);
    }

    function configure(bool fail, bool fee, address target, bytes calldata data) external {
        failTransfers = fail;
        chargeFee = fee;
        callbackTarget = target;
        callbackData = data;
    }

    function claimAsToken(PonziRewards rewards) external {
        rewards.claim(1, address(this));
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (failTransfers) return false;
        if (callbackTarget != address(0)) {
            callbackAttempted = true;
            (callbackSucceeded,) = callbackTarget.call(callbackData);
        }
        return super.transfer(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (chargeFee && from != address(0) && to != address(0)) {
            uint256 fee = amount / 100;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

contract RewardsTransferFailureTest is Test {
    AdversarialToken internal token;
    PonziRewards internal rewards;
    address internal player;

    function setUp() public {
        player = makeAddr("player");
        token = new AdversarialToken();
        rewards = new PonziRewards(address(token), address(this), 700_000_000 ether);
        token.approve(address(rewards), 700_000_000 ether);
        rewards.fund(700_000_000 ether);
        rewards.reserveRound(1);
    }

    function test_failedTokenTransferPreservesClaimAndCommitmentForRetry() public {
        rewards.recordParticipant(1, player);
        rewards.finalizeRound(1, player);
        token.configure(true, false, address(0), "");
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(player);
        rewards.claim(1, player);
        assertFalse(rewards.claimed(1, player));
        assertEq(rewards.committed(), 1_000_000 ether);
        assertEq(rewards.claimable(1, player), 1_000_000 ether);
        token.configure(false, false, address(0), "");
        vm.prank(player);
        rewards.claim(1, player);
        assertEq(token.balanceOf(player), 1_000_000 ether);
    }

    function test_reentrantTokenCannotClaimTwiceEvenWhenItIsAParticipant() public {
        rewards.recordParticipant(1, address(token));
        rewards.finalizeRound(1, address(token));
        token.configure(false, false, address(rewards), abi.encodeCall(rewards.claim, (1, address(token))));
        token.claimAsToken(rewards);
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.balanceOf(address(token)), 1_000_000 ether);
        assertEq(rewards.committed(), 0);
    }

    function test_tokenPaymentFailureDoesNotBlockFinalization() public {
        rewards.recordParticipant(1, player);
        token.configure(true, false, address(0), "");
        rewards.finalizeRound(1, player);
        assertEq(rewards.claimable(1, player), 1_000_000 ether);
        assertEq(rewards.committed(), 1_000_000 ether);
    }

    function test_feeChargingTokenIsRejectedByFundingBalanceCheck() public {
        uint256 beforeBalance = token.balanceOf(address(rewards));
        uint256 fundedBefore = rewards.totalFunded();
        token.configure(false, true, address(0), "");
        token.approve(address(rewards), 100 ether);
        vm.expectRevert(PonziRewards.IncorrectTokenReceipt.selector);
        rewards.fund(100 ether);
        assertEq(token.balanceOf(address(rewards)), beforeBalance);
        assertEq(rewards.totalFunded(), fundedBefore);
    }
}
