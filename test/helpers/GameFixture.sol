// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Ponziramid} from "../../src/Ponziramid.sol";
import {StoneVault} from "../../src/StoneVault.sol";
import {PonziRewards} from "../../src/PonziRewards.sol";

abstract contract GameFixture is Test {
    LaunchToken internal token;
    Ponziramid internal game;
    StoneVault internal vault;
    PonziRewards internal rewards;
    address internal creator;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal outsider;

    function setUp() public virtual {
        vm.warp(1_000_000);
        creator = makeAddr("creator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        outsider = makeAddr("outsider");
        token = new LaunchToken();
        game = new Ponziramid(address(token), creator);
        vault = game.vault();
        rewards = game.rewards();
        token.transfer(creator, 700_000_000 ether);
        vm.startPrank(creator);
        token.approve(address(rewards), token.balanceOf(creator));
        rewards.fund(token.balanceOf(creator));
        vm.stopPrank();
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
        vm.deal(outsider, 1_000 ether);
        vm.deal(creator, 1 ether);
    }

    function _build(address player) internal returns (uint256 id) {
        (uint256 roundId, uint256 price,,) = game.quote();
        vm.prank(player);
        id = game.build{value: price}(roundId, price);
    }

    function _expireAndFinalize() internal {
        vm.warp(game.rounds(game.currentRound()).expiresAt);
        vm.prank(outsider);
        game.finalize();
    }

    function _withdraw(address player, uint256 id) internal {
        vm.prank(player);
        vault.withdrawStone(id, payable(player));
    }

    function _claimBrick(address player, uint256 id) internal returns (uint256) {
        vm.prank(player);
        return game.claimBrickETH(id, payable(player));
    }

    function _assertSolvent() internal view {
        assertGe(address(vault).balance, vault.totalStone(), "principal shortfall");
        assertGe(address(game).balance, game.accountedETH(), "mortar shortfall");
        assertGe(token.balanceOf(address(rewards)), rewards.committed(), "token shortfall");
    }
}

contract RejectETH {
    receive() external payable {
        revert("reject payment");
    }
}

/// @dev Test recipient attempts the same withdrawal or claim during a callback, then accepts payment.
contract ReenterETH {
    address public target;
    bytes public payload;
    bool public attempted;
    bool public succeeded;

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        attempted = false;
        succeeded = false;
    }

    function execute(address target_, bytes calldata payload_)
        external
        payable
        returns (bytes memory result)
    {
        (bool ok, bytes memory data) = target_.call{value: msg.value}(payload_);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(data, 32), mload(data))
            }
        }
        return data;
    }

    receive() external payable {
        attempted = true;
        (succeeded,) = target.call(payload);
    }
}
