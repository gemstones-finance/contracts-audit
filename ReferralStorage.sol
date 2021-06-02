// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "../libs/SafeMath.sol";
import "../libs/AccessControl.sol";

contract ReferralStorage is AccessControl {
    using SafeMath for uint256;
    
    bytes32 public constant WRITE_ACCESS = keccak256("WRITE_ACCESS");

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
        address[] referrals;
    }
    
    struct ReferralsCount {
        uint256 level_1;
        uint256 level_2;
        uint256 level_3;
    }

    event RegisteredReferer(address referee, address referrer);
    event RegisteredRefererFailed(
        address referee,
        address referrer,
        string reason
    );

    // Update value events
    event UpdateTotalReward(address accountAddress, uint256 amount);
    event UpdateLastActive(address referrer, uint256 timestamp);

    mapping(address => Account) public accounts;
    
    address admin;
    
      /**
     * @dev Throws if called by any account other than the admin.
     */
    modifier onlyAdmin() {
        require(isAdmin(), "Only Admin: caller is not the admin");
        _;
    }
    
    modifier onlyWriters() {
        require(hasRole(WRITE_ACCESS, _msgSender()), "Only Writer: caller is not a writer");
        _;
    }
    
    constructor() public {
        // Admin of contract is by default the deployer
        admin = _msgSender();
    }

    /**
     * @dev Utils function for check whether an address has the referrer
     */
    function hasReferrer(address addr) public view returns (bool) {
        return accounts[addr].referrer != address(0);
    }

    /**
     * @dev Add an address as referrer
     * @param referrer The address would set as referrer of msg.sender
     * @return whether success to add upline
     */
    function addReferrer(address referee, address payable referrer, uint256 levels) external onlyWriters returns (bool) {
        
        if (referrer == address(0)) {
            emit RegisteredRefererFailed(
                referee,
                referrer,
                "Referrer cannot be 0x0 address"
            );
            return false;
        } else if (isCircularReference(referrer, referee, levels)) {
            emit RegisteredRefererFailed(
                referee,
                referrer,
                "Referee cannot be one of referrer uplines (circular referrer)"
            );
            return false;
        } else if (hasReferrer(referee)) {
            emit RegisteredRefererFailed(
                referee,
                referrer,
                "Sender is already referred by someone else"
            );
            return false;
        }

        Account storage userAccount = accounts[referee];
        Account storage parentAccount = accounts[referrer];

        userAccount.referrer = referrer;
        userAccount.lastActiveTimestamp = getTime();
        parentAccount.referredCount = parentAccount.referredCount.add(1);
        parentAccount.referrals.push(referee);

        emit RegisteredReferer(referee, referrer);
        return true;
    }

    function isCircularReference(address referrer, address referee, uint256 levels)
        internal
        view
        returns (bool)
    {
        address parent = referrer;

        for (uint256 i; i < levels; i++) {
            if (parent == address(0)) {
                break;
            }

            if (parent == referee) {
                return true;
            }

            parent = accounts[parent].referrer;
        }

        return false;
    }
    
    function getReferralAccount(address referrer) external view returns (Account memory) {
        return accounts[referrer];
    }
    
    function getReferralCounts(address referrerAddress) external view returns (ReferralsCount memory) {
        address[] memory referrals = getReferrals(referrerAddress);
        ReferralsCount memory counts;
        
        if(referrals.length == 0) { return counts; }
        
        counts.level_1 = counts.level_1.add(referrals.length);
        
        for(uint256 i = 0; i < referrals.length; i++) {
            address[] memory level2 = getReferrals(referrals[i]);
            counts.level_2 = counts.level_2.add(level2.length);
            
            if(level2.length == 0) { continue; }
            
            for(uint256 j = 0; j < level2.length; j++) {
                address[] memory level3 = getReferrals(level2[j]);
                counts.level_3 = counts.level_3.add(level3.length);
            }
        }
        
        return counts;
    }
    
    function getReferrals(address referrerAddress) internal view returns (address[] memory) {
        return accounts[referrerAddress].referrals;
    }
    
    function setAccountLastActive(address referrer) external onlyWriters {
        uint256 time = getTime();
        accounts[referrer].lastActiveTimestamp = time;
        emit UpdateLastActive(referrer, time);
    }

    function setAccountReward(address accountAddress, uint256 _totalReward) external onlyWriters {
        accounts[accountAddress].reward = _totalReward;
        emit UpdateTotalReward(accountAddress, _totalReward);
    }
    
    function addWriter(address _address) external onlyAdmin {
        _setupRole(WRITE_ACCESS, _address);
    }
    
    /**
     * @dev Returns true if the caller is the current admin.
     */
    function isWriter() public view returns (bool) {
        return hasRole(WRITE_ACCESS, _msgSender());
    }
    
    function setAdmin(address _newAdmin) external onlyAdmin {
      admin = _newAdmin;
    }
    
    /**
     * @dev Returns true if the caller is the current admin.
     */
    function isAdmin() public view returns (bool) {
        return _msgSender() == admin;
    }
    
      /**
   * @dev Get block timestamp with function for testing mock
   */
  function getTime() public view returns(uint256) {
    return now; // solium-disable-line security/no-block-members
  }
}
