// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {RouterParameters} from "@uniswap/universal-router/contracts/types/RouterParameters.sol";
import {IV4Router} from "../../lib/universal-router/lib/v4-periphery/src/interfaces/IV4Router.sol";

contract RouterTestToken is ERC20 {
    constructor() ERC20("Router test", "RT") {
        _mint(msg.sender, 1000 ether);
    }
}

/// @notice Exercises the router compiled by DeployV4Infra with the API's single-hop layout.
contract UniversalRouterSingleHopTest is Test {
    UniversalRouter internal router;
    RouterTestToken internal token;
    PoolKey internal key;

    receive() external payable {}

    function setUp() public {
        vm.deal(address(this), 100 ether);
        PoolManager manager = new PoolManager(address(this));
        token = new RouterTestToken();
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 3000, 60, IHooks(address(0)));
        manager.initialize(key, uint160(1 << 96));
        PoolModifyLiquidityTest liquidity = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        token.approve(address(liquidity), type(uint256).max);
        liquidity.modifyLiquidity{value: 1 ether}(key, ModifyLiquidityParams(-60, 60, 100 ether, bytes32(0)), "");

        RouterParameters memory params;
        params.v4PoolManager = address(manager);
        router = new UniversalRouter(params);
    }

    function test_exactInputUsesModernTuple() public {
        uint256 beforeBalance = token.balanceOf(address(this));
        _execute(true, 1e15, 1, 0);
        assertGt(token.balanceOf(address(this)), beforeBalance);
    }

    function test_exactOutputUsesModernTuple() public {
        uint256 beforeBalance = token.balanceOf(address(this));
        _execute(false, 1e15, 2e15, 0);
        assertEq(token.balanceOf(address(this)) - beforeBalance, 1e15);
    }

    function test_exactInputPreservesOutputFloor() public {
        vm.expectPartialRevert(IV4Router.V4TooLittleReceived.selector);
        _execute(true, 1e15, 2e15, 0);
    }

    function test_exactOutputPreservesInputCeiling() public {
        vm.expectPartialRevert(IV4Router.V4TooMuchRequested.selector);
        _execute(false, 1e15, 1, 0);
    }

    function test_priceLimitFieldIsDecoded() public {
        vm.expectPartialRevert(IV4Router.V4TooLittleReceivedPerHopSingle.selector);
        _execute(true, 1e15, 1, type(uint256).max);
    }

    function _execute(bool exactIn, uint128 amount, uint128 limit, uint256 minHopPriceX36) internal {
        bytes[] memory params = new bytes[](3);
        if (exactIn) {
            params[0] = abi.encode(IV4Router.ExactInputSingleParams(key, true, amount, limit, minHopPriceX36, ""));
        } else {
            params[0] = abi.encode(IV4Router.ExactOutputSingleParams(key, true, amount, limit, minHopPriceX36, ""));
        }
        uint256 maxIn = exactIn ? amount : limit;
        params[1] = abi.encode(key.currency0, maxIn);
        params[2] = abi.encode(key.currency1, exactIn ? limit : amount);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(exactIn ? hex"060c0f" : hex"080c0f", params);
        router.execute{value: maxIn}(hex"10", inputs, block.timestamp + 1);
    }
}
