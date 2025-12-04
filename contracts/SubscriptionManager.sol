// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./PauseControl.sol";

contract SubscriptionManager is ReentrancyGuardUpgradeable, PauseControl, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant SERVICE_ROLE = keccak256("SERVICE_ROLE");

    enum Tier {
        Plus,
        Pro,
        Enterprise
    }

    // ========= Parameters =========
    address public constant NATIVE_TOKEN = address(0);

    // ========= Subscription Certificate =========
    struct Subscription {
        uint64 expiresAt; // unix seconds
        address paymentToken; // address(0) for native
        bool autoRenew; // user opted-in for pull renewals
        Tier tier;
    }

    struct SubscriptionMap {
        EnumerableSet.AddressSet _keys;
        mapping(address => Subscription) _values;
    }

    struct SubscriptionStorage {
        uint64 subscriptionDuration;
        uint64 renewWindow;
        mapping(address => mapping(Tier => uint256)) tokenPrice;
        address treasury;
        SubscriptionMap _subs;
    }

    // According to ERC-7201 formula: erc7201(id) = keccak256(abi.encode(uint256(keccak256("0g-chat.SubscriptionManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SUBSCRIPTION_STORAGE_LOCATION =
        0x3673f62f81aa9b1c73642fc72b2bde2dfea88f4f23c1819d31e4365ac5f29400;

    // ========= Events =========
    event TokenUpdated(address indexed token, Tier tier, uint256 price);
    event TreasuryUpdated(address indexed treasury);
    event Subscribed(address indexed user, address indexed token, uint256 price, uint256 newExpiry);
    event Renewed(address indexed user, address indexed token, uint256 price, uint256 newExpiry);
    event AutoRenewSet(address indexed user, bool enabled);
    event SubscriptionDurationUpdated(uint256 newDuration);
    event RenewWindowUpdated(uint256 newWindow);
    event BatchRenewalFailed(address indexed user, address indexed token);
    event UpgradeTier(address indexed user, Tier oldTier, Tier newTier);

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

        SubscriptionStorage storage $ = _getSubscriptionStorage();
        $.subscriptionDuration = 30 days;
        $.renewWindow = 3 days;

        _setTreasury(_treasury);
    }

    // ===== Upgrade Auth =====
    function _authorizeUpgrade(address newImplementation) internal override onlyAdmin {}

    // ========= Owner admin =========

    function _getSubscriptionStorage() internal pure returns (SubscriptionStorage storage $) {
        assembly {
            $.slot := SUBSCRIPTION_STORAGE_LOCATION
        }
    }

    function setToken(address token, Tier tier, uint256 price) external onlyAdmin {
        _getSubscriptionStorage().tokenPrice[token][tier] = price;
        emit TokenUpdated(token, tier, price);
    }

    function setTokens(address[] calldata tokens, Tier tier, uint256[] calldata prices) external onlyAdmin {
        require(tokens.length == prices.length, "LENGTH_MISMATCH");
        SubscriptionStorage storage $ = _getSubscriptionStorage();

        for (uint256 i = 0; i < tokens.length; ) {
            $.tokenPrice[tokens[i]][tier] = prices[i];
            emit TokenUpdated(tokens[i], tier, prices[i]);
            unchecked {
                ++i;
            }
        }
    }

    function tokenPrice(address token, Tier tier) public view returns (uint256) {
        return _getSubscriptionStorage().tokenPrice[token][tier];
    }

    function setTreasury(address _treasury) external onlyAdmin {
        _setTreasury(_treasury);
    }

    function treasury() public view returns (address) {
        return _getSubscriptionStorage().treasury;
    }

    function setSubscriptionDuration(uint64 newDuration) external onlyAdmin {
        require(newDuration > 0, "Duration must be greater than 0");
        require(newDuration <= 365 days, "Duration too long");
        _getSubscriptionStorage().subscriptionDuration = newDuration;
        emit SubscriptionDurationUpdated(newDuration);
    }

    function subscriptionDuration() public view returns (uint64) {
        return _getSubscriptionStorage().subscriptionDuration;
    }

    function setRenewWindow(uint64 newWindow) external onlyAdmin {
        require(newWindow > 0, "Renew must be greater than 0");
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        require(newWindow < $.subscriptionDuration, "RenewWindow too long");
        $.renewWindow = newWindow;
        emit RenewWindowUpdated(newWindow);
    }

    function renewWindow() public view returns (uint64) {
        return _getSubscriptionStorage().renewWindow;
    }

    function removeToken(address token) external onlyAdmin {
        SubscriptionStorage storage $ = _getSubscriptionStorage();

        $.tokenPrice[token][Tier.Plus] = 0;
        $.tokenPrice[token][Tier.Pro] = 0;
        $.tokenPrice[token][Tier.Enterprise] = 0;

        emit TokenUpdated(token, Tier.Plus, 0);
        emit TokenUpdated(token, Tier.Pro, 0);
        emit TokenUpdated(token, Tier.Enterprise, 0);
    }

    // ========= Public views  =========

    function getSubscription(
        address user
    ) external view returns (bool active, uint256 expiresAt, address paymentToken, bool autoRenew, Tier tier) {
        Subscription memory s = _getSubscriptionStorage()._subs._values[user];
        active = block.timestamp < s.expiresAt;
        expiresAt = s.expiresAt;
        paymentToken = s.paymentToken;
        autoRenew = s.autoRenew;
        tier = s.tier;
    }

    function isActive(address user) public view returns (bool) {
        return block.timestamp < _getSubscriptionStorage()._subs._values[user].expiresAt;
    }

    // ========= User actions =========

    // --- Pay with ERC20 using allowance already set ---
    function subscribe(address token, Tier tier) external nonReentrant whenNotPaused {
        _subscribe(msg.sender, token, tier);
    }

    // --- Pay with ERC20 in one tx using EIP-2612 permit (if token supports it) ---
    function subscribeWithPermit(
        address token,
        uint256 deadline,
        uint256 amount,
        Tier tier,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external nonReentrant whenNotPaused {
        require(token != NATIVE_TOKEN, "NATIVE_TOKEN");
        _permit(token, msg.sender, amount, deadline, v, r, s);
        _subscribe(msg.sender, token, tier);
    }

    // --- Pay with native (ETH, etc.) ---
    function subscribeNative(Tier tier) external payable nonReentrant whenNotPaused {
        _subscribe(msg.sender, NATIVE_TOKEN, tier);
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

    function upgradeTier(Tier newTier) external payable nonReentrant whenNotPaused {
        SubscriptionStorage storage $ = _getSubscriptionStorage();

        require($._subs._keys.contains(msg.sender), "user exist");
        Subscription memory s = $._subs._values[msg.sender];

        address token = s.paymentToken;
        Tier oldTier = s.tier;

        uint256 newPrice = $.tokenPrice[token][newTier];
        if (newPrice == 0) revert TokenNotAccepted();

        require(uint(newTier) > uint(oldTier), "Can only upgrade");

        uint64 nowTime = uint64(block.timestamp);
        uint64 expiry = s.expiresAt;
        uint256 remainingValue = 0;

        if (expiry > nowTime) {
            uint256 remainingSecs = expiry - nowTime;
            remainingValue = Math.mulDiv($.tokenPrice[token][oldTier], remainingSecs, $.subscriptionDuration);
        }

        if (newPrice > remainingValue) {
            uint256 upgradeCost = newPrice - remainingValue;

            if (token == NATIVE_TOKEN) {
                if (msg.value < upgradeCost) revert WrongValueSent();

                (bool ok, ) = payable($.treasury).call{ value: upgradeCost }("");
                require(ok, "TREASURY_PAYMENT_FAIL");

                uint256 refund = msg.value - upgradeCost;
                if (refund > 0) {
                    (bool ok, ) = payable(msg.sender).call{ value: refund }("");
                    require(ok, "refund failed");
                }
            } else {
                require(msg.value == 0, "ZERO_VALUE");
                IERC20(token).safeTransferFrom(msg.sender, $.treasury, upgradeCost);
            }
        }

        $._subs._values[msg.sender].expiresAt = nowTime + $.subscriptionDuration;
        $._subs._values[msg.sender].tier = newTier;
        $._subs._keys.add(msg.sender);

        emit UpgradeTier(msg.sender, oldTier, newTier);
    }

    // --- Manage auto-renew preference ---
    function setAutoRenew(bool enabled) external whenNotPaused {
        _getSubscriptionStorage()._subs._values[msg.sender].autoRenew = enabled;
        emit AutoRenewSet(msg.sender, enabled);
    }

    // --- Cancel (just disables autoRenew; subscription remains until expiry) ---
    function cancelAutoRenew() external whenNotPaused {
        _getSubscriptionStorage()._subs._values[msg.sender].autoRenew = false;
        emit AutoRenewSet(msg.sender, false);
    }

    // ========= Keeper/bot helpers (anyone can call) =========

    // Pull-renew a single user IF they opted-in and allowance is sufficient.
    function renewFor(address user) external nonReentrant onlyRole(SERVICE_ROLE) {
        Subscription memory s = _getSubscriptionStorage()._subs._values[user];
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
        address[] memory users = _getSubscriptionStorage()._subs._keys.values();
        _renewBatch(users);
    }

    // ========= Internals =========

    function _setTreasury(address _treasury) internal {
        if (_treasury == address(0)) revert ZeroAddressTreasury();
        _getSubscriptionStorage().treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function _subscribe(address user, address token, Tier tier) internal {
        _processPayment(user, token, tier);
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        emit Subscribed(user, token, $.tokenPrice[token][tier], $._subs._values[user].expiresAt);
    }

    function _renew(address user, address token) internal {
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        Tier tier = $._subs._values[user].tier;
        _processPayment(user, token, tier);
        emit Renewed(user, token, $.tokenPrice[token][tier], $._subs._values[user].expiresAt);
    }

    function _processPayment(address user, address token, Tier tier) internal {
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        uint256 price = $.tokenPrice[token][tier];
        if (price == 0) revert TokenNotAccepted();

        if (token == NATIVE_TOKEN) {
            if (msg.value != price) revert WrongValueSent();

            (bool ok, ) = payable($.treasury).call{ value: msg.value }("");
            require(ok, "TREASURY_PAYMENT_FAIL");
        } else {
            require(msg.value == 0, "ZERO_VALUE");
            IERC20(token).safeTransferFrom(user, $.treasury, price);
        }

        uint64 newExpiry = _newExpiry($._subs._values[user].expiresAt);
        $._subs._values[user].expiresAt = newExpiry;
        $._subs._values[user].paymentToken = token;
        $._subs._values[user].tier = tier;
        $._subs._keys.add(user);
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
        uint64 duration = _getSubscriptionStorage().subscriptionDuration;
        if (nowTs >= current) {
            return nowTs + duration;
        } else {
            return current + duration;
        }
    }

    function _renewBatch(address[] memory users) internal {
        bool atLeastOneSuccess = false;
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        for (uint256 i = 0; i < users.length; ) {
            address u = users[i];
            Subscription memory s = $._subs._values[u];
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

            bool success = _tryRenew(u, s.paymentToken, s.tier);
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
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        delete $._subs._values[user];
        return $._subs._keys.remove(user);
    }

    function _isWithinRenewWindow(uint64 expiresAt) internal view returns (bool) {
        return
            uint64(block.timestamp) + _getSubscriptionStorage().renewWindow >= expiresAt &&
            expiresAt >= uint64(block.timestamp);
    }

    function _tryRenew(address user, address token, Tier tier) internal returns (bool) {
        // check allowance+balance before attempting
        if (!_allowanceAndBalanceSufficient(token, user, _getSubscriptionStorage().tokenPrice[token][tier])) {
            return false;
        }

        // attempt transfer+extend
        try this.renewForExternal(user, token) {
            return true;
        } catch {
            return false;
        }
    }

    function _allowanceAndBalanceSufficient(address token, address user, uint256 amount) internal view returns (bool) {
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
