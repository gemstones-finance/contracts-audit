// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../libs/SafeMath.sol";
import "../libs/Ownable.sol";
import "./ReferralStorage.sol";
import "./../GemstoneToken.sol";

contract Referral is Ownable {
    using SafeMath for uint256;

    /**
     * @dev Max referral level depth
     */
    uint8 constant MAX_REFER_DEPTH = 3;

    /**
     * @dev Max referee amount to bonus rate depth
     */
    uint8 constant MAX_REFEREE_BONUS_LEVEL = 3;
    
    /*
     * @dev Minimum time before 'inactivity' can be triggered
     */
    uint256 constant MIN_ACTIVITY_TIMEOUT = 1 days;

    /**
     * @dev The struct of account information
     * @param referrer The referrer addresss
     * @param reward The total referral reward of an address
     * @param referredCount The total referral amount of an address
     * @param lastActiveTimestamp The last active timestamp of an address
     */
    struct Account {
        address payable referrer;
        uint256 reward;
        uint256 referredCount;
        uint256 lastActiveTimestamp;
    }

    /**
     * @dev The struct of referee amount to bonus rate
     * @param lowerBound The minial referee amount
     * @param rate The bonus rate for each referee amount
     */
    struct RefereeBonusRate {
        uint256 lowerBound;
        uint256 rate;
    }

    event PaidReferral(address from, address to, uint256 amount, uint256 level);
    event UpdatedUserLastActiveTime(address user, uint256 timestamp);
    event SetOnlyRewardActiveReferrers(bool boolean);
    event SetReferralDistribution(uint256[] levelRates);
    event SetReferralPercentage(uint256 percentage);
    event SetReferralsEnabled(bool enabled);

    uint256[] levelRate;
    uint256 decimals;
    uint256 secondsUntilInactive;
    bool onlyRewardActiveReferrers;
    RefereeBonusRate[] refereeBonusRateMap;
    ReferralStorage referralStorage;

    uint16 public referralCutPercentage = 100; // 1% by default

    GemstoneToken public gemstones;

    // referralsEnabled by default
    bool referralsEnabled = true;

    /**
     * @param _decimals The base decimals for float calc, for example 1000
     * @param _secondsUntilInactive The seconds that a user does not update will be seen as inactive.
     * @param _onlyRewardActiveReferrers The flag to enable not paying to inactive uplines.
     * @param _levelRate The bonus rate for each level, which will divide by decimals too. The max depth is MAX_REFER_DEPTH.
     * @param _refereeBonusRateMap The bonus rate mapping to each referree amount, which will divide by decimals too. The max depth is MAX_REFER_DEPTH.
     * The map should be pass as [<lower amount>, <rate>, ....]. For example, you should pass [1, 250, 5, 500, 10, 1000] when decimals is 1000 for the following case.
     *
     *  25%     50%     100%
     *   | ----- | ----- |----->
     *  1ppl    5ppl    10ppl
     *
     * @notice refereeBonusRateMap's lower amount should be ascending
     */
    constructor(
        GemstoneToken _gemstones,
        uint256 _decimals,
        uint256 _secondsUntilInactive,
        bool _onlyRewardActiveReferrers,
        uint256[] memory _levelRate,
        uint256[] memory _refereeBonusRateMap,
        ReferralStorage _referralStorage
    ) public {
        require(_levelRate.length > 0, "Referral level should be at least one");
        require(
            _levelRate.length <= MAX_REFER_DEPTH,
            "Exceeded max referral level depth"
        );
        require(
            _refereeBonusRateMap.length % 2 == 0,
            "Referee Bonus Rate Map should be pass as [<lower amount>, <rate>, ....]"
        );
        require(
            _refereeBonusRateMap.length / 2 <= MAX_REFEREE_BONUS_LEVEL,
            "Exceeded max referree bonus level depth"
        );
        require(sum(_levelRate) <= _decimals, "Total level rate exceeds 100%");

        gemstones = _gemstones;
        decimals = _decimals;
        secondsUntilInactive = _secondsUntilInactive;
        onlyRewardActiveReferrers = _onlyRewardActiveReferrers;
        levelRate = _levelRate;
        referralStorage = _referralStorage;

        // Set default referee amount rate as 1ppl -> 100% if rate map is empty.
        if (_refereeBonusRateMap.length == 0) {
            refereeBonusRateMap.push(RefereeBonusRate(1, decimals));
            return;
        }

        for (uint256 i; i < _refereeBonusRateMap.length; i += 2) {
            if (_refereeBonusRateMap[i + 1] > decimals) {
                revert("One of referee bonus rate exceeds 100%");
            }
            // Cause we can't pass struct or nested array without enabling experimental ABIEncoderV2, use array to simulate it
            refereeBonusRateMap.push(
                RefereeBonusRate(
                    _refereeBonusRateMap[i],
                    _refereeBonusRateMap[i + 1]
                )
            );
        }
    }

    function sum(uint256[] memory data) public pure returns (uint256) {
        uint256 S;
        for (uint256 i; i < data.length; i++) {
            S += data[i];
        }
        return S;
    }

    /**
     * @dev Add an address as referrer
     * @param referrer The address would set as referrer of msg.sender
     * @return whether success to add upline
     */
    function addReferrer(address referee, address payable referrer)
        internal
        returns (bool)
    {
        require(referralsEnabled, "Referral System Disabled");
        return referralStorage.addReferrer(referee, referrer, levelRate.length);
    }

    /**
     * @dev Check if the caller has a referrer
     */
    function hasReferrer() public view returns (bool) {
        return hasReferrer(msg.sender);
    }

    /**
     * @dev Check whether a specific address has a referrer
     * @param _address Address to check for
     */
    function hasReferrer(address _address) public view returns (bool) {
        return referralStorage.hasReferrer(_address);
    }

    /**
     * @dev Get block timestamp with function for testing mock
     */
    function getTime() public view returns (uint256) {
        return now; // solium-disable-line security/no-block-members
    }

    /**
     * @dev Given a user amount to calc in which rate period
     * @param amount The number of referrees
     */
    function getRefereeBonusRate(uint256 amount) public view returns (uint256) {
        uint256 rate = refereeBonusRateMap[0].rate;
        for (uint256 i = 1; i < refereeBonusRateMap.length; i++) {
            if (amount < refereeBonusRateMap[i].lowerBound) {
                break;
            }
            rate = refereeBonusRateMap[i].rate;
        }
        return rate;
    }

    /**
     * @dev This will calc and pay referral to uplines instantly
     * @param value The number tokens will be calculated in referral process
     * @return the total referral bonus paid
     */
    function payReferral(address referee, uint256 value)
        internal
        returns (uint256)
    {
        require(referralsEnabled, "Referral System Disabled");

        // Get Account Reference
        ReferralStorage.Account memory account = referralStorage.getReferralAccount(referee);
        address accountAddress = referee;

        uint256 totalReferal;

        for (uint256 i; i < levelRate.length; i++) {
            // If no address, break from loop
            if (account.referrer == address(0)) {
                break;
            }

            if (
                (onlyRewardActiveReferrers &&
                    isReferrerActive(account.referrer)) || !onlyRewardActiveReferrers
            ) {

                // Overwrite loop values with next 'level' of referral
                accountAddress = account.referrer;
                account = referralStorage.getReferralAccount(accountAddress);

                // Calculations for referralcount/referrallevel
                uint256 c = value;
                c = c.mul(levelRate[i]).div(decimals);
                c = c.mul(getRefereeBonusRate(account.referredCount)).div(
                    decimals
                );

                // Transfer funds to Parent
                gemstones.safeTransfer(accountAddress, c);

                // Sum of how much paid to referrals alltogether
                totalReferal = totalReferal.add(c);

                // Update total Reward
                referralStorage.setAccountReward(
                    accountAddress,
                    account.reward.add(c)
                );

                // Emit event
                emit PaidReferral(referee, account.referrer, c, i + 1);
            }
        }

        // Return total amount paid to referrals in chain
        return totalReferal;
    }

    /**
     * @dev Transfer Gemstones away from Referral contract if added by accident (not supposed to be called)
     * @param _amount Amount to transfer away
     */
    function transferFunds(uint256 _amount) external onlyOwner {
        gemstones.safeTransfer(owner(), _amount);
    }

    /**
     * @dev Set the inactivity timer for Referrer payout
     * @param _secondsUntilInactive Seconds until inactivty (min 1 day = 60 * 60 * 24)
     */
    function setSecondsUntilInactive(uint256 _secondsUntilInactive)
        internal
    {
        require(_secondsUntilInactive >= MIN_ACTIVITY_TIMEOUT, "setSecondsUntilInactive: MIN 1 Day");
        secondsUntilInactive = _secondsUntilInactive;
    }

    /**
     * @dev Check whether the provided address is considered 'active'
     * @param _accountAddress Boolean indicating whether referrer is 'active' on the platform
     */
    function isReferrerActive(address _accountAddress) public view returns (bool) {
        ReferralStorage.Account memory account = referralStorage.getReferralAccount(_accountAddress);
        return (account.lastActiveTimestamp.add(secondsUntilInactive) >= getTime());
    }

    /**
     * @dev Enable or disable inactivity check for referral payout (if set to 'true', inactive referrals don't get paid)
     * @param _onlyRewardActiveReferrers Boolean indicating whether referral payout is only paid out to active referrers (default: true)
     */
    function setOnlyRewardActiveReferrers(bool _onlyRewardActiveReferrers)
        external onlyOwner
    {
        onlyRewardActiveReferrers = _onlyRewardActiveReferrers;
        emit SetOnlyRewardActiveReferrers(onlyRewardActiveReferrers);
    }

    /**
     * @dev Set the distribution of referral fee between levels (default => 1: 60%, 2: 30%, 3: 10%)
     * @param _levelRate The distribution per level based on decimals variable in contract (default => [6000, 3000, 1000])
     */
    function setReferralDistribution(uint256[] memory _levelRate)
        external
        onlyOwner
    {
        require(_levelRate.length > 0, "Referral level should be at least one");
        require(
            _levelRate.length <= MAX_REFER_DEPTH,
            "Exceeded max referral level depth"
        );
        require(sum(_levelRate) <= decimals, "Total level rate exceeds 100%");
        
        // Set the Level rate for ditribution per level
        levelRate = _levelRate;
        emit SetReferralDistribution(levelRate);
    }

    /**
     * @dev Set the referral cut percentage (default: 1%)
     * @param _percentage The referral cut percentage payout (default: 100 = 1%)
     */
    function setReferralPercentage(uint16 _percentage) external onlyOwner {
      require(_percentage <= 1000, "Ref %: MAX 10");
      referralCutPercentage = _percentage;
      emit SetReferralPercentage(referralCutPercentage);
    }

    /**
     * @dev Enable or disable the Referral payout
     * @param _referralsEnabled Boolean indicating whether referral payout is enabled or not (default: true)
     */
    function setReferralsEnabled(bool _referralsEnabled) external onlyOwner {
        referralsEnabled = _referralsEnabled;
        emit SetReferralsEnabled(referralsEnabled);
    }

    /**
     * @dev Read whether Referrals payout is enabled or not
     * @return whether referral payout is enabled or not (default: true)
     */
    function isReferralsEnabled() public view returns (bool) {
        return referralsEnabled;
    }
}
