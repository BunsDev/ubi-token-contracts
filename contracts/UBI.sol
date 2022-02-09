// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

/**
 * This code contains elements of ERC20BurnableUpgradeable.sol https://github.com/OpenZeppelin/openzeppelin-contracts-upgradeable/blob/master/contracts/token/ERC20/ERC20BurnableUpgradeable.sol
 * Those have been inlined for the purpose of gas optimization.
 */

import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/cryptography/ECDSA.sol";
import "./interfaces/IStreamable.sol";
import "hardhat/console.sol";

/**
 * @title ProofOfHumanity Interface
 * @dev See https://github.com/Proof-Of-Humanity/Proof-Of-Humanity.
 */
interface IProofOfHumanity {
  function isRegistered(address _submissionID)
    external
    view
    returns (
      bool registered
    );
}

/**
 * @title Universal Basic Income
 * @dev UBI is an ERC20 compatible token that is connected to a Proof of Humanity registry.
 *
 * Tokens are issued and drip over time for every verified submission on a Proof of Humanity registry.
 * The accrued tokens are updated directly on every wallet using the `balanceOf` function.
 * The tokens get effectively minted and persisted in memory when someone interacts with the contract doing a `transfer` or `burn`.
 */
contract UBI is Initializable, IStreamable {


  /* Events */

  /**
   * @dev Emitted when `value` tokens are moved from one account (`from`) to another (`to`).
   *
   * Note that `value` may be zero.
   * Also note that due to continuous minting we cannot emit transfer events from the address 0 when tokens are created.
   * In order to keep consistency, we decided not to emit those events from the address 0 even when minting is done within a transaction.
   */
  event Transfer(address indexed from, address indexed to, uint256 value);

  /**
   * @dev Emitted when the allowance of a `spender` for an `owner` is set by
   * a call to {approve}. `value` is the new allowance.
   */
  event Approval(address indexed owner, address indexed spender, uint256 value);

  using SafeMath for uint256;

  /* Storage */

  mapping (address => uint256) private ubiBalance;

  mapping (address => mapping (address => uint256)) public allowance;

  /// @dev A lower bound of the total supply. Does not take into account tokens minted as UBI by an address before it moves those (transfer or burn).
  uint256 public totalSupply;

  /// @dev Name of the token.
  string public name;

  /// @dev Symbol of the token.
  string public symbol;

  /// @dev Number of decimals of the token.
  uint8 public decimals;

  /// @dev How many tokens per second will be minted for every valid human.
  uint256 public accruedPerSecond;

  /// @dev The contract's governor.
  address public governor;

  /// @dev The Proof Of Humanity registry to reference.
  IProofOfHumanity public proofOfHumanity;

  /// @dev Timestamp since human started accruing.
  mapping(address => uint256) public accruedSince;

  /// @dev Nonces for permit function. Must be modified only through permit function, where is incremented only by one.
  mapping (address => uint256) public nonces;

  /// @dev Chain id used for domain separator.
  uint256 public chainId;

  /// @dev Typehash used for permit function.
  bytes32 public permitTypehash;

  /// @dev Domain separator used for permit function.
  bytes32 public domainSeparator;

  /// @dev Maximum number of streams allowed.
  uint256 public maxStreamsAllowed;

  /*** REENTRANCY GUARD (https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol) ***/
  // The values being non-zero value makes deployment a bit more expensive,
  // but in exchange the refund on every call to nonReentrant will be lower in
  // amount. Since refunds are capped to a percentage of the total
  // transaction's gas, it is best to keep them low in cases like this one, to
  // increase the likelihood of the full refund coming into effect.
  uint256 private constant _NOT_ENTERED = 1;
  uint256 private constant _ENTERED = 2;
  uint256 private _reentrancyStatus;

  /*** IStreamable Storage Properties ***/

  /**
  * @dev Counter for new stream ids. Stores the last used stream id.
  * @notice 0 is an invalid stream. it's used to check for empty streams on `streamIds` mapping
  */
  uint256 public prevStreamId;

  /**
  * @dev The stream objects identifiable by their unsigned integer ids.
  */
  mapping(uint256 => Types.Stream) private streams;

  /// @dev Get the streamIds from human and recipient addresses.
  /// A recipient can have multiple streams with a sender.
  mapping (address => mapping(address => uint256[])) public streamIdsOfSenderAndRecipient;

    
  /// @dev A mapping containing UNORDERED lists of the stream ids of each sender.
  /// @notice This does not guarantee to contain valid streams (may have ended).
  mapping (address => uint256[]) public streamIdsOf;
  
  /* Modifiers */

  /**
  * @dev Prevents a contract from calling itself, directly or indirectly.
  * Calling a `nonReentrant` function from another `nonReentrant`
  * function is not supported. It is possible to prevent this from happening
  * by making the `nonReentrant` function external, and make it call a
  * `private` function that does the actual work.
  */
  modifier nonReentrant() {
    // On the first call to nonReentrant, _notEntered will be true
    require(_reentrancyStatus != _ENTERED, "ReentrancyGuard: reentrant call");

    // Any calls to nonReentrant after this point will fail
    _reentrancyStatus = _ENTERED;

    _;

    // By storing the original value once again, a refund is triggered (see
    // https://eips.ethereum.org/EIPS/eip-2200)
    _reentrancyStatus = _NOT_ENTERED;
  }

  /// @dev Verifies that the sender has ability to modify governed parameters.
  modifier onlyByGovernor() {
    require(governor == msg.sender, "The caller is not the governor.");
    _;
  }

  /* Initializer */

  /** @dev Constructor.
  *  @param _initialSupply for the UBI coin including all decimals.
  *  @param _name for UBI coin.
  *  @param _symbol for UBI coin ticker.
  *  @param _accruedPerSecond How much of the token is accrued per block.
  *  @param _proofOfHumanity The Proof Of Humanity registry to reference.
  */
  function initialize(uint256 _initialSupply, string memory _name, string memory _symbol, uint256 _accruedPerSecond, IProofOfHumanity _proofOfHumanity) public initializer {
    name = _name;
    symbol = _symbol;
    decimals = 18;

    accruedPerSecond = _accruedPerSecond;
    proofOfHumanity = _proofOfHumanity;
    governor = msg.sender;

    ubiBalance[msg.sender] = _initialSupply;
    totalSupply = _initialSupply;

    chainId = _getCurrentChainId();
    permitTypehash = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    domainSeparator = _buildDomainSeparator();
  }

  function upgrade() public onlyByGovernor {
    require(_reentrancyStatus == 0, "Contract already upgraded");
    require(maxStreamsAllowed == 0, "Contract already upgraded");
    _reentrancyStatus = _NOT_ENTERED;
    maxStreamsAllowed = 100;
  }

  /* External */

  /** @dev Starts accruing UBI for a registered submission.
  *  @param _human The submission ID.
  */
  function startAccruing(address _human) external {
    require(proofOfHumanity.isRegistered(_human), "The submission is not registered in Proof Of Humanity.");
    require(accruedSince[_human] == 0, "The submission is already accruing UBI.");
    accruedSince[_human] = block.timestamp;
  }

  /** @dev Allows anyone to report a submission that
  *  should no longer receive UBI due to removal from the
  *  Proof Of Humanity registry. The reporter receives any
  *  leftover accrued UBI.
  *  @param _human The submission ID.
  */
  function reportRemoval(address _human) external  {
    require(!proofOfHumanity.isRegistered(_human), "The submission is still registered in Proof Of Humanity.");
    require(accruedSince[_human] != 0, "The submission is not accruing UBI.");
    uint256 newSupply = accruedPerSecond.mul(block.timestamp.sub(accruedSince[_human]));

    accruedSince[_human] = 0;

    ubiBalance[msg.sender] = ubiBalance[msg.sender].add(newSupply);
    totalSupply = totalSupply.add(newSupply);
  }

  /** @dev Changes `governor` to `_governor`.
  *  @param _governor The address of the new governor.
  */
  function changeGovernor(address _governor) external onlyByGovernor {
    governor = _governor;
  }

  /** @dev Changes `proofOfHumanity` to `_proofOfHumanity`.
  *  @param _proofOfHumanity Registry that meets interface of Proof of Humanity.
  */
  function changeProofOfHumanity(IProofOfHumanity _proofOfHumanity) external onlyByGovernor {
    proofOfHumanity = _proofOfHumanity;
  }

  /**
  * @dev Returns the domain separator used in the encoding of the signature for `permit`, as defined by {EIP712}.
  */
  function DOMAIN_SEPARATOR() external view returns (bytes32) {
    return _buildDomainSeparator();
  }

  /** @dev Transfers `_amount` to `_recipient` and withdraws accrued tokens.
  *  @param _recipient The entity receiving the funds.
  *  @param _amount The amount to tranfer in base units.
  */
  function transfer(address _recipient, uint256 _amount) public returns (bool) {
    uint256 newSupplyFrom;
    uint256 pendingDelegatedAccruedValue = getDelegatedAccruedValue(msg.sender);
    if (accruedSince[msg.sender] != 0 && proofOfHumanity.isRegistered(msg.sender)) {
        newSupplyFrom = accruedPerSecond.mul(block.timestamp.sub(accruedSince[msg.sender]));
        totalSupply = totalSupply.add(newSupplyFrom);
        accruedSince[msg.sender] = block.timestamp;
    }
    ubiBalance[msg.sender] = ubiBalance[msg.sender].add(newSupplyFrom).sub(pendingDelegatedAccruedValue).sub(_amount, "ERC20: transfer amount exceeds balance");
    ubiBalance[_recipient] = ubiBalance[_recipient].add(_amount);
    emit Transfer(msg.sender, _recipient, _amount);
    return true;
  }

  /** @dev Transfers `_amount` from `_sender` to `_recipient` and withdraws accrued tokens.
  *  @param _sender The entity to take the funds from.
  *  @param _recipient The entity receiving the funds.
  *  @param _amount The amount to tranfer in base units.
  */
  function transferFrom(address _sender, address _recipient, uint256 _amount) public returns (bool) {
    uint256 newSupplyFrom;
    uint256 pendingDelegatedAccruedValue = getDelegatedAccruedValue(_sender);
    allowance[_sender][msg.sender] = allowance[_sender][msg.sender].sub(_amount, "ERC20: transfer amount exceeds allowance");
    if (accruedSince[_sender] != 0 && proofOfHumanity.isRegistered(_sender)) {
        newSupplyFrom = accruedPerSecond.mul(block.timestamp.sub(accruedSince[_sender]));
        totalSupply = totalSupply.add(newSupplyFrom);
        accruedSince[_sender] = block.timestamp;
    }
    ubiBalance[_sender] = ubiBalance[_sender].add(newSupplyFrom).sub(pendingDelegatedAccruedValue).sub(_amount, "ERC20: transfer amount exceeds balance");
    ubiBalance[_recipient] = ubiBalance[_recipient].add(_amount);
    emit Transfer(_sender, _recipient, _amount);
    return true;
  }

  /** @dev Approves `_spender` to spend `_amount`.
  *  @param _spender The entity allowed to spend funds.
  *  @param _amount The amount of base units the entity will be allowed to spend.
  */
  function approve(address _spender, uint256 _amount) public returns (bool) {
    allowance[msg.sender][_spender] = _amount;
    emit Approval(msg.sender, _spender, _amount);
    return true;
  }

  /** @dev Increases the `_spender` allowance by `_addedValue`.
  *  @param _spender The entity allowed to spend funds.
  *  @param _addedValue The amount of extra base units the entity will be allowed to spend.
  */
  function increaseAllowance(address _spender, uint256 _addedValue) public returns (bool) {
    uint256 newAllowance = allowance[msg.sender][_spender].add(_addedValue);
    allowance[msg.sender][_spender] = newAllowance;
    emit Approval(msg.sender, _spender, newAllowance);
    return true;
  }

  /** @dev Decreases the `_spender` allowance by `_subtractedValue`.
  *  @param _spender The entity whose spending allocation will be reduced.
  *  @param _subtractedValue The reduction of spending allocation in base units.
  */
  function decreaseAllowance(address _spender, uint256 _subtractedValue) public returns (bool) {
    uint256 newAllowance = allowance[msg.sender][_spender].sub(_subtractedValue, "ERC20: decreased allowance below zero");
    allowance[msg.sender][_spender] = newAllowance;
    emit Approval(msg.sender, _spender, newAllowance);
    return true;
  }

  /** @dev Burns `_amount` of tokens and withdraws accrued tokens.
  *  @param _amount The quantity of tokens to burn in base units.
  */
  function burn(uint256 _amount) public {
    uint256 newSupplyFrom;
    uint256 pendingDelegatedAccruedValue = getDelegatedAccruedValue(msg.sender);
    if(accruedSince[msg.sender] != 0 && proofOfHumanity.isRegistered(msg.sender)) {
      newSupplyFrom = accruedPerSecond.mul(block.timestamp.sub(accruedSince[msg.sender]));
      accruedSince[msg.sender] = block.timestamp;
    }
    ubiBalance[msg.sender] = ubiBalance[msg.sender].add(newSupplyFrom).sub(pendingDelegatedAccruedValue).sub(_amount, "ERC20: burn amount exceeds balance");
    totalSupply = totalSupply.add(newSupplyFrom).sub(_amount);
    emit Transfer(msg.sender, address(0), _amount);
  }

  /** @dev Burns `_amount` of tokens from `_account` and withdraws accrued tokens.
  *  @param _account The entity to burn tokens from.
  *  @param _amount The quantity of tokens to burn in base units.
  */
  function burnFrom(address _account, uint256 _amount) public {
    uint256 newSupplyFrom;
    allowance[_account][msg.sender] = allowance[_account][msg.sender].sub(_amount, "ERC20: burn amount exceeds allowance");
    uint256 pendingDelegatedAccruedValue = getDelegatedAccruedValue(_account);
    if (accruedSince[_account] != 0 && proofOfHumanity.isRegistered(_account)) {
        newSupplyFrom = accruedPerSecond.mul(block.timestamp.sub(accruedSince[_account]));
        accruedSince[_account] = block.timestamp;
    }
    ubiBalance[_account] = ubiBalance[_account].add(newSupplyFrom).sub(pendingDelegatedAccruedValue).sub(_amount, "ERC20: burn amount exceeds balance");
    totalSupply = totalSupply.add(newSupplyFrom).sub(_amount);
    emit Transfer(_account, address(0), _amount);
  }

  /**
  * @dev Approves, through a message signed by the `_owner`, `_spender` to spend `_value` tokens from `_owner`.
  * @param _owner The address of the token owner.
  * @param _spender The address of the spender.
  * @param _value The amount of tokens to approve.
  * @param _deadline The expiration time until which the signature will be considered valid.
  * @param _v The signature v value.
  * @param _r The signature r value.
  * @param _s The signature s value.
  */
  function permit(address _owner, address _spender, uint256 _value, uint256 _deadline, uint8 _v, bytes32 _r, bytes32 _s) public {
    require(_owner != address(0), "ERC20Permit: invalid owner");
    require(block.timestamp <= _deadline, "ERC20Permit: expired deadline");
    bytes32 structHash = keccak256(abi.encode(permitTypehash, _owner, _spender, _value, nonces[_owner], _deadline));
    if (_getCurrentChainId() != chainId) {
      domainSeparator = _buildDomainSeparator();
    }
    bytes32 hash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    address signer = ECDSA.recover(hash, _v, _r, _s);
    require(signer == _owner, "ERC20Permit: invalid signature");
    // Must be modified only here. Doesn't need SafeMath because can't reach overflow if incremented only here by one.
    // See: https://www.schneier.com/blog/archives/2009/09/the_doghouse_cr.html
    nonces[_owner]++;
    allowance[_owner][_spender] = _value;
    emit Approval(_owner, _spender, _value);
  }

  /**
  * @dev Builds and returns the domain separator used in the encoding of the signature for `permit` using the current
  * chain id.
  */
  function _buildDomainSeparator() internal view returns (bytes32) {
    string memory version = "2";
    return keccak256(
      abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256(bytes(name)),
        keccak256(bytes(version)),
        _getCurrentChainId(),
        address(this)
      )
    ); 
  }

  /**
  * @dev Returns the current chain id.
  */
  function _getCurrentChainId() internal pure returns (uint256 currentChainId) {
    assembly {
      currentChainId := chainid()
    }
  }

  /* Getters */

  /** @dev Calculates how much UBI a submission has available for withdrawal.
  *  @param _human The submission ID.
  *  @return accrued The available UBI for withdrawal.
  */
  function getAccruedValue(address _human) public view returns (uint256 accrued) {
    // If this human have not started to accrue, or is not registered, return 0.
    if (accruedSince[_human] == 0 || !proofOfHumanity.isRegistered(_human)) return 0;

    else return accruedPerSecond.mul(block.timestamp.sub(accruedSince[_human]));
  }

  /**
  * @dev Calculates the current user accrued balance.
  * @param _human The submission ID.
  * @return The current balance including accrued Universal Basic Income of the user.
  **/
  function balanceOf(address _human) public view returns (uint256) {
    uint256 pendingDelegatedAccruedValue = 0;

    // Subtract pending value already consolidated
     for(uint256 i = 0; i < streamIdsOf[_human].length; i++) {
        uint256 streamId = streamIdsOf[_human][i];

        Types.Stream memory stream = streams[streamId];
        if(!stream.isEntity) continue; // Stream Exists
        if(!proofOfHumanity.isRegistered(stream.sender)) continue; // Sender is a registered human

        // If stream has not started, or it has been accrued all.
        if(block.timestamp < stream.startTime) continue;

        // Time delegated to the stream
        uint256 streamAccumulatedTime = deltaOf(streamId);
        // // If there is accumulated time and the human accrued after the stream started, subtract delta of accrued since and startTime
        uint256 streamAccruingStart = Math.max(stream.startTime, stream.accruedSince);
        if(streamAccumulatedTime > 0 && accruedSince[_human] >= streamAccruingStart) {
          uint256 streamAccruingStop = Math.min(accruedSince[_human],Math.min(block.timestamp, stream.stopTime));
          uint256 toSubtract = streamAccruingStop.sub(streamAccruingStart);
          // Subtract time already accounted for
          streamAccumulatedTime = streamAccumulatedTime.sub(Math.min(toSubtract,streamAccumulatedTime));
        }   
        // Stream's total accrued value is the accumulated time * stream's ratePerSecond
        pendingDelegatedAccruedValue += streamAccumulatedTime.mul(stream.ratePerSecond);
      }  

      // Total balance is: Last balance + (accrued balance - delegated accrued balance)
      return getAccruedValue(_human).add(ubiBalance[_human]).sub(pendingDelegatedAccruedValue);
  }

    /*** Modifiers ***/

    /**
     * @dev Throws if the caller is not the sender or the recipient of the stream.
     */
    modifier onlySenderOrRecipient(uint256 streamId) {
        require(
            msg.sender == streams[streamId].sender || msg.sender == streams[streamId].recipient,
            "caller is not the sender or the recipient of the stream"
        );
        _;
    }

    /**
     * @dev Throws if the provided id does not point to a valid stream.
     */
    modifier streamExists(uint256 streamId) {
        require(streams[streamId].isEntity, "stream does not exist");
        _;
    }

    /**
     * @notice Returns either the delta in seconds between `block.timestamp` and `startTime` or
     *  between `stopTime` and `startTime, whichever is smaller. If `block.timestamp` is before
     *  `startTime`, it returns 0.
     * @dev Throws if the id does not point to a valid stream.
     * @param streamId ID of the stream for which to query the delta.
     */
    function deltaOf(uint256 streamId) public view returns (uint256) {
      Types.Stream memory stream = streams[streamId];
      if(!stream.isEntity) return 0;

        if (block.timestamp < stream.startTime) return 0; // Stream not started
        if(stream.accruedSince >= stream.stopTime) return 0; // All stream withdrawn
        
      if(stream.accruedSince > 0) {	
        return Math.min(stream.stopTime, block.timestamp).sub(stream.accruedSince);
      } else {
        return Math.min(stream.stopTime, block.timestamp).sub(stream.startTime);
      }
    }

    /*** Contract Logic Starts Here */

    /*** View Functions ***/

    /**
     * @notice Returns the stream with all its properties.
     * @dev Throws if the id does not point to a valid stream.
     * @param streamId The id of the stream to query.
     */
    function getStream(uint256 streamId)
        external
        override
        view
        streamExists(streamId)
        returns (
            address sender,
            address recipient,
            uint256 startTime,
            uint256 stopTime,
            uint256 streamAccruedSince,
            uint256 ratePerSecond
        )
    {
        sender = streams[streamId].sender;
        recipient = streams[streamId].recipient;
        startTime = streams[streamId].startTime;
        stopTime = streams[streamId].stopTime;
        streamAccruedSince = streams[streamId].accruedSince;
        ratePerSecond = streams[streamId].ratePerSecond;
    }

    /**
     * @notice Returns the available funds for the given stream id and address.
     * @dev Throws if the id does not point to a valid stream.
     * @param streamId The id of the stream for which to query the balance.
     */
    function balanceOf(uint256 streamId) public override view streamExists(streamId) returns (uint256) {
        Types.Stream memory stream = streams[streamId];
        if(!stream.isEntity) return 0;

        if(!proofOfHumanity.isRegistered(stream.sender)) return 0;
        if(stream.startTime > block.timestamp) return 0;

        // Time accumulated by the stream
        uint256 streamAccumulatedTime = deltaOf(streamId);

        // UBI accrued by the scream
        uint256 streamAccruedValue = streamAccumulatedTime.mul(stream.ratePerSecond);
        return streamAccruedValue;
    }

    /**
     * @notice Creates a new stream funded by `msg.sender` and paid towards `recipient`.
     * @dev Throws if the recipient is the zero address, the contract itself or the caller.
     *  Throws if the start time is before `block.timestamp`.
     *  Throws if the stop time is before the start time.
     *  Throws if the duration calculation has a math error.
     *  Throws if the rate calculation has a math error.
     *  Throws if the next stream id calculation has a math error.
     *  Throws if the contract is not allowed to transfer enough tokens.
     *  Throws if there is a token transfer failure.
     * @param recipient The address towards which the money is streamed.
     * @param ubiPerSecond The amount of UBI to be streamed every second. MUST be <= accruedPerSecond
     * @param startTime The unix timestamp for when the stream starts.
     * @param stopTime The unix timestamp for when the stream stops.
     * @return The uint256 id of the newly created stream.
     */
    function createStream(address recipient, uint256 ubiPerSecond, uint256 startTime, uint256 stopTime)
        public
        override
        nonReentrant
        returns (uint256)
    {
        require(proofOfHumanity.isRegistered(msg.sender) && accruedSince[msg.sender] > 0, "Only registered humans accruing UBI can stream UBI.");
        require(recipient != address(0x00), "stream to the zero address");
        require(recipient != address(this), "stream to the contract itself");
        require(recipient != msg.sender, "stream to the caller");
        require(ubiPerSecond > 0, "UBI per second is zero");
        require(startTime > block.timestamp, "start time should be in the future");
        require(stopTime > startTime, "stop time before the start time");
        require(ubiPerSecond <= accruedPerSecond, "Cannot delegate a value higher than accruedPerSecond");

        // Check that we are not exceeding the max allowed.
        require(streamIdsOf[msg.sender].length + 1 <= maxStreamsAllowed, "max streams exceeded");

        // Multiple streams to teh same recipient only allowed if none is active on the new stream's time period
        for(uint256 i = 0; i < streamIdsOfSenderAndRecipient[msg.sender][recipient].length; i ++) {
          uint256 existingStreamId = streamIdsOfSenderAndRecipient[msg.sender][recipient][i];
          if(existingStreamId > 0) require(
            !overlapsWith(startTime, stopTime, streams[existingStreamId].startTime, streams[existingStreamId].stopTime),
            "Account is already a recipient on an active or overlaping stream.");
        }

        // Avoid circular delegation validating that the recipient did not delegate to the sender
        for(uint256 i = 0 ; i < streamIdsOf[recipient].length; i++) {
          uint256 recipientStreamId = streamIdsOf[recipient][i];

          // If the recipient of this stream is the same as the sender and overlaps, fail with circular delegation exception
          if(recipientStreamId > 0 && streams[recipientStreamId].recipient == msg.sender) {
            // Get overlap flag
            bool overlaps = overlapsWith(startTime, stopTime, streams[recipientStreamId].startTime, streams[recipientStreamId].stopTime);
     	      require(!overlaps, "Circular delegation not allowed.");
          }
        }

        // Calculate available balance to delegate for the given period.
        uint256 delegatedBalance;
        for(uint256 i = 0; i < streamIdsOf[msg.sender].length; i++) {
          uint256 streamId = streamIdsOf[msg.sender][i];
          Types.Stream memory otherStream = streams[streamId];
          // If streams overlap subtract the delegated balance from the available ubi per second
          if(overlapsWith(otherStream.startTime, otherStream.stopTime, startTime, stopTime)) {
              delegatedBalance = delegatedBalance.add(otherStream.ratePerSecond);
          }
        }

        require(ubiPerSecond <= accruedPerSecond.sub(delegatedBalance), "Delegated value exceeds available balance for the given stream period");

        /* Create and store the stream object. */
        uint256 newStreamId = prevStreamId.add(1);
		    // Create the stream
        streams[newStreamId] = Types.Stream({
          // how many UBI to delegate per second.
          ratePerSecond: ubiPerSecond,
          // Starts with 0. Accumulates as time passes.
          isEntity: true,
          recipient: recipient,
          sender: msg.sender,
          startTime: startTime,
          stopTime: stopTime,
          accruedSince: 0
        });

        streamIdsOfSenderAndRecipient[msg.sender][recipient].push(newStreamId);
        streamIdsOf[msg.sender].push(newStreamId);

        /* Increment the next stream id. */
        prevStreamId = newStreamId;

        emit CreateStream(newStreamId, msg.sender, recipient, ubiPerSecond, startTime, stopTime);
        return newStreamId;
    }

    /**
     * @notice Withdraws the UBI streamed from multiple streams to the recipient's account.
     * @dev Throws if any of the ids does not point to a valid stream.
     *  Throws if the caller is not the sender or the recipient of the stream.
     *  Throws if there is a token transfer failure.
     * @param streamIds Array of stream IDs to withdraw tokens from.
     */
    function withdrawFromStreams(uint256[] calldata streamIds)
        external
        override
        nonReentrant
    {
      for(uint256 i = 0; i < streamIds.length; i++) {
        _withdrawFromStream(streamIds[i]);
      }
    }

    /**
     * @dev Withdraw funds from a specific stream to its recipient. Deletes the stream if its completed.
     * @param streamId The ID of the stream to withdraw from.
     */
    function _withdrawFromStream(uint256 streamId) private streamExists(streamId) {
      // Get stream
      Types.Stream memory stream = streams[streamId];
      // Make sure stream is active and has accrued UBI
      require(stream.startTime <= block.timestamp && stream.accruedSince < stream.stopTime, "Stream has not accrued enough UBI yet.");
      
        uint256 streamBalance = balanceOf(streamId);

        // Consolidate sender balance
        uint256 newSupplyFrom;
        if (accruedSince[stream.sender] > 0 && proofOfHumanity.isRegistered(stream.sender)) {
            
            newSupplyFrom = accruedPerSecond.mul(block.timestamp.sub(accruedSince[stream.sender]));

            totalSupply = totalSupply.add(newSupplyFrom);

            ubiBalance[stream.sender] = balanceOf(stream.sender);

            // Update accruedSince
            accruedSince[stream.sender] = block.timestamp;
        }        

        // Consolidate stream balance.
        ubiBalance[stream.recipient] = ubiBalance[stream.recipient].add(streamBalance);
        streams[streamId].accruedSince = Math.min(block.timestamp, stream.stopTime);
        // DELETE STREAM IF REQUIRED
        // If withdrawing all available balance and stream is completed, remove it from the list of streams
        if(block.timestamp >= stream.stopTime) {
          deleteStream(streamId);
        }

        //transfer(stream.recipient, amount);
        emit WithdrawFromStream(streamId, stream.recipient, streamBalance);
    }

    /// @dev Deletes the given stream from related variables
    function deleteStream(uint256 streamId) internal streamExists(streamId) {

      Types.Stream memory stream = streams[streamId];

      // DELETE FROM streamIdsOf
      // Get the index of the last item
      uint256 indexOfLastItem = streamIdsOf[stream.sender].length - 1;

      for(uint256 i = 0; i < streamIdsOf[stream.sender].length; i++) {
        // If stream is found
        if(streamIdsOf[stream.sender][i] == streamId) {
          // If it's not the last element on the array
          if(i < indexOfLastItem) {
            // Replace the found stream with the last element on the array
            streamIdsOf[stream.sender][i] = streamIdsOf[stream.sender][indexOfLastItem];
          }
          // Delete the last element on the list
          streamIdsOf[stream.sender].pop();
          break;
        }
      }

      // DELETE FROM streamIds
      indexOfLastItem = streamIdsOfSenderAndRecipient[stream.sender][stream.recipient].length - 1;

      // For each stream with the recipient
      for(uint256 i = 0;i < streamIdsOfSenderAndRecipient[stream.sender][stream.recipient].length; i++) {
          // If stream is found
        if(streamIdsOfSenderAndRecipient[stream.sender][stream.recipient][i] == streamId) {
          // If it's not the last element on the array
          if(i < indexOfLastItem) {
            // Replace the found stream with the last element on the array
            streamIdsOfSenderAndRecipient[stream.sender][stream.recipient][i] = streamIdsOfSenderAndRecipient[stream.sender][stream.recipient][indexOfLastItem];
          }
          // Delete the last element on the list
          streamIdsOfSenderAndRecipient[stream.sender][stream.recipient].pop();
          break;
        }
      }

      // Delete the stream
      delete streams[streamId];
    }

    /**
     * @notice Cancels the stream and transfers the tokens back on a pro rata basis.
     * @dev Throws if the id does not point to a valid stream.
     *  Throws if the caller is not the sender or the recipient of the stream.
     *  Throws if there is a token transfer failure.
     * @param streamId The id of the stream to cancel.
     */
    function cancelStream(uint256 streamId)
        external
        override
        nonReentrant
        streamExists(streamId)
        onlySenderOrRecipient(streamId)
    {
      Types.Stream memory stream = streams[streamId];
      // Withdraw funds from the stream and delete it
      _withdrawFromStream(streamId);
      if(streams[streamId].isEntity) {
        // Delete the stream
        deleteStream(streamId);
      }

      emit CancelStream(streamId, stream.sender, stream.recipient);
    }

    function getStreamsCount(address _human) public view returns (uint256) {
      require(proofOfHumanity.isRegistered(_human), "The submission is not registered in Proof Of Humanity.");
      return streamIdsOf[_human].length;
    }

    function getStreamsOf(address _human) public view returns (uint256[] memory) {
      return streamIdsOf[_human];
    }

    /**
     * @dev find out if 2 date ranges overlap
     */
    function overlapsWith(uint256 _startA, uint256 _endA, uint256 _startB, uint256 _endB) public pure returns (bool) {
      return (_startA <= _endB && _endA >= _startB);
    }

    /**
     * @dev gets the delegated accrued value.
     * This sums the accrued value of all active streams from the human's `accruedSince` to `block.timestamp`
     */
    function getDelegatedAccruedValue(address _human) public view returns (uint256) {
      uint256 delegatedAccruedValue;
      // Iterate on each stream id of the human and calculate the currently delegated accrued value
      for(uint256 i = 0; i < streamIdsOf[_human].length; i++) {
        uint256 streamId = streamIdsOf[_human][i];

        Types.Stream memory stream = streams[streamId];
        if(!stream.isEntity) continue; // Stream Exists
        if(!proofOfHumanity.isRegistered(stream.sender)) continue; // Sender is a registered human

        // If stream has not started, or it has been accrued all.
        if(block.timestamp < stream.startTime) continue;

        // Time delegated to the stream
        uint256 streamAccumulatedTime = deltaOf(streamId);

        // Stream's total accrued value is the accumulated time * stream's ratePerSecond
        // Add the stream accrued value to the pending delegated balance
        delegatedAccruedValue += streamAccumulatedTime.mul(stream.ratePerSecond);
      }
      return delegatedAccruedValue;
    }

    /**
     * @dev Set the max number of stream allowed per human.
     */
    function setMaxStreamsAllowed(uint256 newValue) external onlyByGovernor {
      maxStreamsAllowed = newValue;
    }
}
