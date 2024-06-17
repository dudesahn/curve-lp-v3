// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.23;

import {BaseHealthCheck, ERC20} from "@tokenized-strategy-periphery/Bases/HealthCheck/BaseHealthCheck.sol";
import {TradeFactorySwapper} from "@tokenized-strategy-periphery/swappers/TradeFactorySwapper.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/CurveInterfaces.sol";

contract StrategyCurveNoBoost is BaseHealthCheck, TradeFactorySwapper {
    using SafeERC20 for ERC20;

    /* ========== STATE VARIABLES ========== */
    // these should stay the same across different wants.

    // curve infrastructure contracts
    IGauge public immutable gauge;

    /// @notice The address of Arbitrum's CRV minter. Gibs CRV!
    IMinter public constant mintr =
        IMinter(0xabC000d88f23Bb45525E447528DBF656A9D55bf5);

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _asset,
        string memory _name,
        address _gauge
    ) BaseStrategy(_asset, _name) {
        gauge = IGauge(_gauge);
        require(gauge.lp_token() == _asset);

        ERC20(_asset).safeApprove(_gauge, type(uint256).max);
    }

    function setTradeFactory(
        address _tradeFactory,
        address _tokenTo
    ) external onlyManagement {
        _setTradeFactory(_tradeFactory, _tokenTo);
    }

    function addTokens(
        address[] memory _from,
        address[] memory _to
    ) external onlyManagement {
        _addTokens(_from, _to);
    }
    
    /**
     * @dev Can deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy can attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        gauge.deposit(_amount);
    }

    /**
     * @dev Should attempt to free the '_amount' of 'asset'.
     *
     * NOTE: The amount of 'asset' that is already loose has already
     * been accounted for.
     *
     * This function is called during {withdraw} and {redeem} calls.
     * Meaning that unless a whitelist is implemented it will be
     * entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * Should not rely on asset.balanceOf(address(this)) calls other than
     * for diff accounting purposes.
     *
     * Any difference between `_amount` and what is actually freed will be
     * counted as a loss and passed on to the withdrawer. This means
     * care should be taken in times of illiquidity. It may be better to revert
     * if withdraws are simply illiquid so not to realize incorrect losses.
     *
     * @param _amount, The amount of 'asset' to be freed.
     */
    function _freeFunds(uint256 _amount) internal override {
        gauge.withdraw(_amount);
    }

    /**
     * @dev Internal function to harvest all rewards, redeploy any idle
     * funds and return an accurate accounting of all funds currently
     * held by the Strategy.
     *
     * This should do any needed harvesting, rewards selling, accrual,
     * redepositing etc. to get the most accurate view of current assets.
     *
     * NOTE: All applicable assets including loose assets should be
     * accounted for in this function.
     *
     * Care should be taken when relying on oracles or swap values rather
     * than actual amounts as all Strategy profit/loss accounting will
     * be done based on this returned value.
     *
     * This can still be called post a shutdown, a strategist can check
     * `TokenizedStrategy.isShutdown()` to decide if funds should be
     * redeployed or simply realize any profits/losses.
     *
     * @return _totalAssets A trusted and accurate account for the total
     * amount of 'asset' the strategy currently holds including idle funds.
     */
    function _harvestAndReport()
        internal
        override
        returns (uint256 _totalAssets)
    {
        uint256 _looseAssets = asset.balanceOf(address(this));
        if (_looseAssets > 0) {
            _deployFunds(_looseAssets);
        }

        _totalAssets = gauge.balanceOf(address(this));
    }
    
    // should I make this permissionless externally to a keeper wrapper as well?
    function _claimRewards() internal override {
        // claim extra rewards if we have them
        if (rewardsTokens(0) != address(0)) {
            gauge.claim_rewards();
        }

        // Mintr CRV emissions
        mintr.mint(address(gauge));
    }
}