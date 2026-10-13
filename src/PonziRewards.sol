// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Permanent PONZIRAM reward funding; the sole outgoing token path is a verified player claim.
contract PonziRewards is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_FUNDING = 700_000_000 ether;
    uint256 public constant ROUND_REWARD = 1_000_000 ether;
    uint256 public constant PHARAOH_REWARD = 300_000 ether;
    uint256 public constant PARTICIPANT_REWARD = 700_000 ether;

    struct RewardRound {
        bool reserved;
        bool finalized;
        address pharaoh;
        uint256 participants;
        uint256 participationShare;
        uint256 remaining;
    }

    IERC20 public immutable token;
    address public immutable game;
    bool public fundingReached;
    uint256 public committed;
    uint256 public totalFunded;
    mapping(uint256 roundId => RewardRound) public rounds;
    mapping(uint256 roundId => mapping(address player => bool)) public participated;
    mapping(uint256 roundId => mapping(address player => bool)) public claimed;

    error OnlyGame();
    error InvalidAddress();
    error InvalidAmount();
    error IncorrectTokenReceipt();
    error InitialFundingRequired();
    error InsufficientUncommittedTokens();
    error InvalidRound();
    error RoundAlreadyReserved();
    error RoundNotOpen();
    error RoundNotFinalized();
    error NotParticipant();
    error AlreadyClaimed();

    event Funded(address indexed funder, uint256 amount, uint256 balance);
    event InitialFundingReached(uint256 balance);
    event RoundReserved(uint256 indexed roundId, uint256 amount);
    event ParticipantRecorded(uint256 indexed roundId, address indexed player);
    event RewardsFinalized(
        uint256 indexed roundId, address indexed pharaoh, uint256 participationShare, uint256 recycledDust
    );
    event RewardClaimed(
        uint256 indexed roundId, address indexed player, address indexed recipient, uint256 amount
    );

    constructor(address token_, address game_) {
        if (token_ == address(0) || game_ == address(0)) revert InvalidAddress();
        token = IERC20(token_);
        game = game_;
    }

    modifier onlyGame() {
        if (msg.sender != game) revert OnlyGame();
        _;
    }

    /// @notice Deposit permanently. Approve the exact amount on LaunchToken before calling.
    function fund(uint256 amount) external nonReentrant {
        if (amount == 0) revert InvalidAmount();
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 balance = token.balanceOf(address(this));
        if (balance < beforeBalance || balance - beforeBalance != amount) revert IncorrectTokenReceipt();
        totalFunded += amount;
        _observeFunding(balance);
        emit Funded(msg.sender, amount, balance);
    }

    /// @notice The initial threshold is a one-time gate, not a replenishment requirement after payouts.
    function isFunded() public view returns (bool) {
        return fundingReached || token.balanceOf(address(this)) >= INITIAL_FUNDING;
    }

    function uncommitted() public view returns (uint256) {
        return token.balanceOf(address(this)) - committed;
    }

    function canReserveRound() external view returns (bool) {
        return isFunded() && uncommitted() >= ROUND_REWARD;
    }

    /// @dev Called atomically with the first paid brick; unsuccessful builds roll back the reservation.
    function reserveRound(uint256 roundId) external nonReentrant onlyGame {
        if (roundId == 0) revert InvalidRound();
        RewardRound storage r = rounds[roundId];
        if (r.reserved) revert RoundAlreadyReserved();
        uint256 balance = token.balanceOf(address(this));
        _observeFunding(balance);
        if (!fundingReached) revert InitialFundingRequired();
        if (balance < committed || balance - committed < ROUND_REWARD) {
            revert InsufficientUncommittedTokens();
        }
        r.reserved = true;
        r.remaining = ROUND_REWARD;
        committed += ROUND_REWARD;
        emit RoundReserved(roundId, ROUND_REWARD);
    }

    /// @dev Repeated bricks by the same player never create additional participation shares.
    function recordParticipant(uint256 roundId, address player) external onlyGame {
        if (player == address(0)) revert InvalidAddress();
        RewardRound storage r = rounds[roundId];
        if (!r.reserved || r.finalized) revert RoundNotOpen();
        if (!participated[roundId][player]) {
            participated[roundId][player] = true;
            ++r.participants;
            emit ParticipantRecorded(roundId, player);
        }
    }

    /// @dev No token interaction or player loop: finalization cannot depend on token transfer success.
    function finalizeRound(uint256 roundId, address pharaoh) external onlyGame {
        RewardRound storage r = rounds[roundId];
        if (!r.reserved || r.finalized) revert RoundNotOpen();
        if (!participated[roundId][pharaoh]) revert NotParticipant();
        r.finalized = true;
        r.pharaoh = pharaoh;
        r.participationShare = PARTICIPANT_REWARD / r.participants;
        uint256 allocation = PHARAOH_REWARD + r.participationShare * r.participants;
        uint256 dust = ROUND_REWARD - allocation;
        r.remaining = allocation;
        committed -= dust;
        emit RewardsFinalized(roundId, pharaoh, r.participationShare, dust);
    }

    function claimable(uint256 roundId, address player) public view returns (uint256) {
        RewardRound storage r = rounds[roundId];
        if (!r.finalized || !participated[roundId][player] || claimed[roundId][player]) return 0;
        return r.participationShare + (player == r.pharaoh ? PHARAOH_REWARD : 0);
    }

    /// @notice Only the verified participant can claim, optionally to another recipient.
    function claim(uint256 roundId, address recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidAddress();
        RewardRound storage r = rounds[roundId];
        if (!r.finalized) revert RoundNotFinalized();
        if (!participated[roundId][msg.sender]) revert NotParticipant();
        if (claimed[roundId][msg.sender]) revert AlreadyClaimed();
        amount = claimable(roundId, msg.sender);
        claimed[roundId][msg.sender] = true;
        r.remaining -= amount;
        committed -= amount;
        emit RewardClaimed(roundId, msg.sender, recipient, amount);
        token.safeTransfer(recipient, amount);
    }

    function _observeFunding(uint256 balance) private {
        if (!fundingReached && balance >= INITIAL_FUNDING) {
            fundingReached = true;
            emit InitialFundingReached(balance);
        }
    }
}
