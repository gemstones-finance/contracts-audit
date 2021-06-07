// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import './../libs/SafeMath.sol';
import './../libs/Ownable.sol';
import './../base/IBEP20.sol';
import './../base/SafeBEP20.sol';
import "./../libs/ReentrancyGuard.sol";
import "./../Referral/Referral.sol";

// MasterChef is the master of Gemstones. He can make Gemstones and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once GEMSTONES is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Referral, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeMath16 for uint16;

    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardLockedUp;  // Reward locked up.
        uint256 nextHarvestUntil; // When can the user harvest again.
        uint256 lastdeposit;

    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. GEMs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that GEMSTONEs distribution occurs.
        uint256 accGemstonesPerShare; // Accumulated GEMs per share, times 1e12. See below.
        uint16 depositFee;      // Deposit fee in basis points
        uint256 harvestInterval;  // Harvest interval in seconds
        uint256 earlyWithdrawalInterval;   // Early withdraw time in seconds
        uint256 earlyWithdrawalFee;    // Early withdraw fee in percentage
        uint16 harvestFee;              // harvest fee in percentage
    }

    // Dev address.
    address public devAddr;
    // Fee address
    address public feeAddr;
    
    uint256 public totalLockedUpRewards;

    uint256 public gemstonesPerBlock;
    // Bonus muliplier for early gemstones makers.
    uint256 public BONUS_MULTIPLIER = 1;
    
    // Max harvest interval: 14 days.
    uint256 public constant MAXIMUM_HARVEST_INTERVAL = 14 days;
    uint256 public constant MAXIMUM_EARLY_WITHDRAWAL_INTERVAL = 7 days;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Mapping of existing coins added
    mapping (address => bool) public lpTokensAdded;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when GEMSTONES mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmissionRateUpdated(address indexed caller, uint256 previousAmount, uint256 newAmount);
    event RewardLockedUp(address indexed user, uint256 indexed pid, uint256 amountLockedUp);

    constructor(
        GemstoneToken _gemstones,
        address _devAddr,
        address _feeAddr,
        uint256 _gemstonesPerBlock,
        uint256 _startBlock,

        /* Referral */
        uint256 _decimals,
        uint256 _secondsUntilInactive,
        bool _onlyRewardActiveReferrers,
        uint256[] memory _levelRate,
        uint256[] memory _refereeBonusRateMap,
        ReferralStorage _referralStorage
    ) public Referral (
        _gemstones,
        _decimals,
        _secondsUntilInactive,
        _onlyRewardActiveReferrers,
        _levelRate,
        _refereeBonusRateMap,
        _referralStorage
    ) {
        gemstones = _gemstones;
        devAddr = _devAddr;
        feeAddr = _feeAddr;
        gemstonesPerBlock = _gemstonesPerBlock;
        startBlock = _startBlock;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFee, uint256 _harvestInterval,uint256 _earlyWithdrawalInterval, uint16 _earlyWithdrawalFee, uint16 _harvestFee, bool _withUpdate) public onlyOwner {
        require(lpTokensAdded[address(_lpToken)] != true, "Add():: Token Already Added!");
        
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accGemstonesPerShare: 0,
            depositFee: _depositFee,
            harvestFee: _harvestFee,
            harvestInterval: _harvestInterval,
            earlyWithdrawalInterval: _earlyWithdrawalInterval,
            earlyWithdrawalFee: _earlyWithdrawalFee
        }));

        lpTokensAdded[address(_lpToken)] = true;
    }
    

    // Update the given pool's GEMSTONES allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFee, uint256 _harvestInterval,uint256 _earlyWithdrawalInterval, uint16 _earlyWithdrawalFee, bool _withUpdate) public onlyOwner {
        require(_earlyWithdrawalFee <= 1000, "set: earlyWithdrawalFee MAX 10%");
        require(_depositFee <= 1000, "set: depositfee MAX 10%");
        require(_harvestInterval <= MAXIMUM_HARVEST_INTERVAL, "set: too high harvest interval");
        require(_earlyWithdrawalInterval <= MAXIMUM_EARLY_WITHDRAWAL_INTERVAL, "set: too high earlyWithdrawal interval");

        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFee = _depositFee;
        poolInfo[_pid].harvestInterval = _harvestInterval;
        poolInfo[_pid].earlyWithdrawalInterval = _earlyWithdrawalInterval;
        poolInfo[_pid].earlyWithdrawalFee = _earlyWithdrawalFee;

    }

    function getlastdeposit(uint256 _pid, address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_pid][_user];
        return user.lastdeposit;
    }


    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // View function to see pending GEMSTONEs on frontend.
    function pendingGemstones(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accGemstonesPerShare = pool.accGemstonesPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 gemstonesReward = multiplier.mul(gemstonesPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accGemstonesPerShare = accGemstonesPerShare.add(gemstonesReward.mul(1e12).div(lpSupply));
        }
        
        uint256 pending = user.amount.mul(accGemstonesPerShare).div(1e12).sub(user.rewardDebt);
        return pending.add(user.rewardLockedUp);

    }
    
    // View function to see if user can harvest Gemstones.
    function canHarvest(uint256 _pid, address _user) public view returns (bool) {
        UserInfo storage user = userInfo[_pid][_user];
        return block.timestamp >= user.nextHarvestUntil;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);

        uint256 gemstonesReward = multiplier.mul(gemstonesPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        gemstones.mint(feeAddr , gemstonesReward.div(10));
        gemstones.mint(address(this), gemstonesReward);
        pool.accGemstonesPerShare = pool.accGemstonesPerShare.add(gemstonesReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number; 
    }

    function deposit(uint256 _pid, uint256 _amount, address _referrerAddress) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        
        payOrLockupPendingGemstones(_pid);

        // If the current user doesn't have a referrer yet, add the address
        if (_referrerAddress != address(0) && _amount > 0 && isReferralsEnabled() && !hasReferrer(msg.sender)) {
            addReferrer(msg.sender, payable(_referrerAddress));
        }
        
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.lastdeposit=now;
            referralStorage.setAccountLastActive(msg.sender);

            if (pool.depositFee > 0) {
                uint256 depositFee = _amount.mul(pool.depositFee).div(10000);
                pool.lpToken.safeTransfer(feeAddr, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accGemstonesPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: user doesnt have enough funds");
        updatePool(_pid);
        
        payOrLockupPendingGemstones(_pid);

        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            if(now > user.lastdeposit + pool.earlyWithdrawalInterval ){
                pool.lpToken.safeTransfer(address(msg.sender), _amount);
            }else{
                uint256 fee = _amount.mul(pool.earlyWithdrawalFee).div(10000);
                uint256 amountWithoutFee = _amount.sub(fee);
                pool.lpToken.safeTransfer(address(msg.sender), amountWithoutFee);
                pool.lpToken.safeTransfer(address(feeAddr), fee);
             }
        }

        user.rewardDebt = user.amount.mul(pool.accGemstonesPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);

    }
    
    
     function payOrLockupPendingGemstones(uint256 _pid) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        if (user.nextHarvestUntil == 0) {
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);
        }

        uint256 pending = user.amount.mul(pool.accGemstonesPerShare).div(1e12).sub(user.rewardDebt);
        if (canHarvest(_pid, msg.sender)) {
            uint256 totalRewards = pending.add(user.rewardLockedUp);

            // reset lockup
            totalLockedUpRewards = totalLockedUpRewards.sub(user.rewardLockedUp);
            user.rewardLockedUp = 0;
            user.nextHarvestUntil = block.timestamp.add(pool.harvestInterval);

            uint256 fee = 0;

            if(pool.harvestFee > 0){
                fee = totalRewards.mul(pool.harvestFee).div(10000);
                totalRewards = totalRewards.sub(fee);
            }

            // Transfer the 'actual' reward to the user
            safeGemstonesTransfer(msg.sender, totalRewards);

            // Calculate Referral Cut and mint it
            uint256 referralCut = 0;
                                
            // Pay referral
            uint256 paidToReferrals = 0;
            
            // If referral is enabled, and the user is referred
            if(isReferralsEnabled() && hasReferrer(msg.sender)) {
                referralCut = totalRewards.mul(referralCutPercentage).div(10000);
                gemstones.mint(address(this), referralCut);

                // Pay the referral cut (note: 60% to first level, 30% to second level, 10% to 3rd)
                paidToReferrals = payReferral(msg.sender, referralCut);
                uint256 rest = referralCut.sub(paidToReferrals);
                // transfer the rest (if any) to fee address (if not all 3 levels are present)
                safeGemstonesTransfer(feeAddr, rest.add(fee));

                // Transfer the fee user paid back to user
                if(paidToReferrals > 0) {
                    safeGemstonesTransfer(msg.sender, paidToReferrals);
                }
            } else {
                if(fee > 0 || referralCut > 0){
                    // Transfer to fee address
                    safeGemstonesTransfer(feeAddr, referralCut.add(fee));
                }
            }
        }
        else if (pending > 0) {
            user.rewardLockedUp = user.rewardLockedUp.add(pending);
            totalLockedUpRewards = totalLockedUpRewards.add(pending);
            emit RewardLockedUp(msg.sender, _pid, pending);
        }
    }

  
    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardLockedUp = 0;
        user.nextHarvestUntil = 0;
        pool.lpToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Safe gemstones transfer function, just in case if rounding error causes pool to not have enough GEMSTONEs.
    function safeGemstonesTransfer(address _to, uint256 _amount) internal {
        uint256 bal = gemstones.balanceOf(address(this));
        if (_amount > bal) {
            gemstones.transfer(_to, bal);
        } else {
            gemstones.transfer(_to, _amount);
        } 
    }

    function setDevAddress(address _devAddr) public {
        require(msg.sender == devAddr, "setDevAddress: FORBIDDEN");
        require(_devAddr != address(0), "setDevAddress: ZERO");
        devAddr = _devAddr;
    }
    
    function setFeeAddress(address _feeAddr) public {
        require(msg.sender == feeAddr, "setFeeAddress: FORBIDDEN");
        require(_feeAddr != address(0), "setFeeAddress: ZERO");
        feeAddr = _feeAddr;
    }
    
    function updateEmissionRate(uint256 _gemstonesPerBlock, bool _updateAllPools) public onlyOwner {
        require(_gemstonesPerBlock < 15000000000000000000, "updateEmissionRate: TOO HIGH");
        gemstonesPerBlock = _gemstonesPerBlock;

        if(_updateAllPools) {
            massUpdatePools();
        }
        
        emit EmissionRateUpdated(msg.sender, gemstonesPerBlock, _gemstonesPerBlock);
    }
}