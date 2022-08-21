// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;
pragma abicoder v2;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "./DaobiVoteContract.sol";
import "./DaobiChancellorsSeal.sol";

import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

/// @custom:security-contact jennifer.dodgson@gmail.com
contract DAObiContract3 is Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, PausableUpgradeable, AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    //additions to support on-chain election of chancellor: 
    address public chancellor; //the address of the current chancellor

    // the address of the voting contract
    //the voting contract should contain a mapping in which, given an address, the number of votes for that address (if any) can be found
    address public votingContract; 
    address public sealContract; //address of the Chancellor's Seal contract

    //events related to voting
    event ClaimAttempted(address _claimant, uint40 _votes);
    event ClaimSucceeded(address _claimant, uint40 _votes);
    event NewChancellor(address _newChanc);
    event VoteContractChange(address _newVoteScheme);
    event DaobiMinted(uint256 amount);

    //signals that the Chancellor's seal contract has been retargeted.  
    //The contract itself may send events internally; emits will be emitted from that address
    event SealContractChange(address _newSealAddr);

    //events and variables related to Uniswap/DAO integration
    address public DAOvault = 0x9f216b3644082530E6568755768786123DD56367;
    ISwapRouter public constant uniswapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564); //swaprouter02
    address private constant daobiToken = 0xD79dA24D607FF594233F02126771dD35938F922b; //address of Token A, RinkDB
    address private constant chainToken = 0xc778417E063141139Fce010982780140Aa0cD5Ab; //address of Token B, RinkWETH
    uint24 swapFee = 3000; //uniswap pair swap fee, 3000 is standard (.3%)
    event DAORetargeted(address _newDAO);


    /// @custom:oz-upgrades-unsafe-allow constructor

    constructor() initializer {}

    function initialize() initializer public {
        __ERC20_init("DAObiContract2", "DBT");
        __ERC20Burnable_init();
        __Pausable_init();
        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender); //PAUSER_ROLE is the contract "moderator"
        //_mint(msg.sender, 1000 * 10 ** decimals()); for testing, no longer needed
        _grantRole(MINTER_ROLE, msg.sender); //MINTER_ROLE should be the chancellor
        _grantRole(UPGRADER_ROLE, msg.sender);
    }

    //THIS FUNCTION MUST BE EXECUTED IMMEDIATELY AFTER UPGRADEPROXY() TO POINT TO THE VOTE CONTRACT
    function retargetVoting(address _voteContract) public onlyRole(PAUSER_ROLE) {
        //pauses the contract to prevent minting and claiming after deployment until unpaused        
        votingContract = _voteContract;
        emit VoteContractChange(_voteContract);
        pause();
    }

    function retargetSeal(address _sealContract) public onlyRole(PAUSER_ROLE) {
        //pauses the contract to prevent minting and claiming after deployment until unpaused        
        sealContract = _sealContract;
        emit SealContractChange(_sealContract);
        pause();
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mint(uint256 amount) public payable whenNotPaused onlyRole(MINTER_ROLE) {
        require(amount > 0, "Must pass non 0 DB amount");    

        _mint(address(this), amount); //mint tokens into contract
        _mint(DAOvault, amount / 20); //mint 5% extra tokens into DAO vault
        
        TransferHelper.safeApprove(daobiToken,address(uniswapRouter),amount); //approve uniswap transaction

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams(
            daobiToken, //input token
            chainToken, //output token
            swapFee,
            DAOvault, //eth from transaction sent to DAO
            block.timestamp + 15, //execute trade immediately
            amount,
            1, //trade will execute even if only 1 wei is received back
            0 //sqrtPriceLimitX96
        );

        uniswapRouter.exactInputSingle{ value: msg.value }(params);

        emit DaobiMinted(amount);
    }

    function retargetDAO(address _newVault) public whenNotPaused onlyRole(PAUSER_ROLE){
        DAOvault = _newVault;
        emit DAORetargeted(_newVault);
    }

    function setSwapFee(uint24 _swapFee) public whenNotPaused onlyRole(PAUSER_ROLE){
        swapFee = _swapFee;
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        whenNotPaused
        override
    {
        super._beforeTokenTransfer(from, to, amount);
    }

    
    //require holding a voting token
    //check whether the claimant has a higher vote total than the current chancellor.  If they do, set them as current chancellor
    function makeClaim() whenNotPaused public {
        DaobiVoteContract dvc = DaobiVoteContract(votingContract);        
        require (dvc.balanceOf(msg.sender) > 0, "Daobi: You don't even have a voting token!");
        require (dvc.checkStatus(msg.sender) == true, "Daobi: You have withdrawn from service!");
        require (dvc.assessVotes(msg.sender) > 0, "Daobi: You need AT LEAST one vote!");
        require (msg.sender != chancellor, "You are already Chancellor!");        
        
        if (dvc.checkStatus(chancellor) == false) {
            emit ClaimSucceeded(msg.sender, dvc.assessVotes(msg.sender));
            assumeChancellorship(msg.sender);            
        }
        else if (dvc.assessVotes(msg.sender) > dvc.assessVotes(chancellor)) {
            emit ClaimSucceeded(msg.sender, dvc.assessVotes(msg.sender));            
            assumeChancellorship(msg.sender); 
        }
        else {
            emit ClaimAttempted(msg.sender, dvc.assessVotes(msg.sender));
        }
        
    }

    //recover seal to chancellor if it's somehow missing
    function recoverSeal() public {
        require (msg.sender == chancellor, "Only the Chancellor can reclaim this Seal!");   

        DaobiChancellorsSeal seal = DaobiChancellorsSeal(sealContract); 
        require (seal.totalSupply() > 0, "The Seal doesn't currently exist");

        seal.approve(address(this), 1);
        seal.safeTransferFrom(seal.ownerOf(1), chancellor, 1);
    }

    function assumeChancellorship(address _newChancellor) private {
        //this will fail if the voting contract has not been assigned the VOTE_CONTRACT role
        DaobiChancellorsSeal seal = DaobiChancellorsSeal(sealContract); 
        seal.approve(address(this), 1);
        seal.safeTransferFrom(seal.ownerOf(1), _newChancellor, 1);

        _revokeRole(MINTER_ROLE, chancellor);
        chancellor = _newChancellor;
        _grantRole(MINTER_ROLE, chancellor);

        emit NewChancellor(chancellor);
    }

    function _authorizeUpgrade(address newImplementation)
        internal
        onlyRole(UPGRADER_ROLE)
        override
    {}

    receive() payable external {}

}