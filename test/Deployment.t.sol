// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Ponziramid} from "../src/Ponziramid.sol";
import {StoneVault} from "../src/StoneVault.sol";
import {PonziRewards} from "../src/PonziRewards.sol";

contract FactoryProbe {
    function deploy(bytes memory code, bytes32 salt) external returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(code, 32), mload(code), salt)
        }
        require(deployed != address(0), "constructor failed");
    }
}

contract DeploymentTest is Test {
    /// @dev The launch policy's payer share: 70% of the fixed supply, carried by launch.json.
    uint256 internal constant CREATOR_ALLOCATION = 700_000_000 ether;

    function test_factoryDeploymentKeepsAllSupplyAndBindsChildCustodyWithoutInitialization() public {
        FactoryProbe factory = new FactoryProbe();
        address owner = makeAddr("explicit-launch-owner");
        LaunchToken token = LaunchToken(factory.deploy(type(LaunchToken).creationCode, bytes32(uint256(1))));
        bytes memory code = abi.encodePacked(
            type(Ponziramid).creationCode, abi.encode(address(token), owner, CREATOR_ALLOCATION)
        );
        Ponziramid game = Ponziramid(factory.deploy(code, bytes32(uint256(2))));
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(game)), 0);
        assertEq(token.balanceOf(address(game.rewards())), 0);
        assertEq(game.owner(), owner);
        assertTrue(game.owner() != address(factory));
        assertEq(game.vault().game(), address(game));
        assertEq(game.rewards().game(), address(game));
        assertEq(address(game.rewards().token()), address(token));
        assertEq(game.rewards().INITIAL_FUNDING(), CREATOR_ALLOCATION);
        assertFalse(game.paused());
        assertEq(game.currentRound(), 0);
        _checkRuntime(address(token));
        _checkRuntime(address(game));
        _checkRuntime(address(game.vault()));
        _checkRuntime(address(game.rewards()));
        assertLe(code.length, 49_152, "EIP-3860 initcode limit");
        emit log_named_uint("Ponziramid initcode with arguments (bytes)", code.length);
        emit log_named_uint("Ponziramid runtime (bytes)", address(game).code.length);
    }

    function test_constructorSucceedsWithCodeLessDependencyOnEmptyChain() public {
        address tokenAddress = makeAddr("token-without-code");
        assertEq(tokenAddress.code.length, 0);
        Ponziramid game = new Ponziramid(tokenAddress, makeAddr("owner"), CREATOR_ALLOCATION);
        assertEq(address(game.rewards().token()), tokenAddress);
        assertGt(address(game.vault()).code.length, 0);
        assertGt(address(game.rewards()).code.length, 0);
        assertEq(game.vault().game(), address(game));
    }

    function test_invalidConstructorAddressesAreRejected() public {
        address nonzero = makeAddr("constructor-parameter");
        vm.expectRevert(Ponziramid.InvalidAddress.selector);
        new Ponziramid(address(0), nonzero, CREATOR_ALLOCATION);
        vm.expectRevert(Ponziramid.InvalidAddress.selector);
        new Ponziramid(nonzero, address(0), CREATOR_ALLOCATION);
        vm.expectRevert(StoneVault.InvalidAddress.selector);
        new StoneVault(address(0));
        vm.expectRevert(PonziRewards.InvalidAddress.selector);
        new PonziRewards(address(0), nonzero, CREATOR_ALLOCATION);
        vm.expectRevert(PonziRewards.InvalidAddress.selector);
        new PonziRewards(nonzero, address(0), CREATOR_ALLOCATION);
    }

    /// @dev The gate must be startable (one round reward) and satisfiable (within the fixed supply).
    function test_creatorAllocationArgumentIsBoundedAndBoundImmutably() public {
        address nonzero = makeAddr("constructor-parameter");
        vm.expectRevert(PonziRewards.InvalidInitialFunding.selector);
        new Ponziramid(nonzero, nonzero, 0);
        vm.expectRevert(PonziRewards.InvalidInitialFunding.selector);
        new Ponziramid(nonzero, nonzero, 1_000_000 ether - 1);
        vm.expectRevert(PonziRewards.InvalidInitialFunding.selector);
        new Ponziramid(nonzero, nonzero, 1e27 + 1);
        vm.expectRevert(PonziRewards.InvalidInitialFunding.selector);
        new PonziRewards(nonzero, nonzero, 1_000_000 ether - 1);

        Ponziramid smallest = new Ponziramid(nonzero, nonzero, 1_000_000 ether);
        assertEq(smallest.rewards().INITIAL_FUNDING(), 1_000_000 ether);
        Ponziramid largest = new Ponziramid(nonzero, nonzero, 1e27);
        assertEq(largest.rewards().INITIAL_FUNDING(), 1e27);
        Ponziramid policy = new Ponziramid(nonzero, nonzero, CREATOR_ALLOCATION);
        assertEq(policy.rewards().INITIAL_FUNDING(), CREATOR_ALLOCATION);
        assertEq(policy.rewards().TOKEN_SUPPLY(), 1e27);
        (bool ok,) =
            address(policy.rewards()).call(abi.encodeWithSignature("setInitialFunding(uint256)", uint256(1)));
        assertFalse(ok, "the threshold has no setter");
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0, "empty runtime");
        assertLe(code.length, 24_576, "EIP-170 runtime limit");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
