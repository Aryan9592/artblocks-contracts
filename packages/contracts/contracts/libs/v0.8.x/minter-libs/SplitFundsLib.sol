// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc.

import "../../../interfaces/v0.8.x/IMinterBaseV0.sol";
import "../../../interfaces/v0.8.x/IGenArt721CoreContractV3_Base.sol";
import "../../../interfaces/v0.8.x/IGenArt721CoreContractV3.sol";
import "../../../interfaces/v0.8.x/IGenArt721CoreContractV3_Engine.sol";

import "@openzeppelin-4.7/contracts/token/ERC20/IERC20.sol";

pragma solidity ^0.8.0;

/**
 * @title Art Blocks Split Funds Library
 * @notice This library is designed for the Art Blocks platform. It splits
 * Ether (ETH) and ERC20 token funds among stakeholders, such as sender
 * (if refund is applicable), providers, artists, and artists' additional
 * payees.
 * @author Art Blocks Inc.
 */

library SplitFundsLib {
    /**
     * @notice Currency updated for project `_projectId` to symbol
     * `_currencySymbol` and address `_currencyAddress`.
     */
    event ProjectCurrencyInfoUpdated(
        uint256 indexed _projectId,
        address indexed _coreContract,
        address indexed _currencyAddress,
        string _currencySymbol
    );

    // position of Split Funds Lib storage, using a diamond storage pattern
    // for this library
    bytes32 constant SPLIT_FUNDS_LIB_STORAGE_POSITION =
        keccak256("splitfundslib.storage");

    // contract-level variables
    struct IsEngineCache {
        bool isEngine;
        bool isCached;
    }

    // project-level variables
    struct SplitFundsProjectConfig {
        address currencyAddress; // address(0) if ETH
        string currencySymbol; // Assumed to be ETH if null
    }

    // Diamond storage pattern is used in this library
    struct SplitFundsLibStorage {
        mapping(address coreContract => mapping(uint256 projectId => SplitFundsProjectConfig)) splitFundsProjectConfigs;
        mapping(address coreContract => IsEngineCache) isEngineCacheConfigs;
    }

    /**
     * @notice splits ETH funds between sender (if refund), providers,
     * artist, and artist's additional payee for a token purchased on
     * project `_projectId`.
     * WARNING: This function uses msg.value and msg.sender to determine
     * refund amounts, and therefore may not be applicable to all use cases
     * (e.g. do not use with Dutch Auctions with on-chain settlement).
     * @dev This function relies on msg.sender and msg.value, so it must be
     * called directly from the contract that is receiving the payment.
     * @dev possible DoS during splits is acknowledged, and mitigated by
     * business practices, including end-to-end testing on mainnet, and
     * admin-accepted artist payment addresses.
     * @param _projectId Project ID for which funds shall be split.
     * @param _pricePerTokenInWei Current price of token, in Wei.
     * @param _coreContract Address of the GenArt721CoreContract associated
     * with the project.
     */
    function splitFundsETHRefundSender(
        uint256 _projectId,
        uint256 _pricePerTokenInWei,
        address _coreContract
    ) internal {
        if (msg.value > 0) {
            bool success_;
            // send refund to sender
            uint256 refund = msg.value - _pricePerTokenInWei;
            if (refund > 0) {
                (success_, ) = msg.sender.call{value: refund}("");
                require(success_, "Refund failed");
            }
            // split revenues
            splitRevenuesETHNoRefund(
                _projectId,
                _pricePerTokenInWei,
                _coreContract
            );
        }
    }

    /**
     * @notice Splits ETH revenues between providers, artist, and artist's
     * additional payee for revenue generated by project `_projectId`.
     * This function does NOT refund msg.sender, and does NOT use msg.value
     * when determining the value to be split.
     * @dev possible DoS during splits is acknowledged, and mitigated by
     * business practices, including end-to-end testing on mainnet, and
     * admin-accepted artist payment addresses.
     * @param _projectId Project ID for which funds shall be split.
     * @param _valueInWei Value to be split, in Wei.
     * @param _coreContract Address of the GenArt721CoreContract
     * associated with the project.
     */
    function splitRevenuesETHNoRefund(
        uint256 _projectId,
        uint256 _valueInWei,
        address _coreContract
    ) internal {
        if (_valueInWei == 0) {
            return; // return early
        }
        // split funds between platforms, artist, and artist's
        // additional payee
        bool isEngine_ = isEngine(_coreContract);
        if (isEngine_) {
            // get engine splits
            // uint256 platformProviderRevenue_;
            // address payable platformProviderAddress_;
            (
                uint256 renderProviderRevenue_,
                address payable renderProviderAddress_,
                uint256 platformProviderRevenue_,
                address payable platformProviderAddress_,
                uint256 artistRevenue_,
                address payable artistAddress_,
                uint256 additionalPayeePrimaryRevenue_,
                address payable additionalPayeePrimaryAddress_
            ) = IGenArt721CoreContractV3_Engine(_coreContract)
                    .getPrimaryRevenueSplits(_projectId, _valueInWei);
            // require total revenue split is 100%
            require(
                renderProviderRevenue_ +
                    platformProviderRevenue_ +
                    artistRevenue_ +
                    additionalPayeePrimaryRevenue_ ==
                    _valueInWei,
                "Invalid revenue split totals"
            );
            // Platform Provider payment (only possible if engine)
            if (platformProviderRevenue_ > 0) {
                (bool success, ) = platformProviderAddress_.call{
                    value: platformProviderRevenue_
                }("");
                require(success, "Platform Provider payment failed");
            }
            // Render Provider / Art Blocks payment
            if (renderProviderRevenue_ > 0) {
                (bool success, ) = renderProviderAddress_.call{
                    value: renderProviderRevenue_
                }("");
                require(success, "Render Provider payment failed");
            }
            // artist payment
            if (artistRevenue_ > 0) {
                (bool success, ) = artistAddress_.call{value: artistRevenue_}(
                    ""
                );
                require(success, "Artist payment failed");
            }
            // additional payee payment
            if (additionalPayeePrimaryRevenue_ > 0) {
                (bool success, ) = additionalPayeePrimaryAddress_.call{
                    value: additionalPayeePrimaryRevenue_
                }("");
                require(success, "Additional Payee payment failed");
            }
        } else {
            // get flagship splits
            (
                uint256 renderProviderRevenue_, // artblocks revenue
                address payable renderProviderAddress_, // artblocks address
                uint256 artistRevenue_,
                address payable artistAddress_,
                uint256 additionalPayeePrimaryRevenue_,
                address payable additionalPayeePrimaryAddress_
            ) = IGenArt721CoreContractV3(_coreContract).getPrimaryRevenueSplits(
                    _projectId,
                    _valueInWei
                );
            // require total revenue split is 100%
            require(
                renderProviderRevenue_ +
                    artistRevenue_ +
                    additionalPayeePrimaryRevenue_ ==
                    _valueInWei,
                "Invalid revenue split totals"
            );
            // Render Provider / Art Blocks payment
            if (renderProviderRevenue_ > 0) {
                (bool success, ) = renderProviderAddress_.call{
                    value: renderProviderRevenue_
                }("");
                require(success, "Render Provider payment failed");
            }
            // artist payment
            if (artistRevenue_ > 0) {
                (bool success, ) = artistAddress_.call{value: artistRevenue_}(
                    ""
                );
                require(success, "Artist payment failed");
            }
            // additional payee payment
            if (additionalPayeePrimaryRevenue_ > 0) {
                (bool success, ) = additionalPayeePrimaryAddress_.call{
                    value: additionalPayeePrimaryRevenue_
                }("");
                require(success, "Additional Payee payment failed");
            }
        }
    }

    /**
     * @notice Splits ERC20 funds between providers, artist, and artist's
     * additional payee, for a token purchased on project `_projectId`.
     * The function performs checks to ensure that the ERC20 token is
     * approved for transfer, and that a non-zero ERC20 token address is
     * configured.
     * @dev This function relies on msg.sender and msg.value, so it must be
     * called directly from the contract that is receiving the payment.
     * @dev possible DoS during splits is acknowledged, and mitigated by
     * business practices, including end-to-end testing on mainnet, and
     * admin-accepted artist payment addresses.
     * @param _projectId Project ID for which funds shall be split.
     * @param _pricePerTokenInWei Current price of token, in Wei.
     * @param _coreContract Core contract address.
     */
    function splitFundsERC20(
        uint256 _projectId,
        uint256 _pricePerTokenInWei,
        address _coreContract
    ) internal {
        if (_pricePerTokenInWei == 0) {
            return; // nothing to split, return early
        }
        IERC20 _projectCurrency;
        // block scope to avoid stack too deep error
        {
            SplitFundsProjectConfig
                storage splitFundsProjectConfig = getSplitFundsProjectConfig(
                    _projectId,
                    _coreContract
                );
            address currencyAddress = splitFundsProjectConfig.currencyAddress;
            require(
                currencyAddress != address(0),
                "ERC20: payment not configured"
            );
            require(msg.value == 0, "ERC20: No ETH when using ERC20");
            // ERC20 token is used for payment
            validateERC20Approvals({
                _msgSender: msg.sender,
                _currencyAddress: currencyAddress,
                _pricePerTokenInWei: _pricePerTokenInWei
            });
            _projectCurrency = IERC20(currencyAddress);
        }
        // split remaining funds between foundation, artist, and artist's
        bool isEngine_ = isEngine(_coreContract);
        if (isEngine_) {
            // get engine splits
            // uint256 platformProviderRevenue_;
            // address payable platformProviderAddress_;
            (
                uint256 renderProviderRevenue_,
                address payable renderProviderAddress_,
                uint256 platformProviderRevenue_,
                address payable platformProviderAddress_,
                uint256 artistRevenue_,
                address payable artistAddress_,
                uint256 additionalPayeePrimaryRevenue_,
                address payable additionalPayeePrimaryAddress_
            ) = IGenArt721CoreContractV3_Engine(_coreContract)
                    .getPrimaryRevenueSplits(_projectId, _pricePerTokenInWei);
            // require total revenue split is 100%
            require(
                renderProviderRevenue_ +
                    platformProviderRevenue_ +
                    artistRevenue_ +
                    additionalPayeePrimaryRevenue_ ==
                    _pricePerTokenInWei,
                "Invalid revenue split totals"
            );
            // Platform Provider payment (only possible if engine)
            if (platformProviderRevenue_ > 0) {
                require(
                    _projectCurrency.transferFrom(
                        msg.sender,
                        platformProviderAddress_,
                        platformProviderRevenue_
                    ),
                    "Platform Provider payment failed"
                );
            }
            // Art Blocks payment
            if (renderProviderRevenue_ > 0) {
                require(
                    _projectCurrency.transferFrom(
                        msg.sender,
                        renderProviderAddress_,
                        renderProviderRevenue_
                    ),
                    "Render Provider payment failed"
                );
            }
            // artist payment
            if (artistRevenue_ > 0) {
                require(
                    _projectCurrency.transferFrom(
                        msg.sender,
                        artistAddress_,
                        artistRevenue_
                    ),
                    "Artist payment failed"
                );
            }
            // additional payee payment
            if (additionalPayeePrimaryRevenue_ > 0) {
                // @dev some ERC20 may not revert on transfer failure, so we
                // check the return value
                require(
                    _projectCurrency.transferFrom(
                        msg.sender,
                        additionalPayeePrimaryAddress_,
                        additionalPayeePrimaryRevenue_
                    ),
                    "Additional Payee payment failed"
                );
            }
        } else {
            // get flagship splits
            (
                uint256 renderProviderRevenue_, // artblocks revenue
                address payable renderProviderAddress_, // artblocks address
                uint256 artistRevenue_,
                address payable artistAddress_,
                uint256 additionalPayeePrimaryRevenue_,
                address payable additionalPayeePrimaryAddress_
            ) = IGenArt721CoreContractV3(_coreContract).getPrimaryRevenueSplits(
                    _projectId,
                    _pricePerTokenInWei
                );
            // require total revenue split is 100%
            require(
                renderProviderRevenue_ +
                    artistRevenue_ +
                    additionalPayeePrimaryRevenue_ ==
                    _pricePerTokenInWei,
                "Invalid revenue split totals"
            );
            // Art Blocks payment
            if (renderProviderRevenue_ > 0) {
                require(
                    _projectCurrency.transferFrom(
                        msg.sender,
                        renderProviderAddress_,
                        renderProviderRevenue_
                    ),
                    "Render Provider payment failed"
                );
            }
            // artist payment
            if (artistRevenue_ > 0) {
                require(
                    _projectCurrency.transferFrom(
                        msg.sender,
                        artistAddress_,
                        artistRevenue_
                    ),
                    "Artist payment failed"
                );
            }
            // additional payee payment
            if (additionalPayeePrimaryRevenue_ > 0) {
                // @dev some ERC20 may not revert on transfer failure, so we
                // check the return value
                require(
                    _projectCurrency.transferFrom(
                        msg.sender,
                        additionalPayeePrimaryAddress_,
                        additionalPayeePrimaryRevenue_
                    ),
                    "Additional Payee payment failed"
                );
            }
        }
    }

    /**
     * @notice Updates payment currency of the referenced
     * SplitFundsProjectConfig to be `_currencySymbol` at address
     * `_currencyAddress`.
     * Only supports setting currency info of ERC20 tokens.
     * @dev artist-defined currency symbol is used instead of any on-chain
     * currency symbol.
     * @param _projectId Project ID to update.
     * @param _coreContract Core contract address.
     * @param _currencySymbol Currency symbol.
     * @param _currencyAddress Currency address.
     */
    function updateProjectCurrencyInfoERC20(
        uint256 _projectId,
        address _coreContract,
        string memory _currencySymbol,
        address _currencyAddress
    ) internal {
        // CHECKS
        require(_currencyAddress != address(0), "null address, only ERC20");
        require(bytes(_currencySymbol).length > 0, "only non-null symbol");
        // EFFECTS
        SplitFundsProjectConfig
            storage splitFundsProjectConfig = getSplitFundsProjectConfig(
                _projectId,
                _coreContract
            );
        splitFundsProjectConfig.currencySymbol = _currencySymbol;
        splitFundsProjectConfig.currencyAddress = _currencyAddress;

        emit ProjectCurrencyInfoUpdated({
            _projectId: _projectId,
            _coreContract: _coreContract,
            _currencyAddress: _currencyAddress,
            _currencySymbol: _currencySymbol
        });
    }

    /**
     * @notice Force sends `amount` (in wei) ETH to `to`, with a gas stipend
     * equal to `minterRefundGasLimit`.
     * If sending via the normal procedure fails, force sends the ETH by
     * creating a temporary contract which uses `SELFDESTRUCT` to force send
     * the ETH.
     * Reverts if the current contract has insufficient balance.
     * @param _to The address to send ETH to.
     * @param _amount The amount of ETH to send.
     * @dev This function is adapted from the `forceSafeTransferETH` function
     * in the `https://github.com/Vectorized/solady` repository, with
     * modifications to not check if the current contract has sufficient
     * balance. Therefore, the contract should be checked for sufficient
     * balance before calling this function in the minter itself, if
     * applicable.
     */
    function forceSafeTransferETH(
        address _to,
        uint256 _amount,
        uint256 _minterRefundGasLimit
    ) internal {
        // Manually inlined because the compiler doesn't inline functions with
        // branches.
        /// @solidity memory-safe-assembly
        assembly {
            // @dev intentionally do not check if this contract has sufficient
            // balance, because that is not intended to be a valid state.

            // Transfer the ETH and check if it succeeded or not.
            if iszero(call(_minterRefundGasLimit, _to, _amount, 0, 0, 0, 0)) {
                // if the transfer failed, we create a temporary contract with
                // initialization code that uses `SELFDESTRUCT` to force send
                // the ETH.
                // note: Compatible with `SENDALL`:
                // https://eips.ethereum.org/EIPS/eip-4758

                //---------------------------------------------------------------------------------------------------------------//
                // Opcode  | Opcode + Arguments  | Description        | Stack View                                               //
                //---------------------------------------------------------------------------------------------------------------//
                // Contract creation code that uses `SELFDESTRUCT` to force send ETH to a specified address.                     //
                // Creation code summary: 0x73<20-byte toAddress>0xff                                                            //
                //---------------------------------------------------------------------------------------------------------------//
                // 0x73    |  0x73_toAddress     | PUSH20 toAddress   | toAddress                                                //
                // 0xFF    |  0xFF               | SELFDESTRUCT       |                                                          //
                //---------------------------------------------------------------------------------------------------------------//
                // Store the address in scratch space, starting at 0x00, which begins the 20-byte address at 32-20=12 in memory
                // @dev use scratch space because we have enough space for simple creation code (less than 0x40 bytes)
                mstore(0x00, _to)
                // store opcode PUSH20 immediately before the address, starting at 0x0b (11) in memory
                mstore8(0x0b, 0x73)
                // store opcode SELFDESTRUCT immediately after the address, starting at 0x20 (32) in memory
                mstore8(0x20, 0xff)
                // this will always succeed because the contract creation code is
                // valid, and the address is valid because it is a 20-byte value
                if iszero(create(_amount, 0x0b, 0x16)) {
                    // @dev For better gas estimation.
                    if iszero(gt(gas(), 1000000)) {
                        revert(0, 0)
                    }
                }
            }
        }
    }

    /**
     * @notice Returns whether or not the provided address `_coreContract`
     * is an Art Blocks Engine core contract. Caches the result for future access.
     * @param _coreContract Address of the core contract to check.
     */
    function isEngine(address _coreContract) internal returns (bool) {
        IsEngineCache storage isEngineCache = getIsEngineCacheConfig(
            _coreContract
        );
        if (isEngineCache.isCached) {
            return isEngineCache.isEngine;
        } else {
            bool _isEngine = getV3CoreIsEngine(_coreContract);
            return _isEngine;
        }
    }

    /**
     * @notice Returns whether a V3 core contract is an Art Blocks Engine
     * contract or not. Return value of false indicates that the core is a
     * flagship contract. This function does not update the cache state for the
     * given V3 core contract.
     * @dev this function reverts if a core contract does not return the
     * expected number of return values from getPrimaryRevenueSplits() for
     * either a flagship or engine core contract.
     * @dev this function uses the length of the return data (in bytes) to
     * determine whether the core is an engine or not.
     * @param _coreContract The address of the deployed core contract.
     */
    function getV3CoreIsEngineView(
        address _coreContract
    ) internal view returns (bool) {
        // call getPrimaryRevenueSplits() on core contract
        bytes memory payload = abi.encodeWithSignature(
            "getPrimaryRevenueSplits(uint256,uint256)",
            0,
            0
        );
        (bool success, bytes memory returnData) = _coreContract.staticcall(
            payload
        );
        require(success, "getPrimaryRevenueSplits() call failed");
        // determine whether core is engine or not, based on return data length
        uint256 returnDataLength = returnData.length;
        if (returnDataLength == 6 * 32) {
            // 6 32-byte words returned if flagship (not engine)
            // @dev 6 32-byte words are expected because the non-engine core
            // contracts return a payout address and uint256 payment value for
            // the artist, and artist's additional payee, and Art Blocks.
            // also note that per Solidity ABI encoding, the address return
            // values are padded to 32 bytes.

            return false;
        } else if (returnDataLength == 8 * 32) {
            // 8 32-byte words returned if engine
            // @dev 8 32-byte words are expected because the engine core
            // contracts return a payout address and uint256 payment value for
            // the artist, artist's additional payee, render provider
            // typically Art Blocks, and platform provider (partner).
            // also note that per Solidity ABI encoding, the address return
            // values are padded to 32 bytes.
            return true;
        } else {
            // unexpected return value length
            revert("Unexpected revenue split bytes");
        }
    }

    /**
     * Gets the currency address and symbol for the referenced
     * SplitFundsProjectConfig.
     * Only supports ERC20 tokens - returns currencySymbol of `UNCONFIG` if
     * `currencyAddress` is zero.
     * @param _projectId Project ID to get config for
     * @param _coreContract Core contract address to get config for
     * @return currencyAddress
     * @return currencySymbol
     */
    function getCurrencyInfoERC20(
        uint256 _projectId,
        address _coreContract
    )
        internal
        view
        returns (address currencyAddress, string memory currencySymbol)
    {
        SplitFundsProjectConfig
            storage splitFundsProjectConfig = getSplitFundsProjectConfig(
                _projectId,
                _coreContract
            );
        currencyAddress = splitFundsProjectConfig.currencyAddress;
        // default to "UNCONFIG" if project currency address is initial value
        currencySymbol = currencyAddress == address(0)
            ? "UNCONFIG"
            : splitFundsProjectConfig.currencySymbol;
    }

    /**
     * Get the balance of `_currencyAddress` ERC20 tokens for `_walletAddress`.
     * @param _currencyAddress ERC20 token address.
     * @param _walletAddress wallet address.
     * @return balance
     */
    function getERC20Balance(
        address _currencyAddress,
        address _walletAddress
    ) internal view returns (uint256) {
        return IERC20(_currencyAddress).balanceOf(_walletAddress);
    }

    /**
     * Gets the allowance of `_spenderAddress` to spend `_walletAddress`'s
     * `_currencyAddress` ERC20 tokens.
     * @param _currencyAddress ERC20 token address.
     * @param _walletAddress wallet address.
     * @param _spenderAddress spender address.
     * @return allowance
     */
    function getERC20Allowance(
        address _currencyAddress,
        address _walletAddress,
        address _spenderAddress
    ) internal view returns (uint256 allowance) {
        allowance = IERC20(_currencyAddress).allowance(
            _walletAddress,
            _spenderAddress
        );
        return allowance;
    }

    /**
     * @notice Returns whether a V3 core contract is an Art Blocks Engine
     * contract or not. Return value of false indicates that the core is a
     * flagship contract. If this function resolves without reverting, it also
     * updates the cache state for the given V3 core contract.
     * @dev this function reverts if a core contract does not return the
     * expected number of return values from getPrimaryRevenueSplits() for
     * either a flagship or engine core contract.
     * @dev this function uses the length of the return data (in bytes) to
     * determine whether the core is an engine or not.
     * @param _coreContract The address of the deployed core contract.
     */
    function getV3CoreIsEngine(address _coreContract) private returns (bool) {
        IsEngineCache storage isEngineCache = getIsEngineCacheConfig(
            _coreContract
        );
        // call getPrimaryRevenueSplits() on core contract
        bytes memory payload = abi.encodeWithSignature(
            "getPrimaryRevenueSplits(uint256,uint256)",
            0,
            0
        );
        (bool success, bytes memory returnData) = _coreContract.call(payload);
        require(success, "getPrimaryRevenueSplits() call failed");
        // determine whether core is engine or not, based on return data length
        uint256 returnDataLength = returnData.length;
        if (returnDataLength == 6 * 32) {
            // 6 32-byte words returned if flagship (not engine)
            // @dev 6 32-byte words are expected because the non-engine core
            // contracts return a payout address and uint256 payment value for
            // the artist, and artist's additional payee, and Art Blocks.
            // also note that per Solidity ABI encoding, the address return
            // values are padded to 32 bytes.
            isEngineCache.isCached = true;
            isEngineCache.isEngine = false;
            return false;
        } else if (returnDataLength == 8 * 32) {
            // 8 32-byte words returned if engine
            // @dev 8 32-byte words are expected because the engine core
            // contracts return a payout address and uint256 payment value for
            // the artist, artist's additional payee, render provider
            // typically Art Blocks, and platform provider (partner).
            // also note that per Solidity ABI encoding, the address return
            // values are padded to 32 bytes.
            isEngineCache.isCached = true;
            isEngineCache.isEngine = true;
            return true;
        } else {
            // unexpected return value length
            revert("Unexpected revenue split bytes");
        }
    }

    /**
     * Validate that `_msgSender` has approved the contract to spend at least
     * `_pricePerTokenInWei` of `_currencyAddress` ERC20 tokens, and that
     * `_msgSender` has a balance of at least `_pricePerTokenInWei` of
     * `_currencyAddress` ERC20 tokens.
     * Reverts if insufficient allowance or balance.
     * @param _msgSender Address of the message sender to validate.
     * @param _currencyAddress Address of the ERC20 token to validate.
     * @param _pricePerTokenInWei Price per token in wei to validate.
     */
    function validateERC20Approvals(
        address _msgSender,
        address _currencyAddress,
        uint256 _pricePerTokenInWei
    ) private view {
        require(
            IERC20(_currencyAddress).allowance(_msgSender, address(this)) >=
                _pricePerTokenInWei,
            "Insufficient ERC20 allowance"
        );
        require(
            IERC20(_currencyAddress).balanceOf(_msgSender) >=
                _pricePerTokenInWei,
            "Insufficient ERC20 balance"
        );
    }

    /**
     * Loads the SplitFundsProjectConfig for a given project and core contract.
     * @param _projectId Project Id to get config for
     * @param _coreContract Core contract address to get config for
     */
    function getSplitFundsProjectConfig(
        uint256 _projectId,
        address _coreContract
    ) internal view returns (SplitFundsProjectConfig storage) {
        return s().splitFundsProjectConfigs[_coreContract][_projectId];
    }

    /**
     * Loads the IsEngineCache for a given core contract.
     * @param _coreContract Core contract address to get config for
     */
    function getIsEngineCacheConfig(
        address _coreContract
    ) internal view returns (IsEngineCache storage) {
        return s().isEngineCacheConfigs[_coreContract];
    }

    /**
     * @notice Return the storage struct for reading and writing. This library
     * uses a diamond storage pattern when managing storage.
     * @return storageStruct The SetPriceLibStorage struct.
     */
    function s()
        internal
        pure
        returns (SplitFundsLibStorage storage storageStruct)
    {
        bytes32 position = SPLIT_FUNDS_LIB_STORAGE_POSITION;
        assembly {
            storageStruct.slot := position
        }
    }
}
