// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import "./PauseControl.sol";

contract SubscriptionManager is ReentrancyGuardUpgradeable, PauseControl, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");

    // ========= Parameters =========
    address public constant NATIVE_TOKEN = address(0);

    uint64 public subscriptionDuration;
    uint64 public renewWindow;

    // Accepted token => fixed price (in that token's smallest units)
    mapping(address => uint256) public tokenPrice;

    address public treasury;

    // ========= Subscription Certificate =========
    struct Subscription {
        uint64 expiresAt; // unix seconds
        address paymentToken; // address(0) for native
        bool autoRenew; // user opted-in for pull renewals
    }

    struct SubscriptionMap {
        EnumerableSet.AddressSet _keys;
        mapping(address => Subscription) _values;
    }
    SubscriptionMap private _subs;

    // ========= Events =========
    event TokenUpdated(address indexed token, uint256 price);
    event TreasuryUpdated(address indexed treasury);
    event Subscribed(address indexed user, address indexed token, uint256 price, uint256 newExpiry);
    event Renewed(address indexed user, address indexed token, uint256 price, uint256 newExpiry);
    event AutoRenewSet(address indexed user, bool enabled);
    event SubscriptionDurationUpdated(uint256 newDuration);
    event RenewWindowUpdated(uint256 newWindow);
    event BatchRenewalFailed(address indexed user, address indexed token);

    // ========= Errors =========
    error TokenNotAccepted();
    error WrongValueSent();
    error ZeroAddressTreasury();

    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        _;
    }

    constructor() {
        _disableInitializers();
    }

    function initialize(address _treasury) public initializer {
        __ReentrancyGuard_init();
        __AccessControlEnumerable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(SERVICE_ROLE, msg.sender);
        _setRoleAdmin(ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(PAUSER_ROLE, ADMIN_ROLE);
        _setRoleAdmin(SERVICE_ROLE, ADMIN_ROLE);

        subscriptionDuration = 30 days;
        renewWindow = 3 days;

        _setTreasury(_treasury);
    }

    // ===== Upgrade Auth =====
    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    // ========= Owner admin =========

    function setToken(address token, uint256 price) external onlyAdmin {
        tokenPrice[token] = price;
        emit TokenUpdated(token, price);
    }

    function setTokens(address[] calldata tokens, uint256[] calldata prices) external onlyAdmin {
        require(tokens.length == prices.length, "LENGTH_MISMATCH");

        for (uint256 i = 0; i < tokens.length; ) {
            tokenPrice[tokens[i]] = prices[i];
            emit TokenUpdated(tokens[i], prices[i]);
            unchecked {
                ++i;
            }
        }
    }

    function setTreasury(address _treasury) external onlyAdmin {
        _setTreasury(_treasury);
    }

    function setSubscriptionDuration(uint64 newDuration) external onlyAdmin {
        require(newDuration > 0, "Duration must be greater than 0");
        require(newDuration <= 365 days, "Duration too long");
        subscriptionDuration = newDuration;
        emit SubscriptionDurationUpdated(newDuration);
    }

    function setRenewWindow(uint64 newWindow) external onlyAdmin {
        require(newWindow > 0, "Renew must be greater than 0");
        require(newWindow < subscriptionDuration, "RenewWindow too long");
        renewWindow = newWindow;
        emit RenewWindowUpdated(newWindow);
    }

    function removeToken(address token) external onlyAdmin {
        tokenPrice[token] = 0;
        emit TokenUpdated(token, 0);
    }

    // ========= Public views  =========

    function getSubscription(
        address user
    ) external view returns (bool active, uint256 expiresAt, address paymentToken, bool autoRenew) {
        Subscription memory s = _subs._values[user];
        active = block.timestamp < s.expiresAt;
        expiresAt = s.expiresAt;
        paymentToken = s.paymentToken;
        autoRenew = s.autoRenew;
    }

    function isActive(address user) public view returns (bool) {
        return block.timestamp < _subs._values[user].expiresAt;
    }

    // ========= User actions =========

    // --- Pay with ERC20 using allowance already set ---
    function subscribe(address token) external nonReentrant whenNotPaused {
        _subscribe(msg.sender, token);
    }

    // --- Pay with ERC20 in one tx using EIP-2612 permit (if token supports it) ---
    function subscribeWithPermit(
        address token,
        uint256 deadline,
        uint256 amount,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        require(token != NATIVE_TOKEN, "NATIVE_TOKEN");
        _permit(token, msg.sender, amount, deadline, v, r, s);
        _subscribe(msg.sender, token);
    }

    // --- Pay with native (ETH, etc.) ---
    function subscribeNative() external payable nonReentrant whenNotPaused {
        _subscribe(msg.sender, NATIVE_TOKEN);
    }

    // --- Renew with ERC20 (pull, requires allowance or prior permit call) ---
    function renew(address token) external nonReentrant whenNotPaused {
        _renew(msg.sender, token);
    }

    function renewWithPermit(
        address token,
        uint256 deadline,
        uint256 amount,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        require(token != NATIVE_TOKEN, "NATIVE_TOKEN");
        _permit(token, msg.sender, amount, deadline, v, r, s);
        _renew(msg.sender, token);
    }

    function renewNative() external payable nonReentrant whenNotPaused {
        _renew(msg.sender, NATIVE_TOKEN);
    }

    // --- Manage auto-renew preference ---
    function setAutoRenew(bool enabled) external whenNotPaused {
        _subs._values[msg.sender].autoRenew = enabled;
        emit AutoRenewSet(msg.sender, enabled);
    }

    // --- Cancel (just disables autoRenew; subscription remains until expiry) ---
    function cancelAutoRenew() external whenNotPaused {
        _subs._values[msg.sender].autoRenew = false;
        emit AutoRenewSet(msg.sender, false);
    }

    // ========= Keeper/bot helpers (anyone can call) =========

    // Pull-renew a single user IF they opted-in and allowance is sufficient.
    function renewFor(address user) external nonReentrant onlyRole(SERVICE_ROLE) {
        Subscription memory s = _subs._values[user];
        require(s.autoRenew, "AUTORENEW_OFF");
        require(_isWithinRenewWindow(s.expiresAt), "CANNOT_RENEW");

        if (s.paymentToken == NATIVE_TOKEN) {
            // Native auto-renew cannot be pulled (no allowance concept).
            revert TokenNotAccepted();
        }

        _renew(user, s.paymentToken);
    }

    function renewBatchWithUsers(address[] calldata users) external nonReentrant onlyRole(SERVICE_ROLE) {
        _renewBatch(users);
    }

    function renewBatch() external nonReentrant onlyRole(SERVICE_ROLE) {
        address[] memory users = _subs._keys.values();
        _renewBatch(users);
    }

    // ========= Internals =========

    function _setTreasury(address _treasury) internal {
        if (_treasury == address(0)) revert ZeroAddressTreasury();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function _subscribe(address user, address token) internal {
        _processPayment(user, token);
        emit Subscribed(user, token, tokenPrice[token], _subs._values[user].expiresAt);
    }

    function _renew(address user, address token) internal {
        _processPayment(user, token);
        emit Renewed(user, token, tokenPrice[token], _subs._values[user].expiresAt);
    }

    function _processPayment(address user, address token) internal {
        uint256 price = tokenPrice[token];
        if (price == 0) revert TokenNotAccepted();

        if (token == NATIVE_TOKEN) {
            if (msg.value != price) revert WrongValueSent();

            (bool ok, ) = payable(treasury).call{ value: msg.value }("");
            require(ok, "TREASURY_PAYMENT_FAIL");
        } else {
            require(msg.value == 0, "ZERO_VALUE");
            IERC20(token).safeTransferFrom(user, treasury, price);
        }

        uint64 newExpiry = _newExpiry(_subs._values[user].expiresAt);
        _subs._values[user].expiresAt = newExpiry;
        _subs._values[user].paymentToken = token;
        _subs._keys.add(user);
    }

    function _permit(
        address token,
        address user,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {
        // Best-effort call; if token doesn't support EIP-2612 this will revert.
        IERC20Permit(token).permit(user, address(this), value, deadline, v, r, s);
    }

    function _newExpiry(uint64 current) internal view returns (uint64) {
        uint64 nowTs = uint64(block.timestamp);
        if (nowTs >= current) {
            return nowTs + uint64(subscriptionDuration);
        } else {
            return current + uint64(subscriptionDuration);
        }
    }

    function _renewBatch(address[] memory users) internal {
        bool atLeastOneSuccess = false;
        for (uint256 i = 0; i < users.length; ) {
            address u = users[i];
            Subscription memory s = _subs._values[u];
            if (!s.autoRenew) {
                unchecked {
                    ++i;
                }
                continue;
            }
            if (!_isWithinRenewWindow(s.expiresAt)) {
                unchecked {
                    ++i;
                }

                if (uint64(block.timestamp) > s.expiresAt) {
                    _remove(u);
                }

                continue;
            }
            if (s.paymentToken == NATIVE_TOKEN) {
                unchecked {
                    ++i;
                }
                continue;
            }

            bool success = _tryRenew(u, s.paymentToken);
            if (!success) {
                emit BatchRenewalFailed(u, s.paymentToken);
            } else {
                atLeastOneSuccess = true;
            }
            unchecked {
                ++i;
            }
        }

        require(atLeastOneSuccess, "success renew");
    }

    function _remove(address user) internal returns (bool) {
        delete _subs._values[user];
        return _subs._keys.remove(user);
    }

    function _isWithinRenewWindow(uint64 expiresAt) internal view returns (bool) {
        return uint64(block.timestamp) + renewWindow >= expiresAt && expiresAt >= uint64(block.timestamp);
    }

    function _tryRenew(address user, address token) internal returns (bool) {
        // check allowance+balance before attempting
        if (!allowanceAndBalanceSufficient(token, user, tokenPrice[token])) {
            return false;
        }

        // attempt transfer+extend
        try this.renewForExternal(user, token) {
            return true;
        } catch {
            return false;
        }
    }

    function allowanceAndBalanceSufficient(address token, address user, uint256 amount) internal view returns (bool) {
        if (IERC20(token).allowance(user, address(this)) < amount) return false;
        if (IERC20(token).balanceOf(user) < amount) return false;
        return true;
    }

    function renewForExternal(address user, address token) external {
        require(msg.sender == address(this), "ONLY_SELF");
        _renew(user, token);
    }

    // Fallback rejects accidental native sends (must use subscribeNative/renewNative)
    receive() external payable {
        revert WrongValueSent();
    }

    fallback() external payable {
        revert WrongValueSent();
    }
}
