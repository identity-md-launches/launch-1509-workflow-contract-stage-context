// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {StoneVault} from "./StoneVault.sol";
import {PonziRewards} from "./PonziRewards.sol";

/// @notice PONZIRAMID's immutable, fee-funded game. Principal lives only in StoneVault.
/// @dev Every operation is constant-time; no settlement or claim iterates through players or bricks.
contract Ponziramid is ReentrancyGuard {
    uint256 public constant START_PRICE = 0.001 ether;
    uint256 public constant BUILD_COOLDOWN = 60 seconds;
    uint256 public constant ROUND_EXTENSION = 24 hours;
    uint256 public constant MAX_ROUND_DURATION = 7 days;
    uint256 public constant WITHDRAWAL_PENALTY = 10 minutes;

    struct Round {
        uint256 startedAt;
        uint256 expiresAt;
        uint256 nextPrice;
        uint256 placedBricks;
        uint256 activeBricks;
        uint256 activeStone;
        uint256 dividendPerBrick;
        uint256 dividendsRemaining;
        uint256 tomb;
        address pharaoh;
        bool finalized;
        uint256 diamondPool;
        uint256 diamondRemaining;
        uint256 diamondClaimsRemaining;
    }

    struct Brick {
        address player;
        uint256 roundId;
        uint256 indexInRound;
        uint256 stone;
        uint256 startDividend;
        uint256 dividendsPaid;
        uint256 frozenDividend;
        bool withdrawn;
        bool exitedBeforeExpiry;
        bool diamondClaimed;
    }

    address public immutable owner;
    StoneVault public immutable vault;
    PonziRewards public immutable rewards;
    bool public paused;
    uint256 public currentRound;
    uint256 public brickCount;
    uint256 public nextTomb;
    uint256 public totalMortarReceived;
    uint256 public totalEthPaid;
    uint256 public totalCredits;
    mapping(address player => uint256) public ethCredit;
    mapping(address player => uint256) public lastBuildAt;
    mapping(address player => bool) private _hasBuilt;
    mapping(uint256 roundId => Round) private _rounds;
    mapping(uint256 brickId => Brick) private _bricks;

    error InvalidAddress();
    error OnlyOwner();
    error OnlyVault();
    error Paused();
    error StaleRound();
    error IncorrectPrice();
    error RoundExpired();
    error Cooldown();
    error ConsecutivePharaoh();
    error NoRound();
    error NotExpired();
    error AlreadyFinalized();
    error InvalidBrick();
    error AlreadyWithdrawn();
    error NotBrickOwner();
    error NothingToClaim();
    error TransferFailed();

    event CustodyCreated(address indexed vault, address indexed rewards);
    event PauseChanged(bool paused);
    event RoundStarted(uint256 indexed roundId, uint256 startedAt, uint256 expiresAt, uint256 seededTomb);
    event BrickPlaced(
        uint256 indexed brickId,
        uint256 indexed roundId,
        address indexed player,
        uint256 indexInRound,
        uint256 price,
        uint256 stone,
        uint256 mortar,
        uint256 expiresAt
    );
    event MortarAllocated(
        uint256 indexed roundId, uint256 indexed brickId, uint256 dividends, uint256 tomb, uint256 ownerFee
    );
    event BrickDeactivated(uint256 indexed brickId, bool beforeExpiry, uint256 expiresAt);
    event RoundFinalized(
        uint256 indexed roundId,
        address indexed pharaoh,
        uint256 pharaohPrize,
        uint256 diamondPool,
        uint256 nextTombSeed
    );
    event DiamondDustRecycled(uint256 indexed roundId, uint256 amount);
    event BrickETHClaimed(
        uint256 indexed brickId,
        address indexed player,
        address indexed recipient,
        uint256 dividends,
        uint256 diamondPrize
    );
    event ETHClaimed(address indexed player, address indexed recipient, uint256 amount);

    /// @notice Fully configures the game and creates its two immutable custody contracts.
    /// @dev Only CREATEs local bytecode; never calls the token or any pre-existing contract here.
    ///      token_ is the launch's $token; owner_ is $owner, never the factory or tx.origin.
    constructor(address token_, address owner_) {
        if (token_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        owner = owner_;
        vault = new StoneVault(address(this));
        rewards = new PonziRewards(token_, address(this));
        emit CustodyCreated(address(vault), address(rewards));
    }

    function rounds(uint256 roundId) external view returns (Round memory) {
        return _rounds[roundId];
    }

    function bricks(uint256 brickId) external view returns (Brick memory) {
        return _bricks[brickId];
    }

    /// @notice Quote in wei. An expired, unfinalized round still needs finalize() before building.
    function quote() public view returns (uint256 roundId, uint256 price, uint256 stone, uint256 mortar) {
        roundId = currentRound;
        if (roundId == 0 || _rounds[roundId].finalized) {
            ++roundId;
            price = START_PRICE;
        } else {
            price = _rounds[roundId].nextPrice;
        }
        stone = Math.mulDiv(price, 90, 100);
        mortar = price - stone;
    }

    /// @notice Buy the next ordered brick. Expected round and exact price protect stale transactions.
    function build(uint256 expectedRoundId, uint256 expectedPrice)
        external
        payable
        nonReentrant
        returns (uint256 brickId)
    {
        if (paused) revert Paused();
        (uint256 roundId, uint256 price, uint256 stone, uint256 mortar) = quote();
        if (roundId != expectedRoundId) revert StaleRound();
        if (price != expectedPrice || msg.value != price) revert IncorrectPrice();
        if (_hasBuilt[msg.sender] && block.timestamp - lastBuildAt[msg.sender] < BUILD_COOLDOWN) {
            revert Cooldown();
        }
        if (roundId != currentRound) _startRound(roundId);
        Round storage r = _rounds[roundId];
        if (block.timestamp >= r.expiresAt) revert RoundExpired();
        if (r.pharaoh == msg.sender) revert ConsecutivePharaoh();

        uint256 earlierShare = mortar / 2;
        uint256 ownerFee = mortar / 10;
        uint256 distributed = 0;
        if (r.activeBricks != 0) {
            uint256 perBrick = earlierShare / r.activeBricks;
            distributed = perBrick * r.activeBricks;
            r.dividendPerBrick += perBrick;
            r.dividendsRemaining += distributed;
        }
        // No earlier active bricks, division dust and split dust all stay in the Tomb.
        uint256 tombAdded = mortar - ownerFee - distributed;
        r.tomb += tombAdded;
        ethCredit[owner] += ownerFee;
        totalCredits += ownerFee;
        totalMortarReceived += mortar;

        brickId = ++brickCount;
        Brick storage b = _bricks[brickId];
        b.player = msg.sender;
        b.roundId = roundId;
        b.indexInRound = r.placedBricks++;
        b.stone = stone;
        b.startDividend = r.dividendPerBrick;
        ++r.activeBricks;
        r.activeStone += stone;
        r.nextPrice = Math.mulDiv(price, 1005, 1000);
        r.pharaoh = msg.sender;
        r.expiresAt = Math.min(block.timestamp + ROUND_EXTENSION, r.startedAt + MAX_ROUND_DURATION);
        lastBuildAt[msg.sender] = block.timestamp;
        _hasBuilt[msg.sender] = true;

        rewards.recordParticipant(roundId, msg.sender);
        vault.deposit{value: stone}(brickId, msg.sender);
        emit MortarAllocated(roundId, brickId, distributed, tombAdded, ownerFee);
        emit BrickPlaced(brickId, roundId, msg.sender, b.indexInRound, price, stone, mortar, r.expiresAt);
    }

    /// @dev Principal withdrawal's only callback. No token calls, payouts, pause gate or finalization.
    ///      After expiry the active totals are a frozen snapshot, even before anyone finalizes.
    function onStoneWithdrawal(uint256 brickId) external nonReentrant {
        if (msg.sender != address(vault)) revert OnlyVault();
        Brick storage b = _bricks[brickId];
        if (b.player == address(0)) revert InvalidBrick();
        if (b.withdrawn) revert AlreadyWithdrawn();
        Round storage r = _rounds[b.roundId];
        b.withdrawn = true;
        b.frozenDividend = r.dividendPerBrick;
        if (!r.finalized && block.timestamp < r.expiresAt) {
            b.exitedBeforeExpiry = true;
            --r.activeBricks;
            r.activeStone -= b.stone;
            // A bank run can end the round now, never retroactively before the withdrawal.
            uint256 remaining = r.expiresAt - block.timestamp;
            r.expiresAt = remaining > WITHDRAWAL_PENALTY ? r.expiresAt - WITHDRAWAL_PENALTY : block.timestamp;
        }
        emit BrickDeactivated(brickId, b.exitedBeforeExpiry, r.expiresAt);
    }

    /// @notice Permissionless, including while paused; never pushes ETH or PONZIRAM to players.
    function finalize() external nonReentrant {
        uint256 roundId = currentRound;
        if (roundId == 0) revert NoRound();
        Round storage r = _rounds[roundId];
        if (r.finalized) revert AlreadyFinalized();
        if (block.timestamp < r.expiresAt) revert NotExpired();
        r.finalized = true;
        uint256 pharaohPrize = Math.mulDiv(r.tomb, 40, 100);
        uint256 diamondPool = pharaohPrize;
        uint256 seed = r.tomb - pharaohPrize - diamondPool;
        ethCredit[r.pharaoh] += pharaohPrize;
        totalCredits += pharaohPrize;
        if (r.activeBricks == 0) {
            seed += diamondPool;
            diamondPool = 0;
        } else {
            r.diamondPool = diamondPool;
            r.diamondRemaining = diamondPool;
            r.diamondClaimsRemaining = r.activeBricks;
        }
        nextTomb += seed;
        rewards.finalizeRound(roundId, r.pharaoh);
        emit RoundFinalized(roundId, r.pharaoh, pharaohPrize, diamondPool, seed);
    }

    /// @notice Dividends earned so far and finalized diamond-hands prize, both in wei.
    function claimableBrickETH(uint256 brickId)
        public
        view
        returns (uint256 dividends, uint256 diamondPrize)
    {
        Brick storage b = _bricks[brickId];
        if (b.player == address(0)) return (0, 0);
        Round storage r = _rounds[b.roundId];
        uint256 accumulator = b.withdrawn ? b.frozenDividend : r.dividendPerBrick;
        dividends = accumulator - b.startDividend - b.dividendsPaid;
        if (r.finalized && !b.exitedBeforeExpiry && !b.diamondClaimed) {
            diamondPrize = Math.mulDiv(r.diamondPool, b.stone, r.activeStone);
        }
    }

    /// @notice Claim a brick's ETH without withdrawing its principal or forfeiting future earnings.
    function claimBrickETH(uint256 brickId, address payable recipient)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (recipient == address(0)) revert InvalidAddress();
        Brick storage b = _bricks[brickId];
        if (b.player != msg.sender) revert NotBrickOwner();
        Round storage r = _rounds[b.roundId];
        (uint256 dividends, uint256 diamondPrize) = claimableBrickETH(brickId);
        b.dividendsPaid += dividends;
        r.dividendsRemaining -= dividends;
        bool settlingDiamond = r.finalized && !b.exitedBeforeExpiry && !b.diamondClaimed;
        if (settlingDiamond) {
            b.diamondClaimed = true;
            r.diamondRemaining -= diamondPrize;
            if (--r.diamondClaimsRemaining == 0) {
                uint256 dust = r.diamondRemaining;
                r.diamondRemaining = 0;
                nextTomb += dust;
                emit DiamondDustRecycled(b.roundId, dust);
            }
        }
        amount = dividends + diamondPrize;
        if (amount == 0 && !settlingDiamond) revert NothingToClaim();
        emit BrickETHClaimed(brickId, msg.sender, recipient, dividends, diamondPrize);
        if (amount != 0) _pay(recipient, amount);
    }

    /// @notice Pull the caller's credited Pharaoh prizes and/or owner's earned Mortar fees.
    function claimETH(address payable recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidAddress();
        amount = ethCredit[msg.sender];
        if (amount == 0) revert NothingToClaim();
        ethCredit[msg.sender] = 0;
        totalCredits -= amount;
        emit ETHClaimed(msg.sender, recipient, amount);
        _pay(recipient, amount);
    }

    /// @notice The owner's sole administrative power affects new builds only; time continues running.
    function setPaused(bool paused_) external {
        if (msg.sender != owner) revert OnlyOwner();
        paused = paused_;
        emit PauseChanged(paused_);
    }

    /// @notice All game ETH still owed or earmarked, excluding any unsolicited forced ETH.
    function accountedETH() external view returns (uint256) {
        return totalMortarReceived - totalEthPaid;
    }

    function _startRound(uint256 roundId) private {
        // Reservation happens before accepting any brick or moving its principal.
        rewards.reserveRound(roundId);
        currentRound = roundId;
        Round storage r = _rounds[roundId];
        r.startedAt = block.timestamp;
        r.expiresAt = block.timestamp + ROUND_EXTENSION;
        r.nextPrice = START_PRICE;
        r.tomb = nextTomb;
        nextTomb = 0;
        emit RoundStarted(roundId, r.startedAt, r.expiresAt, r.tomb);
    }

    function _pay(address payable recipient, uint256 amount) private {
        totalEthPaid += amount;
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
