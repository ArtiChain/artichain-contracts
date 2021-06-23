pragma solidity 0.6.12;

// SPDX-License-Identifier: MIT

import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import './ArtichainToken.sol';
import './libs/ReentrancyGuard.sol';

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
contract ArtichainPresale is Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    // The token being sold
    ArtichainToken public token;

    // The token being received
    IBEP20 public tokenBUSD;

    // Address where funds are collected
    address public wallet;
    address public tokenWallet;

    // total amount for sale
    uint256 public cap;

    // Amount of sold tokens in presale
    uint256 public totalSoldAmount;

    // Amount of busd raised
    uint256 public busdRaised;

    uint256 public startTime;
    uint256 public endTime;

    bool isFinished = false;

    // Track investor contributions
    mapping(address => uint256) public contributions;

    // Presale Stages
    struct PresaleStage {
        uint256 stage;
        uint256 cap;
        uint256 rate;
        uint256 bonus;
    }

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
        address _tokenWallet,
        address _token,
        address _tokenBUSD,
        uint256 _startTime,
        uint256 _prevSold
    ) public {
        require(_wallet != address(0), "wallet shouldn't be zero address");
        require(_token != address(0), "token shouldn't be zero address");
        require(_tokenBUSD != address(0), "busd shouldn't be zero address");

        wallet = _wallet;
        tokenWallet = _tokenWallet;
        token = ArtichainToken(_token);
        tokenBUSD = IBEP20(_tokenBUSD);

        startTime = _startTime;
        endTime = _startTime + (3 * 7 days); // 3 weeks

        // 10k tokens for presale + bonus 350
        cap = 10350 * (10**uint(token.decimals()));

        presaleStages[1] = PresaleStage(1, 4000 * (10**uint(token.decimals())), 5000, 500);
        presaleStages[2] = PresaleStage(2, 3000 * (10**uint(token.decimals())), 5500, 300);
        presaleStages[3] = PresaleStage(3, 3000 * (10**uint(token.decimals())), 6000, 200);

        totalSoldAmount = _prevSold;
        soldAmounts[1] = _prevSold;
    }

    /**
     * @dev Checks whether the cap has been reached.
     * @return Whether the cap was reached
     */
    function capReached() public view returns (bool) {
        return totalSoldAmount >= cap;
    }

    function currentStage() public view returns (uint256) {
        if(block.timestamp < startTime) return 0;
        if(isFinished == true) return 4;

        uint256 curStage = (block.timestamp - startTime) / 7 days + 1;
        
        uint256 currentCap = 0;
        for(uint256 i = 1; i <= curStage; i++) {
            currentCap = currentCap.add(presaleStages[i].cap);
        }

        if(currentCap <= totalSoldAmount) {
            curStage = curStage.add(1);
        }

        return curStage;
    }

    function currentRate() public view returns (uint256) {
        uint256 currentPresaleStage = currentStage();
        if(currentPresaleStage < 1) return presaleStages[1].rate;
        if(currentPresaleStage > 3) return presaleStages[3].rate;

        return presaleStages[currentPresaleStage].rate;
    }

    /**
     * @dev Reverts if not in Presale time range.
     */
    modifier onlyWhileOpen {
        require(startTime <= block.timestamp, "Presale is not started");
        require(capReached() == false, "Presale cap is reached");
        require(block.timestamp <= endTime && isFinished == false, "Presale is closed");

        _;
    }

    /**
     * @dev Checks whether the period in which the Presale is open has already elapsed.
     * @return Whether Presale period has elapsed
     */
    function hasClosed() external view returns (bool) {
        return capReached() || block.timestamp > endTime || isFinished;
    }

    /**
     * @dev Start presale.
     * @return Whether presale is started
     */
    function startPresale() external onlyOwner returns (bool) {
        require(startTime > block.timestamp, "Presale is already started");

        startTime = block.timestamp;
        endTime = startTime + (3 * 7 days);  // 3 weeks

        emit PresaleStarted();
        return true;
    }

    /**
     * @dev update presale params.
     * @return Whether presale is updated
     */
    function setPresale(uint256 _stage, uint256 _cap, uint256 _rate, uint256 _bonus) external onlyOwner returns (bool) {
        require(_stage > 0 && _stage <= 3, "Invalid stage");
        require(!(currentStage() == _stage && startTime <= block.timestamp), "Cannot change params for current stage");
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
    function finishPresale() external onlyOwner returns (bool) {
        require(startTime <= block.timestamp, "Presale is not started");
        require(isFinished == false , "Presale was finished");
        
        _finishPresale();

        return true;
    }

    /**
     * @dev Returns the amount contributed so far by a sepecific user.
     * @param _beneficiary Address of contributor
     * @return User contribution so far
     */
    function getUserContribution(address _beneficiary) external view returns (uint256) {
        return contributions[_beneficiary];
    }

    /**
     * @dev Returns if exchange rate was set by a sepecific user.
     * @param _rate exchange rate for current presale stage
     */
    function setExchangeRate(uint256 _rate) external onlyWhileOpen onlyOwner returns (bool) {
        require(_rate >= 5000, "rate should be greater than 5000"); // 50 busd

        uint256 currentPresaleStage = currentStage();

        presaleStages[currentPresaleStage].rate = _rate;
        
        emit RateChanged(currentPresaleStage, _rate);
        return true;
    }

    function updateCompanyWallet(address _wallet) external onlyOwner returns (bool){
        wallet = _wallet;
        return true;
    }

    function setTokenWallet(address _wallet) external onlyOwner {
        tokenWallet = _wallet;
    }

    /**
     * @dev low level token purchase ***DO NOT OVERRIDE***
     * @param busdAmount purchased busd amount
     */
    function buyTokens(uint256 busdAmount) external nonReentrant{
        _preValidatePurchase(msg.sender, busdAmount);

        uint256 currentPresaleStage = currentStage();

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

        uint256 currentPresaleStage = currentStage();
        require(currentPresaleStage > 0 , "Presale is not started");
        require(currentPresaleStage <= 3 && isFinished == false, "Presale was finished");

        // calculate token amount to be created
        uint256 tokens = _getTokenAmount(_busdAmount);
        require(tokens >= 10**uint(token.decimals()) / 10, "AIT amount must exceed 0.1");

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
        // token.mint(_beneficiary, _tokenAmount);
        token.transferFrom(tokenWallet, _beneficiary, _tokenAmount);
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
        uint256 currentPresaleStage = currentStage();

        // optional override
        totalSoldAmount = totalSoldAmount.add(_tokenAmount);
        soldAmounts[currentPresaleStage] = soldAmounts[currentPresaleStage].add(_tokenAmount);
        userSales[_buyer].push(Presale(currentPresaleStage, presaleStages[currentPresaleStage].rate, _busdAmount, _tokenAmount));

        if(currentStage() > 3) _finishPresale();
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
        uint256 currentPresaleStage = currentStage();
        return _busdAmount.mul(10**uint(token.decimals() - tokenBUSD.decimals())).mul(100).div(presaleStages[currentPresaleStage].rate);
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
        endTime = block.timestamp;
        isFinished = true;

        emit PresaleFinished();
    }
}
