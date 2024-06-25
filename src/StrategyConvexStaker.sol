// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseStrategy, ERC20} from "@tokenized-strategy/BaseStrategy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TradeFactorySwapper} from "@periphery/swappers/TradeFactorySwapper.sol";
import {AuctionSwapper, Auction} from "@periphery/swappers/AuctionSwapper.sol";
import {IConvexBooster, IConvexRewards} from "./interfaces/ConvexInterfaces.sol";

contract StrategyConvexStaker is
    BaseStrategy,
    TradeFactorySwapper,
    AuctionSwapper
{
    using SafeERC20 for ERC20;

    // Mapping to be set by management for any reward tokens.
    // This can be used to set different mins for different tokens
    // or to set to uin256.max if selling a reward token is reverting
    mapping(address => uint256) public minAmountToSellMapping;

    /// @notice This is the deposit contract that all Convex pools use, aka booster.
    IConvexBooster public immutable booster;

    /// @notice This is unique to each pool and holds the rewards.
    IConvexRewards public immutable rewardsContract;

    /// @notice This is a unique numerical identifier for each Convex pool.
    uint256 public immutable pid;

    constructor(
        address _asset,
        uint256 _pid,
        address _booster,
        string memory _name
    ) BaseStrategy(_asset, _name) {
        // ideally this booster value is pre-filled using a factory (specific to each chain)
        booster = IConvexBooster(_booster);

        // pid is specific to each pool
        pid = _pid;

        // use our pid to pull the corresponding rewards contract and LP token
        (address lptoken, , , address _rewardsContract, , ) = booster.poolInfo(
            _pid
        );
        rewardsContract = IConvexRewards(_rewardsContract);

        // make sure we used the correct pid for our asset
        if (address(lptoken) != _asset) {
            revert();
        }

        // approve LP deposits on the booster
        ERC20(_asset).forceApprove(_booster, type(uint256).max);
    }

    /// @notice Balance of loose want in the strategy.
    function balanceOfWant() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /// @notice Balance of want staked in Convex.
    function balanceOfStake() public view returns (uint256) {
        return rewardsContract.balanceOf(address(this));
    }

    /**
     * @dev Should deploy up to '_amount' of 'asset' in the yield source.
     *
     * This function is called at the end of a {deposit} or {mint}
     * call. Meaning that unless a whitelist is implemented it will
     * be entirely permissionless and thus can be sandwiched or otherwise
     * manipulated.
     *
     * @param _amount The amount of 'asset' that the strategy should attempt
     * to deposit in the yield source.
     */
    function _deployFunds(uint256 _amount) internal override {
        // the final true argument means we deposit + stake at the same time
        booster.deposit(pid, _amount, true);
    }

    /**
     * @dev Will attempt to free the '_amount' of 'asset'.
     *
     * The amount of 'asset' that is already loose has already
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
        rewardsContract.withdrawAndUnwrap(_amount, false);
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
        uint256 _looseAssets = balanceOfWant();
        if (_looseAssets > 0) {
            _deployFunds(_looseAssets);
        }

        // claim any pending rewards
        _claimRewards();

        _totalAssets = balanceOfStake();
    }

    /**
     * @notice Use to manually claim rewards from our staking contract.
     * @dev Can only be called by management. Mostly helpful to make life easier for trade factory.
     */
    function manualRewardsClaim() external onlyKeepers {
        _claimRewards();
    }

    function _claimRewards() internal override {
        rewardsContract.getReward(address(this), true);
    }

    /* ========== TRADE FACTORY FUNCTIONS ========== */

    /**
     * @notice Use to update our trade factory.
     * @dev Can only be called by management.
     * @param _tradeFactory Address of new trade factory.
     */
    function setTradeFactory(address _tradeFactory) external onlyManagement {
        _setTradeFactory(_tradeFactory, address(asset));
    }

    /**
     * @notice Use to add tokens to our rewardTokens array. Also enables token on trade factory if one is set.
     * @dev Can only be called by management.
     * @param _token Address of token to add.
     */
    function addToken(address _token) external onlyManagement {
        require(_token != address(asset), "!allowed");
        _addToken(_token, address(asset));
    }

    /**
     * @notice Use to remove tokens from our rewardTokens array. Also disables token on trade factory.
     * @dev Can only be called by management.
     * @param _token Address of token to remove.
     */
    function removeToken(address _token) external onlyEmergencyAuthorized {
        _removeToken(_token, address(asset));
    }

    /* ========== AUCTION FUNCTIONS ========== */

    function setAuction(address _auction) external onlyEmergencyAuthorized {
        if (_auction != address(0)) {
            require(Auction(_auction).want() == address(asset), "wrong want");
        }
        auction = _auction;
    }

    function _auctionKicked(
        address _token
    ) internal override returns (uint256 _kicked) {
        require(_token != address(asset), "!allowed");
        _kicked = super._auctionKicked(_token);
        require(_kicked >= minAmountToSellMapping[_token], "too little");
    }

    /**
     * @notice Set the `minAmountToSellMapping` for a specific `_token`.
     * @dev This can be used by management to adjust wether or not the
     * _claimAndSellRewards() function will attempt to sell a specific
     * reward token. This can be used if liquidity is to low, amounts
     * are to low or any other reason that may cause reverts.
     *
     * @param _token The address of the token to adjust.
     * @param _amount Min required amount to sell.
     */
    function setMinAmountToSellMapping(
        address _token,
        uint256 _amount
    ) external onlyManagement {
        minAmountToSellMapping[_token] = _amount;
    }
}
