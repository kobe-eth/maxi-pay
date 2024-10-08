// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "forge-std/Test.sol";

import "test/Utils.sol";
import "src/Factory.sol";
import "src/sdbal/Vester.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockMerkle {
  function claim(address token, uint256, address account, uint256 amount, bytes32[] calldata) public {
        ERC20(token).transfer(account, amount);
    }
}

contract TestSDVester is Test {
    using stdStorage for StdStorage;

     address public constant SD_DELEGATION = address(0x52ea58f4FC3CEd48fa18E909226c1f8A0EF887DC);
     address public constant DELEGATION_REGISTRY = address(0x469788fE6E9E9681C6ebF3bF78e7Fd26Fc015446);
     address public constant VOTING_REWARDS_MERKLE_STASH = address(0x03E34b085C52985F6a5D27243F20C84bDdc01Db4);

     ERC20 public constant SD_BAL_GAUGE =
         ERC20(address(0x3E8C72655e48591d93e6dfdA16823dB0fF23d859));

     ERC20 public constant SD_BAL = ERC20(address(0xF24d8651578a55b0C119B9910759a351A3458895));
     ERC20 public constant BAL = ERC20(address(0xba100000625a3754423978a60c9317c58a424e3D));
     ERC20 public constant USDC = ERC20(address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48));

     address public constant MAXIS_OPS = address(0x166f54F44F271407f24AA1BE415a730035637325);
     address public constant DAO_MSIG = address(0x10A19e7eE7d7F8a52822f6817de8ea18204F2e4f);

    Utils internal utils;

    address payable[] internal users;
    address public alice;
    address public bob;
    address public randomEOA;

    Factory public factory;
    Vester public vester;

    function setStorage(address _user, bytes4 _selector, address _contract, uint256 value) public {
        uint256 slot = stdstore.target(_contract).sig(_selector).with_key(_user).find();
        vm.store(_contract, bytes32(slot), bytes32(value));
    }

    function setUp() public {
        vm.createSelectFork("mainnet", 20_921_329);

        utils = new Utils();
        users = utils.createUsers(5);
        alice = users[0];
        vm.label(alice, "Alice");
        bob = users[1];
        vm.label(bob, "Bob");
        randomEOA = users[2];
        vm.label(randomEOA, "randomEOA");

        vester = new Vester();
        factory = new Factory(address(vester), MAXIS_OPS);
    }


    //////////////////////////////////////////////////////////////////
    //                   Setters and misc                           //
    //////////////////////////////////////////////////////////////////
    /// @dev DAO msig can override beneficiary
    function testSetBeneficiaryBis() public {
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        vm.prank(MAXIS_OPS);
        aliceVester.setBeneficiary(bob);
        assertEq(aliceVester.beneficiary(), bob);
    }

    function testSetBeneficiaryUnhappy() public {
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        vm.expectRevert(abi.encodeWithSelector(Vester.NotMaxis.selector));
        vm.prank(alice);
        aliceVester.setBeneficiary(bob);
    }

    //////////////////////////////////////////////////////////////////
    //                   Deposits and claims                        //
    //////////////////////////////////////////////////////////////////
    /// @dev Simple case when deposit creates vesting position
    function testDepositHappy(uint256 _depositAmount) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        // Deploy a new vesting contract
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        // Give st auraBAL to the DAO multisig
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        // Approve the vesting contract to spend st auraBAL
        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        // Deposit st auraBAL into the vesting contract
        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount);
        assertEq(aliceVester.getVestingNonce(), 1);
        // Make sure the vesting contract has the st auraBAL
        assertEq(SD_BAL_GAUGE.balanceOf(address(aliceVester)), _depositAmount);
        // Make sure vesting position was created
        Vester.VestingPosition memory vestingPosition = aliceVester.getVestingPosition(0);
        assertEq(vestingPosition.amount, _depositAmount);
        assertFalse(vestingPosition.claimed);
    }

    /// @dev Simple claim
    function testClaimHappyStandardVestingPeriod(uint256 _depositAmount) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount);

        // Roll time to the end of the vesting period
        vm.warp(block.timestamp + vester.DEFAULT_VESTING_PERIOD());

        // Claim
        vm.prank(alice);
        aliceVester.claim(0);

        // Make sure the vesting position has been claimed
        Vester.VestingPosition memory vestingPosition = aliceVester.getVestingPosition(0);
        assertTrue(vestingPosition.claimed);

        // Check Alice balance now:
        assertEq(SD_BAL_GAUGE.balanceOf(address(alice)), _depositAmount);
        assertGt(BAL.balanceOf(address(alice)), 0);
        assertGt(USDC.balanceOf(address(alice)), 0);

    }

    function testClaimHappyCustomVestingPeriod(uint256 _depositAmount, uint256 _vestingPeriod) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        _vestingPeriod = bound(_vestingPeriod, 1 days, 1000 days);
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount, _vestingPeriod);

        // Roll time to the end of the vesting period
        vm.warp(block.timestamp + _vestingPeriod);

        // Claim
        vm.prank(alice);
        aliceVester.claim(0);

        // Make sure the vesting position has been claimed
        Vester.VestingPosition memory vestingPosition = aliceVester.getVestingPosition(0);
        assertTrue(vestingPosition.claimed);

        // Check Alice balance now:
        assertEq(SD_BAL_GAUGE.balanceOf(address(alice)), _depositAmount);
        assertGt(BAL.balanceOf(address(alice)), 0);
        assertGt(USDC.balanceOf(address(alice)), 0);
    }

    function testMultipleClaims(uint256 _depositAmount, uint256 _positionsAmnt) public {
        _positionsAmnt = bound(_positionsAmnt, 1, 10);
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply() / _positionsAmnt);
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(
            address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), SD_BAL_GAUGE.totalSupply()
        );

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), type(uint256).max);
        for (uint256 i = 0; i < _positionsAmnt; i++) {
            vm.prank(MAXIS_OPS);
            aliceVester.deposit(_depositAmount);
            // Check nonce:
            assertEq(aliceVester.getVestingNonce(), i + 1);
        }
        // Now roll time to the end of the vesting period and claim all positions
        vm.warp(block.timestamp + vester.DEFAULT_VESTING_PERIOD());
        for (uint256 i = 0; i < _positionsAmnt; i++) {
            vm.prank(alice);
            Vester(aliceVester).claim(i);
        }
        // Make sure Alice balance is now _depositAmount * _positionsAmnt
        assertEq(SD_BAL_GAUGE.balanceOf(address(alice)), _depositAmount * _positionsAmnt);
        assertGt(BAL.balanceOf(address(alice)), 0);
        assertGt(USDC.balanceOf(address(alice)), 0);
    }

    /// @dev Should revert when trying to claim too early
    function testClaimTooEarly(uint256 _depositAmount, uint256 _vestingPeriod) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        _vestingPeriod = bound(_vestingPeriod, 1 days, 1000 days);
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount, _vestingPeriod);

        // Roll time almost to the end of the vesting period
        vm.warp(block.timestamp + (_vestingPeriod - 1));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vester.NotVestedYet.selector));
        aliceVester.claim(0);
    }

    function testClaimNotBeneficiary(uint256 _depositAmount, uint256 _vestingPeriod) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        _vestingPeriod = bound(_vestingPeriod, 1 days, 1000 days);
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount, _vestingPeriod);

        vm.warp(block.timestamp + (_vestingPeriod + 1));

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Vester.NotBeneficiary.selector));
        aliceVester.claim(0);
    }

    /// @dev Should revert when trying to claim same position twice
    function testClaimCannotClaimMulTimes(uint256 _depositAmount, uint256 _vestingPeriod) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        _vestingPeriod = bound(_vestingPeriod, 1 days, 1000 days);
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount, _vestingPeriod);

        vm.warp(block.timestamp + (_vestingPeriod + 1));

        vm.prank(alice);
        aliceVester.claim(0);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Vester.AlreadyClaimed.selector));
        aliceVester.claim(0);
    }

    //////////////////////////////////////////////////////////////////
    //                       Claim Rewards                          //
    //////////////////////////////////////////////////////////////////
    function testClaimAuraRewards(uint256 _depositAmount, uint256 _vestingPeriod) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        _vestingPeriod = bound(_vestingPeriod, 1 days, 1000 days);
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount, _vestingPeriod);
        // Aura rewards will start pounding in immediately, so no need to warp time
        skip(1 days);

        vm.prank(alice);
        aliceVester.claimRewards();
        assertGt(BAL.balanceOf(address(alice)), 0);
        assertGt(USDC.balanceOf(address(alice)), 0);
    }

    //////////////////////////////////////////////////////////////////
    //                            Sweep                             //
    //////////////////////////////////////////////////////////////////

    function testSweepHappy(uint256 _sweepAmount) public {
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));

        // Now give vesting contract some tokens and sweep them
        setStorage(address(aliceVester), BAL.balanceOf.selector, address(BAL), _sweepAmount);

        // DAO msig can sweep now
        vm.prank(MAXIS_OPS);
        aliceVester.sweep(address(BAL), _sweepAmount, bob);

        assertEq(BAL.balanceOf(bob), _sweepAmount);
    }

    function testSweepUnhappyProtected(uint256 _sweepAmount) public {
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));

        setStorage(address(aliceVester), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _sweepAmount);

        // DAO msig can sweep now
        vm.prank(MAXIS_OPS);
        vm.expectRevert(abi.encodeWithSelector(Vester.ProtectedToken.selector));
        aliceVester.sweep(address(SD_BAL_GAUGE), _sweepAmount, bob);

        assertEq(SD_BAL_GAUGE.balanceOf(bob), 0);
    }

    //////////////////////////////////////////////////////////////////
    //                       Ragequit                               //
    //////////////////////////////////////////////////////////////////
    function testRageQuitHappy(uint256 _depositAmount) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount);

        // Roll time to the end of the vesting period to accrue BAL rewards
        vm.warp(block.timestamp + vester.DEFAULT_VESTING_PERIOD());

        // Rage quite to random EOA
        vm.prank(DAO_MSIG);
        aliceVester.ragequit(randomEOA);
        assertEq(SD_BAL_GAUGE.balanceOf(randomEOA), _depositAmount);
        assertGt(BAL.balanceOf(randomEOA), 0);

        // Make sure vester has no more st auraBAL
        assertEq(SD_BAL_GAUGE.balanceOf(address(aliceVester)), 0);
        // Make sure vester has no more BAL
        assertEq(BAL.balanceOf(address(aliceVester)), 0);
        // Make sure contract is bricked
        assertTrue(aliceVester.paused());
    }

    function testCannotRQToZeroAddr(uint256 _depositAmount) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount);

        // Roll time to the end of the vesting period to accrue BAL rewards
        vm.warp(block.timestamp + vester.DEFAULT_VESTING_PERIOD());

        // Rage quite to random EOA
        vm.prank(DAO_MSIG);
        vm.expectRevert("ERC20: transfer to the zero address");
        aliceVester.ragequit(address(0));
        assertFalse(aliceVester.paused());
    }

    function testClaimVotingRewards(uint256 _depositAmount) public {
        _depositAmount = bound(_depositAmount, 1e18, SD_BAL_GAUGE.totalSupply());
        
        vm.prank(MAXIS_OPS);
        Vester aliceVester = Vester(factory.deployVestingContract(alice));
        setStorage(address(MAXIS_OPS), SD_BAL_GAUGE.balanceOf.selector, address(SD_BAL_GAUGE), _depositAmount);

        vm.prank(MAXIS_OPS);
        SD_BAL_GAUGE.approve(address(aliceVester), _depositAmount);

        vm.prank(MAXIS_OPS);
        aliceVester.deposit(_depositAmount);

        skip(1 days);

        vm.prank(alice);
        vm.expectRevert("Invalid proof.");
        aliceVester.claimVotingRewards(address(SD_BAL), 0, 1e18, new bytes32[](0));


        assertEq(SD_BAL.balanceOf(alice), 0);
        assertEq(SD_BAL.balanceOf(address(aliceVester)), 0);

        address votingRewardsMerkleStash = vester.VOTING_REWARDS_MERKLE_STASH();
        vm.mockFunction(votingRewardsMerkleStash, address(new MockMerkle()), abi.encodeWithSignature("claim(address,uint256,address,uint256,bytes32[])"));

        vm.prank(alice);
        aliceVester.claimVotingRewards(address(SD_BAL), 0, 1e18, new bytes32[](0));

        assertEq(SD_BAL.balanceOf(alice), 1e18);
        assertEq(SD_BAL.balanceOf(address(aliceVester)), 0);
    }
}