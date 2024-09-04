// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCall } from "@eth-optimism/contracts-bedrock/src/libraries/SafeCall.sol";
import { IOptimismMintableERC20, ILegacyMintableERC20 } from "@eth-optimism/contracts-bedrock/src/universal/IOptimismMintableERC20.sol";
import { CrossDomainMessenger } from "@eth-optimism/contracts-bedrock/src/universal/CrossDomainMessenger.sol";
import { OptimismMintableERC20 } from "@eth-optimism/contracts-bedrock/src/universal/OptimismMintableERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { EIP712Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";

/// @custom:upgradeable
/// @title AviBridge
/// @notice AviBridge is a base contract for the L1 and L2 standard ERC20 bridges. It handles
///         the core bridging logic, including escrowing tokens that are native to the local chain
///         and minting/burning tokens that are native to the remote chain.
abstract contract AviBridge is AccessControl, EIP712Upgradeable {
    using SafeERC20 for IERC20;

    /// @notice Number of admins on the contract.
    uint256 private _numAdmins;

    /// @notice The L2 gas limit set when eth is depoisited using the receive() function.
    uint32 internal constant RECEIVE_DEFAULT_GAS_LIMIT = 200_000;

    /// @notice Messenger contract on this domain.
    CrossDomainMessenger public MESSENGER;

    /// @notice Corresponding bridge on the other domain.
    AviBridge public OTHER_BRIDGE;

    /// @notice The EIP712 transaction signer
    address public backendUser;

    /// @notice access control role pauser constant.
    bytes32 public constant PAUSER_ROLE = keccak256("aviator.pauser_role");

    /// @notice Mapping that stores deposits for a given pair of local and remote tokens.
    mapping(address => mapping(address => uint256)) public deposits;

    /// @notice The address of the receiver of the flat fee. On L1 it's the address on the same chain, while on L2 it's the L1 address
    address public flatFeeRecipient;

    /// @notice The flat bridging fee for all deposits. Measured in ETH.
    uint256 public flatFee;

    /// @notice Emitted when an ETH bridge is initiated to the other chain.
    /// @param from      Address of the sender.
    /// @param to        Address of the receiver.
    /// @param amount    Amount of ETH sent.
    /// @param extraData Extra data sent with the transaction.
    event ETHBridgeInitiated(address indexed from, address indexed to, uint256 amount, bytes extraData);

    /// @notice Emitted when an ETH bridge is finalized on this chain.
    /// @param from      Address of the sender.
    /// @param to        Address of the receiver.
    /// @param amount    Amount of ETH sent.
    /// @param extraData Extra data sent with the transaction.
    event ETHBridgeFinalized(address indexed from, address indexed to, uint256 amount, bytes extraData);

    /// @notice Emitted when an ERC20 bridge is initiated to the other chain.
    /// @param localToken  Address of the ERC20 on this chain.
    /// @param remoteToken Address of the ERC20 on the remote chain.
    /// @param from        Address of the sender.
    /// @param to          Address of the receiver.
    /// @param amount      Amount of the ERC20 sent.
    /// @param extraData   Extra data sent with the transaction.
    event ERC20BridgeInitiated(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );

    /// @notice Emitted when an ERC20 bridge is finalized on this chain.
    /// @param localToken  Address of the ERC20 on this chain.
    /// @param remoteToken Address of the ERC20 on the remote chain.
    /// @param from        Address of the sender.
    /// @param to          Address of the receiver.
    /// @param amount      Amount of the ERC20 sent.
    /// @param extraData   Extra data sent with the transaction.
    event ERC20BridgeFinalized(
        address indexed localToken,
        address indexed remoteToken,
        address indexed from,
        address to,
        uint256 amount,
        bytes extraData
    );

    /// @notice Emitted when the backend address is changed.
    /// @param oldBackend  Address of previous backend.
    /// @param newBackend  Address of new backend.
    /// @param executedBy  Address of caller.
    event BackendChanged(
        address indexed oldBackend,
        address indexed newBackend,
        address indexed executedBy
    );

    /// @notice Emitted when the Flat Fee Recipient address is changed.
    /// @param previousFlatFeeRecipient     Address of previsous Flat Fee Recipient.
    /// @param flatFeeRecipient             Address of new Flat Fee Recipient.
    /// @param executedBy                   Address of caller.
    event FlatFeeRecipientChanged(
        address previousFlatFeeRecipient,
        address flatFeeRecipient,
        address executedBy
    );

    /// @notice Emitted when the Flat Fee is changed.
    /// @param previousFlatFee  uint256 of the previous value.
    /// @param flatFee          uint256 of the new value.
    /// @param executedBy       Address of caller.
    event FlatFeeChanged(
        uint256 previousFlatFee,
        uint256 flatFee,
        address executedBy
    );

    /// @notice Only allow EOAs to call the functions. Note that this is not safe against contracts
    ///         calling code within their constructors, but also doesn't really matter since we're
    ///         just trying to prevent users accidentally depositing with smart contract wallets.
    modifier onlyEOA() {
        require(!Address.isContract(msg.sender), "AviBridge: function can only be called from an EOA");
        _;
    }

    /// @notice Ensures that the caller is a cross-chain message from the other bridge.
    modifier onlyOtherBridge() {
        require(
            msg.sender == address(MESSENGER) && MESSENGER.xDomainMessageSender() == address(OTHER_BRIDGE),
            "AviBridge: function can only be called from the other bridge"
        );
        _;
    }

    modifier onlyPauserOrAdmin() {
        require(
            hasRole(DEFAULT_ADMIN_ROLE, msg.sender) || hasRole(PAUSER_ROLE, msg.sender),
                "AviBridge: function can only be called by pauser or admin role"
        );
        _;
    }

    /// @param _messenger   Address of CrossDomainMessenger on this network.
    /// @param _otherBridge Address of the other AviBridge contract.
    function __SkyBridge_init(address payable _messenger, address payable _otherBridge) public onlyInitializing {
        MESSENGER = CrossDomainMessenger(_messenger);
        OTHER_BRIDGE = AviBridge(_otherBridge);

        __EIP712_init("SkyBridge", "1");
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender); // make the deployer admin
        _numAdmins = 1;
        flatFee = 0.001 ether;
    }

    /// @notice Updates the flat fee recipient for all deposits.
    /// @param _recipient New flat fee recipient address
    function setFlatFeeRecipient(address _recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_recipient != address(0), "AviBridge: _recipient address cannot be zero");

        address previousFlatFeeRecipient = flatFeeRecipient;

        flatFeeRecipient = _recipient;

        emit FlatFeeRecipientChanged(previousFlatFeeRecipient, flatFeeRecipient, msg.sender);
    }

    /// @notice Updates the flat fee for all deposits.
    /// @param _fee New flat fee.
    function setFlatFee(uint256 _fee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_fee <= 0.005 ether, "AviBridge: _fee must be less than or equal to 0.005 ether");

        uint256 previousFee = flatFee;
        flatFee = _fee;

        emit FlatFeeChanged(previousFee, flatFee, msg.sender);
    }

    /// @notice Add a new admin address to the list of admins.
    /// @param _admin New admin address.
    function addAdmin(address _admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!hasRole(DEFAULT_ADMIN_ROLE, _admin), "Admin already added.");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _numAdmins++;
    }

    /// @notice Remove an admin from the list of admins.
    /// @param _admin Address to remove.
    function removeAdmin(address _admin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(DEFAULT_ADMIN_ROLE, _admin), "Address is not a recognized admin.");
        require (_numAdmins > 1, "Cannot remove the only admin.");

        _revokeRole(DEFAULT_ADMIN_ROLE, _admin);
        _numAdmins--;
    }

    /// @notice Add a new pauser address to the list of pausers.
    /// @param _pauser New Pauser address.
    function addPauser(address _pauser) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(!hasRole(PAUSER_ROLE, _pauser), "Pauser already added.");

        _grantRole(PAUSER_ROLE, _pauser);
    }

    /// @notice Remove an pauser from the list of pausers.
    /// @param _pauser Address to remove.
    function removePauser(address _pauser) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(PAUSER_ROLE, _pauser), "Address is not a recognized pauser.");

        _revokeRole(PAUSER_ROLE, _pauser);
    }

    /// @notice set a new backend address.
    /// @param _backend New backend address.
    function setBackend(address _backend) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_backend != address(0), "AviBridge: address cannot be zero.");
        require(_backend != backendUser, "AviBridge: that address is already the backend user.");

        address _previousBackend = backendUser;

        backendUser = _backend;

        emit BackendChanged(_previousBackend, _backend, msg.sender);
    }

    /// @notice Allows EOAs to bridge ETH by sending directly to the bridge.
    ///         Must be implemented by contracts that inherit.
    receive() external payable virtual;

    /// @notice This function should return true if the contract is paused.
    ///         On L1 this function will check the SuperchainConfig for its paused status.
    ///         On L2 this function should be a no-op.
    /// @return Whether or not the contract is paused.
    function paused() public view virtual returns (bool);

    /// @notice Finalizes an ETH bridge on this chain. Can only be triggered by the other
    ///         AviBridge contract on the remote chain.
    /// @param _from      Address of the sender.
    /// @param _to        Address of the receiver.
    /// @param _amount    Amount of ETH being bridged.
    /// @param _extraData Extra data to be sent with the transaction. Note that the recipient will
    ///                   not be triggered with this data, but it will be emitted and can be used
    ///                   to identify the transaction.
    function finalizeBridgeETH(
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _extraData
    )
        public
        payable
        onlyOtherBridge
    {
        require(paused() == false, "AviBridge: paused");
        require(msg.value == _amount, "AviBridge: amount sent does not match amount required");
        require(_to != address(this), "AviBridge: cannot send to self");
        require(_to != address(MESSENGER), "AviBridge: cannot send to messenger");
        require(_to != address(0), "AviBridge: cannot send to zero address");

        // Emit the correct events. By default this will be _amount, but child
        // contracts may override this function in order to emit legacy events as well.
        _emitETHBridgeFinalized(_from, _to, _amount, _extraData);

        bool success = SafeCall.call(_to, gasleft(), _amount, hex"");
        require(success, "AviBridge: ETH transfer failed");
    }

    /// @notice Finalizes an ERC20 bridge on this chain. Can only be triggered by the other
    ///         AviBridge contract on the remote chain.
    /// @param _localToken  Address of the ERC20 on this chain.
    /// @param _remoteToken Address of the corresponding token on the remote chain.
    /// @param _from        Address of the sender.
    /// @param _to          Address of the receiver.
    /// @param _amount      Amount of the ERC20 being bridged.
    /// @param _extraData   Extra data to be sent with the transaction. Note that the recipient will
    ///                     not be triggered with this data, but it will be emitted and can be used
    ///                     to identify the transaction.
    function finalizeBridgeERC20(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes calldata _extraData
    )
        public
        onlyOtherBridge
    {
        require(paused() == false, "AviBridge: paused");
        require(_to != address(0), "AviBridge: cannot transfer to the zero address");

        if (_isOptimismMintableERC20(_localToken)) {
            require(
                _isCorrectTokenPair(_localToken, _remoteToken),
                "AviBridge: wrong remote token for Optimism Mintable ERC20 local token"
            );

            OptimismMintableERC20(_localToken).mint(_to, _amount);
        } else {
            require(deposits[_localToken][_remoteToken] >= _amount, "AviBridge: insufficient balance deposited");

            deposits[_localToken][_remoteToken] = deposits[_localToken][_remoteToken] - _amount;
            IERC20(_localToken).safeTransfer(_to, _amount);
        }

        // Emit the correct events. By default this will be ERC20BridgeFinalized, but child
        // contracts may override this function in order to emit legacy events as well.
        _emitERC20BridgeFinalized(_localToken, _remoteToken, _from, _to, _amount, _extraData);
    }

    /// @notice Initiates a bridge of ETH through the CrossDomainMessenger.
    /// @param _from        Address of the sender.
    /// @param _to          Address of the receiver.
    /// @param _amount      Amount of ETH being bridged.
    /// @param _minGasLimit Minimum amount of gas that the bridge can be relayed with.
    /// @param _extraData   Extra data to be sent with the transaction. Note that the recipient will
    ///                     not be triggered with this data, but it will be emitted and can be used
    ///                     to identify the transaction.
    function _initiateBridgeETH(
        address _from,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes memory _extraData
    )
        internal
    {
        // Emit the correct events. By default this will be _amount, but child
        // contracts may override this function in order to emit legacy events as well.
        _emitETHBridgeInitiated(_from, _to, _amount, _extraData);

        MESSENGER.sendMessage{ value: _amount }(
            address(OTHER_BRIDGE),
            abi.encodeWithSelector(this.finalizeBridgeETH.selector, _from, _to, _amount, _extraData),
            _minGasLimit
        );
    }

    /// @notice Sends ERC20 tokens to a receiver's address on the other chain.
    /// @param _localToken  Address of the ERC20 on this chain.
    /// @param _remoteToken Address of the corresponding token on the remote chain.
    /// @param _to          Address of the receiver.
    /// @param _amount      Amount of local tokens to deposit.
    /// @param _minGasLimit Minimum amount of gas that the bridge can be relayed with.
    /// @param _extraData   Extra data to be sent with the transaction. Note that the recipient will
    ///                     not be triggered with this data, but it will be emitted and can be used
    ///                     to identify the transaction.
    function _initiateBridgeERC20(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _amount,
        uint32 _minGasLimit,
        bytes memory _extraData
    )
    internal
    {
        uint256 balanceBefore;
        uint256 balanceAfter;
        uint256 actualAmount;

        if (_isOptimismMintableERC20(_localToken)) {
            require(
                _isCorrectTokenPair(_localToken, _remoteToken),
                "AviBridge: wrong remote token for Optimism Mintable ERC20 local token"
            );

            OptimismMintableERC20(_localToken).burn(_from, _amount);

            actualAmount = _amount;
        } else {
            balanceBefore = IERC20(_localToken).balanceOf(address(this));

            IERC20(_localToken).safeTransferFrom(_from, address(this), _amount);

            balanceAfter = IERC20(_localToken).balanceOf(address(this));

            actualAmount = balanceAfter - balanceBefore;

            deposits[_localToken][_remoteToken] += actualAmount;
        }

        // Emit the correct events. By default this will be ERC20BridgeInitiated, but child
        // contracts may override this function in order to emit legacy events as well.
        _emitERC20BridgeInitiated(_localToken, _remoteToken, _from, _to, actualAmount, _extraData);

        MESSENGER.sendMessage(
            address(OTHER_BRIDGE),
            abi.encodeWithSelector(
                this.finalizeBridgeERC20.selector,
                // Because this call will be executed on the remote chain, we reverse the order of
                // the remote and local token addresses relative to their order in the
                // finalizeBridgeERC20 function.
                _remoteToken,
                _localToken,
                _from,
                _to,
                actualAmount,
                _extraData
            ),
            _minGasLimit
        );
    }

    /// @notice Checks if a given address is an OptimismMintableERC20. Not perfect, but good enough.
    ///         Just the way we like it.
    /// @param _token Address of the token to check.
    /// @return True if the token is an OptimismMintableERC20.
    function _isOptimismMintableERC20(address _token) internal view returns (bool) {
        return ERC165Checker.supportsInterface(_token, type(ILegacyMintableERC20).interfaceId)
            || ERC165Checker.supportsInterface(_token, type(IOptimismMintableERC20).interfaceId);
    }

    /// @notice Checks if the "other token" is the correct pair token for the OptimismMintableERC20.
    ///         Calls can be saved in the future by combining this logic with
    ///         `_isOptimismMintableERC20`.
    /// @param _mintableToken OptimismMintableERC20 to check against.
    /// @param _otherToken    Pair token to check.
    /// @return True if the other token is the correct pair token for the OptimismMintableERC20.
    function _isCorrectTokenPair(address _mintableToken, address _otherToken) internal view returns (bool) {
        if (ERC165Checker.supportsInterface(_mintableToken, type(ILegacyMintableERC20).interfaceId)) {
            return _otherToken == ILegacyMintableERC20(_mintableToken).l1Token();
        } else {
            return _otherToken == IOptimismMintableERC20(_mintableToken).remoteToken();
        }
    }

    /// @notice Emits the ETHBridgeInitiated event and if necessary the appropriate legacy event
    ///         when an ETH bridge is finalized on this chain.
    /// @param _from      Address of the sender.
    /// @param _to        Address of the receiver.
    /// @param _amount    Amount of ETH sent.
    /// @param _extraData Extra data sent with the transaction.
    function _emitETHBridgeInitiated(
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _extraData
    )
        internal
        virtual
    {
        emit ETHBridgeInitiated(_from, _to, _amount, _extraData);
    }

    /// @notice Emits the ETHBridgeFinalized and if necessary the appropriate legacy event when an
    ///         ETH bridge is finalized on this chain.
    /// @param _from      Address of the sender.
    /// @param _to        Address of the receiver.
    /// @param _amount    Amount of ETH sent.
    /// @param _extraData Extra data sent with the transaction.
    function _emitETHBridgeFinalized(
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _extraData
    )
        internal
        virtual
    {
        emit ETHBridgeFinalized(_from, _to, _amount, _extraData);
    }

    /// @notice Emits the ERC20BridgeInitiated event and if necessary the appropriate legacy
    ///         event when an ERC20 bridge is initiated to the other chain.
    /// @param _localToken  Address of the ERC20 on this chain.
    /// @param _remoteToken Address of the ERC20 on the remote chain.
    /// @param _from        Address of the sender.
    /// @param _to          Address of the receiver.
    /// @param _amount      Amount of the ERC20 sent.
    /// @param _extraData   Extra data sent with the transaction.
    function _emitERC20BridgeInitiated(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _extraData
    )
        internal
        virtual
    {
        emit ERC20BridgeInitiated(_localToken, _remoteToken, _from, _to, _amount, _extraData);
    }

    /// @notice Emits the ERC20BridgeFinalized event and if necessary the appropriate legacy
    ///         event when an ERC20 bridge is initiated to the other chain.
    /// @param _localToken  Address of the ERC20 on this chain.
    /// @param _remoteToken Address of the ERC20 on the remote chain.
    /// @param _from        Address of the sender.
    /// @param _to          Address of the receiver.
    /// @param _amount      Amount of the ERC20 sent.
    /// @param _extraData   Extra data sent with the transaction.
    function _emitERC20BridgeFinalized(
        address _localToken,
        address _remoteToken,
        address _from,
        address _to,
        uint256 _amount,
        bytes memory _extraData
    )
        internal
        virtual
    {
        emit ERC20BridgeFinalized(_localToken, _remoteToken, _from, _to, _amount, _extraData);
    }

    /// @notice Override renounceRole to disable it.
    function renounceRole(bytes32, address) public pure override {
        revert("AviBridge: renounceRole is disabled, use removeAdmin to remove yourself as an admin");
    }

    /// @notice Override revokeRole to disable it.
    function revokeRole(bytes32 role, address) public virtual override onlyRole(getRoleAdmin(role)) {
        revert("AviBridge: revokeRole is disabled, use removeAdmin to remove yourself as an admin");
    }
}
