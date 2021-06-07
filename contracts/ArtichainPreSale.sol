pragma solidity 0.6.12;

// SPDX-License-Identifier: MIT

import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import './ArtichainToken.sol';

/**
 * @title AITPresale
 * @dev AITPresale is a  contract for managing a token presale,
 * allowing investors to purchase tokens with busd. This contract implements
 * such functionality in its most fundamental form and can be extended to provide additional
 * functionality and/or custom behavior.
 * The external interface represents the basic interface for purchasing tokens, and conform
 * the base architecture for Presales. They are *not* intended to be modified / overriden.
 * The internal interface conforms the extensible and modifiable surface of Presales. Override
 * the methods to add functionality. Consider using 'super' where appropiate to concatenate
 * behavior.
 * start time (11 june 2021 14:00 UTC - 8,192,324 block)
 */
contract ArtichainPresale is Ownable {
    using SafeMath for uint256;

    // The token being sold
    ArtichainToken public token;

    // The token being received
    IBEP20 public tokenBUSD;

    // Address where funds are collected
    address public wallet;

    // How many token a buyer gets per busd 70.
    // The rate is the conversion between busd and the smallest and indivisible token unit.
    // So, if you are using a rate of 10**18 with a TRC20 token with 18 decimals called AIT
    // In first step, 50 busd will give you 1000000000000000000 unit, or 1 AIT.
    // rate is 5000 when price is 50 busd
    uint256 public rate; 

    // total token for sale
    uint256 public cap;

    // Amount of tokens minted in presale
    uint256 public totalSoldAmount;

    // Amount of busd raised
    uint256 public busdRaised;

    uint256 public startBlock;
    uint256 public endBlock;

    // Track investor contributions
    mapping(address => uint256) public contributions;

    // Presale Stages
    struct PresaleStage {
        uint256 stage;
        uint256 cap;
        uint256 rate;
        uint256 bonus;
    }

    // current presale stage
    uint256 public currentPresaleStage;
    // Percentages with Presale stages
    mapping(uint256 => PresaleStage) public presaleStages;
    // sold amount for stages
    mapping(uint256 => uint256) public soldAmounts;
    
    struct Presale {
        uint256 stage;
        uint256 rate;
        uint256 usdAmount;
        uint256 tokenAmount;
    }
    mapping(address => Presale[]) public userSales;
    
    /**
     * Event for token purchase logging
     * @param purchaser who paid for the tokens
     * @param curStage current presale stage
     * @param rate current rate
     * @param value busd paid for purchase
     * @param amount amount of tokens purchased
     */
    event TokenPurchase(
        address indexed purchaser,
        uint256 curStage,
        uint256 rate,
        uint256 value,
        uint256 amount
    );

    event PresaleStarted();
    event PresaleStageChanged(uint256 nextStage);
    event RateChanged(uint256 stage, uint256 rate);
    event PresaleFinished();

    // -----------------------------------------
    // Presale external interface
    // -----------------------------------------

    constructor(
        address _wallet,
        address _token,
        address _tokenBUSD,
        uint256 _startBlock
    ) public {
        require(_wallet != address(0), "wallet shouldn't be zero address");
        require(_token != address(0), "token shouldn't be zero address");
        require(_tokenBUSD != address(0), "busd shouldn't be zero address");

        wallet = _wallet;
        token = ArtichainToken(_token);
        tokenBUSD = IBEP20(_tokenBUSD);

        startBlock = _startBlock;
        endBlock = _startBlock + (4 * 7 days) / 3; // 4 weeks

        // 10k tokens for presale + bonus 350
        cap = 10350 * (10**uint256(token.decimals()));

        presaleStages[1] = PresaleStage(1, 4000 * (10**uint256(token.decimals())), 5000, 500);
        presaleStages[2] = PresaleStage(2, 3000 * (10**uint256(token.decimals())), 6000, 300);
        presaleStages[3] = PresaleStage(3, 3000 * (10**uint256(token.decimals())), 7000, 200);

        rate = 5000;
        currentPresaleStage = 1;
    }

    /**
     * @dev Checks whether the cap has been reached.
     * @return Whether the cap was reached
     */
    function capReached() public view returns (bool) {
        return totalSoldAmount >= cap;
    }

    /**
     * @dev Reverts if not in Presale time range.
     */
    modifier onlyWhileOpen {
        require(startBlock <= block.number, "Presale is not started");
        require(capReached() == false, "Presale cap is reached");

        // solium-disable-next-line security/no-block-members
        require(
            block.number >= startBlock && block.number <= endBlock,
            "Presale is closed"
        );
        _;
    }

    /**
     * @dev Checks whether the period in which the Presale is open has already elapsed.
     * @return Whether Presale period has elapsed
     */
    function hasClosed() public view returns (bool) {
        // solium-disable-next-line security/no-block-members
        return capReached() || block.number > endBlock;
    }

    /**
     * @dev Start presale.
     * @return Whether presale is started
     */
    function startPresale() public onlyOwner returns (bool) {
        require(startBlock > block.number, "Presale is already started");

        currentPresaleStage = 1;
        startBlock = block.number;
        endBlock = startBlock + (4 * 7 days) / 3;  // 4 weeks

        rate = presaleStages[currentPresaleStage].rate;

        emit PresaleStarted();
        return true;
    }

    /**
     * @dev update presale params.
     * @return Whether presale is updated
     */
    function setPresale(uint256 _stage, uint256 _cap, uint256 _rate, uint256 _bonus) public onlyOwner returns (bool) {
        require(_stage > 0 && _stage <= 3, "Invalid stage");
        require(!(currentPresaleStage == _stage && startBlock <= block.number), "Cannot change params for current stage");
        require(_cap > 0 && _rate > 0);

        presaleStages[_stage].cap = _cap;
        presaleStages[_stage].rate = _rate;
        presaleStages[_stage].bonus = _bonus;

        return true;
    }

    /**
     * @dev Finish presale.
     * @return Whether presale is finished
     */
    function finishPresale() public onlyOwner returns (bool) {
        require(startBlock <= block.number, "Presale is not started");
        require(currentPresaleStage < 5 , "Presale was finished");
        
        _finishPresale();

        return true;
    }

    /**
     * @dev Returns the amount contributed so far by a sepecific user.
     * @param _beneficiary Address of contributor
     * @return User contribution so far
     */
    function getUserContribution(address _beneficiary)
        public
        view
        returns (uint256)
    {
        return contributions[_beneficiary];
    }

    /**
     * @dev Check the parameters of current presale stage.
     * @return PresaleStage params
     */
    function currentStage() public view onlyWhileOpen returns (uint256) {
        return currentPresaleStage;
    }

    /**
     * @dev Returns if exchange rate was set by a sepecific user.
     * @param _rate exchange rate for current presale stage
     */
    function setExchangeRate(uint256 _rate) public onlyWhileOpen onlyOwner returns (bool) {
        require(_rate >= 5000, "rate should be greater than 5000"); // 50 busd

        presaleStages[currentPresaleStage].rate = _rate;
        rate = presaleStages[currentPresaleStage].rate;

        emit RateChanged(currentPresaleStage, _rate);
        return true;
    }

    function updateCompanyWallet(address _wallet) public onlyWhileOpen onlyOwner returns (bool){
        wallet = _wallet;
        return true;
    }

    /**
     * @dev low level token purchase ***DO NOT OVERRIDE***
     * @param busdAmount purchased busd amount
     */
    function buyTokens(uint256 busdAmount) public {
        _preValidatePurchase(msg.sender, busdAmount);

        // calculate token amount to be created
        uint256 tokens = _getTokenAmount(busdAmount);
        
        uint256 bonus = presaleStages[currentPresaleStage].bonus;
        bonus = tokens.mul(bonus).div(10000);
        tokens = tokens.add(bonus);

        _forwardFunds(busdAmount);

        // update state
        busdRaised = busdRaised.add(busdAmount);

        _processPurchase(msg.sender, tokens);
        emit TokenPurchase(msg.sender, currentPresaleStage, presaleStages[currentPresaleStage].rate, busdAmount, tokens);

        _updatePurchasingState(msg.sender, busdAmount, tokens);
        _postValidatePurchase(msg.sender, tokens);
    }

    // -----------------------------------------
    // Internal interface (extensible)
    // -----------------------------------------

    /**
     * @dev Validation of an incoming purchase. Use require statements to revert state when conditions are not met. Use super to concatenate validations.
     * @param _beneficiary Address performing the token purchase
     * @param _busdAmount Value in wei involved in the purchase
     */
    function _preValidatePurchase(address _beneficiary, uint256 _busdAmount)
        internal
        onlyWhileOpen
    {
        require(_beneficiary != address(0), "can't buy for zero address");

        // calculate token amount to be created
        uint256 tokens = _getTokenAmount(_busdAmount);
        require(tokens >= 10**(uint256(token.decimals())), "AIT amount must exceed 1");

        contributions[_beneficiary] = contributions[_beneficiary].add(_busdAmount);
        
        uint256 bonus = presaleStages[currentPresaleStage].bonus;
        bonus = tokens.mul(bonus).div(10000);
        tokens = tokens.add(bonus);

        uint256 soldAmount = totalSoldAmount.add(tokens);
        require(soldAmount <= cap, "CAP reached, can't sell more token");
    }

    /**
     * @dev Validation of an executed purchase. Observe state and use revert statements to undo rollback when valid conditions are not met.
     * @param _beneficiary Address performing the token purchase
     * @param _busdAmount Value in wei involved in the purchase
     */
    function _postValidatePurchase(address _beneficiary, uint256 _busdAmount)
        internal
    {
        // optional override
    }

    /**
     * @dev Source of tokens. Override this method to modify the way in which the Presale ultimately gets and sends its tokens.
     * @param _beneficiary Address performing the token purchase
     * @param _tokenAmount Number of tokens to be emitted
     */
    function _deliverTokens(address _beneficiary, uint256 _tokenAmount)
        internal
    {
        token.mint(_beneficiary, _tokenAmount);
    }

    /**
     * @dev Executed when a purchase has been validated and is ready to be executed. Not necessarily emits/sends tokens.
     * @param _beneficiary Address receiving the tokens
     * @param _tokenAmount Number of tokens to be purchased
     */
    function _processPurchase(address _beneficiary, uint256 _tokenAmount)
        internal
    {
        _deliverTokens(_beneficiary, _tokenAmount);
    }

    /**
     * @dev Override for extensions that require an internal state to check for validity (current user contributions, etc.)
     * @param _buyer Address receiving the tokens
     * @param _busdAmount Value in busd involved in the purchase
     * @param _tokenAmount Value in token involved in the purchase
     */
    function _updatePurchasingState(address _buyer, uint256 _busdAmount, uint256 _tokenAmount)
        internal
    {
        // optional override
        totalSoldAmount = totalSoldAmount.add(_tokenAmount);
        soldAmounts[currentPresaleStage] = soldAmounts[currentPresaleStage].add(_tokenAmount);
        userSales[_buyer].push(Presale(currentPresaleStage, presaleStages[currentPresaleStage].rate, _busdAmount, _tokenAmount));

        // update current presale stage
        uint256 currentCap = 0;
        for(uint256 i = 1; i <= currentPresaleStage; i++) {
            currentCap = currentCap.add(presaleStages[i].cap);
        }

        if(currentCap <= totalSoldAmount) {
            currentPresaleStage++;
            if(currentPresaleStage <= 3) {
                rate = presaleStages[currentPresaleStage].rate;

                emit PresaleStageChanged(currentPresaleStage);
            }
        }

        if(currentPresaleStage > 3) _finishPresale();
    }

    /**
     * @dev Override to extend the way in which ether is converted to tokens.
     * @param _busdAmount Value in wei to be converted into tokens
     * @return Number of tokens that can be purchased with the specified _busdAmount
     */
    function _getTokenAmount(uint256 _busdAmount)
        internal
        view
        returns (uint256)
    {
        return _busdAmount.mul(10**(uint256(token.decimals() - tokenBUSD.decimals()))).mul(100).div(rate);
    }

    /**
     * @dev Determines how BUSD is stored/forwarded on purchases.
     */
    function _forwardFunds(uint256 _busdAmount) internal {
        tokenBUSD.transferFrom(msg.sender, wallet, _busdAmount);
    }

    /**
     * @dev Finish presale.
     */
    function _finishPresale() internal {
        endBlock = block.timestamp;
        currentPresaleStage = 5;

        if(totalSoldAmount < cap) {
            uint256 remainAmount = cap.sub(totalSoldAmount);  // 10k - totalsold
            token.mint(wallet, remainAmount);
        }

        emit PresaleFinished();
    }

    function transferTokenOwner(address _owner) public onlyOwner {
        token.transferOwnership(_owner);
    }
}
