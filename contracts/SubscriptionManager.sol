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

    uint256 public constant SECONDS_PER_DAY = 24 * 60 * 60;
    int256 public constant OFFSET19700101 = 2440588;

    enum Tier {
        Free,
        Plus,
        Pro,
        Enterprise,
        Reserved4,
        Reserved5,
        Reserved6,
        Reserved7,
        Reserved8,
        Reserved9
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
        uint64 subscriptionDurationInMonth;
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
    event Subscribed(
        address indexed user,
        address indexed sender,
        address indexed token,
        uint256 price,
        uint256 newExpiry
    );
    event Renewed(
        address indexed user,
        address indexed sender,
        address indexed token,
        uint256 price,
        uint256 newExpiry
    );
    event AutoRenewSet(address indexed user, bool indexed enabled);
    event SubscriptionDurationUpdated(uint256 indexed newDuration);
    event RenewWindowUpdated(uint256 indexed newWindow);
    event UpgradeTier(address indexed user, address indexed sender, Tier oldTier, Tier newTier);

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
        $.subscriptionDurationInMonth = 1;
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
        require(tier != Tier.Free, "FREE TIER");
        _getSubscriptionStorage().tokenPrice[token][tier] = price;
        emit TokenUpdated(token, tier, price);
    }

    function setTokens(address[] calldata tokens, Tier tier, uint256[] calldata prices) external onlyAdmin {
        require(tier != Tier.Free, "FREE TIER");
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
        require(newDuration <= 12, "Duration too long");
        _getSubscriptionStorage().subscriptionDurationInMonth = newDuration;
        emit SubscriptionDurationUpdated(newDuration);
    }

    function subscriptionDuration() public view returns (uint64) {
        return _getSubscriptionStorage().subscriptionDurationInMonth;
    }

    function setRenewWindow(uint64 newWindow) external onlyAdmin {
        require(newWindow > 0, "Renew must be greater than 0");
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        require(newWindow < $.subscriptionDurationInMonth * 30 days, "RenewWindow too long");
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
    ) external view returns (uint256 expiresAt, address paymentToken, bool autoRenew, Tier tier) {
        Subscription memory s = _getSubscriptionStorage()._subs._values[user];
        if (block.timestamp < s.expiresAt) {
            tier = s.tier;
        } else {
            tier = Tier.Free;
        }
        expiresAt = s.expiresAt;
        paymentToken = s.paymentToken;
        autoRenew = s.autoRenew;
    }

    function getTier(address user) public view returns (Tier) {
        Subscription memory s = _getSubscriptionStorage()._subs._values[user];
        if (block.timestamp < s.expiresAt) {
            return s.tier;
        } else {
            return Tier.Free;
        }
    }

    // ========= User actions =========

    // --- Pay with native (ETH, etc.) ---
    function subscribeNative(Tier tier, address recipient) external payable nonReentrant whenNotPaused {
        address subscribeTo = recipient == address(0) ? msg.sender : recipient;
        require(subscribeTo != address(0), "Invalid recipient address");
        _subscribe(subscribeTo, NATIVE_TOKEN, tier);
    }

    // --- Renew with ERC20 (pull, requires allowance or prior permit call) ---
    function renewNative(address recipient) external payable nonReentrant whenNotPaused {
        address subscribeTo = recipient == address(0) ? msg.sender : recipient;
        require(subscribeTo != address(0), "Invalid recipient address");
        _renew(subscribeTo, NATIVE_TOKEN);
    }

    function upgradeTier(Tier newTier, address recipient) external payable nonReentrant whenNotPaused {
        address subscribeTo = recipient == address(0) ? msg.sender : recipient;
        require(subscribeTo != address(0), "Invalid recipient address");

        SubscriptionStorage storage $ = _getSubscriptionStorage();

        require($._subs._keys.contains(subscribeTo), "user not exist");
        Subscription memory s = $._subs._values[subscribeTo];

        address token = s.paymentToken;
        Tier oldTier = s.tier;

        uint256 newPrice = $.tokenPrice[token][newTier];
        uint256 oldPrice = $.tokenPrice[token][oldTier];
        if (newPrice == 0 || oldPrice == 0) revert TokenNotAccepted();
        require(newPrice > oldPrice, "Can only upgrade");

        uint64 nowTime = uint64(block.timestamp);
        uint64 expiry = s.expiresAt;
        uint256 remainingValue = 0;

        if (expiry > nowTime) {
            uint256 remainingSecs = expiry - nowTime;
            remainingValue = Math.mulDiv(
                oldPrice,
                remainingSecs,
                uint256(expiry) - _subMonths(expiry, $.subscriptionDurationInMonth)
            );
        }

        if (newPrice > remainingValue) {
            uint256 upgradeCost = newPrice - remainingValue;

            if (token == NATIVE_TOKEN) {
                if (msg.value < upgradeCost) revert WrongValueSent();

                (bool ok, ) = payable($.treasury).call{ value: upgradeCost }("");
                require(ok, "TREASURY_PAYMENT_FAIL");

                uint256 refund = msg.value - upgradeCost;
                if (refund > 0) {
                    (ok, ) = payable(msg.sender).call{ value: refund }("");
                    require(ok, "refund failed");
                }
            } else {
                require(msg.value == 0, "ZERO_VALUE");
                IERC20(token).safeTransferFrom(msg.sender, $.treasury, upgradeCost);
            }
        }

        $._subs._values[subscribeTo].expiresAt = uint64(_addMonths(nowTime, $.subscriptionDurationInMonth));
        $._subs._values[subscribeTo].tier = newTier;
        $._subs._keys.add(subscribeTo);

        emit UpgradeTier(subscribeTo, msg.sender, oldTier, newTier);
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

    // ========= Internals =========

    function _setTreasury(address _treasury) internal {
        if (_treasury == address(0)) revert ZeroAddressTreasury();
        _getSubscriptionStorage().treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function _subscribe(address user, address token, Tier tier) internal {
        _processPayment(user, token, tier);
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        emit Subscribed(user, msg.sender, token, $.tokenPrice[token][tier], $._subs._values[user].expiresAt);
    }

    function _renew(address user, address token) internal {
        SubscriptionStorage storage $ = _getSubscriptionStorage();
        Tier tier = $._subs._values[user].tier;
        _processPayment(user, token, tier);
        emit Renewed(user, msg.sender, token, $.tokenPrice[token][tier], $._subs._values[user].expiresAt);
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
            IERC20(token).safeTransferFrom(msg.sender, $.treasury, price);
        }

        uint64 newExpiry = _newExpiry($._subs._values[user].expiresAt);
        $._subs._values[user].expiresAt = newExpiry;
        $._subs._values[user].paymentToken = token;
        $._subs._values[user].tier = tier;
        $._subs._keys.add(user);
    }

    function _newExpiry(uint64 current) internal view returns (uint64) {
        uint64 nowTs = uint64(block.timestamp);
        uint64 duration = _getSubscriptionStorage().subscriptionDurationInMonth;
        if (nowTs >= current) {
            return uint64(_addMonths(nowTs, duration));
        } else {
            return uint64(_addMonths(current, duration));
        }
    }
    // Fallback rejects accidental native sends (must use subscribeNative/renewNative)
    receive() external payable {
        revert WrongValueSent();
    }

    fallback() external payable {
        revert WrongValueSent();
    }

    function _addMonths(uint256 timestamp, uint256 _months) internal pure returns (uint256 newTimestamp) {
        (uint256 year, uint256 month, uint256 day) = _daysToDate(timestamp / SECONDS_PER_DAY);

        month += _months;
        year += (month - 1) / 12;
        month = ((month - 1) % 12) + 1;

        uint256 daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }

        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + (timestamp % SECONDS_PER_DAY);
        require(newTimestamp >= timestamp);
    }

    function _subMonths(uint256 timestamp, uint256 _months) internal pure returns (uint256 newTimestamp) {
        (uint256 year, uint256 month, uint256 day) = _daysToDate(timestamp / SECONDS_PER_DAY);
        uint256 yearMonth = year * 12 + (month - 1) - _months;
        year = yearMonth / 12;
        month = (yearMonth % 12) + 1;
        uint256 daysInMonth = _getDaysInMonth(year, month);
        if (day > daysInMonth) {
            day = daysInMonth;
        }
        newTimestamp = _daysFromDate(year, month, day) * SECONDS_PER_DAY + (timestamp % SECONDS_PER_DAY);
        require(newTimestamp <= timestamp);
    }

    function _daysToDate(uint256 _days) internal pure returns (uint256 year, uint256 month, uint256 day) {
        unchecked {
            int256 __days = int256(_days);

            int256 L = __days + 68569 + OFFSET19700101;
            int256 N = (4 * L) / 146097;
            L = L - (146097 * N + 3) / 4;
            int256 _year = (4000 * (L + 1)) / 1461001;
            L = L - (1461 * _year) / 4 + 31;
            int256 _month = (80 * L) / 2447;
            int256 _day = L - (2447 * _month) / 80;
            L = _month / 11;
            _month = _month + 2 - 12 * L;
            _year = 100 * (N - 49) + _year + L;

            year = uint256(_year);
            month = uint256(_month);
            day = uint256(_day);
        }
    }

    function _daysFromDate(uint256 year, uint256 month, uint256 day) internal pure returns (uint256 _days) {
        require(year >= 1970);
        int256 _year = int256(year);
        int256 _month = int256(month);
        int256 _day = int256(day);

        int256 __days = _day -
            32075 +
            (1461 * (_year + 4800 + (_month - 14) / 12)) / 4 +
            (367 * (_month - 2 - ((_month - 14) / 12) * 12)) / 12 -
            (3 * ((_year + 4900 + (_month - 14) / 12) / 100)) / 4 -
            OFFSET19700101;

        _days = uint256(__days);
    }

    function _getDaysInMonth(uint256 year, uint256 month) internal pure returns (uint256 daysInMonth) {
        if (month == 1 || month == 3 || month == 5 || month == 7 || month == 8 || month == 10 || month == 12) {
            daysInMonth = 31;
        } else if (month != 2) {
            daysInMonth = 30;
        } else {
            daysInMonth = _isLeapYear(year) ? 29 : 28;
        }
    }

    function _isLeapYear(uint256 year) internal pure returns (bool leapYear) {
        leapYear = ((year % 4 == 0) && (year % 100 != 0)) || (year % 400 == 0);
    }
}
