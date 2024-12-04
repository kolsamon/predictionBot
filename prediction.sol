// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "./libraries/ReentrancyGuardTransient.sol";

/**
 * @title PancakeAIPrediction
 */
contract PancakeAIPrediction is Ownable, Pausable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    bool public genesisLockOnce = false;
    bool public genesisStartOnce = false;

    address public adminAddress; // address of the admin
    address public operatorAddress; // address of the operator

    uint256 public bufferSeconds; // number of seconds for valid execution of a prediction round
    uint256 public intervalSeconds; // interval in seconds between two prediction rounds

    uint256 public minBetAmount; // minimum betting amount (denominated in wei)
    uint256 public treasuryFee; // treasury rate (e.g. 200 = 2%, 150 = 1.50%)
    uint256 public treasuryAmount; // treasury amount that was not claimed

    uint256 public currentEpoch; // current epoch for prediction round

    uint256 public constant MAX_TREASURY_FEE = 1000; // 10%

    mapping(uint256 => mapping(address => BetInfo)) public ledger;
    mapping(uint256 => Round) public rounds;
    mapping(address => uint256[]) public userRounds;

    enum Position {
        Bull, // AI correct
        Bear // AI wrong

    }

    struct Round {
        uint32 startTimestamp; // type(uint32).max is equal to timestamp 4294967295(Sunday February 7 2106 6:28:15 AM), which will meet the requirement
        uint32 lockTimestamp;
        uint32 closeTimestamp;
        uint128 AIPrice;
        uint128 lockPrice;
        uint128 closePrice;
        uint128 totalAmount;
        uint128 bullAmount;
        uint128 bearAmount;
        uint128 rewardBaseCalAmount;
        uint128 rewardAmount;
        bool oracleCalled;
    }

    struct BetInfo {
        Position position;
        uint128 amount;
        bool claimed; // default false
    }

    event BetBear(address indexed sender, uint256 indexed epoch, uint128 amount);
    event BetBull(address indexed sender, uint256 indexed epoch, uint128 amount);
    event Claim(address indexed sender, uint256 indexed epoch, uint256 amount);
    event EndRound(uint256 indexed epoch, uint128 price);
    event LockRound(uint256 indexed epoch, uint128 price);

    event NewAdminAddress(address indexed admin);
    event NewBufferAndIntervalSeconds(uint256 bufferSeconds, uint256 intervalSeconds);
    event NewMinBetAmount(uint256 indexed epoch, uint256 minBetAmount);
    event NewTreasuryFee(uint256 indexed epoch, uint256 treasuryFee);
    event NewOperatorAddress(address indexed operator);

    event Pause(uint256 indexed epoch);
    event RewardsCalculated(
        uint256 indexed epoch, uint256 rewardBaseCalAmount, uint256 rewardAmount, uint256 treasuryAmount
    );

    event StartRound(uint256 indexed epoch, uint128 AIPrice);
    event TokenRecovery(address indexed token, uint256 amount);
    event TreasuryClaim(uint256 amount);
    event Unpause(uint256 indexed epoch);

    modifier onlyAdmin() {
        require(msg.sender == adminAddress, "Not admin");
        _;
    }

    modifier onlyAdminOrOperator() {
        require(msg.sender == adminAddress || msg.sender == operatorAddress, "Not admin/operator");
        _;
    }

    modifier onlyOperator() {
        require(msg.sender == operatorAddress, "Not operator");
        _;
    }

    modifier notContract() {
        require(!_isContract(msg.sender), "Contract not allowed");
        require(msg.sender == tx.origin, "Proxy contract not allowed");
        _;
    }

    /**
     * @notice Constructor
     * @param _adminAddress: admin address
     * @param _operatorAddress: operator address
     * @param _intervalSeconds: number of time within an interval
     * @param _bufferSeconds: buffer of time for resolution of price
     * @param _minBetAmount: minimum bet amounts (in wei)
     * @param _treasuryFee: treasury fee (1000 = 10%)
     */
    constructor(
        address _adminAddress,
        address _operatorAddress,
        uint256 _intervalSeconds,
        uint256 _bufferSeconds,
        uint256 _minBetAmount,
        uint256 _treasuryFee
    ) Ownable(msg.sender) {
        require(_treasuryFee <= MAX_TREASURY_FEE, "Treasury fee too high");

        adminAddress = _adminAddress;
        operatorAddress = _operatorAddress;
        intervalSeconds = _intervalSeconds;
        bufferSeconds = _bufferSeconds;
        minBetAmount = _minBetAmount;
        treasuryFee = _treasuryFee;
    }

    /**
     * @notice Bet AI wrong
     * @dev In order to be compatible with previous versions, we use bear for AI wrong
     * @param epoch: epoch
     */
    function betBear(uint256 epoch) external payable whenNotPaused nonReentrant notContract {
        require(epoch == currentEpoch, "Bet is too early/late");
        Round storage round = rounds[epoch];
        require(_bettable(round), "Round not bettable");
        require(msg.value >= minBetAmount, "Bet amount must be greater than minBetAmount");
        BetInfo storage betInfo = ledger[epoch][msg.sender];
        require(betInfo.amount == 0, "Can only bet once per round");

        unchecked {
            // Update round data
            uint128 amount = uint128(msg.value);
            round.totalAmount = round.totalAmount + amount;
            round.bearAmount = round.bearAmount + amount;

            // Update user data
            betInfo.position = Position.Bear;
            betInfo.amount = amount;
            userRounds[msg.sender].push(epoch);
            emit BetBear(msg.sender, epoch, amount);
        }
    }

    /**
     * @notice Bet AI correct
     * @dev In order to be compatible with previous versions, we use bull for AI correct
     * @param epoch: epoch
     */
    function betBull(uint256 epoch) external payable whenNotPaused nonReentrant notContract {
        require(epoch == currentEpoch, "Bet is too early/late");
        Round storage round = rounds[epoch];
        require(_bettable(round), "Round not bettable");
        require(msg.value >= minBetAmount, "Bet amount must be greater than minBetAmount");
        BetInfo storage betInfo = ledger[epoch][msg.sender];
        require(betInfo.amount == 0, "Can only bet once per round");

        unchecked {
            // Update round data
            uint128 amount = uint128(msg.value);
            round.totalAmount = round.totalAmount + amount;
            round.bullAmount = round.bullAmount + amount;

            // Update user data
            betInfo.position = Position.Bull;
            betInfo.amount = amount;
            userRounds[msg.sender].push(epoch);
            emit BetBull(msg.sender, epoch, amount);
        }
    }

    /**
     * @notice Claim reward for an array of epochs
     * @param epochs: array of epochs
     */
    function claim(uint256[] calldata epochs) external nonReentrant notContract {
        uint256 reward; // Initializes reward

        uint256 length = epochs.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 claimEpoch = epochs[i];
            Round memory round = rounds[claimEpoch];

            require(round.startTimestamp != 0, "Round has not started");
            require(uint32(block.timestamp) > round.closeTimestamp, "Round has not ended");

            uint256 addedReward = 0;
            BetInfo storage betInfo = ledger[claimEpoch][msg.sender];
            // Round valid, claim rewards
            if (round.oracleCalled) {
                require(claimable(claimEpoch, msg.sender), "Not eligible for claim");
                addedReward = (betInfo.amount * uint256(round.rewardAmount)) / round.rewardBaseCalAmount;
            }
            // Round invalid, refund bet amount
            else {
                require(refundable(claimEpoch, msg.sender), "Not eligible for refund");
                addedReward = betInfo.amount;
            }

            betInfo.claimed = true;
            reward += addedReward;

            emit Claim(msg.sender, claimEpoch, addedReward);
        }

        if (reward != 0) {
            _safeTransferNativeToken(address(msg.sender), reward);
        }
    }

    /**
     * @notice Start the next round n, lock price for round n-1, end round n-2
     * @dev Callable by operator
     */
    function executeRound(uint128 currentPrice, uint128 AIPrice) external whenNotPaused onlyOperator {
        require(
            genesisStartOnce && genesisLockOnce,
            "Can only run after genesisStartRound and genesisLockRound is triggered"
        );

        // CurrentEpoch refers to previous round (n-1)
        _safeLockRound(currentEpoch, currentPrice);
        _safeEndRound(currentEpoch - 1, currentPrice);
        _calculateRewards(currentEpoch - 1);

        // Increment currentEpoch to current round (n)
        currentEpoch = currentEpoch + 1;
        _safeStartRound(currentEpoch, AIPrice);
    }

    /**
     * @notice Lock genesis round
     * @dev Callable by operator
     */
    function genesisLockRound(uint128 currentPrice, uint128 AIPrice) external whenNotPaused onlyOperator {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered");
        require(!genesisLockOnce, "Can only run genesisLockRound once");

        _safeLockRound(currentEpoch, currentPrice);

        currentEpoch = currentEpoch + 1;
        _startRound(currentEpoch, AIPrice);
        genesisLockOnce = true;
    }

    /**
     * @notice Start genesis round
     * @dev Callable by admin or operator
     */
    function genesisStartRound(uint128 AIPrice) external whenNotPaused onlyOperator {
        require(!genesisStartOnce, "Can only run genesisStartRound once");

        currentEpoch = currentEpoch + 1;
        _startRound(currentEpoch, AIPrice);
        genesisStartOnce = true;
    }

    /**
     * @notice Claim all rewards in treasury
     * @dev Callable by admin
     */
    function claimTreasury() external nonReentrant onlyAdmin {
        uint256 currentTreasuryAmount = treasuryAmount;
        treasuryAmount = 0;
        _safeTransferNativeToken(adminAddress, currentTreasuryAmount);

        emit TreasuryClaim(currentTreasuryAmount);
    }

    /**
     * @notice called by the admin to pause, triggers stopped state
     * @dev Callable by admin or operator
     */
    function pause() external whenNotPaused onlyAdminOrOperator {
        _pause();

        emit Pause(currentEpoch);
    }

    /**
     * @notice called by the admin to unpause, returns to normal state
     * Reset genesis state. Once paused, the rounds would need to be kickstarted by genesis
     * @dev Callable by admin or operator or keeper
     */
    function unpause() external whenPaused onlyAdminOrOperator {
        genesisStartOnce = false;
        genesisLockOnce = false;
        _unpause();

        emit Unpause(currentEpoch);
    }

    /**
     * @notice Set buffer and interval (in seconds)
     * @dev Callable by admin
     */
    function setBufferAndIntervalSeconds(uint256 _bufferSeconds, uint256 _intervalSeconds)
        external
        whenPaused
        onlyAdmin
    {
        require(_bufferSeconds < _intervalSeconds, "bufferSeconds must be inferior to intervalSeconds");
        bufferSeconds = _bufferSeconds;
        intervalSeconds = _intervalSeconds;

        emit NewBufferAndIntervalSeconds(_bufferSeconds, _intervalSeconds);
    }

    /**
     * @notice Set minBetAmount
     * @dev Callable by admin
     */
    function setMinBetAmount(uint256 _minBetAmount) external whenPaused onlyAdmin {
        require(_minBetAmount != 0, "Must be superior to 0");
        minBetAmount = _minBetAmount;

        emit NewMinBetAmount(currentEpoch, minBetAmount);
    }

    /**
     * @notice Set operator address
     * @dev Callable by admin
     */
    function setOperator(address _operatorAddress) external onlyAdmin {
        require(_operatorAddress != address(0), "Cannot be zero address");
        operatorAddress = _operatorAddress;

        emit NewOperatorAddress(_operatorAddress);
    }

    /**
     * @notice Set treasury fee
     * @dev Callable by admin
     */
    function setTreasuryFee(uint256 _treasuryFee) external whenPaused onlyAdmin {
        require(_treasuryFee <= MAX_TREASURY_FEE, "Treasury fee too high");
        treasuryFee = _treasuryFee;

        emit NewTreasuryFee(currentEpoch, treasuryFee);
    }

    /**
     * @notice It allows the owner to recover tokens sent to the contract by mistake
     * @param _token: token address
     * @param _amount: token amount
     * @dev Callable by owner
     */
    function recoverToken(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(address(msg.sender), _amount);

        emit TokenRecovery(_token, _amount);
    }

    /**
     * @notice Set admin address
     * @dev Callable by owner
     */
    function setAdmin(address _adminAddress) external onlyOwner {
        require(_adminAddress != address(0), "Cannot be zero address");
        adminAddress = _adminAddress;

        emit NewAdminAddress(_adminAddress);
    }

    /**
     * @notice Returns round epochs and bet information for a user that has participated
     * @param user: user address
     * @param cursor: cursor
     * @param size: size
     */
    function getUserRounds(address user, uint256 cursor, uint256 size)
        external
        view
        returns (uint256[] memory, BetInfo[] memory, uint256)
    {
        uint256 length = size;

        if (length > userRounds[user].length - cursor) {
            length = userRounds[user].length - cursor;
        }

        uint256[] memory values = new uint256[](length);
        BetInfo[] memory betInfo = new BetInfo[](length);

        for (uint256 i = 0; i < length; i++) {
            values[i] = userRounds[user][cursor + i];
            betInfo[i] = ledger[values[i]][user];
        }

        return (values, betInfo, cursor + length);
    }

    /**
     * @notice Returns round epochs length
     * @param user: user address
     */
    function getUserRoundsLength(address user) external view returns (uint256) {
        return userRounds[user].length;
    }

    /**
     * @notice Get the claimable stats of specific epoch and user account
     * @param epoch: epoch
     * @param user: user address
     */
    function claimable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];

        bool AICorrect = (round.closePrice > round.lockPrice && round.AIPrice > round.lockPrice)
            || (round.closePrice < round.lockPrice && round.AIPrice < round.lockPrice)
            || (round.closePrice == round.lockPrice && round.AIPrice == round.lockPrice);

        return round.oracleCalled && betInfo.amount != 0 && !betInfo.claimed
            && ((AICorrect && betInfo.position == Position.Bull) || (!AICorrect && betInfo.position == Position.Bear));
    }

    /**
     * @notice Get the refundable stats of specific epoch and user account
     * @param epoch: epoch
     * @param user: user address
     */
    function refundable(uint256 epoch, address user) public view returns (bool) {
        BetInfo memory betInfo = ledger[epoch][user];
        Round memory round = rounds[epoch];
        return !round.oracleCalled && !betInfo.claimed
            && block.timestamp > uint256(round.closeTimestamp) + bufferSeconds && betInfo.amount != 0;
    }

    /**
     * @notice Calculate rewards for round
     * @param epoch: epoch
     */
    function _calculateRewards(uint256 epoch) internal {
        Round storage round = rounds[epoch];
        require(round.rewardBaseCalAmount == 0 && round.rewardAmount == 0, "Rewards calculated");
        uint256 rewardBaseCalAmount;
        uint256 treasuryAmt;
        uint256 rewardAmount;

        // Bull win when AI is correct
        if (
            (round.closePrice > round.lockPrice && round.AIPrice > round.lockPrice)
                || (round.closePrice < round.lockPrice && round.AIPrice < round.lockPrice)
                || (round.closePrice == round.lockPrice && round.AIPrice == round.lockPrice)
        ) {
            rewardBaseCalAmount = round.bullAmount;
            // no winner, house win
            if (rewardBaseCalAmount == 0) {
                treasuryAmt = round.totalAmount;
            } else {
                treasuryAmt = (round.totalAmount * treasuryFee) / 10000;
            }
            rewardAmount = round.totalAmount - treasuryAmt;
        } else {
            // Bear win when AI is wrong
            rewardBaseCalAmount = round.bearAmount;
            // no winner, house win
            if (rewardBaseCalAmount == 0) {
                treasuryAmt = round.totalAmount;
            } else {
                treasuryAmt = (round.totalAmount * treasuryFee) / 10000;
            }
            rewardAmount = round.totalAmount - treasuryAmt;
        }

        round.rewardBaseCalAmount = uint128(rewardBaseCalAmount);
        round.rewardAmount = uint128(rewardAmount);

        // Add to treasury
        treasuryAmount += treasuryAmt;

        emit RewardsCalculated(epoch, rewardBaseCalAmount, rewardAmount, treasuryAmt);
    }

    /**
     * @notice End round
     * @param epoch: epoch
     * @param price: price of the round
     */
    function _safeEndRound(uint256 epoch, uint128 price) internal {
        require(rounds[epoch].lockTimestamp != 0, "Can only end round after round has locked");
        require(uint32(block.timestamp) >= rounds[epoch].closeTimestamp, "Can only end round after closeTimestamp");
        require(
            block.timestamp <= uint256(rounds[epoch].closeTimestamp) + bufferSeconds,
            "Can only end round within bufferSeconds"
        );

        unchecked {
            Round storage round = rounds[epoch];
            round.closePrice = price;
            round.oracleCalled = true;

            emit EndRound(epoch, round.closePrice);
        }
    }

    /**
     * @notice Lock round
     * @param epoch: epoch
     * @param price: price of the round
     */
    function _safeLockRound(uint256 epoch, uint128 price) internal {
        Round storage round = rounds[epoch];
        require(round.startTimestamp != 0, "Can only lock round after round has started");
        require(uint32(block.timestamp) >= round.lockTimestamp, "Can only lock round after lockTimestamp");
        require(
            block.timestamp <= uint256(round.lockTimestamp) + bufferSeconds, "Can only lock round within bufferSeconds"
        );

        unchecked {
            round.closeTimestamp = uint32(block.timestamp + intervalSeconds);
            round.lockPrice = price;

            emit LockRound(epoch, price);
        }
    }

    /**
     * @notice Start round
     * Previous round n-2 must end
     * @param epoch: epoch
     * @param AIPrice: AI prediction price
     */
    function _safeStartRound(uint256 epoch, uint128 AIPrice) internal {
        require(genesisStartOnce, "Can only run after genesisStartRound is triggered");
        require(rounds[epoch - 2].closeTimestamp != 0, "Can only start round after round n-2 has ended");
        require(
            uint32(block.timestamp) >= rounds[epoch - 2].closeTimestamp,
            "Can only start new round after round n-2 closeTimestamp"
        );
        _startRound(epoch, AIPrice);
    }

    /**
     * @notice Transfer native token in a safe way
     * @param to: address to transfer native token to
     * @param value: native token amount to transfer (in wei)
     */
    function _safeTransferNativeToken(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}("");
        require(success, "TransferHelper: TRANSFER_FAILED");
    }

    /**
     * @notice Start round
     * Previous round n-2 must end
     * @param epoch: epoch
     * @param AIPrice: AI prediction price
     */
    function _startRound(uint256 epoch, uint128 AIPrice) internal {
        unchecked {
            Round storage round = rounds[epoch];
            round.startTimestamp = uint32(block.timestamp);
            round.lockTimestamp = uint32(block.timestamp + intervalSeconds);
            round.closeTimestamp = uint32(block.timestamp + (2 * intervalSeconds));
            round.totalAmount = 0;
            round.AIPrice = AIPrice;
        }
        emit StartRound(epoch, AIPrice);
    }

    /**
     * @notice Determine if a round is valid for receiving bets
     * Round must have started and locked
     * Current timestamp must be within startTimestamp and closeTimestamp
     */
    function _bettable(Round storage round) internal view returns (bool) {
        return round.startTimestamp != 0 && round.lockTimestamp != 0 && uint32(block.timestamp) > round.startTimestamp
            && uint32(block.timestamp) < round.lockTimestamp;
    }

    /**
     * @notice Returns true if `account` is a contract.
     * @param account: account address
     */
    function _isContract(address account) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(account)
        }
        return size != 0;
    }
}