pragma solidity 0.6.12;
// SPDX-License-Identifier: MIT

import '@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol';
import '@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol';

import "./ArtichainToken.sol";
interface IMigratorArt {
    // Perform LP token migration from legacy PancakeSwap to ArtichainSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to PancakeSwap LP tokens.
    // ArtichainSwap must mint EXACTLY the same amount of PancakeSwap LP tokens or
    // else something bad will happen. Traditional PancakeSwap does not
    // do that so be careful!
    function migrate(IBEP20 token) external returns (IBEP20);
}

// MasterArt is the master of Ait. He can make Ait and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once AIT is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterArt is Ownable {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of AITs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accAitPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accAitPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IBEP20 lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. AITs to distribute per block.
        uint256 lastRewardBlock;  // Last block number that AITs distribution occurs.
        uint256 accAitPerShare; // Accumulated AITs per share, times 1e12. See below.
        uint16 depositFee;      // Deposit fee in basis points
    }

    // Block reward plan
    struct BlockRewardInfo {
        uint256 firstBlock;           // First block number
        uint256 lastBlock;            // Last block number
        uint256 reward;               // Block reward amount
    }

    // The Artichain TOKEN!
    ArtichainToken public ait;
    // Dev address.
    address public devAddr;
    // Fee address
    address public feeAddr;
    // Bonus muliplier for early ait makers.
    uint256 public BONUS_MULTIPLIER = 1;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorArt public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    BlockRewardInfo[] public rewardInfo;

    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when AIT mining starts.
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event SetDevAddress(address indexed user, address indexed newAddress);

    constructor(
        ArtichainToken _ait,
        address _devAddr,
        address _feeAddr,
        uint256 _startBlock
    ) public {
        ait = _ait;
        devAddr = _devAddr;
        feeAddr = _feeAddr;
        startBlock = _startBlock;

        // staking pool
        poolInfo.push(PoolInfo({
            lpToken: _ait,
            allocPoint: 1000,
            lastRewardBlock: startBlock,
            accAitPerShare: 0,
            depositFee: 0
        }));

        setRewardInfo();

        totalAllocPoint = 1000;
    }

    function updateMultiplier(uint256 multiplierNumber) public onlyOwner {
        BONUS_MULTIPLIER = multiplierNumber;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint256 _allocPoint, IBEP20 _lpToken, uint16 _depositFee, bool _withUpdate) public onlyOwner {
        require(_depositFee <= 10000, "set: invalid deposit fee basis points");

        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accAitPerShare: 0,
            depositFee: _depositFee
        }));

        updateStakingPool();
    }

    // Update the given pool's AIT allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFee, bool _withUpdate) public onlyOwner {
        require(_depositFee <= 10000, "set: invalid deposit fee basis points");

        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFee = _depositFee;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
            updateStakingPool();
        }
    }

    function updateStakingPool() internal {
        uint256 length = poolInfo.length;
        uint256 points = 0;
        for (uint256 pid = 1; pid < length; ++pid) {
            points = points.add(poolInfo[pid].allocPoint);
        }
        if (points != 0) {
            points = points.div(3);
            totalAllocPoint = totalAllocPoint.sub(poolInfo[0].allocPoint).add(points);
            poolInfo[0].allocPoint = points;
        }
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorArt _migrator) public onlyOwner {
        migrator = _migrator;
    }

    // Migrate lp token to another lp contract. Can be called by anyone. We trust that migrator contract is good.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "migrate: no migrator");
        PoolInfo storage pool = poolInfo[_pid];
        IBEP20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IBEP20 newLpToken = migrator.migrate(lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "migrate: bad");
        pool.lpToken = newLpToken;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        return _to.sub(_from).mul(BONUS_MULTIPLIER);
    }

    // Returns reward for each block
    function getBlockReward() public view returns (uint256) {
        if(block.number < startBlock) return 0;

        for(uint i = 0; i < 3; i++) {
            if(block.number <= rewardInfo[i].lastBlock) {
                return rewardInfo[i].reward;
            }
        }

        return 0;
    }

    // Update reward table for 3 years
    // first year reward: 4000 
    // second year reward: 2000 
    // third year reward: 1000 
    function setRewardInfo() internal {
        if(rewardInfo.length == 0) {
            uint256 supply = 4000;
            for(uint i = 0; i < 3; i++) {
                uint256 perBlockReward = supply.mul(3 * 1e18).mul(100).div(101).div(365 days);
                rewardInfo.push(BlockRewardInfo({firstBlock: 0, lastBlock: 0, reward: perBlockReward}));
                supply = supply.div(2);
            }
        }

        uint256 _firstBlock = startBlock;
        for(uint i = 0; i < 3; i++) {
            rewardInfo[i].firstBlock = _firstBlock;
            rewardInfo[i].lastBlock = _firstBlock + (365 days) / 3;
            _firstBlock = _firstBlock + (365 days) / 3 + 1;
        }
    }

    function calcPoolReward(uint256 _pid) internal view returns (uint256){
        PoolInfo storage pool = poolInfo[_pid];
        if(block.number < startBlock) return 0;

        uint256 aitReward = 0;
        uint256 lastBlock = pool.lastRewardBlock;
        for(uint i = 0; i < 3; i++) {
            if(pool.lastRewardBlock > rewardInfo[i].lastBlock) continue;

            if(block.number <= rewardInfo[i].lastBlock) {
                uint256 multiplier = getMultiplier(lastBlock, block.number);
                uint256 _reward = multiplier.mul(rewardInfo[i].reward);
                aitReward = aitReward.add(_reward);

                break;
            } else {
                uint256 multiplier = getMultiplier(lastBlock, rewardInfo[i].lastBlock);
                uint256 _reward = multiplier.mul(rewardInfo[i].reward);
                aitReward = aitReward.add(_reward);
            }
            lastBlock = rewardInfo[i].lastBlock;
        }

        return aitReward.mul(pool.allocPoint).div(totalAllocPoint);
    }

    // View function to see pending AITs on frontend.
    function pendingAit(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accAitPerShare = pool.accAitPerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 aitReward = calcPoolReward(_pid);
            accAitPerShare = accAitPerShare.add(aitReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accAitPerShare).div(1e12).sub(user.rewardDebt);
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
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 aitReward = calcPoolReward(_pid);

        ait.mint(devAddr, aitReward.div(100)); // 1% is dev reward
        ait.mint(address(this), aitReward);
        pool.accAitPerShare = pool.accAitPerShare.add(aitReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterArt for AIT allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accAitPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                safeAitTransfer(msg.sender, pending);
            }
        }
        if (_amount > 0) {
            pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            if (pool.depositFee > 0) {
                uint256 depositFee = _amount.mul(pool.depositFee).div(10000);
                pool.lpToken.safeTransfer(feeAddr, depositFee);
                user.amount = user.amount.add(_amount).sub(depositFee);
            } else {
                user.amount = user.amount.add(_amount);
            }
        }
        user.rewardDebt = user.amount.mul(pool.accAitPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from MasterArt.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accAitPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            safeAitTransfer(msg.sender, pending);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.lpToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accAitPerShare).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe ait transfer function, just in case if rounding error causes pool to not have enough AITs.
    function safeAitTransfer(address _to, uint256 _amount) internal {
        uint256 aitBal = ait.balanceOf(address(this));
        bool transferSuccess = false;
        if (_amount > aitBal) {
            transferSuccess = ait.transfer(_to, aitBal);
        } else {
            transferSuccess = ait.transfer(_to, _amount);
        }
        require(transferSuccess, "safeAitTransfer: transfer failed");
    }

    // Update dev address by the previous dev.
    function dev(address _devAddr) public {
        require(msg.sender == devAddr, "dev: wut?");
        devAddr = _devAddr;

        emit SetDevAddress(msg.sender, _devAddr);
    }
    
    // Update fee address by the previous fee manager.
    function setFeeAddress(address _feeAddr) public {
        require(msg.sender == feeAddr, "setFeeAddress: Forbidden");
        feeAddr = _feeAddr;

        emit SetFeeAddress(msg.sender, _feeAddr);
    }

    function updateStartBlock(uint256 _startBlock) public onlyOwner {
        require(block.number < startBlock, "Staking was started already");
        require(block.number < _startBlock);
        
        startBlock = _startBlock;
        setRewardInfo();
    }
}
