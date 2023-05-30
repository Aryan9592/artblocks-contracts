// SPDX-License-Identifier: LGPL-3.0-only
// Created By: Art Blocks Inc.

import "../../interfaces/0.8.x/IGenArt721CoreContractV3_Base.sol";
import "../../interfaces/0.8.x/IDelegationRegistry.sol";
import "../../interfaces/0.8.x/ISharedMinterV0.sol";
import "../../interfaces/0.8.x/IMinterFilterV1.sol";

import "../../libs/0.8.x/SplitFundsLib.sol";
import "../../libs/0.8.x/MaxInvocationsLib.sol";

import "@openzeppelin-4.5/contracts/security/ReentrancyGuard.sol";

pragma solidity 0.8.19;

/**
 * @title Filtered Minter contract that allows tokens to be minted with ETH.
 * This is designed to be used with GenArt721CoreContractV3 flagship or
 * engine contracts.
 * @author Art Blocks Inc.
 * @notice Privileged Roles and Ownership:
 * This contract is designed to be managed, with limited powers.
 * Privileged roles and abilities are controlled by the project's artist, which
 * can be modified by the core contract's Admin ACL contract. Both of these
 * roles hold extensive power and can modify minter details.
 * Care must be taken to ensure that the admin ACL contract and artist
 * addresses are secure behind a multi-sig or other access control mechanism.
 * ----------------------------------------------------------------------------
 * The following functions are restricted to a project's artist:
 * - updatePricePerTokenInWei
 * - setProjectMaxInvocations
 * - manuallyLimitProjectMaxInvocations
 * ----------------------------------------------------------------------------
 * Additional admin and artist privileged roles may be described on other
 * contracts that this minter integrates with.
 */
contract MinterSetPriceV5 is ReentrancyGuard, ISharedMinterV0 {
    /// Minter filter address this minter interacts with
    address public immutable minterFilterAddress;

    /// Minter filter this minter may interact with.
    IMinterFilterV1 private immutable minterFilter;

    /// minterType for this minter
    string public constant minterType = "MinterSetPriceV5";

    /// minter version for this minter
    string public constant minterVersion = "v5.0.0";

    uint256 constant ONE_MILLION = 1_000_000;

    /// contractAddress => projectId => base project config
    mapping(address => mapping(uint256 => ProjectConfig)) public projectConfig;

    // STATE VARIABLES FOR SplitFundsLib
    // contractAddress => IsEngineCache
    mapping(address => SplitFundsLib.IsEngineCache) private _isEngineCaches;

    // STATE VARIABLES FOR MaxInvocationsLib
    /// contractAddress => projectId => max invocations specific project config
    mapping(address => mapping(uint256 => MaxInvocationsLib.MaxInvocationsProjectConfig))
        public maxInvocationsProjectConfig;

    function _onlyArtist(
        uint256 _projectId,
        address _coreContract
    ) internal view {
        require(
            msg.sender ==
                IGenArt721CoreContractV3_Base(_coreContract)
                    .projectIdToArtistAddress(_projectId),
            "Only Artist"
        );
    }

    /**
     * @notice Initializes contract to be a Filtered Minter for
     * `_minterFilter` minter filter.
     * @param _minterFilter Minter filter for which this will be a
     * filtered minter.
     */
    constructor(address _minterFilter) ReentrancyGuard() {
        minterFilterAddress = _minterFilter;
        minterFilter = IMinterFilterV1(_minterFilter);
    }

    /**
     * @notice Returns whether or not the provided address `_coreContract`
     * is an Art Blocks Engine core contract. Caches the result for future access.
     * @param _coreContract Address of the core contract to check.
     */
    function _isEngine(address _coreContract) internal returns (bool) {
        SplitFundsLib.IsEngineCache storage isEngineCache = _isEngineCaches[
            _coreContract
        ];
        if (isEngineCache.isCached) {
            return isEngineCache.isEngine;
        } else {
            bool isEngine = SplitFundsLib.getV3CoreIsEngine(
                _coreContract,
                isEngineCache
            );
            return isEngine;
        }
    }

    /**
     * @notice Syncs local maximum invocations of project `_projectId` based on
     * the value currently defined in the core contract.
     * @param _coreContract Core contract address for the given project.
     * @param _projectId Project ID to set the maximum invocations for.
     * @dev this enables gas reduction after maxInvocations have been reached -
     * core contracts shall still enforce a maxInvocation check during mint.
     */
    function syncProjectMaxInvocationsToCore(
        uint256 _projectId,
        address _coreContract
    ) public {
        uint256 maxInvocations = MaxInvocationsLib
            .syncProjectMaxInvocationsToCore(
                _projectId,
                _coreContract,
                maxInvocationsProjectConfig
            );
        emit ProjectMaxInvocationsLimitUpdated(
            _projectId,
            _coreContract,
            maxInvocations
        );
    }

    /**
     * @notice Manually sets the local maximum invocations of project `_projectId`
     * with the provided `_maxInvocations`, checking that `_maxInvocations` is less
     * than or equal to the value of project `_project_id`'s maximum invocations that is
     * set on the core contract.
     * @dev Note that a `_maxInvocations` of 0 can only be set if the current `invocations`
     * value is also 0 and this would also set `maxHasBeenInvoked` to true, correctly short-circuiting
     * this minter's purchase function, avoiding extra gas costs from the core contract's maxInvocations check.
     * @param _projectId Project ID to set the maximum invocations for.
     * @param _coreContract Core contract address for the given project.
     * @param _maxInvocations Maximum invocations to set for the project.
     */
    function manuallyLimitProjectMaxInvocations(
        uint256 _projectId,
        address _coreContract,
        uint256 _maxInvocations
    ) external {
        _onlyArtist(_projectId, _coreContract);
        MaxInvocationsLib.manuallyLimitProjectMaxInvocations(
            _projectId,
            _coreContract,
            _maxInvocations,
            maxInvocationsProjectConfig
        );
        emit ProjectMaxInvocationsLimitUpdated(
            _projectId,
            _coreContract,
            _maxInvocations
        );
    }

    /**
     * @notice projectId => has project reached its maximum number of
     * invocations? Note that this returns a local cache of the core contract's
     * state, and may be out of sync with the core contract. This is
     * intentional, as it only enables gas optimization of mints after a
     * project's maximum invocations has been reached. A false negative will
     * only result in a gas cost increase, since the core contract will still
     * enforce a maxInvocation check during minting. A false positive is not
     * possible because the V3 core contract only allows maximum invocations
     * to be reduced, not increased. Based on this rationale, we intentionally
     * do not do input validation in this method as to whether or not the input
     * @param `_projectId` is an existing project ID.
     * @param `_coreContract` is an existing core contract address.
     */
    function projectMaxHasBeenInvoked(
        uint256 _projectId,
        address _coreContract
    ) external view returns (bool) {
        return
            maxInvocationsProjectConfig[_coreContract][_projectId]
                .maxHasBeenInvoked;
    }

    /**
     * @notice projectId => project's maximum number of invocations.
     * Optionally synced with core contract value, for gas optimization.
     * Note that this returns a local cache of the core contract's
     * state, and may be out of sync with the core contract. This is
     * intentional, as it only enables gas optimization of mints after a
     * project's maximum invocations has been reached.
     * @dev A number greater than the core contract's project max invocations
     * will only result in a gas cost increase, since the core contract will
     * still enforce a maxInvocation check during minting. A number less than
     * the core contract's project max invocations is only possible when the
     * project's max invocations have not been synced on this minter, since the
     * V3 core contract only allows maximum invocations to be reduced, not
     * increased. When this happens, the minter will enable minting, allowing
     * the core contract to enforce the max invocations check. Based on this
     * rationale, we intentionally do not do input validation in this method as
     * to whether or not the input `_projectId` is an existing project ID.
     * @param `_projectId` is an existing project ID.
     * @param `_coreContract` is an existing core contract address.
     */
    function projectMaxInvocations(
        uint256 _projectId,
        address _coreContract
    ) external view returns (uint256) {
        return
            uint256(
                maxInvocationsProjectConfig[_coreContract][_projectId]
                    .maxInvocations
            );
    }

    /**
     * @notice Updates this minter's price per token of project `_projectId`
     * to be '_pricePerTokenInWei`, in Wei.
     * This price supersedes any legacy core contract price per token value.
     * @dev Note that it is intentionally supported here that the configured
     * price may be explicitly set to `0`.
     * @param _projectId Project ID to set the price per token for.
     * @param _coreContract Core contract address for the given project.
     * @param _pricePerTokenInWei Price per token to set for the project, in Wei.
     */
    function updatePricePerTokenInWei(
        uint256 _projectId,
        address _coreContract,
        uint256 _pricePerTokenInWei
    ) external {
        _onlyArtist(_projectId, _coreContract);
        MaxInvocationsLib.MaxInvocationsProjectConfig
            storage _maxInvocationsProjectConfig = maxInvocationsProjectConfig[
                _coreContract
            ][_projectId];
        ProjectConfig storage _projectConfig = projectConfig[_coreContract][
            _projectId
        ];
        _projectConfig.pricePerTokenInWei = _pricePerTokenInWei;
        _projectConfig.priceIsConfigured = true;
        emit PricePerTokenInWeiUpdated(
            _projectId,
            _coreContract,
            _pricePerTokenInWei
        );

        // sync local max invocations if not initially populated
        // @dev if local max invocations and maxHasBeenInvoked are both
        // initial values, we know they have not been populated.
        if (
            _maxInvocationsProjectConfig.maxInvocations == 0 &&
            _maxInvocationsProjectConfig.maxHasBeenInvoked == false
        ) {
            syncProjectMaxInvocationsToCore(_projectId, _coreContract);
        }
    }

    /**
     * @notice Purchases a token from project `_projectId`.
     * @param _projectId Project ID to mint a token on.
     * @return tokenId Token ID of minted token
     */
    function purchase(
        uint256 _projectId,
        address _coreContract
    ) external payable returns (uint256 tokenId) {
        tokenId = purchaseTo(msg.sender, _projectId, _coreContract);
        return tokenId;
    }

    /**
     * @notice gas-optimized version of purchase(uint256).
     */
    function purchase_H4M(
        uint256 _projectId,
        address _coreContract
    ) external payable returns (uint256 tokenId) {
        tokenId = purchaseTo(msg.sender, _projectId, _coreContract);
        return tokenId;
    }

    /**
     * @notice gas-optimized version of purchaseTo(address, uint256).
     */
    function purchaseTo(
        address _to,
        uint256 _projectId,
        address _coreContract
    ) public payable nonReentrant returns (uint256 tokenId) {
        // CHECKS
        ProjectConfig storage _projectConfig = projectConfig[_coreContract][
            _projectId
        ];
        MaxInvocationsLib.MaxInvocationsProjectConfig
            storage _maxInvocationsProjectConfig = maxInvocationsProjectConfig[
                _coreContract
            ][_projectId];

        // Note that `maxHasBeenInvoked` is only checked here to reduce gas
        // consumption after a project has been fully minted.
        // `_projectConfig.maxHasBeenInvoked` is locally cached to reduce
        // gas consumption, but if not in sync with the core contract's value,
        // the core contract also enforces its own max invocation check during
        // minting.
        require(
            !_maxInvocationsProjectConfig.maxHasBeenInvoked,
            "Maximum number of invocations reached"
        );

        // require artist to have configured price of token on this minter
        require(_projectConfig.priceIsConfigured, "Price not configured");

        // load price of token into memory
        uint256 pricePerTokenInWei = _projectConfig.pricePerTokenInWei;

        require(
            msg.value >= pricePerTokenInWei,
            "Must send minimum value to mint!"
        );

        // EFFECTS
        tokenId = minterFilter.mint_joo(
            _to,
            _projectId,
            _coreContract,
            msg.sender
        );

        // invocation is token number plus one, and will never overflow due to
        // limit of 1e6 invocations per project. block scope for gas efficiency
        // (i.e. avoid an unnecessary var initialization to 0).
        unchecked {
            uint256 tokenInvocation = (tokenId % ONE_MILLION) + 1;
            uint256 localMaxInvocations = _maxInvocationsProjectConfig
                .maxInvocations;
            // handle the case where the token invocation == minter local max
            // invocations occurred on a different minter, and we have a stale
            // local maxHasBeenInvoked value returning a false negative.
            // @dev this is a CHECK after EFFECTS, so security was considered
            // in detail here.
            require(
                tokenInvocation <= localMaxInvocations,
                "Maximum invocations reached"
            );
            // in typical case, update the local maxHasBeenInvoked value
            // to true if the token invocation == minter local max invocations
            // (enables gas efficient reverts after sellout)
            if (tokenInvocation == localMaxInvocations) {
                _maxInvocationsProjectConfig.maxHasBeenInvoked = true;
            }
        }

        // INTERACTIONS
        SplitFundsLib.splitFundsETH(
            _projectId,
            pricePerTokenInWei,
            _coreContract,
            _isEngine(_coreContract)
        );

        return tokenId;
    }

    /**
     * @notice Gets if price of token is configured, price of minting a
     * token on project `_projectId`, and currency symbol and address to be
     * used as payment. Supersedes any core contract price information.
     * @param _projectId Project ID to get price information for.
     * @return isConfigured true only if token price has been configured on
     * this minter
     * @return tokenPriceInWei current price of token on this minter - invalid
     * if price has not yet been configured
     * @return currencySymbol currency symbol for purchases of project on this
     * minter. This minter always returns "ETH"
     * @return currencyAddress currency address for purchases of project on
     * this minter. This minter always returns null address, reserved for ether
     */
    function getPriceInfo(
        uint256 _projectId,
        address _coreContract
    )
        external
        view
        returns (
            bool isConfigured,
            uint256 tokenPriceInWei,
            string memory currencySymbol,
            address currencyAddress
        )
    {
        ProjectConfig storage _projectConfig = projectConfig[_coreContract][
            _projectId
        ];
        isConfigured = _projectConfig.priceIsConfigured;
        tokenPriceInWei = _projectConfig.pricePerTokenInWei;
        currencySymbol = "ETH";
        currencyAddress = address(0);
    }
}
