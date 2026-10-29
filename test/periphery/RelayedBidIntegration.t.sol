// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ContinuousClearingAuction} from "@continuous-clearing-auction/ContinuousClearingAuction.sol";
import {AuctionParameters} from "@continuous-clearing-auction/interfaces/IContinuousClearingAuction.sol";
import {UmiaValidationHook} from "../../src/periphery/UmiaValidationHook.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Models a destination-chain executor holding the user's bridged funds.
contract BidRelayer {
    function bid(
        ContinuousClearingAuction auction,
        address currency,
        uint256 price,
        uint128 amount,
        address owner,
        bytes calldata credential
    ) external payable returns (uint256) {
        if (currency != address(0)) {
            address permit2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
            MockERC20(currency).approve(permit2, amount);
            IAllowanceTransfer(permit2).approve(currency, address(auction), amount, uint48(block.timestamp + 300));
        }
        return auction.submitBid{value: msg.value}(price, amount, owner, credential);
    }
}

/// @dev Runs a bid the way the hub's Relay orders do: each call separate, as the RelayRouter
///      executes them, with the Permit2 grant scoped to the current block (expiration 0).
contract RouterStyleRelayer {
    function run(address[] calldata targets, bytes[] calldata datas) external {
        for (uint256 i; i < targets.length; ++i) {
            (bool ok, bytes memory reason) = targets[i].call(datas[i]);
            if (!ok) {
                assembly {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }
}

contract RelayedBidIntegrationTest is Test, DeployPermit2 {
    uint256 constant SIGNER_KEY = 1234;
    uint256 constant FLOOR = 1000 << 96;
    uint256 constant TICK = 100 << 96;
    uint128 constant AMOUNT = 1 ether;
    address owner = makeAddr("bid-owner");

    function _auction(address currency) internal returns (ContinuousClearingAuction auction, UmiaValidationHook hook) {
        MockERC20 token = new MockERC20("Token", "TKN", 18);
        hook = new UmiaValidationHook(address(this), address(0), vm.addr(SIGNER_KEY));
        AuctionParameters memory params = AuctionParameters({
            currency: currency,
            tokensRecipient: address(this),
            fundsRecipient: address(this),
            startBlock: uint64(block.number + 1),
            endBlock: uint64(block.number + 101),
            claimBlock: uint64(block.number + 111),
            tickSpacing: TICK,
            validationHook: address(hook),
            floorPrice: FLOOR,
            requiredCurrencyRaised: AMOUNT * 10,
            auctionStepsData: abi.encodePacked(uint24(100_000), uint40(100))
        });
        auction = new ContinuousClearingAuction(address(token), 1000e18, params, address(0));
        token.mint(address(auction), 1000e18);
        auction.onTokensReceived();
        hook.setCCA(address(auction));
        hook.enableStep(0, new bytes32[](0), new string[](0));
        hook.enableStepPermit(0);
        hook.setVerifyEveryBid(0, true);
        vm.roll(block.number + 1);
    }

    function _permit(UmiaValidationHook hook) internal view returns (bytes memory) {
        bytes32 nonce = keccak256("relay-bid");
        uint256 deadline = block.timestamp + 300;
        bytes32 structHash =
            keccak256(abi.encode(hook.SERVER_PERMIT_TYPEHASH(), owner, uint256(0), nonce, deadline, AMOUNT));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", hook.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, digest);
        return abi.encodePacked(uint8(1), abi.encode(uint256(0), nonce, deadline, abi.encodePacked(r, s, v)));
    }

    function test_relayNativeBid_fundsFromExecutor_refundToOwner() public {
        (ContinuousClearingAuction auction, UmiaValidationHook hook) = _auction(address(0));
        BidRelayer relay = new BidRelayer();
        uint256 ownerBefore = owner.balance;
        uint256 id = relay.bid{value: AMOUNT}(auction, address(0), FLOOR + TICK, AMOUNT, owner, _permit(hook));
        assertEq(auction.bids(id).owner, owner);
        assertEq(owner.balance, ownerBefore);
        assertEq(address(auction).balance, AMOUNT);
        assertEq(address(relay).balance, 0);
        vm.roll(block.number + 100);
        vm.prank(address(relay));
        auction.exitBid(id);
        assertEq(owner.balance, ownerBefore + AMOUNT);
        assertEq(address(relay).balance, 0);
    }

    function test_relayOrderCalls_bidForOwner_leaveNoAllowanceOnRouter() public {
        address permit2 = deployPermit2();
        MockERC20 currency = new MockERC20("USD", "USD", 18);
        (ContinuousClearingAuction auction, UmiaValidationHook hook) = _auction(address(currency));
        RouterStyleRelayer router = new RouterStyleRelayer();
        currency.mint(address(router), AMOUNT);

        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);
        targets[0] = address(currency);
        datas[0] = abi.encodeCall(currency.approve, (permit2, AMOUNT));
        targets[1] = permit2;
        datas[1] = abi.encodeCall(IAllowanceTransfer.approve, (address(currency), address(auction), AMOUNT, 0));
        targets[2] = address(auction);
        datas[2] = abi.encodeWithSignature(
            "submitBid(uint256,uint128,address,uint256,bytes)", FLOOR + TICK, AMOUNT, owner, FLOOR, _permit(hook)
        );
        uint256 id = auction.nextBidId();
        router.run(targets, datas);

        assertEq(auction.bids(id).owner, owner);
        assertEq(currency.balanceOf(address(router)), 0);
        assertEq(currency.allowance(address(router), permit2), 0);
        (uint160 granted,,) =
            IAllowanceTransfer(permit2).allowance(address(router), address(currency), address(auction));
        assertEq(granted, 0);
    }

    function test_relayOrderCalls_zeroExpiryGrantCannotBeSpentLater() public {
        address permit2 = deployPermit2();
        MockERC20 currency = new MockERC20("USD", "USD", 18);
        (ContinuousClearingAuction auction,) = _auction(address(currency));
        RouterStyleRelayer router = new RouterStyleRelayer();
        currency.mint(address(router), AMOUNT);

        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);
        targets[0] = address(currency);
        datas[0] = abi.encodeCall(currency.approve, (permit2, AMOUNT));
        targets[1] = permit2;
        datas[1] = abi.encodeCall(IAllowanceTransfer.approve, (address(currency), address(auction), AMOUNT, 0));
        router.run(targets, datas);

        // A grant left behind by a fill that stopped short expires with its block.
        vm.warp(block.timestamp + 1);
        vm.prank(address(auction));
        vm.expectRevert(abi.encodeWithSignature("AllowanceExpired(uint256)", block.timestamp - 1));
        IAllowanceTransfer(permit2).transferFrom(address(router), address(auction), AMOUNT, address(currency));
    }

    function test_relayTokenBid_spendsOnlyExecutorTokens_refundToOwner() public {
        deployPermit2();
        MockERC20 currency = new MockERC20("USD", "USD", 18);
        (ContinuousClearingAuction auction, UmiaValidationHook hook) = _auction(address(currency));
        BidRelayer relay = new BidRelayer();
        currency.mint(address(relay), AMOUNT);
        currency.mint(owner, AMOUNT * 2);
        // The owner gives no token approval; the executor pays from its own balance.
        uint256 id = relay.bid(auction, address(currency), FLOOR + TICK, AMOUNT, owner, _permit(hook));
        assertEq(auction.bids(id).owner, owner);
        assertEq(currency.balanceOf(owner), AMOUNT * 2);
        assertEq(currency.balanceOf(address(relay)), 0);
        assertEq(currency.balanceOf(address(auction)), AMOUNT);
        vm.roll(block.number + 100);
        vm.prank(address(relay));
        auction.exitBid(id);
        assertEq(currency.balanceOf(owner), AMOUNT * 3);
        assertEq(currency.balanceOf(address(relay)), 0);
    }
}
