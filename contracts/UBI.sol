// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20BurnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20SnapshotUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/Initializable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./Humanity.sol";


contract UBI is ForHumans, Initializable, ERC20BurnableUpgradeable, ERC20SnapshotUpgradeable {

  using SafeMath for uint256;

  /* Events */

  /** @dev Emitted when UBI is minted or taken by a reporter.
    *  @param _recipient The accruer of the UBI.
    *  @param _beneficiary The withdrawer or taker.
    *  @param _value The value withdrawn.
    */
  event Mint(
      address indexed _recipient,
      address indexed _beneficiary,
      uint256 _value
  );

  /* Storage */

  /// @dev How many tokens per second will be minted for every valid human.
  uint256 public accruedPerSecond;

  /// @dev The contract's governor.
  address public governor;

  /// @dev Store the time when this human started accruing.
  mapping(address => uint256) public accruedSince;

  /// @dev Tokens withdrawn
  mapping(address => uint256) public withdrawn;

  /* Modifiers */

  /// @dev Verifies that the sender has ability to modify governed parameters.
  modifier onlyByGovernor() {
    require(governor == msg.sender, "The caller is not the governor.");
    _;
  }

  /** @dev is already accruing token subsidy
  *  @param _human for the address of the human.
  *  @param _accruing if it's actively accruing value.
  */
  modifier isAccruing(address _human, bool _accruing) {
    bool accruing = accruedSince[_human] != 0;
    require(
      accruing == _accruing,
      accruing
        ? "The submission is already accruing UBI."
        : "The submission is not accruing UBI."
    );
    _;
  }

  /* Initalizer */

  /** @dev Constructor.
  *  @param _initialSupply for the UBI coin including all decimals.
  *  @param _name for UBI coin.
  *  @param _symbol for UBI coin ticker.
  *  @param _accruedPerSecond How much of the token is accrued per block.
  *  @param _proofOfHumanity The Proof Of Humanity registry to reference.
  */
  function initialize(uint256 _initialSupply, string memory _name, string memory _symbol, uint256 _accruedPerSecond, IProofOfHumanity _proofOfHumanity) public initializer {
    __Context_init_unchained();
    __ERC20_init_unchained(_name, _symbol);

    accruedPerSecond = _accruedPerSecond;
    proofOfHumanity = _proofOfHumanity;
    governor = msg.sender;

    _mint(msg.sender, _initialSupply);
  }

  /* External */

  /** @dev Starts accruing UBI for a registered submission.
  *  @param _human The submission ID.
  */
  function startAccruing(address _human) external isRegistered(_human, true) isAccruing(_human, false) {
    accruedSince[_human] = block.timestamp;
  }

  /** @dev Allows anyone to report a submission that
  *  should no longer receive UBI due to removal from the
  *  Proof Of Humanity registry. The reporter receives any
  *  leftover accrued UBI.
  *  @param _human The submission ID.
  */
  function reportRemoval(address _human) external isRegistered(_human, false) isAccruing(_human, true) {
    uint256 newSupply = getAccruedValue(_human);

    accruedSince[_human] = 0;
    withdrawn[_human] = 0;

    _mint(msg.sender, newSupply);

    emit Mint(_human, msg.sender, newSupply);
  }

  /** @dev Changes `accruedPerSecond` to `_accruedPerSecond`.
  *  @param _accruedPerSecond How much of the token is accrued per block.
  */
  function changeAccruedPerSecond(uint256 _accruedPerSecond) external onlyByGovernor {
    accruedPerSecond = _accruedPerSecond;
  }

  /** @dev Changes `proofOfHumanity` to `_proofOfHumanity`.
  *  @param _proofOfHumanity Registry that meets interface of Proof of Humanity
  */
  function changeProofOfHumanity(IProofOfHumanity _proofOfHumanity) external onlyByGovernor {
    proofOfHumanity = _proofOfHumanity;
  }

  /** @dev External function for Snapshot event emitter only accessible by governor.  */
  function snapshot() external onlyByGovernor returns(uint256) {
    return _snapshot();
  }

  /* Getters */

  /** @dev Calculates how much UBI a submission has available for withdrawal.
  *  @param _human The submission ID.
  *  @return accrued The available UBI for withdrawal.
  */
  function getAccruedValue(address _human) public view returns (uint256 accrued) {
    uint256 totalAccrued = accruedPerSecond.mul(block.timestamp.sub(accruedSince[_human]));

    // If this human does not have started to accrue, or current available balance to withdraw is negative, return 0.
    if (accruedSince[_human] == 0 || withdrawn[_human] >= totalAccrued) return 0;

    else return totalAccrued.sub(withdrawn[_human]);
  }

  /** Overrides */

  /**
  * @dev calculates the current user accrued balance
  *  @param _human The submission ID.
  * @return the accumulated debt of the user
  **/
  function balanceOf(address _human) public view virtual override returns (uint256) {
    uint256 accountBalance = super.balanceOf(_human);
    uint256 accrued = getAccruedValue(_human);

    return accountBalance.add(accrued);
  }

  /** @dev Overrides with Snapshot mechanisms _beforeTokenTransfer functions.  */
  function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override(ERC20Upgradeable, ERC20SnapshotUpgradeable) {
    _mintAccrued(from);
    _mintAccrued(to);
    ERC20SnapshotUpgradeable._beforeTokenTransfer(from, to, amount);
  }

  /** Internal */

  /** @dev Universal Basic Income mechanism
  *  @param _human The submission ID.
  */
  function _mintAccrued(address _human) internal virtual {
    uint256 newSupply = getAccruedValue(_human);

    if (newSupply > 0) {
      withdrawn[_human] += newSupply;
      _mint(_human, newSupply);
      emit Mint(_human, _human, newSupply);
    }
  }
}
