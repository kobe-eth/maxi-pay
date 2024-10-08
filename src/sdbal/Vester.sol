// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "lib/openzeppelin-contracts/contracts/security/Pausable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import "src/interfaces/IVester.sol";
import "src/interfaces/IMerkle.sol";
import "src/interfaces/IDelegate.sol";
import "src/interfaces/ILiquidityGauge.sol";

/// @title Vester contract
/// @notice Each Maxis User has a personal vesting contract deployed
 contract Vester is Initializable, Pausable, IVester {
     using SafeERC20 for ERC20;

     //////////////////////////////////////////////////////////////////
     //                         Constants                            //
     //////////////////////////////////////////////////////////////////

     address public constant SD_DELEGATION = address(0x52ea58f4FC3CEd48fa18E909226c1f8A0EF887DC);
     address public constant DELEGATION_REGISTRY = address(0x469788fE6E9E9681C6ebF3bF78e7Fd26Fc015446);
     address public constant VOTING_REWARDS_MERKLE_STASH = address(0x03E34b085C52985F6a5D27243F20C84bDdc01Db4);

     ERC20 public constant SD_BAL_GAUGE =
         ERC20(address(0x3E8C72655e48591d93e6dfdA16823dB0fF23d859));

     ERC20 public constant BAL = ERC20(address(0xba100000625a3754423978a60c9317c58a424e3D));
     ERC20 public constant USDC = ERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

     address public constant MAXIS_OPS = address(0x166f54F44F271407f24AA1BE415a730035637325);
     address public constant DAO_MSIG = address(0x10A19e7eE7d7F8a52822f6817de8ea18204F2e4f);
     uint256 public constant DEFAULT_VESTING_PERIOD = 365 days;

     //////////////////////////////////////////////////////////////////
     //                         Storage                              //
     //////////////////////////////////////////////////////////////////

     address public beneficiary;
     uint256 internal vestingNonce;

     // Mapping for vesting positions
     // Nonce -> VestingPosition
     mapping(uint256 => VestingPosition) internal vestingPositions;

     //////////////////////////////////////////////////////////////////
     //                         Events                               //
     //////////////////////////////////////////////////////////////////

     event BeneficiaryChanged(address indexed oldBeneficiary, address indexed newBeneficiary);
     event VestingPositionCreated(uint256 indexed nonce, uint256 amount, uint256 vestingEnds);
     event Claimed(uint256 indexed nonce, uint256 amount);
     event ClaimedVotingRewards(address token,uint256 amount);
     event Ragequit(address indexed to);
     event Sweep(address indexed token, uint256 amount, address indexed to);

    error NotBeneficiary();
    error NotMaxis();
    error NotDAO();
    error AlreadyClaimed();
    error NotVestedYet();

    error ProtectedToken();

     constructor() {
         // Disable initializers for the implementation contract
         _disableInitializers();
     }

     /// @notice Contract initializer
     /// @param _beneficiary Address of the beneficiary that will be able to claim tokens
     function initialise(address _beneficiary) public initializer {
         beneficiary = _beneficiary;

         /// Delegate to SD_DELEGATION.
         IDelegate(DELEGATION_REGISTRY).setDelegate(bytes32("sdbal.eth"), SD_DELEGATION);
     }

     //////////////////////////////////////////////////////////////////
     //                       Modifiers                              //
     //////////////////////////////////////////////////////////////////

     modifier onlyBeneficiary() {
         if (msg.sender != beneficiary) {
             revert NotBeneficiary();
         }
         _;
     }

     modifier onlyDaoMsig() {
         if (msg.sender != DAO_MSIG) {
             revert NotDAO();
         }
         _;
     }

     modifier onlyMaxisOps() {
         if (msg.sender != MAXIS_OPS) {
             revert NotMaxis();
         }
         _;
     }

     //////////////////////////////////////////////////////////////////
     //                   Permissioned Setters                       //
     //////////////////////////////////////////////////////////////////
     function setBeneficiary(address _beneficiary) public onlyMaxisOps {
         address oldBeneficiary = beneficiary;
         beneficiary = _beneficiary;
         emit BeneficiaryChanged(oldBeneficiary, _beneficiary);
     }

     //////////////////////////////////////////////////////////////////
     //                       External functions                     //
     //////////////////////////////////////////////////////////////////
     /// @notice Get current vesting nonce. This nonce represents future vesting position nonce
     /// @dev If needed to check current existing nonce, subtract 1 from this value
     function getVestingNonce() external view returns (uint256) {
         return vestingNonce;
     }

     /// @notice Get vesting position by nonce
     /// @param _nonce Nonce of the vesting position
     function getVestingPosition(uint256 _nonce) external view returns (VestingPosition memory) {
         return vestingPositions[_nonce];
     }

     /// @notice Claim vesting position
     /// @param _nonce Nonce of the vesting position
     function claim(uint256 _nonce) external onlyBeneficiary whenNotPaused {
         VestingPosition storage vestingPosition = vestingPositions[_nonce];
         if (vestingPosition.claimed) {
             revert AlreadyClaimed();
         }
         if (block.timestamp < vestingPosition.vestingEnds) {
             revert NotVestedYet();
         }
         vestingPosition.claimed = true;

         // Claim BAL rewards
         ILiquidityGauge(address(SD_BAL_GAUGE)).claim_rewards(address(this), msg.sender);

         // Transfer staked BAL to beneficiary
         SD_BAL_GAUGE.safeTransfer(msg.sender, vestingPosition.amount);

         emit Claimed(_nonce, vestingPosition.amount);
     }

     /// @notice Deposit logic but with default vesting period
     /// @param _amount Amount of tokens to deposit
     function deposit(uint256 _amount) external onlyMaxisOps whenNotPaused {
         _deposit(_amount, DEFAULT_VESTING_PERIOD);
     }

     /// @notice Deposit logic
     /// @param _amount Amount of tokens to deposit
     /// @param _vestingPeriod Vesting period in seconds
     function deposit(uint256 _amount, uint256 _vestingPeriod) external onlyMaxisOps whenNotPaused {
         _deposit(_amount, _vestingPeriod);
     }

     /// @notice Maxis msig should be able to sweep any ERC20 tokens except staked aura bal
     /// @param _token Address of the token to sweep
     /// @param _amount Amount of tokens to sweep
     /// @param _to Address to send the tokens to
     function sweep(address _token, uint256 _amount, address _to) external onlyMaxisOps {
         if (_token == address(SD_BAL_GAUGE)) {
             revert ProtectedToken();
         }
         ERC20(_token).safeTransfer(_to, _amount);
         emit Sweep(_token, _amount, _to);
     }

     /// @notice Ragequit all in case of emergency
     /// @dev This function is only callable by the DAO multisig
     /// @param _to Address to send all BAL BAL and BAL to
     function ragequit(address _to) external onlyDaoMsig {
         // Claim rewards and transfer BAL to beneficiary
         ILiquidityGauge(address(SD_BAL_GAUGE)).claim_rewards(address(this), _to);

         // Transfer staked BAL BAL to beneficiary
         SD_BAL_GAUGE.safeTransfer(_to, SD_BAL_GAUGE.balanceOf(address(this)));

         // Transfer BAL to beneficiary.
         BAL.safeTransfer(_to, BAL.balanceOf(address(this)));

         // Transfer USDC to beneficiary.
         USDC.safeTransfer(_to, USDC.balanceOf(address(this)));

         // Pause and render the contract useless
         _pause();
         emit Ragequit(_to);
     }

     /// @notice Function to claim aura rewards from staked auraBAL
     /// @notice Can be still claimed even if the contract is paused
     function claimRewards() external onlyBeneficiary {
         ILiquidityGauge(address(SD_BAL_GAUGE)).claim_rewards(address(this), beneficiary);
     }

     function claimVotingRewards(address token, uint index, uint256 amount, bytes32[] calldata proofs) external onlyBeneficiary {
        IMerkle(VOTING_REWARDS_MERKLE_STASH).claim(token, index, address(this), amount, proofs);
        ERC20(token).safeTransfer(msg.sender, amount);

        emit ClaimedVotingRewards(token, amount);
     }

     //////////////////////////////////////////////////////////////////
     //                       Internal functions                     //
     //////////////////////////////////////////////////////////////////
     function _deposit(uint256 _amount, uint256 _vestingPeriod) internal {
         // Local variable to avoid multiple SLOADs
         uint256 _nonce = vestingNonce;
         // Increase nonce
         vestingNonce++;
         uint256 vestingEnds = block.timestamp + _vestingPeriod;
         vestingPositions[_nonce] = VestingPosition(_amount, vestingEnds, false);
         SD_BAL_GAUGE.safeTransferFrom(msg.sender, address(this), _amount);
         emit VestingPositionCreated(_nonce, _amount, vestingEnds);
     }
 }
