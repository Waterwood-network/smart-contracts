// SPDX-License-Identifier: MIT

/**
 * WOOD Token forked from open source code of FLUX Token, Submitted for verification at Etherscan.io on 2020-05-08
 * Flux Tpoken: https://github.com/Datamine-Crypto/white-paper/blob/master/contracts/flux.sol
 */

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Recipient.sol";
import "@openzeppelin/contracts/token/ERC777/IERC777Sender.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/introspection/IERC1820Registry.sol";
import "@openzeppelin/contracts/token/ERC777/ERC777.sol";
import "@openzeppelin/contracts/token/ERC777/ERC777Upgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @dev Representation of each WATER Lock-in
 * @dev amount: WATER locked-in amount
 * @dev burnedamount: How much WOOD was burned
 * @dev blockNumber: When did the lock-in start
 * @dev lastMintBlockNumber: When was the last time this address minted?
 * @dev minterAddress: Who is allowed to mint on behalf of this address
 */

struct AddressLock {
    uint256 amount;
    uint256 burnedamount;
    uint256 blockNumber;
    uint256 lastMintBlockNumber;
    address minterAddress;
}

/**
 * @dev Waterwood Crypto - WOOD Smart Contract
 * upgradeable contract
 * @codingsh
 */

contract WOODToken is
    ERC777,
    IERC777Recipient,
    ERC777Upgradeable,
    OwnableUpgradeable
{
    /**
     * @dev Protect against overflows by using safe math operations (these are .add,.sub functions)
     */
    using SafeMath for uint256;

    /**
     * @dev for the re-entrancy attack protection
     */
    mapping(address => bool) private mutex;

    /**
     * @dev To avoid re-entrancy attacks
     */
    modifier preventRecursion() {
        if (mutex[_msgSender()] == false) {
            mutex[_msgSender()] = true;
            _; // Call the actual code
            mutex[_msgSender()] = false;
        }

        // Don't call the method if you are inside one already (_ above is what does the calling)
    }

    /**
     * @dev To limit one action per block per address
     */
    modifier preventSameBlock(address targetAddress) {
        require(
            addressLocks[targetAddress].blockNumber != block.number &&
                addressLocks[targetAddress].lastMintBlockNumber != block.number,
            "You can not lock/unlock/mint in the same block"
        );

        _; // Call the actual code
    }

    /**
     * @dev WATER must be locked-in to execute this function
     */
    modifier requireLocked(address targetAddress, bool requiredState) {
        if (requiredState) {
            require(
                addressLocks[targetAddress].amount != 0,
                "You must have locked-in your WATER tokens"
            );
        } else {
            require(
                addressLocks[targetAddress].amount == 0,
                "You must have unlocked your WATER tokens"
            );
        }

        _; // Call the actual code
    }

    /**
     * @dev This will be WATER token smart contract address
     */
    IERC777 private immutable _token;

    IERC1820Registry private _erc1820 =
        IERC1820Registry(0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24);
    bytes32 private constant TOKENS_RECIPIENT_INTERFACE_HASH =
        keccak256("ERC777TokensRecipient");

    /**
     * @dev Decline some incoming transactions (Only allow WOOD smart contract to send/recieve WATER tokens)
     */
    function tokensReceived(
        address operator,
        address from,
        address to,
        uint256 amount,
        bytes calldata,
        bytes calldata
    ) external override {
        require(amount > 0, "You must receive a positive number of tokens");
        require(
            _msgSender() == address(_token),
            "You can only lock-in WATER tokens"
        );

        // Ensure someone doesn't send in some WATER to this contract by mistake (Only the contract itself can send itself WATER)
        require(
            operator == address(this),
            "Only WOOD contract can send itself WATER tokens"
        );
        require(to == address(this), "Funds must be coming into WOOD token");
        require(from != to, "Why would WOOD contract send tokens to itself?");
    }

    /**
     * @dev Set to 5760 on mainnet (min 24 hours before time bonus starts)
     */
    uint256 private immutable _startTimeReward;

    /**
     * @dev Set to 161280 on mainnet (max 28 days before max 3x time reward bonus)
     */
    uint256 private immutable _maxTimeReward;

    /**
     * @dev How long until you can lock-in any WATER token amount
     */
    uint256 private immutable _failsafeTargetBlock;

    /**
     * @dev initialize uppgrade contract
     */

    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    function initialize(
        address token,
        uint256 startTimeReward,
        uint256 maxTimeReward,
        uint256 failsafeBlockDuration
    ) public virtual initializer {
        __ERC7770_init("Waterwood WOOD", "WOOD", new address[](0));
        require(maxTimeReward > 0, "maxTimeReward must be at least 1 block"); // to avoid division by 0

        _token = IERC777(token);
        _startTimeReward = startTimeReward;
        _maxTimeReward = maxTimeReward;
        _failsafeTargetBlock = block.number.add(failsafeBlockDuration);

        _erc1820.setInterfaceImplementer(
            address(this),
            TOKENS_RECIPIENT_INTERFACE_HASH,
            address(this)
        );
        __Ownable_init();
    }

    /**
     * @dev show contract version
     */
    function version() public pure returns (string memory) {
        return "version 1!";
    }

    /**
     * @dev How much max WATER can you lock-in during failsafe duration?
     */
    uint256 private constant _failsafeMaxAmount = 100 * (10**18);

    /**
     * @dev 0.00000001 WOOD minted/block/1 WATER
     * @dev 10^18 / 10^8 = 10^10
     */
    uint256 private constant _mintPerBlockDivisor = 10**8;

    /**
     * @dev To avoid small WOOD/WATER burn ratios we multiply the ratios by this number.
     */
    uint256 private constant _ratioMultiplier = 10**10;

    /**
     * @dev To get 4 decimals on our multipliers we'll multiply all ratios & divide ratios by this number.
     * @dev This is done because we're using integers without any decimals.
     */
    uint256 private constant _percentMultiplier = 10000;

    /**
     * @dev This is our max 10x WOOD burn multiplier. It's multiplicative with the time multiplier.
     */
    uint256 private constant _maxBurnMultiplier = 500000;

    /**
     * @dev This is our max 3x WATER lock-in time multiplier. It's multiplicative with the burn multiplier.
     */
    uint256 private constant _maxTimeMultiplier = 100000;

    /**
     * @dev How does time reward bonus scales? This is the "2x" in the "1x base + (0x to 2x bonus) = max 3x"
     */
    uint256 private constant _targetBlockMultiplier = 90000;

    /**
     * @dev PUBLIC FACING: By making addressLocks public we can access elements through the contract view (vs having to create methods)
     */
    mapping(address => AddressLock) public addressLocks;

    /**
     * @dev PUBLIC FACING: Store how much locked in WATER there is globally
     */
    uint256 public globalLockedamount;

    /**
     * @dev PUBLIC FACING: Store how much is burned globally (only from the locked-in WATER addresses)
     */
    uint256 public globalBurnedamount;

    // Events
    event Locked(
        address sender,
        uint256 blockNumber,
        address minterAddress,
        uint256 amount,
        uint256 burnedamountIncrease
    );
    event Unlocked(
        address sender,
        uint256 amount,
        uint256 burnedamountDecrease
    );
    event BurnedToAddress(
        address sender,
        address targetAddress,
        uint256 amount
    );
    event Minted(
        address sender,
        uint256 blockNumber,
        address sourceAddress,
        address targetAddress,
        uint256 targetBlock,
        uint256 amount
    );

    //////////////////// END HEADER //////////////////////

    /**
     * @dev PUBLIC FACING: Lock-in WATER tokens with the specified address as the minter.
     */
    function lock(address minterAddress, uint256 amount)
        public
        preventRecursion
        preventSameBlock(_msgSender())
        requireLocked(_msgSender(), false) // Ensure WATER is unlocked for sender
    {
        require(amount > 0, "You must provide a positive amount to lock-in");

        // Ensure you can only lock up to 100 WATER during failsafe period
        if (block.number < _failsafeTargetBlock) {
            require(
                amount <= _failsafeMaxAmount,
                "You can only lock-in up to 100 WATER during failsafe."
            );
        }

        AddressLock storage senderAddressLock = addressLocks[_msgSender()]; // Shortcut accessor

        senderAddressLock.amount = amount;
        senderAddressLock.blockNumber = block.number;
        senderAddressLock.lastMintBlockNumber = block.number; // Reset the last mint height to new lock height
        senderAddressLock.minterAddress = minterAddress;

        globalLockedamount = globalLockedamount.add(amount);
        globalBurnedamount = globalBurnedamount.add(
            senderAddressLock.burnedamount
        );

        emit Locked(
            _msgSender(),
            block.number,
            minterAddress,
            amount,
            senderAddressLock.burnedamount
        );

        // Send [amount] of WATER token from the address that is calling this function to WOOD smart contract.
        IERC777(_token).operatorSend(
            _msgSender(),
            address(this),
            amount,
            "",
            ""
        ); // [RE-ENTRANCY WARNING] external call, must be at the end
    }

    /**
     * @dev PUBLIC FACING: Unlock any sender locked-in WATER tokens
     */
    function unlock()
        public
        preventRecursion
        preventSameBlock(_msgSender())
        requireLocked(_msgSender(), true) // Ensure WATER is locked-in for sender
    {
        AddressLock storage senderAddressLock = addressLocks[_msgSender()]; // Shortcut accessor

        uint256 amount = senderAddressLock.amount;
        senderAddressLock.amount = 0;

        globalLockedamount = globalLockedamount.sub(amount);
        globalBurnedamount = globalBurnedamount.sub(
            senderAddressLock.burnedamount
        );

        emit Unlocked(_msgSender(), amount, senderAddressLock.burnedamount);

        // Send back the locked-in WATER amount to person calling the method
        IERC777(_token).send(_msgSender(), amount, ""); // [RE-ENTRANCY WARNING] external call, must be at the end
    }

    /**
     * @dev PUBLIC FACING: Burn WOOD tokens to a specific address
     */
    function burnToAddress(address targetAddress, uint256 amount)
        public
        preventRecursion
        requireLocked(targetAddress, true) // Ensure the address you are burning to has WATER locked-in
    {
        require(amount > 0, "You must burn > 0 WOOD");

        AddressLock storage targetAddressLock = addressLocks[targetAddress]; // Shortcut accessor, pay attention to targetAddress here

        targetAddressLock.burnedamount = targetAddressLock.burnedamount.add(
            amount
        );

        globalBurnedamount = globalBurnedamount.add(amount);

        emit BurnedToAddress(_msgSender(), targetAddress, amount);

        // Call the normal ERC-777 burn (this will destroy WOOD tokens). We don't check address balance for amount because the internal burn does this check for us.
        _burn(_msgSender(), amount, "", ""); // [RE-ENTRANCY WARNING] external call, must be at the end
    }

    /**
     * @dev PUBLIC FACING: Mint WOOD tokens from a specific address to a specified address UP TO the target block
     */
    function mintToAddress(
        address sourceAddress,
        address targetAddress,
        uint256 targetBlock
    )
        public
        preventRecursion
        preventSameBlock(sourceAddress)
        requireLocked(sourceAddress, true) // Ensure the adress that is being minted from has WATER locked-in
    {
        require(
            targetBlock <= block.number,
            "You can only mint up to current block"
        );

        AddressLock storage sourceAddressLock = addressLocks[sourceAddress]; // Shortcut accessor, pay attention to sourceAddress here

        require(
            sourceAddressLock.lastMintBlockNumber < targetBlock,
            "You can only mint ahead of last mint block"
        );
        require(
            sourceAddressLock.minterAddress == _msgSender(),
            "You must be the delegated minter of the sourceAddress"
        );

        uint256 mintAmount = getMintAmount(sourceAddress, targetBlock);
        require(mintAmount > 0, "You can not mint zero balance");

        sourceAddressLock.lastMintBlockNumber = targetBlock; // Reset the mint height

        emit Minted(
            _msgSender(),
            block.number,
            sourceAddress,
            targetAddress,
            targetBlock,
            mintAmount
        );

        // Call the normal ERC-777 mint (this will mint WOOD tokens to targetAddress)
        _mint(targetAddress, mintAmount, "", ""); // [RE-ENTRANCY WARNING] external call, must be at the end
    }

    //////////////////// VIEW ONLY //////////////////////

    /**
     * @dev PUBLIC FACING: Get mint amount of a specific amount up to a target block
     */
    function getMintAmount(address targetAddress, uint256 targetBlock)
        public
        view
        returns (uint256)
    {
        AddressLock storage targetAddressLock = addressLocks[targetAddress]; // Shortcut accessor

        // Ensure this address has WATER locked-in
        if (targetAddressLock.amount == 0) {
            return 0;
        }

        require(
            targetBlock <= block.number,
            "You can only calculate up to current block"
        );
        require(
            targetAddressLock.lastMintBlockNumber <= targetBlock,
            "You can only specify blocks at or ahead of last mint block"
        );

        uint256 blocksMinted =
            targetBlock.sub(targetAddressLock.lastMintBlockNumber);

        uint256 amount = targetAddressLock.amount; // Total of locked-in WATER for this address
        uint256 blocksMintedByAmount = amount.mul(blocksMinted);

        // Adjust by multipliers
        uint256 burnMultiplier = getAddressBurnMultiplier(targetAddress);
        uint256 timeMultipler = getAddressTimeMultiplier(targetAddress);
        uint256 WOODAfterMultiplier =
            blocksMintedByAmount
                .mul(burnMultiplier)
                .div(_percentMultiplier)
                .mul(timeMultipler)
                .div(_percentMultiplier);

        uint256 actualWOODMinted =
            WOODAfterMultiplier.div(_mintPerBlockDivisor);
        return actualWOODMinted;
    }

    /**
     * @dev PUBLIC FACING: Find out the current address WATER lock-in time bonus (Using 1 block = 15 sec formula)
     */
    function getAddressTimeMultiplier(address targetAddress)
        public
        view
        returns (uint256)
    {
        AddressLock storage targetAddressLock = addressLocks[targetAddress]; // Shortcut accessor

        // Ensure this address has WATER locked-in
        if (targetAddressLock.amount == 0) {
            return _percentMultiplier;
        }

        // You don't get any bonus until min blocks passed
        uint256 targetBlockNumber =
            targetAddressLock.blockNumber.add(_startTimeReward);
        if (block.number < targetBlockNumber) {
            return _percentMultiplier;
        }

        // 24 hours - min before starting to receive rewards
        // 28 days - max for waiting 28 days (The function returns PERCENT (10000x) the multiplier for 4 decimal accuracy
        uint256 blockDiff =
            block
                .number
                .sub(targetBlockNumber)
                .mul(_targetBlockMultiplier)
                .div(_maxTimeReward)
                .add(_percentMultiplier);

        uint256 timeMultiplier = Math.min(_maxTimeMultiplier, blockDiff); // Min 1x, Max 3x
        return timeMultiplier;
    }

    /**
     * @dev PUBLIC FACING: Get burn multipler for a specific address. This will be returned as PERCENT (10000x)
     */
    function getAddressBurnMultiplier(address targetAddress)
        public
        view
        returns (uint256)
    {
        uint256 myRatio = getAddressRatio(targetAddress);
        uint256 globalRatio = getGlobalRatio();

        // Avoid division by 0 & ensure 1x multiplier if nothing is locked
        if (globalRatio == 0 || myRatio == 0) {
            return _percentMultiplier;
        }

        // The final multiplier is return with 10000x multiplication and will need to be divided by 10000 for final number
        uint256 burnMultiplier =
            Math.min(
                _maxBurnMultiplier,
                myRatio.mul(_percentMultiplier).div(globalRatio).add(
                    _percentMultiplier
                )
            ); // Min 1x, Max 10x
        return burnMultiplier;
    }

    /**
     * @dev PUBLIC FACING: Get WATER/WOOD burn ratio for a specific address
     */
    function getAddressRatio(address targetAddress)
        public
        view
        returns (uint256)
    {
        AddressLock storage targetAddressLock = addressLocks[targetAddress]; // Shortcut accessor

        uint256 addressLockedamount = targetAddressLock.amount;
        uint256 addressBurnedamount = targetAddressLock.burnedamount;

        // If you haven't minted or burned anything then you get the default 1x multiplier
        if (addressLockedamount == 0) {
            return 0;
        }

        // Burn/Lock-in ratios for both address & network
        // Note that we multiply both ratios by the ratio multiplier before dividing. For tiny WOOD/WATER burn ratios.
        uint256 myRatio =
            addressBurnedamount.mul(_ratioMultiplier).div(addressLockedamount);
        return myRatio;
    }

    /**
     * @dev PUBLIC FACING: Get WATER/WOOD burn ratio for global (entire network)
     */
    function getGlobalRatio() public view returns (uint256) {
        // If you haven't minted or burned anything then you get the default 1x multiplier
        if (globalLockedamount == 0) {
            return 0;
        }

        // Burn/Lock-in ratios for both address & network
        // Note that we multiply both ratios by the ratio multiplier before dividing. For tiny WOOD/WATER burn ratios.
        uint256 globalRatio =
            globalBurnedamount.mul(_ratioMultiplier).div(globalLockedamount);
        return globalRatio;
    }

    /**
     * @dev PUBLIC FACING: Grab a collection of data
     * @dev ABIEncoderV2 was still experimental at time of writing this. Better approach would be to return struct.
     */
    function getAddressDetails(address targetAddress)
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        uint256 WOODBalance = balanceOf(targetAddress);
        uint256 mintAmount = getMintAmount(targetAddress, block.number);

        uint256 addressTimeMultiplier = getAddressTimeMultiplier(targetAddress);
        uint256 addressBurnMultiplier = getAddressBurnMultiplier(targetAddress);

        return (
            block.number,
            WOODBalance,
            mintAmount,
            addressTimeMultiplier,
            addressBurnMultiplier,
            globalLockedamount,
            globalBurnedamount
        );
    }

    /**
     * @dev PUBLIC FACING: Grab additional token details
     * @dev ABIEncoderV2 was still experimental at time of writing this. Better approach would be to return struct.
     */
    function getAddressTokenDetails(address targetAddress)
        public
        view
        returns (
            uint256,
            bool,
            uint256,
            uint256,
            uint256
        )
    {
        bool isWOODOperator =
            IERC777(_token).isOperatorFor(address(this), targetAddress);
        uint256 WATERBalance = IERC777(_token).balanceOf(targetAddress);

        uint256 myRatio = getAddressRatio(targetAddress);
        uint256 globalRatio = getGlobalRatio();

        return (
            block.number,
            isWOODOperator,
            WATERBalance,
            myRatio,
            globalRatio
        );
    }
}
