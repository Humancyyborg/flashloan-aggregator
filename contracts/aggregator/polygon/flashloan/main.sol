//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "hardhat/console.sol";

import "@uniswap/v3-core/contracts/interfaces/callback/IUniswapV3FlashCallback.sol";

import {Helper} from "./helpers.sol";

import {TokenInterface, InstaFlashReceiverInterface, IUniswapV3Pool} from "./interfaces.sol";

contract FlashAggregatorPolygon is Helper {
    using SafeERC20 for IERC20;

    event LogFlashloan(
        address indexed account,
        uint256 indexed route,
        address[] tokens,
        uint256[] amounts
    );

    /**
     * @dev Callback function for aave flashloan.
     * @notice Callback function for aave flashloan.
     * @param _assets list of asset addresses for flashloan.
     * @param _amounts list of amounts for the corresponding assets for flashloan.
     * @param _premiums list of premiums/fees for the corresponding addresses for flashloan.
     * @param _initiator initiator address for flashloan.
     * @param _data extra data passed.
     */
    function executeOperation(
        address[] memory _assets,
        uint256[] memory _amounts,
        uint256[] memory _premiums,
        address _initiator,
        bytes memory _data
    ) external verifyDataHash(_data) returns (bool) {
        require(_initiator == address(this), "not-same-sender");
        require(msg.sender == aaveLendingAddr, "not-aave-sender");

        FlashloanVariables memory instaLoanVariables_;

        (address sender_, bytes memory data_) = abi.decode(
            _data,
            (address, bytes)
        );

        instaLoanVariables_._tokens = _assets;
        instaLoanVariables_._amounts = _amounts;
        instaLoanVariables_._instaFees = calculateFees(
            _amounts,
            calculateFeeBPS(1)
        );
        instaLoanVariables_._iniBals = calculateBalances(
            _assets,
            address(this)
        );

        safeApprove(instaLoanVariables_, _premiums, aaveLendingAddr);
        safeTransfer(instaLoanVariables_, sender_);

        if (checkIfDsa(sender_)) {
            Address.functionCall(
                sender_,
                data_,
                "DSA-flashloan-fallback-failed"
            );
        } else {
            InstaFlashReceiverInterface(sender_).executeOperation(
                _assets,
                _amounts,
                instaLoanVariables_._instaFees,
                sender_,
                data_
            );
        }

        instaLoanVariables_._finBals = calculateBalances(
            _assets,
            address(this)
        );
        validateFlashloan(instaLoanVariables_);

        return true;
    }

    /**
     * @dev Fallback function for balancer flashloan.
     * @notice Fallback function for balancer flashloan.
     * @param _amounts list of amounts for the corresponding assets or amount of ether to borrow as collateral for flashloan.
     * @param _fees list of fees for the corresponding addresses for flashloan.
     * @param _data extra data passed(includes route info aswell).
     */
    function receiveFlashLoan(
        IERC20[] memory,
        uint256[] memory _amounts,
        uint256[] memory _fees,
        bytes memory _data
    ) external verifyDataHash(_data) {
        require(msg.sender == balancerLendingAddr, "not-balancer-sender");

        FlashloanVariables memory instaLoanVariables_;

        (
            uint256 route_,
            address[] memory tokens_,
            uint256[] memory amounts_,
            address sender_,
            bytes memory data_
        ) = abi.decode(_data, (uint256, address[], uint256[], address, bytes));

        instaLoanVariables_._tokens = tokens_;
        instaLoanVariables_._amounts = amounts_;
        instaLoanVariables_._iniBals = calculateBalances(
            tokens_,
            address(this)
        );
        instaLoanVariables_._instaFees = calculateFees(
            amounts_,
            calculateFeeBPS(route_)
        );

        if (route_ == 5) {
            safeTransfer(instaLoanVariables_, sender_);

            if (checkIfDsa(sender_)) {
                Address.functionCall(
                    sender_,
                    data_,
                    "DSA-flashloan-fallback-failed"
                );
            } else {
                InstaFlashReceiverInterface(sender_).executeOperation(
                    tokens_,
                    amounts_,
                    instaLoanVariables_._instaFees,
                    sender_,
                    data_
                );
            }

            instaLoanVariables_._finBals = calculateBalances(
                tokens_,
                address(this)
            );
            validateFlashloan(instaLoanVariables_);
            safeTransferWithFee(
                instaLoanVariables_,
                _fees,
                balancerLendingAddr
            );
        } else if (route_ == 7) {
            require(_fees[0] == 0, "flash-ETH-fee-not-0");

            address[] memory wEthTokenList = new address[](1);
            wEthTokenList[0] = wEthToken;

            aaveSupply(wEthTokenList, _amounts);
            aaveBorrow(tokens_, amounts_);
            safeTransfer(instaLoanVariables_, sender_);

            if (checkIfDsa(sender_)) {
                Address.functionCall(
                    sender_,
                    data_,
                    "DSA-flashloan-fallback-failed"
                );
            } else {
                InstaFlashReceiverInterface(sender_).executeOperation(
                    tokens_,
                    amounts_,
                    instaLoanVariables_._instaFees,
                    sender_,
                    data_
                );
            }

            aavePayback(tokens_, amounts_);
            aaveWithdraw(wEthTokenList, _amounts);
            instaLoanVariables_._finBals = calculateBalances(
                tokens_,
                address(this)
            );
            validateFlashloan(instaLoanVariables_);
            instaLoanVariables_._amounts = _amounts;
            instaLoanVariables_._tokens = wEthTokenList;
            safeTransferWithFee(
                instaLoanVariables_,
                _fees,
                balancerLendingAddr
            );
        } else {
            revert("wrong-route");
        }
    }

    struct info {
        uint256 amount0;
        uint256 amount1;
        address sender_;
        PoolKey key;
        bytes data;
    }

    struct para {
        uint256 fee0;
        uint256 fee1;
        bytes data;
    }

    /// @param fee0 The fee from calling flash for token0
    /// @param fee1 The fee from calling flash for token1
    /// @param data The data needed in the callback passed as FlashCallbackData from `initFlash`
    /// @notice implements the callback called from flash
    /// @dev fails if the flash is not profitable, meaning the amountOut from the flash is less than the amount borrowed
    function uniswapV3FlashCallback(
        uint256 fee0,
        uint256 fee1,
        bytes memory data
    ) external verifyDataHash(data) {
        info memory _data;
        para memory _para;

        _para.fee0 = fee0;
        _para.fee1 = fee1;
        _para.data = data;

        (_data.amount0, _data.amount1, _data.sender_, _data.key, _data.data) = abi.decode(
            data,
            (uint256, uint256, address, PoolKey,bytes)
        );

        address pool = computeAddress(factory, _data.key);
        require(msg.sender == pool, "Invalid sender");

        address token0 = _data.key.token0;
        address token1 = _data.key.token1;

        FlashloanVariables memory instaLoanVariables_;

        uint256[] memory amounts_ = new uint256[](2);
        address[] memory tokens_ = new address[](2);
        uint256[] memory fees_ = new uint256[](2);

        amounts_[0] = _data.amount0;
        tokens_[0] = token0;
        amounts_[1] = _data.amount1;
        tokens_[1] = token1;
        fees_[0] = _para.fee0;
        fees_[1] = _para.fee1;

        instaLoanVariables_._tokens = tokens_;
        instaLoanVariables_._amounts = amounts_;
        instaLoanVariables_._iniBals = calculateBalances(
            tokens_,
            address(this)
        );

        uint256 fees = uint256(_data.key.fee);
        if (fees < InstaFeeBPS) {
            fees = InstaFeeBPS;
        }
        instaLoanVariables_._instaFees = calculateFees(
            amounts_,
            fees
        );

        safeTransfer(instaLoanVariables_, _data.sender_);

        if (checkIfDsa(_data.sender_)) {
            Address.functionCall(
                _data.sender_,
                _para.data,
                "DSA-flashloan-fallback-failed"
            );
        } else {
            InstaFlashReceiverInterface(_data.sender_).executeOperation(
                tokens_,
                amounts_,
                instaLoanVariables_._instaFees,
                _data.sender_,
                _data.data
            );
        }

        instaLoanVariables_._finBals = calculateBalances(
            tokens_,
            address(this)
        );

        validateFlashloan(instaLoanVariables_);

        safeApprove(instaLoanVariables_, fees_, msg.sender);
        safeTransferWithFee(instaLoanVariables_, fees_, msg.sender);
    }

    /**
     * @dev Middle function for route 1.
     * @notice Middle function for route 1.
     * @param _tokens list of token addresses for flashloan.
     * @param _amounts list of amounts for the corresponding assets or amount of ether to borrow as collateral for flashloan.
     * @param _data extra data passed.
     */
    function routeAave(
        address[] memory _tokens,
        uint256[] memory _amounts,
        bytes memory _data
    ) internal {
        bytes memory data_ = abi.encode(msg.sender, _data);
        uint256 length_ = _tokens.length;
        uint256[] memory _modes = new uint256[](length_);
        for (uint256 i = 0; i < length_; i++) {
            _modes[i] = 0;
        }
        dataHash = bytes32(keccak256(data_));
        aaveLending.flashLoan(
            address(this),
            _tokens,
            _amounts,
            _modes,
            address(0),
            data_,
            3228
        );
    }

    /**
     * @dev Middle function for route 5.
     * @notice Middle function for route 5.
     * @param _tokens token addresses for flashloan.
     * @param _amounts list of amounts for the corresponding assets.
     * @param _data extra data passed.
     */
    function routeBalancer(
        address[] memory _tokens,
        uint256[] memory _amounts,
        bytes memory _data
    ) internal {
        uint256 length_ = _tokens.length;
        IERC20[] memory tokens_ = new IERC20[](length_);
        for (uint256 i = 0; i < length_; i++) {
            tokens_[i] = IERC20(_tokens[i]);
        }
        bytes memory data_ = abi.encode(
            5,
            _tokens,
            _amounts,
            msg.sender,
            _data
        );
        dataHash = bytes32(keccak256(data_));
        balancerLending.flashLoan(
            InstaFlashReceiverInterface(address(this)),
            tokens_,
            _amounts,
            data_
        );
    }

    /**
     * @dev Middle function for route 7.
     * @notice Middle function for route 7.
     * @param _tokens token addresses for flashloan.
     * @param _amounts list of amounts for the corresponding assets.
     * @param _data extra data passed.
     */
    function routeBalancerAave(
        address[] memory _tokens,
        uint256[] memory _amounts,
        bytes memory _data
    ) internal {
        bytes memory data_ = abi.encode(
            7,
            _tokens,
            _amounts,
            msg.sender,
            _data
        );
        IERC20[] memory wethTokenList_ = new IERC20[](1);
        uint256[] memory wethAmountList_ = new uint256[](1);
        wethTokenList_[0] = IERC20(wEthToken);
        wethAmountList_[0] = getWEthBorrowAmount();
        dataHash = bytes32(keccak256(data_));
        balancerLending.flashLoan(
            InstaFlashReceiverInterface(address(this)),
            wethTokenList_,
            wethAmountList_,
            data_
        );
    }

    /**
     * @dev Middle function for route 8.
     * @notice Middle function for route 8.
     * @param _tokens token addresses for flashloan.
     * @param _amounts list of amounts for the corresponding assets.
     * @param _data extra data passed.
     *@param _instadata pool key encoded
     */
    function routeUniswap(
        address[] memory _tokens,
        uint256[] memory _amounts,
        bytes memory _data,
        bytes memory _instadata
    ) internal {
        PoolKey memory key = abi.decode(_instadata, (PoolKey));

        uint256 length_ = _tokens.length;
        uint256[] memory amounts_ = new uint256[](2);
        if (length_ == 1) {
            require(
                (_tokens[0] == key.token0 || _tokens[0] == key.token1),
                "Tokens does not match pool"
            );
            if (_tokens[0] == key.token0) {
                amounts_[0] = _amounts[0];
                amounts_[1] = 0;
            } else {
                amounts_[0] = 0;
                amounts_[1] = _amounts[0];
            }
        } else if (length_ == 2) {
            require(
                (_tokens[0] == key.token0 && _tokens[1] == key.token1),
                "Tokens does not match pool"
            );
            amounts_[0] = _amounts[0];
            amounts_[1] = _amounts[1];
        } else {
            revert("Number of tokens does not match");
        }

        IUniswapV3Pool pool = IUniswapV3Pool(computeAddress(factory, key));
    
        bytes memory data_ = abi.encode(
            amounts_[0],
            amounts_[1],
            msg.sender,
            key,
            _data
        );
        dataHash = bytes32(keccak256(data_));
        pool.flash(address(this), amounts_[0], amounts_[1], data_);
    }

    /**
     * @dev Main function for flashloan for all routes. Calls the middle functions according to routes.
     * @notice Main function for flashloan for all routes. Calls the middle functions according to routes.
     * @param _tokens token addresses for flashloan.
     * @param _amounts list of amounts for the corresponding assets.
     * @param _route route for flashloan.
     * @param _data extra data passed.
     */
    function flashLoan(
        address[] memory _tokens,
        uint256[] memory _amounts,
        uint256 _route,
        bytes calldata _data,
        bytes calldata _instadata // kept for future use by instadapp. Currently not used anywhere.
    ) external reentrancy {
        require(_tokens.length == _amounts.length, "array-lengths-not-same");

        (_tokens, _amounts) = bubbleSort(_tokens, _amounts);
        validateTokens(_tokens);

        if (_route == 1) {
            routeAave(_tokens, _amounts, _data);
        } else if (_route == 5) {
            routeBalancer(_tokens, _amounts, _data);
        } else if (_route == 7) {
            routeBalancerAave(_tokens, _amounts, _data);
        } else if (_route == 8) {
            routeUniswap(_tokens, _amounts, _data, _instadata);
        } else {
            revert("route-does-not-exist");
        }

        emit LogFlashloan(msg.sender, _route, _tokens, _amounts);
    }

    /**
     * @dev Function to get the list of available routes.
     * @notice Function to get the list of available routes.
     */
    function getRoutes() public pure returns (uint16[] memory routes_) {
        routes_ = new uint16[](4);
        routes_[0] = 1;
        routes_[1] = 5;
        routes_[2] = 7;
        routes_[3] = 8;
    }

    /**
     * @dev Function to transfer fee to the treasury.
     * @notice Function to transfer fee to the treasury.
     * @param _tokens token addresses for transferring fee to treasury.
     */
    function transferFeeToTreasury(address[] memory _tokens) public {
        for (uint256 i = 0; i < _tokens.length; i++) {
            IERC20 token_ = IERC20(_tokens[i]);
            uint256 decimals_ = TokenInterface(_tokens[i]).decimals();
            uint256 amtToSub_ = decimals_ == 18 ? 1e10 : decimals_ > 12
                ? 10000
                : decimals_ > 7
                ? 100
                : 10;
            uint256 amtToTransfer_ = token_.balanceOf(address(this)) > amtToSub_
                ? (token_.balanceOf(address(this)) - amtToSub_)
                : 0;
            if (amtToTransfer_ > 0)
                token_.safeTransfer(treasuryAddr, amtToTransfer_);
        }
    }
}

contract InstaFlashAggregatorPolygon is FlashAggregatorPolygon {
    /* 
     Deprecated
    */
    function initialize() public {
        require(status == 0, "cannot-call-again");
        status = 1;
    }

    receive() external payable {}
}
