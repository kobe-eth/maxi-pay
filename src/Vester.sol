// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "../lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces/IAuraRewardPool.sol";
import { console2 } from "../lib/forge-std/src/console2.sol";

library VesterErrors {
    error NotDaoMsig();
    error NotBeneficiary();
    error AlreadyClaimed();
    error NotVestedYet();
}

/// @title Vester contract
/// @notice Each Maxis User has a personal vesting contract deployed
contract Vester is Initializable {
    using SafeERC20 for ERC20;

    struct VestingPosition {
        uint256 amount;
        uint256 vestingEnds;
        bool claimed;
    }

    //////////////////////////////////////////////////////////////////
    //                         Constants                            //
    //////////////////////////////////////////////////////////////////
    ERC20 public constant STAKED_AURABAL = ERC20(address(0x4EA9317D90b61fc28C418C247ad0CA8939Bbb0e9));
    ERC20 public constant AURA = ERC20(address(0x1509706a6c66CA549ff0cB464de88231DDBe213B));

    IAuraRewardPool public constant AURA_REWARD_POOL =
        IAuraRewardPool(address(0x14b820F0F69614761E81ea4431509178dF47bBD3));
    address public constant DAO_MSIG = address(0xaF23DC5983230E9eEAf93280e312e57539D098D0);
    uint256 public constant DEFAULT_VESTING_PERIOD = 365 days;
    //////////////////////////////////////////////////////////////////
    //                         Storage                              //
    //////////////////////////////////////////////////////////////////
    address public beneficiary;
    uint256 public vestingNonce;
    // Mapping for vesting positions
    // Nonce -> VestingPosition
    mapping(uint256 => VestingPosition) public vestingPositions;

    //////////////////////////////////////////////////////////////////
    //                         Events                               //
    //////////////////////////////////////////////////////////////////
    event BeneficiaryChanged(address indexed oldBeneficiary, address indexed newBeneficiary);
    event VestingPositionCreated(uint256 indexed nonce, uint256 amount, uint256 vestingEnds);
    event Claimed(uint256 indexed nonce, uint256 amount);
    event Ragequit(address indexed to);
    /// @notice Contract initializer
    /// @param _beneficiary Address of the beneficiary that will be able to claim tokens

    function initialise(address _beneficiary) public initializer {
        beneficiary = _beneficiary;
    }

    //////////////////////////////////////////////////////////////////
    //                       Modifiers                              //
    //////////////////////////////////////////////////////////////////

    modifier onlyBeneficiary() {
        if (msg.sender != beneficiary) {
            revert VesterErrors.NotBeneficiary();
        }
        _;
    }

    modifier onlyDaoMsig() {
        if (msg.sender != DAO_MSIG) {
            revert VesterErrors.NotDaoMsig();
        }
        _;
    }

    //////////////////////////////////////////////////////////////////
    //                   Permissioned Setters                       //
    //////////////////////////////////////////////////////////////////
    function setBeneficiary(address _beneficiary) public onlyDaoMsig {
        address oldBeneficiary = beneficiary;
        beneficiary = _beneficiary;
        emit BeneficiaryChanged(oldBeneficiary, _beneficiary);
    }

    //////////////////////////////////////////////////////////////////
    //                       External functions                     //
    //////////////////////////////////////////////////////////////////
    /// @notice Get vesting position by nonce
    /// @param _nonce Nonce of the vesting position
    function getVestingPosition(uint256 _nonce) external view returns (VestingPosition memory) {
        return vestingPositions[_nonce];
    }

    /// @notice Deposit logic
    /// @param _amount Amount of tokens to deposit
    /// @param _vestingPeriod Vesting period in seconds
    function deposit(uint256 _amount, uint256 _vestingPeriod) external {
        _deposit(_amount, _vestingPeriod);
    }

    /// @notice Deposit logic but with default vesting period
    /// @param _amount Amount of tokens to deposit
    function deposit(uint256 _amount) external {
        _deposit(_amount, DEFAULT_VESTING_PERIOD);
    }

    /// @notice Claim vesting position
    /// @param _nonce Nonce of the vesting position
    function claim(uint256 _nonce) external onlyBeneficiary {
        VestingPosition storage vestingPosition = vestingPositions[_nonce];
        if (vestingPosition.claimed) {
            revert VesterErrors.AlreadyClaimed();
        }
        if (block.timestamp < vestingPosition.vestingEnds) {
            revert VesterErrors.NotVestedYet();
        }
        vestingPosition.claimed = true;
        // Claim AURA rewards
        // TODO: Q: should send all AURA rewards even if there are multiple vesting positions?
        AURA_REWARD_POOL.getReward();
        // Transfer staked AURA BAL to beneficiary
        STAKED_AURABAL.safeTransfer(beneficiary, vestingPosition.amount);
        // Transfer AURA to beneficiary
        AURA.safeTransfer(beneficiary, AURA.balanceOf(address(this)));

        emit Claimed(_nonce, vestingPosition.amount);
    }

    /// @notice Ragequit all AURA BAL and AURA in case of emergency
    /// @dev This function is only callable by the DAO multisig
    /// @param _to Address to send all AURA BAL and AURA to
    function ragequit(address _to) external onlyDaoMsig {
        // Claim rewards and transfer AURA to beneficiary
        AURA_REWARD_POOL.getReward();
        console2.log(AURA.balanceOf(address(this)));
        // Transfer staked AURA BAL to beneficiary
        STAKED_AURABAL.safeTransfer(_to, STAKED_AURABAL.balanceOf(address(this)));
        // Transfer AURA to beneficiary
        AURA.safeTransfer(_to, AURA.balanceOf(address(this)));
        emit Ragequit(_to);
    }

    //////////////////////////////////////////////////////////////////
    //                       Internal functions                     //
    //////////////////////////////////////////////////////////////////
    function _deposit(uint256 _amount, uint256 _vestingPeriod) internal {
        STAKED_AURABAL.safeTransferFrom(msg.sender, address(this), _amount);
        uint256 vestingEnds = block.timestamp + _vestingPeriod;
        vestingPositions[vestingNonce] = VestingPosition(_amount, vestingEnds, false);
        emit VestingPositionCreated(vestingNonce, _amount, vestingEnds);
        vestingNonce++;
    }
}
