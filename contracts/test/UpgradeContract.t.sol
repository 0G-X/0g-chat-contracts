// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract UpgradeContract is UUPSUpgradeable {
    uint64 public subscriptionDuration;

    constructor() {
        _disableInitializers();
    }

    // ===== Upgrade Auth =====
    function _authorizeUpgrade(address newImplementation) internal override {}

    function getSubscription(
        address /* user */
    ) external view returns (bool active, uint256 expiresAt, address paymentToken, bool autoRenew) {
        active = true;
        expiresAt = block.timestamp;
        paymentToken = address(0);
        autoRenew = true;
    }
}
