// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.23;

import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "openzeppelin-contracts/contracts/utils/introspection/IERC165.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {
    AccessControlDefaultAdminRules
} from "openzeppelin-contracts/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {IERC20Permit} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStakingV1} from "./interfaces/IStakingV1.sol";
import {IMigratorV1} from "./interfaces/IMigratorV1.sol";

/**
 *     @title Fixed APR staking contract
 */
contract Staking is IMigratorV1, Pausable, ReentrancyGuard, AccessControlDefaultAdminRules {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER");
    bytes32 public constant MIGRATOR_ROLE = keccak256("MIGRATOR");

    uint8 public constant MAX_STAKES_PER_USER = 100;

    // staking and reward token are the same and can be set only once during deployment
    // we assume ERC20 doesn't have any fee on transfer or rebasing logic
    IERC20 public immutable TOKEN;

    uint256 public activeTotalStaked;//@audit-info সব user মিলে 50,000 token stake করেছে।
    uint256 public activeTotalRewards;//@audit-info Contract এর pending reward obligation 5,000 token।

    StakingPeriod[] public stakingPeriods;  //@audit-info get specific staking pool information
    mapping(address user => UserStake[]) public userStakes;//@audit-info User এর 3টা stake আছে। stacke 0, stake 1, stake 2
    mapping(address migrator => mapping(address user => bool isAuthorized)) public migrationPermits;//@audit-info User V2 migrator contract কে approve করেছে।

    constructor(address _admin, address _manager, address _pauser, address _token)
        AccessControlDefaultAdminRules(1 days, _admin)
    {
        TOKEN = IERC20(_token);
        _grantRole(MANAGER_ROLE, _manager);
        _grantRole(PAUSER_ROLE, _pauser);
    }

    function stake(uint8 periodIndex, uint256 amount, StakeParams calldata params)//@audit-info  uint64 maxStakingDurationSeconds; ,, uint64 maxUnlockDurationSeconds; ,, uint32 minAprBps;
    address referrer;
        external
        nonReentrant
        whenNotPaused
        returns (uint8)
    {
        return _stake(periodIndex, amount, params);
    }


    function stakeWithPermit(
        uint8 periodIndex,
        uint256 amount,
        StakeParams calldata params,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused returns (uint8) {
        // try catch for avoiding frontrun griefing
        // https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/IERC20Permit.sol#L14
        try IERC20Permit(address(TOKEN)).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        return _stake(periodIndex, amount, params);
    }

    // user allowed to withdraw when contract is paused
    function withdraw(uint8 stakeIndex) external nonReentrant {//@audit-info Contract pause করলে নতুন stake/addition বন্ধ হয়, কিন্তু পুরানো stake exit করা যায়।
        _withdraw(stakeIndex);
    }

    function setMigrationPermit(address _migrator, bool _isMigrationPermitted) external {//@audit-info ইউজারকে control দেয় তার staking position migrate করা যাবে কি না।
        if (!hasRole(MIGRATOR_ROLE, _migrator)) revert MigratorNotFound(_migrator);

        migrationPermits[_migrator][msg.sender] = _isMigrationPermitted;
        emit MigrationPermitUpdated(_migrator, msg.sender, _isMigrationPermitted);
    }
  
    function addStakingPeriod(//@audit-info “This function allows the manager/admin to create
        uint256 _cap,//@audit-info 10_000 capacity
        uint64 _stakingDurationSeconds,//@audit-info 30 * 24 * 60 * 60  // 30 days
        uint64 _unlockDurationSeconds,//@audit-info  10 * 24 * 60 * 60   // 10 days linear unlock
        uint32 _aprBps,//@audit-info 10% APR
        bool _isActive
    ) external onlyRole(MANAGER_ROLE) returns (uint8) {
        if (_stakingDurationSeconds == 0) revert StakingDurationCannotBeZero();
        if (_unlockDurationSeconds == 0) revert UnlockDurationCannotBeZero();
        if (stakingPeriods.length > type(uint8).max) revert MaxStakingPeriodsReached();

        // to simplify logic, we don't set restrictions on non-zero rewards
        uint8 periodIndex = uint8(stakingPeriods.length);
        stakingPeriods.push(
            StakingPeriod({
                cap: _cap,
                capUsed: 0,//@audit-info initially no one has staked yet.
                stakingDurationSeconds: _stakingDurationSeconds,
                unlockDurationSeconds: _unlockDurationSeconds,
                aprBps: _aprBps,
                isActive: _isActive
            })
        );

        emit StakingPeriodAdded(periodIndex, _cap, _stakingDurationSeconds, _unlockDurationSeconds, _aprBps, _isActive);
        return periodIndex;
    }

    function updateStakingPeriod(
        uint8 periodIndex,//@audit-info periodIndex = 0
        uint256 _cap,
        uint64 _stakingDurationSeconds,
        uint64 _unlockDurationSeconds,
        uint32 _aprBps,
        bool _isActive
    ) external onlyRole(MANAGER_ROLE) {
        if (_stakingDurationSeconds == 0) revert StakingDurationCannotBeZero();
        if (_unlockDurationSeconds == 0) revert UnlockDurationCannotBeZero();
        if (periodIndex >= stakingPeriods.length) revert PeriodNotFound();
        StakingPeriod storage stakingPeriod = stakingPeriods[periodIndex];

        // we allow to set cap lower than is currently being used
        stakingPeriod.cap = _cap;
        stakingPeriod.stakingDurationSeconds = _stakingDurationSeconds;
        stakingPeriod.unlockDurationSeconds = _unlockDurationSeconds;
        stakingPeriod.aprBps = _aprBps;
        stakingPeriod.isActive = _isActive;

        emit StakingPeriodUpdated(
            periodIndex, _cap, _stakingDurationSeconds, _unlockDurationSeconds, _aprBps, _isActive
        );
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**        
     *     @dev manager allowed to recover full amount of any ERC20 token accidentally sent to staking contract
     *          except staking token itself. In case of staking token - manager allowed to recover only
     *          extra amount (which is not supposed to be distributed to users)
     */
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyRole(MANAGER_ROLE) {
        if (tokenAddress == address(TOKEN)) {
            uint256 requiredBalance = activeTotalStaked + activeTotalRewards;
            uint256 contractTokenBalance = TOKEN.balanceOf(address(this));
            if (contractTokenBalance < requiredBalance + tokenAmount) {
                // invariant contractTokenBalance >= requiredBalance so can't underflow //@audit-issue 
                revert NotEnoughBalanceToRecover(tokenAddress, tokenAmount, contractTokenBalance - requiredBalance);
            }
        }
        IERC20(tokenAddress).safeTransfer(msg.sender, tokenAmount);//@audit-issue What if multiple users send the tokens That time the will handle it and you cover and back to the US
        emit Recovered(tokenAddress, tokenAmount);
    }

    /**
     *     @dev fully withdrawn stakes are not getting migrated
     */
    function migratePositionsFrom(address user)
        external
        nonReentrant
        onlyRole(MIGRATOR_ROLE)
        returns (UserStake[] memory)
    {
        if (!migrationPermits[msg.sender][user]) revert MigratorNotPermitted(msg.sender, user);//@audit-issue where is the bool

        UserStake[] memory stakes = userStakes[user];

        uint256 stakesToMigrateCount;  //@audit-info এখানে কোনো stake store হয়নি। শুধু number গণনা হয়েছে 2
        // Count migratedStakes array size
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].claimedAmount + stakes[i].claimedReward < stakes[i].amount + stakes[i].reward) {//@audit-info  if (claimed < total), যদি stake fully claimed না হয় তাহলে migrate হবে। ,0 < 1008 → TRUE , 504 < 504 → FALSE, 101 < 302 → TRUE , 
                stakesToMigrateCount++;  //@audit-info Stake 0 ,Stake 2 ;Count = 2
            }
        }
                                       //@audit-info size of anrray⤵️
        UserStake[] memory migratedStakes = new UserStake[](stakesToMigrateCount);  //@audit-info migratedStakes size = 2 ,,নতুন array (যেখানে migrate হওয়া stakes রাখা হবে),, After two array will store
        delete userStakes[user];//@audit-info পুরো storage array খালি।

        uint256 migratedCount;  //@audit-info migratedStakes array এর index track করবে
        uint256 unclaimedUserAmount;  //@audit-info user এর unclaimed principal হিসাব
        uint256 unclaimedUserRewards;  //@audit-info user এর unclaimed reward হিসাব
        for (uint256 i = 0; i < stakes.length; i++) {
            if (stakes[i].claimedAmount + stakes[i].claimedReward >= stakes[i].amount + stakes[i].reward) {  //@audit-info  migrate করো না,storage এ রেখে de
                userStakes[user].push(stakes[i]);
                continue;
            }
            
            unclaimedUserAmount += stakes[i].amount - stakes[i].claimedAmount;   //@audit-info cholbe when claimed < total   //@audit-info 1000 - 400 = 600
            unclaimedUserRewards += stakes[i].reward - stakes[i].claimedReward;   //@audit-info 8 - 2 = 6
             //! Jante hobe
            migratedStakes[migratedCount] = stakes[i];  //@audit-info Storing the stake[i] to migratedCount index of migratedStakes array. migratedStakes[0] = stakes[0],  [Stake0, Stake2]
            migratedCount++;
        }

        // The capUsed is intentionally not decremented for migrated positions. Migration is a terminal operation:
        // the manager will deactivate all staking periods or pauser will pause the contract before migration begins
        activeTotalStaked -= unclaimedUserAmount;  //@audit-info activeTotalStaked = 10000,, unclaimedUserAmount = 600 ,,activeTotalStaked = 9400
        activeTotalRewards -= unclaimedUserRewards;  //@audit-info activeTotalRewards = 500 ,,unclaimedUserRewards = 6 ,, activeTotalRewards = 494

        TOKEN.safeTransfer(msg.sender, unclaimedUserAmount + unclaimedUserRewards);   //@audit-info 600 + 6 = 606 tokens

        emit MigrateFrom(msg.sender, user);  //@audit-info migrator = msg.sender
        return migratedStakes;
    }

    function getStakingPeriods() external view returns (StakingPeriod[] memory) {  //@audit-info Return all staking pools
        return stakingPeriods;
    }

    function getStakingPeriod(uint8 periodIndex) external view returns (StakingPeriod memory) {//@audit-info Specific staking pool information
        if (periodIndex >= stakingPeriods.length) revert PeriodNotFound();
        return stakingPeriods[periodIndex];
    }

    function getUserStakes(address user) external view returns (UserStake[] memory) {//@audit-info Specific staking pool information return করা
        return userStakes[user];
    }

    function getUserStake(address user, uint8 stakeIndex) external view returns (UserStake memory) {//@audit-info Return a specific stake of a user
        if (stakeIndex >= userStakes[user].length) revert StakeNotFound();
        return userStakes[user][stakeIndex];
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlDefaultAdminRules, IERC165)
        returns (bool)
    {
        return interfaceId == type(IMigratorV1).interfaceId || interfaceId == type(IStakingV1).interfaceId
            || super.supportsInterface(interfaceId);  //@audit-info Parent contract এর interfaces check করো
    }

    function _stake(uint8 periodIndex, uint256 amount, StakeParams calldata params) internal returns (uint8) {  //@audit-info amount = 1,000
        if (amount == 0) revert CannotStakeZero();
        if (periodIndex >= stakingPeriods.length) revert PeriodNotFound();

        StakingPeriod storage stakingPeriod = stakingPeriods[periodIndex];  //@audit-info এখানে specific staking period load করছে।
        if (!stakingPeriod.isActive) revert StakingPeriodInactive(periodIndex);  //@audit-info staking period active হতে হবে

/*  //@audit-info User says:

     APR >= 10%
     staking duration <= 30 days
     unlock <= 7 days ⤵️*/
        // ensuring that staking period conditions were not updated in front of this operation
        if (stakingPeriod.stakingDurationSeconds > params.maxStakingDurationSeconds) {  //@audit-info কিন্তু transaction confirm হওয়ার আগে manager update করলো: ,, 90 > 30  → TRUE
            revert StakingPeriodStakingDurationDiffer(
                periodIndex, params.maxStakingDurationSeconds, stakingPeriod.stakingDurationSeconds
            );
        }
        if (stakingPeriod.unlockDurationSeconds > params.maxUnlockDurationSeconds) {  //@audit-info Manager update করলো:,, unlockDuration = 30 days ,,30 > 7
            revert StakingPeriodUnlockDurationDiffer(
                periodIndex, params.maxUnlockDurationSeconds, stakingPeriod.unlockDurationSeconds
            );
        }
        if (stakingPeriod.aprBps < params.minAprBps) {  //@audit-info Manager update করলো:,,APR = 5%,, 500 < 1000
            revert StakingPeriodAprDiffer(periodIndex, params.minAprBps, stakingPeriod.aprBps);
        }

        uint256 updatedCapUsed = stakingPeriod.capUsed + amount;  //@audit-info updatedCapUsed = 6000 + 1000,, updatedCapUsed = 7000
        if (stakingPeriod.cap < updatedCapUsed) revert StakingCapReached(stakingPeriod.cap);//@audit-info 10000 < 7000 ❌ false
        if (userStakes[msg.sender].length >= MAX_STAKES_PER_USER) revert MaxUserStakesReached(MAX_STAKES_PER_USER);   //@audit-info একজন user সর্বোচ্চ 100 stakes রাখতে পারবে।

        uint256 rewardBpsDenominator = 1e4 * 365 days;
        uint256 reward = (amount * stakingPeriod.aprBps * stakingPeriod.stakingDurationSeconds) / rewardBpsDenominator;/*@audit-info reward = 1000 × 1000 × 30                                 
                                                                                                                                        
                                                                                                                                              ----------------
                                                                                                                                                 10000 × 365       = 82.19 token */

        uint256 contractBalance = TOKEN.balanceOf(address(this));
        uint256 requiredBalance = activeTotalStaked + activeTotalRewards + reward;  //@audit-info requiredBalance = 10000 + 250 + 8 ,, requiredBalance = 10258
        // ensure that smart-contract balance is enough to pay reward
        if (requiredBalance > contractBalance) {   //@audit-info 10258 > 11000 ❌ false
            revert NotEnoughContractBalance(address(TOKEN), contractBalance, requiredBalance);
        }

        activeTotalStaked += amount;  //@audit-info activeTotalStaked = 10,000 + 1,000 ,, activeTotalStaked = 11,000
        activeTotalRewards += reward;//@audit-info activeTotalRewards = 500 + 8 ,, activeTotalRewards = 508
        stakingPeriod.capUsed = updatedCapUsed;  //@audit-info capUsed = 6000 + 1000 ,, capUsed = 7000

        uint8 stakeIndex = uint8(userStakes[msg.sender].length);
        userStakes[msg.sender].push(
            UserStake({
                amount: amount,      //@audit-info amount = 1000
                reward: reward,      //@audit-info reward = 8 tokens
                claimedAmount: 0,    //@audit-info  claimedAmount: 0
                claimedReward: 0,    //@audit-info claimedAmount = 500
                aprBps: stakingPeriod.aprBps,
                stakeTime: uint64(block.timestamp),
                unlockTime: uint64(block.timestamp) + stakingPeriod.stakingDurationSeconds,
                unlockDuration: stakingPeriod.unlockDurationSeconds
            })
        );

        emit Staked(msg.sender, periodIndex, params.referrer, stakeIndex, amount);
        TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        return stakeIndex;
    }

    /**
     *             @notice withdraw linear unlock mechanism
     *             staked amount and reward accrued linearly during unlock period
     *             user can withdraw multiple times
     */
    function _withdraw(uint8 stakeIndex) internal {  //@audit-ok  Fractional rounding

        if (stakeIndex >= userStakes[msg.sender].length) revert StakeNotFound();  //@audit-info msg.sender = the caller of the function.,,userStakes[msg.sender] → array of this user’s stakes.,, Check if the stakeIndex exists.

        UserStake storage userStake = userStakes[msg.sender][stakeIndex];  //@audit-info Load the specific stake struct for this user.
        if (block.timestamp <= userStake.unlockTime) {   //@audit-info stakeTime + stakingDuration (from _stake()).,,User cannot withdraw before unlockTime.
            revert RewardsNotAvailableYet(uint64(block.timestamp), userStake.unlockTime);
        }
        if (userStake.claimedAmount + userStake.claimedReward >= userStake.amount + userStake.reward) {   //@audit-info claimedAmount + claimedReward = 110,, amount + reward = 110
            revert AlreadyWithdrawn(stakeIndex);
        }

        uint256 accruedAmount =
            _getAccrued(userStake.amount, userStake.unlockDuration, block.timestamp - userStake.unlockTime);  //@audit-info accruedAmount = _getAccrued(1000, 10, 3) = 1000 * 3 / 10 = 300
        uint256 accruedReward =
            _getAccrued(userStake.reward, userStake.unlockDuration, block.timestamp - userStake.unlockTime);  //@audit-info accruedReward = _getAccrued(8, 10, 3) = 8 * 3 / 10 ≈ 2.4 ≈ 2 tokens

        uint256 amountToClaim = accruedAmount - userStake.claimedAmount;  //@audit-info  300 - 0 = 300
        uint256 rewardToClaim = accruedReward - userStake.claimedReward;   //@audit-info 2 - 0 = 2
              /*@audit-info activeTotalStaked = 11,000
activeTotalRewards = 508
userStake.amount = 1000
userStake.reward = 8
userStake.claimedAmount = 0
userStake.claimedReward = 0
amountToClaim = 300
rewardToClaim = 2*/

        activeTotalStaked -= amountToClaim;  //@audit-info 11,000 - 300 = 10,700
        activeTotalRewards -= rewardToClaim;  //@audit-info  508 - 2 = 506
        userStake.claimedAmount += amountToClaim;  //@audit-info  0 + 300 = 300
        userStake.claimedReward += rewardToClaim;  //@audit-info 0 + 2 = 2

        emit Withdrawn(msg.sender, stakeIndex, amountToClaim, rewardToClaim);  //@audit-info  300, 2
        TOKEN.safeTransfer(msg.sender, amountToClaim + rewardToClaim);  //@audit-info sends tokens to the user. ,,300 + 2 = 302 tokens
    }
        //@audit-info Linearly grow unlock function
    function _getAccrued(uint256 amount, uint256 duration, uint256 elapsed) internal pure returns (uint256) {
        return Math.mulDiv(amount, Math.min(elapsed, duration), duration);  //@audit-info 1000 × 3 / 10 = 300 tokens unlocked
    }  //@audit-info Why min is critical,, Without min,, 1000 × 11 / 10 = 1100  ,,User extra token পেত।
    
}
