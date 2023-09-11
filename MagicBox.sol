// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {FloorToken, ILBFactory} from "./FloorToken.sol";// TJ
import {TransferTripleTaxToken} from "./TransferTripleTaxToken.sol"; // TJ
import {ILBPair} from "./lib/joe-v2/src/interfaces/ILBPair.sol";
import {ILBRouter} from "./lib/joe-v2/src/interfaces/ILBRouter.sol";

import {LBRouter} from "./lib/joe-v2/src/LBRouter.sol";
import {ILBToken} from "./lib/joe-v2/src/interfaces/ILBToken.sol";
import {IStrategy} from "./lib/interfaces/IStrategy.sol";
import {ERC20} from "./TransferTaxToken.sol"; //TJ
import {IERC20} from "./lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IStakedMBOX} from "./lib/interfaces/IStakedMBOX.sol";
//import {MBOXvault} from "./GMXstrategy.sol"; //later initialize vault

contract MAGICBOX is FloorToken, TransferTripleTaxToken{

    event Borrow(address indexed user, uint256 btcAmount, uint256 sMBOXAmount);
    error AlreadyBorrowed();
    error NoActiveBorrows();
    error HardResetNotEnabled();
    error NotEnoughBtcToBorrow();
    error Unauthorized();
    error VaultAlreadySet();

    //hardcoded token addresses
    IERC20 public constant wbtc =
        IERC20(0x152b9d0FdC40C096757F570A51E494bd4b943E50); // wbtc
    LBRouter public constant router =
        LBRouter(payable(0xb4315e873dBcf96Ffd0acd8EA43f689D8c20fB30)); //Trader Joe Liquidity Bin Router Address

    address public treasury; // treasury address
    address public controller;
    address public strategy;
    address public buyandburn;
     //IStrategy public strat;
    IStakedMBOX public sMBOX;
    address public vault; // sMBOX vault address
    address public wbtcvault;
    address public MBOXstakersvesting;
    uint256 public gmxBTCamount;
    uint256 public constant BUY_BURN_FEE = 0;
    uint256 public constant BUY_STAKER_FEE = 0;
    uint256 public constant SELL_BURN_FEE = 0;
    uint256 public constant SELL_STAKER_FEE = 0;
    uint256 public constant TREASURY_FEE = 0;

    uint256 internal constant PRECISION = 1e18;
    uint256 public constant INITIAL_TOTAL_SUPPLY = 60_000_000 * 1e18; //60MM
    uint256 public constant VEST_SUPPLY = 150000 * 1e18;

    // Lending & Strategy state

    uint256 public totalBorrowedBtc; // total BTC taken out of the floor bin that is owed to the protocol
    mapping(address => uint256) public borrowedBtc; // BTC owed to the protocol by each user
    mapping(address => uint256) public sMBOXDeposited; // sMBOX deposited by each user
    mapping(address => bool) public strategyborrow;
    uint256 public borrowedBtclimit;
    uint256 public strategyborrowcap;


    constructor(
        string memory name,
        string memory symbol,
        address owner,
        ILBFactory lbFactory,
        uint24 activeId,
        uint16 binStep,
        uint256 tokenPerBin,
        address _treasury,
        address _controller,
        address _sVault,
        address _MBOXstakersvesting
    ) FloorToken(wbtc, lbFactory, activeId, binStep, tokenPerBin) TransferTripleTaxToken(name, symbol, owner) {
        treasury = _treasury;
        controller = _controller; 
        //strategy = _strategy;
        strategyborrowcap = 4;
        _mint(_MBOXstakersvesting, VEST_SUPPLY);
        MBOXstakersvesting = _MBOXstakersvesting;
        //vault = _sVault;
        //sMBOX = new StakedMBOX(address(this), _treasury);
        //setVault(_sVault);
        //_mint(controller, BASE_SUPPLY);

        /* Approvals */
        approve(address(router), type(uint256).max);
        approve(_sVault, type(uint256).max);
        wbtc.approve(address(router), type(uint256).max);
        ILBToken(address(pair)).approveForAll(address(router), true);
        ILBToken(address(pair)).approveForAll(address(pair), true);

        //setstrategy
        //strat = IStrategy(_strategy);

        //unpauseRebalance();
        //sMBOX.deposit(1e18, address(0)); //inititialize vault and depositor dead address
    }

    function setVault(address vault_) public {
        if (msg.sender != address(controller)) revert Unauthorized();
        if (vault != address(0)) revert VaultAlreadySet();
        vault = vault_;
        sMBOX = IStakedMBOX(vault_);
        approve(vault_, type(uint256).max);
    }

    function totalSupply() public view override(ERC20, FloorToken) returns (uint256) {
        return ERC20.totalSupply();
    }

    function balanceOf(address account) public view override(FloorToken, ERC20) returns (uint256) {
        return ERC20.balanceOf(account);
    }

    function _mint(address account, uint256 amount) internal override(FloorToken, ERC20) {
        ERC20._mint(account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual override(ERC20, FloorToken){
        super._burn(account, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override(FloorToken/*, ERC20*/) {
        FloorToken._beforeTokenTransfer(from, to, amount);
    }

        /// -----------------------------------------------------------------------
    /// BORROWING — These are commented because they may change how we calculate floor bin
    /// -----------------------------------------------------------------------

    /// @notice Calculate max borrowable BTC based on sMBOX balance
    /// @dev    Allows any input amount of sMBOX, even if higher than total supply.
    ///         Must be gated on frontend.

    function maxBorrowable(
        uint256 sMBOXAmount_
    ) public view returns (uint256 untaxed, uint256 taxed) {
        uint256 equivalentMBOX = sMBOX.previewRedeem(sMBOXAmount_);
        uint256 MBOXFloorPrice = floorPrice();
        untaxed = (equivalentMBOX * MBOXFloorPrice) / PRECISION;
        return (untaxed, (untaxed * 95) / 100);
    }

    function testpreview(uint256 _test) public view returns (uint256){
        uint256 we = sMBOX.previewMint(_test);
        return we;
    }

    function arb(uint256 btcAmountOut_) external view returns(uint256){
            uint256 MBOXFloorPrice = floorPrice();

            // round up since solidity rounds down
            uint256 MBOXRequired = (
                ((btcAmountOut_ * PRECISION) / MBOXFloorPrice)
            ) + 1;
        return MBOXRequired;
    }

       /// borrow()
    /// -----------------------------------------------------------------------
    /// Pay 5% interest up front, borrow up to max amount of BTC of collateralized
    /// staked Jimbo.

    // Function to borrow BTC against sMBOX. Can only have one active
    // borrow position at a time.

    function borrow(uint256 btcAmountOut_) external {
        // Check if user has an active borrow
        if (borrowedBtc[msg.sender] == 0) {
            // Calculate how much sMBOX to deposit
            uint256 MBOXFloorPrice = floorPrice();

            // round up since solidity rounds down
            uint256 MBOXRequired = (
                ((btcAmountOut_ * PRECISION) / MBOXFloorPrice)
            ) + 1;

            // 4626 impl should round up when dividing here for share count
            uint256 sMBOXToDeposit = sMBOX.previewMint(MBOXRequired);

            // Calculate fees and borrow amount
            uint256 stakeFees = (btcAmountOut_ * 17) / 1000;
            uint256 burnFees = (btcAmountOut_ * 17) / 1000;
            uint256 tres = (btcAmountOut_ * 16) / 1000;
            uint256 borrowAmount = (btcAmountOut_ -
                ((btcAmountOut_ * 50) / 1000)) - 1;

            // Adjust internal state
            sMBOXDeposited[msg.sender] = sMBOXToDeposit;
            borrowedBtc[msg.sender] += btcAmountOut_;
            totalBorrowedBtc += btcAmountOut_;

            // Deposit from user
            sMBOX.transferFrom(msg.sender, address(this), sMBOXToDeposit);
            //jimbo.setIsRebalancing(true);
            //add unpause rebalancing
            //_removeFloorLiquidity();
            //call rebalance
            //unpauseRebalance();
            _removeLiquidity();

            if (wbtc.balanceOf(address(this)) < btcAmountOut_)
                revert NotEnoughBtcToBorrow();

            // Floor fee remains in contract
            wbtc.transfer(treasury, tres);
            wbtc.transfer(msg.sender, borrowAmount);
            //add for staker and buyback
            wbtc.transfer(treasury, burnFees);
            wbtc.transfer(wbtcvault, stakeFees);
            //Remaining wbtc is transferred to burn contract to buy back and burn MBOX tokens to dead address
            //you can always lookup burn address
            uint256 getremain = wbtc.balanceOf(address(this));
            wbtc.transfer(buyandburn, getremain);
        } else {
            revert AlreadyBorrowed();
        }
    }

    // Repay all borrowed BTC and withdraw uJimbo
    function repayAndWithdraw() external {
        // Check if user has an active borrow
        if (borrowedBtc[msg.sender] > 0) {
            // Calculate repayment and adjust internal state
            uint256 btcRepaid = borrowedBtc[msg.sender];
            borrowedBtc[msg.sender] = 0;
            totalBorrowedBtc -= btcRepaid;

            // Return all uJimbo to user
            uint256 sMBOXToReturn = sMBOXDeposited[msg.sender];
            sMBOXDeposited[msg.sender] = 0;

            // Transfer BTC to contract and uJimbo back to user
            wbtc.transferFrom(msg.sender, buyandburn, btcRepaid);
            sMBOX.transfer(msg.sender, sMBOXToReturn);
        } else {
            revert NoActiveBorrows();
        }
    }
    
    function deploytoGMX() public returns (uint256) {
        //require(strategyborrow[strategy] == true,'Not paid old loan');
        require(msg.sender == controller,'Not controller');
        //pauserebase
        //unpauseRebalance();
        _removeLiquidity();
        uint256 poolBTCbal  = wbtc.balanceOf(address(this));
        uint256 newbal = poolBTCbal / strategyborrowcap;
        //uint amounttovaultperc = strategyborrowcap / 100;
        //uint amounttovault = amounttovaultperc * poolBTCbal;
        //deposit to vault.. add vault interface
        //gmxBTCamount = amounttovault;
        wbtc.transfer(strategy, newbal);

        uint256 getremain = wbtc.balanceOf(address(this));
        wbtc.transfer(buyandburn, getremain);
        //strat.enter(newbal, 0);
        //strategy.deposit(){value: amounttovault}
        //if not paid back last borow can't borrow
        //strategyborrow[strategy] == false;
        //addliquidity
        //_deployFloorLiquidity(wbtc.balanceOf(address(this)));
        //rebalanceFloor();
        return newbal;
    }
    
    /*function repayfromstrategy() public {
        require(strategyborrow[strategy] == false, 'No pool balance in vault');
        require(msg.sender == controller,'Not controller');
        //pauserebase
        strat.withdrawall(0);
        uint256 newbal = wbtc.balanceOf(address(this));
        uint256 rewardamount = gmxBTCamount - newbal;
        uint256 stakeFees = (rewardamount * 17) / 1000;
        uint256 burnFees = (rewardamount * 17) / 1000;
        uint256 tres = (rewardamount * 16) / 1000;
        wbtc.transfer(treasury, tres);
        wbtc.transfer(treasury, burnFees);
        wbtc.transfer(wbtcvault, stakeFees);

        //unpauseRebalance();
        // _deployLiquidity or safedeposit
        strategyborrow[strategy] == true;
        //_deployFloorLiquidity(wbtc.balanceOf(address(this)));
        //();
    }

    function restrategize() external{
        require(msg.sender == controller,'Not controller');
        repayfromstrategy();
        deploytoGMX();
    }*/

    function changestrategy(address _strategy) external{
        require(msg.sender == controller,'Not controller');
        //strat = IStrategy(_strategy);
        strategy = _strategy;
    } //add onlyowner

    function checkActiveid() public view returns (uint256){
        uint24 activeId = pair.getActiveId();
        return activeId;
    }

    /*function _deployFloorLiquidity(uint256 amount) public {
        (uint24 floorId, uint24 roofId) = range();
        uint24 activeId = pair.getActiveId() + 1;
        uint256 amount1 = wbtc.balanceOf(address(this));

        int256[] memory deltaIds = new int256[](1);
        uint256[] memory distributionX = new uint256[](1);
        uint256[] memory distributionY = new uint256[](1);

        deltaIds[0] = int256(uint256(uint24((1 << 23) - 1) - activeId));
        distributionX[0] = 0;
        distributionY[0] = 1e18;   

        ILBRouter.LiquidityParameters memory parameter1 = ILBRouter.LiquidityParameters(
            IERC20(address(this)),
            wbtc,
            100,
            0,
            amount1,
            0,
            0,
            activeId,
            0,
            deltaIds,
            distributionX,
            distributionY,
            address(this),
            address(this),
            block.timestamp + 100
        );

        router.addLiquidity(parameter1);
    }*/

    function _removeLiquidity() internal {
        (uint24 floorId, uint24 roofId) = range();
        uint256 floorBinLiquidityLPBalance = pair.balanceOf(
            address(this),
            floorId //check if correct
        );

        if (floorBinLiquidityLPBalance > 0) {
            uint256[] memory ids = new uint256[](1);
            uint256[] memory amounts = new uint256[](1);

            ids[0] = floorId;
            amounts[0] = floorBinLiquidityLPBalance;

            pair.burn(address(this), address(this), ids, amounts);
        }
    }

        /// @dev Internal function to add liq function
    /*function _addLiquidity(
        int256[] memory deltaIds,
        uint256[] memory distributionX,
        uint256[] memory distributionY,
        uint256 amountX,
        uint256 amountY,
        uint24 activeIdDesired
    ) internal {
        uint256 amountXmin = 0;//(amountX * 99) / 100; // We allow 1% amount slippage
        uint256 amountYmin = (amountY * 99) / 100; // We allow 1% amount slippage

        uint256 idSlippage = activeIdDesired - pair.getActiveId();

        ILBRouter.LiquidityParameters memory liquidityParameters = ILBRouter
            .LiquidityParameters(
                IERC20(address(this)),
                wbtc,
                binStep,
                /*amountX,
                amountY,
                amountXmin,
                amountYmin,
                activeIdDesired, //activeIdDesired
                idSlippage,
                deltaIds,
                distributionX,
                distributionY,
                address(this),
                address(this),
                block.timestamp + 100
            );

        router.addLiquidity(liquidityParameters);
    }*/

    function setstrategycap(uint256 _cap) external {
        require(msg.sender == controller,'Not controller');
        require(_cap >= 0,'Greater than 30% of pools BTC');
        strategyborrowcap = _cap;
    }

    function setController(address _controller) external {
        require(msg.sender == treasury,'Not controller');
        controller = _controller;
    }

    function setwbtcVault(address vault_) public {
        require(msg.sender == controller,'Not controller');
        wbtcvault = vault_;
    }

    function setTreasury(address _treasury) external {
        require(msg.sender == controller,'Not controller');
        treasury = _treasury;
    }

    function setBuyback(address _buyback) external {
        require(msg.sender == controller,'Not controller');
        buyandburn = _buyback;
    }

}