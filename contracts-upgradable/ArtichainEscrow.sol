pragma solidity ^0.8.0;
// SPDX-License-Identifier: MIT

import '@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol';
import '@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol';
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract ArtichainEscrow is OwnableUpgradeable {
    using SafeMath for uint256;

    address public wallet;
    IBEP20 public token;

    uint256 public depositFee;
    uint256 public withdrawFee;
    bool public allowReleaseRequest;
 
    enum PaymentStatus {Pending, Completed, Rejected, Cancelled, Refunded, Disputed, Resolved}
    enum PaymenentType {PersonalPayment, ProfessionalPayment}
    struct Payment {
        address buyer;
        address seller;
        uint256 amount;
        uint256 delay;
        uint releaseTime;
        bool isRecursive;
        string code;
        PaymentStatus status;
    }
    
    mapping(address => uint256) public balances; // token balances
    mapping(address => uint256) public lockedBalances;

    uint256 orderIndex;
    mapping(uint256 => Payment) public personalPayments;
    mapping(uint256 => Payment) public professionalPayments;

    struct LockedPayment {
        PaymenentType paymentType;
        PaymentStatus status;
        uint256 orderId;
        address sender;
        uint256 amount;
        string code;
        uint256 releasedTime;
    }
    mapping(address => LockedPayment[]) public lockedPayments;


    event Deposited(address indexed payee, uint256 tokenAmount);
    event Withdrawn(address indexed payee, uint256 tokenAmount);

    event PaymentCreated(uint256 orderId, uint paymentType, address indexed buyer, address indexed seller, uint256 tokenAmount, bool isRecursive, uint delay, string code, uint timestamp);
    event PaymentReleased(uint paymentType, address indexed seller, uint256 orderId, uint256 amount);
    event Paymentlocked(uint256 orderId, uint paymentType, address indexed seller, address indexed buyer, uint256 amount, uint releasedTime, string code);
    event PaymentUnlocked(address indexed unlocker, uint256 orderId, uint256 amount);
    event PaymentDisputed(address indexed disputer, uint256 orderId);
    event PaymentCancelled(address indexed buyer, uint256 orderId);
    event PaymentRejected(address indexed buyer, uint256 orderId);
    event DisputeResolved(uint256 orderId);
    
    function initialize(IBEP20 _token, address _wallet, uint256 _depositFee, uint256 _withdrawFee) public initializer {
        __Ownable_init();

        token = _token;
        wallet = _wallet;
        depositFee = _depositFee;
        withdrawFee = _withdrawFee;
        allowReleaseRequest = false;
    }
    function _authorizeUpgrade(address newImplementation) internal {}
    
    function deposit(uint256 _amount) external {
        require(_amount > 0, "Invalid amount");
        require(token.transferFrom(msg.sender, address(this), _amount));

        if(depositFee > 0) {
            uint256 fee = _amount.mul(depositFee).div(10000);
            token.transfer(wallet, fee);
            _amount = _amount.sub(fee);
        }

        balances[msg.sender] = balances[msg.sender].add(_amount);
        
        emit Deposited(msg.sender, _amount);
    }

    function withdraw(uint256 _amount) external {
        require(balances[msg.sender] >= _amount && _amount > 0);
        
        if(depositFee > 0) {
            uint256 fee = _amount.mul(withdrawFee).div(10000);
            _amount = _amount.sub(fee);

            token.transfer(wallet, fee);
            balances[msg.sender] = balances[msg.sender].sub(fee);
        }

        token.transfer(msg.sender, _amount);
        balances[msg.sender] = balances[msg.sender].sub(_amount);

        emit Withdrawn(msg.sender, _amount);
    }

    function createPayment(uint _paymentType, address _seller, uint256 _amount, bool _recursive, uint256 _delay, string memory _code) external {
        require(_amount > 0, "Invalid Amount");
        require(balances[msg.sender] >= _amount, "Insufficient balance");
        require(_delay > 0, "delay should be greater than 0");
        require(_seller != address(0), "Invalid Address");

        uint256 _releaseTime = block.timestamp + _delay * 1 days;
        uint256 _orderId = orderIndex.add(1);

        PaymenentType paymentType = PaymenentType.PersonalPayment;
        bool isRecursive = _recursive;
        
        if(_paymentType == 0) {
            personalPayments[_orderId] = Payment(msg.sender, _seller, _amount, _delay, _releaseTime, _recursive, _code, PaymentStatus.Pending);
        } else {
            paymentType = PaymenentType.ProfessionalPayment;
            isRecursive = false;

            professionalPayments[_orderId] = Payment(msg.sender, _seller, _amount, _delay, _releaseTime, false, _code, PaymentStatus.Pending);
        }

        balances[msg.sender] = balances[msg.sender].sub(_amount);
        lockedBalances[msg.sender] = lockedBalances[msg.sender].add(_amount);
        
        orderIndex++;

        emit PaymentCreated(_orderId, _paymentType, msg.sender, _seller, _amount, isRecursive, _delay, _code, block.timestamp);
    }

    function disputePayment(uint256 _orderId) external {
        require(professionalPayments[_orderId].buyer != address(0), "OrderID is invalid");

        Payment memory _payment = professionalPayments[_orderId];
        require(msg.sender == _payment.buyer || msg.sender == _payment.seller, "Permission denied");
        require(_payment.status == PaymentStatus.Pending || _payment.releaseTime < block.timestamp, "Payment can not be disputed");

        professionalPayments[_orderId].status = PaymentStatus.Disputed;
        lockedBalances[_payment.buyer] = lockedBalances[_payment.buyer].sub(_payment.amount);

        token.transfer(wallet, _payment.amount);

        emit PaymentDisputed(msg.sender, _orderId);
    }

    function resolveDispute(uint256 _orderId) external onlyOwner returns (bool) {
        require(professionalPayments[_orderId].buyer != address(0), "OrderID is invalid");

        Payment  memory _payment = professionalPayments[_orderId];
        require(_payment.status == PaymentStatus.Disputed, "Not disputed payment");

        professionalPayments[_orderId].status = PaymentStatus.Resolved;

        emit DisputeResolved(_orderId);

        return true;
    }

    function cancelPayment(uint256 _orderId) external {
        require(personalPayments[_orderId].buyer != address(0), "OrderID is invalid");

        Payment memory _payment = personalPayments[_orderId];
        require(msg.sender == _payment.buyer, "Permission denied");
        require(_payment.status == PaymentStatus.Pending, "Payment can not be cancelled");

        personalPayments[_orderId].status = PaymentStatus.Cancelled;

        lockedBalances[_payment.buyer] = lockedBalances[_payment.buyer].sub(_payment.amount);
        balances[_payment.buyer] = balances[_payment.buyer].add(_payment.amount);

        emit PaymentCancelled(_payment.buyer, _orderId);
    }

    function releasePayment(uint256 _orderId, uint _paymentType) external {
        require(_paymentType < 2, "Invalid request");

        if(_paymentType == 0) {
            require(personalPayments[_orderId].buyer == msg.sender, "Permission denied");
            require(personalPayments[_orderId].status == PaymentStatus.Pending, "Payment can not be released");
            // require(personalPayments[_orderId].releaseTime < block.timestamp, "Payment can not be released");
        } else {
            require(professionalPayments[_orderId].buyer == msg.sender, "Permission denied");
            require(professionalPayments[_orderId].status == PaymentStatus.Pending, "Payment can not be released");
            // require(professionalPayments[_orderId].releaseTime < block.timestamp, "Payment can not be released");
        }

        _paymentRelease(_orderId, _paymentType);
    }

    function releasePaymentRequest(uint256 _orderId, uint _paymentType) external {
        require(allowReleaseRequest == true, "Request to release a payment is denied");
        require(_paymentType < 2, "Invalid request");

        if(_paymentType == 0) {
            require(personalPayments[_orderId].seller == msg.sender || msg.sender == owner(), "Permission denied");
            require(personalPayments[_orderId].status == PaymentStatus.Pending, "Payment can not be released");
            require(personalPayments[_orderId].releaseTime < block.timestamp, "Payment can not be released");
        } else {
            require(professionalPayments[_orderId].seller == msg.sender || msg.sender == owner(), "Permission denied");
            require(professionalPayments[_orderId].status == PaymentStatus.Pending, "Payment can not be released");
            require(professionalPayments[_orderId].releaseTime < block.timestamp, "Payment can not be released");
        }

        _paymentRelease(_orderId, _paymentType);
    }

    function _paymentRelease(uint256 _orderId, uint _paymentType) internal {
        if(_paymentType == 0) {
            Payment memory _payment = personalPayments[_orderId];

            lockedBalances[_payment.buyer] = lockedBalances[_payment.buyer].sub(_payment.amount);
            lockedPayments[_payment.seller].push(LockedPayment(PaymenentType.PersonalPayment, PaymentStatus.Pending, _orderId, _payment.buyer, _payment.amount, _payment.code, block.timestamp));

            emit PaymentReleased(0, _payment.seller, _orderId, _payment.amount);
            emit Paymentlocked(_orderId, 0, _payment.seller, _payment.buyer, _payment.amount, block.timestamp, _payment.code);

            if(_payment.isRecursive) {
                if(balances[_payment.buyer] < _payment.amount) {
                    personalPayments[_orderId].status = PaymentStatus.Rejected;

                    emit PaymentRejected(_payment.buyer, _orderId);
                } else {
                    balances[_payment.buyer] = balances[_payment.buyer].sub(_payment.amount);
                    lockedBalances[_payment.buyer] = lockedBalances[_payment.buyer].add(_payment.amount);
                    personalPayments[_orderId].releaseTime = block.timestamp + _payment.delay * 1 days;
                }
            } else {
                personalPayments[_orderId].status = PaymentStatus.Completed;
            }
        } else {
            Payment memory _payment = professionalPayments[_orderId];

            professionalPayments[_orderId].status = PaymentStatus.Completed;
            lockedBalances[_payment.buyer] = lockedBalances[_payment.buyer].sub(_payment.amount);
            lockedPayments[_payment.seller].push(LockedPayment(PaymenentType.ProfessionalPayment, PaymentStatus.Pending, _orderId, _payment.buyer, _payment.amount, _payment.code, block.timestamp));

            emit PaymentReleased(1, _payment.seller, _orderId, _payment.amount);
            emit Paymentlocked(_orderId, 1, _payment.seller, _payment.buyer, _payment.amount, block.timestamp, _payment.code);
        }
    }

    function unlockPayment(uint256 _orderId, string memory _code) external {
        require(lockedPayments[msg.sender].length > 0, "Locked payment not found");

        for(uint i = 0; i < lockedPayments[msg.sender].length; i++) {
            LockedPayment memory _payment = lockedPayments[msg.sender][i];
            if(_payment.orderId == _orderId) {
                require(keccak256(bytes(_payment.code)) == keccak256(bytes(_code)), "Payment code is wrong");
                require(_payment.status == PaymentStatus.Pending, "Already unlocked");

                lockedPayments[msg.sender][i].status = PaymentStatus.Completed;
                balances[msg.sender] = balances[msg.sender].add(_payment.amount);

                emit PaymentUnlocked(msg.sender, _orderId, _payment.amount);

                for(uint j = i; j < lockedPayments[msg.sender].length - 1; j++) {
                    lockedPayments[msg.sender][i] = lockedPayments[msg.sender][j+1];
                }
                lockedPayments[msg.sender].pop();
                
                break;
            }
        }
    }

    function balanceOf(address _address) external view returns (uint256, uint256, uint256) {
        uint256 available = 0;
        if(balances[_address] != 0) {
            available = balances[_address];
        }

        uint256 locked = 0;
        if(lockedBalances[_address] != 0) {
            locked = lockedBalances[_address];
        }

        for(uint i = 0; i < lockedPayments[_address].length; i++) {
            if(lockedPayments[_address][i].status == PaymentStatus.Pending) {
                locked = locked.add(lockedPayments[_address][i].amount);
            }
        }
        
        uint256 disputed = 0;
        for(uint i = 1; i <= orderIndex; i++) {
            if(professionalPayments[i].status != PaymentStatus.Disputed) continue;
            if(professionalPayments[i].buyer != _address &&  professionalPayments[i].seller != _address) continue;

            disputed = disputed.add(professionalPayments[i].amount);
        }

        return (available, locked, disputed);
    }

    function balance() external view returns (uint256, uint256, uint256) {
        uint256 available = 0;
        if(balances[msg.sender] != 0) {
            available = balances[msg.sender];
        }

        uint256 locked = 0;
        if(lockedBalances[msg.sender] != 0) {
            locked = lockedBalances[msg.sender];
        }

        for(uint i = 0; i < lockedPayments[msg.sender].length; i++) {
            if(lockedPayments[msg.sender][i].status == PaymentStatus.Pending) {
                locked = locked.add(lockedPayments[msg.sender][i].amount);
            }
        }

        uint256 disputed = 0;
        for(uint i = 1; i <= orderIndex; i++) {
            if(professionalPayments[i].status != PaymentStatus.Disputed) continue;
            if(professionalPayments[i].buyer != msg.sender &&  professionalPayments[i].seller != msg.sender) continue;
            disputed = disputed.add(professionalPayments[i].amount);
        }

        return (available, locked, disputed);
    }
    
    function setFee(uint256 _depositFee, uint256 _withdrawFee) external onlyOwner {
        require(_depositFee >= 0 && _withdrawFee >= 0, "Invalid fee");
        
        depositFee = _depositFee;
        withdrawFee = _withdrawFee;
    }

    function setWallet(address _wallet) external {
        require(wallet == msg.sender, "setWallet: Forbidden");
        wallet = _wallet;
    }
    function setReleaseReqStatus(bool _allowable) external onlyOwner {
        allowReleaseRequest = _allowable;
    }
}