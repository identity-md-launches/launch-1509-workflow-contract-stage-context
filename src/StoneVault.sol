// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IStoneWithdrawalObserver {
    function onStoneWithdrawal(uint256 brickId) external;
}

/// @notice Isolated principal custody. Only each brick's depositor can withdraw its entire Stone.
/// @dev The immutable game's callback does accounting only: no settlement, token calls or pause checks.
contract StoneVault is ReentrancyGuard {
    struct Deposit {
        address player;
        uint256 amount;
    }

    address public immutable game;
    uint256 public totalStone;
    mapping(uint256 brickId => Deposit) public deposits;
    mapping(address player => uint256) public stoneOf;

    error OnlyGame();
    error InvalidAddress();
    error InvalidDeposit();
    error NotDepositor();
    error AlreadyWithdrawn();
    error TransferFailed();

    event StoneDeposited(uint256 indexed brickId, address indexed player, uint256 amount);
    event StoneWithdrawn(
        uint256 indexed brickId, address indexed player, address indexed recipient, uint256 amount
    );

    constructor(address game_) {
        if (game_ == address(0)) revert InvalidAddress();
        game = game_;
    }

    function deposit(uint256 brickId, address player) external payable nonReentrant {
        if (msg.sender != game) revert OnlyGame();
        if (player == address(0)) revert InvalidAddress();
        if (brickId == 0 || msg.value == 0 || deposits[brickId].player != address(0)) {
            revert InvalidDeposit();
        }
        deposits[brickId] = Deposit(player, msg.value);
        totalStone += msg.value;
        stoneOf[player] += msg.value;
        emit StoneDeposited(brickId, player, msg.value);
    }

    /// @notice Refund one brick directly, even if the game is paused or has not been finalized.
    /// @dev A rejected payment reverts the entire operation, preserving principal and game state.
    function withdrawStone(uint256 brickId, address payable recipient) external nonReentrant {
        if (recipient == address(0)) revert InvalidAddress();
        Deposit storage d = deposits[brickId];
        if (d.player != msg.sender) revert NotDepositor();
        uint256 amount = d.amount;
        if (amount == 0) revert AlreadyWithdrawn();
        d.amount = 0;
        totalStone -= amount;
        stoneOf[msg.sender] -= amount;

        IStoneWithdrawalObserver(game).onStoneWithdrawal(brickId);
        emit StoneWithdrawn(brickId, msg.sender, recipient, amount);
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
    }
}
