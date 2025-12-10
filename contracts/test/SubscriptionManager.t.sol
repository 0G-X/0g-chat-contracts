// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import { Test } from "forge-std/Test.sol";
import { SubscriptionManager } from "../SubscriptionManager.sol";
import { UpgradeContract } from "./UpgradeContract.t.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { console } from "forge-std/console.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MTK") {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockERC20Permit is ERC20Permit {
    constructor() ERC20("MockTokenPermit", "MTKP") ERC20Permit("MockTokenPermit") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function permitDigest(
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                        owner,
                        spender,
                        value,
                        nonce,
                        deadline
                    )
                )
            );
    }
}

contract SubscriptionManagerTest is Test {
    SubscriptionManager subMgr;
    ERC1967Proxy proxy;
    SubscriptionManager proxiedSubMgr;

    MockERC20 token;

    address admin = address(0x1);
    address treasury = address(0x2);
    uint256 userPk = 0xA11CE;
    address user = vm.addr(userPk);

    function setUp() public {
        token = new MockERC20();

        subMgr = new SubscriptionManager();
        bytes memory initData = abi.encodeWithSelector(subMgr.initialize.selector, treasury);

        vm.prank(admin);
        proxy = new ERC1967Proxy(address(subMgr), initData);
        proxiedSubMgr = SubscriptionManager(payable(address(proxy)));

        // Give admin all roles
        vm.startPrank(admin);
        proxiedSubMgr.setToken(address(token), SubscriptionManager.Tier.Plus, 1e18);
        proxiedSubMgr.setToken(address(token), SubscriptionManager.Tier.Pro, 2e18);
        proxiedSubMgr.setToken(address(token), SubscriptionManager.Tier.Enterprise, 3e18);
        vm.stopPrank();

        // Mint tokens to user
        token.mint(user, 10e18);
    }

    function testSetTreasury() public {
        address newTreasury = address(0x4);
        vm.prank(admin);
        proxiedSubMgr.setTreasury(newTreasury);
        assertEq(proxiedSubMgr.treasury(), newTreasury);
    }

    function testFailSetTreasuryZero() public {
        vm.prank(admin);
        vm.expectRevert(SubscriptionManager.ZeroAddressTreasury.selector);
        proxiedSubMgr.setTreasury(address(0));
    }

    function testSetSubscriptionDuration() public {
        vm.prank(admin);
        proxiedSubMgr.setSubscriptionDuration(60 days);
        assertEq(proxiedSubMgr.subscriptionDuration(), 60 days);
    }

    function testFailSetSubscriptionDurationZero() public {
        vm.prank(admin);
        vm.expectRevert(bytes("Duration must be greater than 0"));
        proxiedSubMgr.setSubscriptionDuration(0);
    }

    function testSetRenewWindow() public {
        vm.prank(admin);
        proxiedSubMgr.setRenewWindow(2 days);
        assertEq(proxiedSubMgr.renewWindow(), 2 days);
    }

    function testFailSetRenewWindowTooLong() public {
        vm.prank(admin);
        vm.expectRevert(bytes("RenewWindow too long"));

        proxiedSubMgr.setRenewWindow(400 days);
    }

    function testRemoveToken() public {
        vm.prank(admin);
        proxiedSubMgr.removeToken(address(token));
        assertEq(proxiedSubMgr.tokenPrice(address(token), SubscriptionManager.Tier.Plus), 0);
        assertEq(proxiedSubMgr.tokenPrice(address(token), SubscriptionManager.Tier.Pro), 0);
        assertEq(proxiedSubMgr.tokenPrice(address(token), SubscriptionManager.Tier.Enterprise), 0);
    }

    function testSubscribeERC20() public {
        vm.startPrank(user);
        token.approve(address(proxiedSubMgr), 1e18);
        (, , , SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Free);

        proxiedSubMgr.subscribe(address(token), SubscriptionManager.Tier.Plus);
        (uint256 expiresAt, , , SubscriptionManager.Tier newTier) = proxiedSubMgr.getSubscription(user);
        assertGt(expiresAt, block.timestamp);
        assertTrue(newTier == SubscriptionManager.Tier.Plus);
        vm.stopPrank();
    }

    function testSubscribeERC20WithPermit() public {
        MockERC20Permit tokenPermit = new MockERC20Permit();

        tokenPermit.mint(user, 10e18);

        vm.startPrank(admin);
        proxiedSubMgr.setToken(address(tokenPermit), SubscriptionManager.Tier.Plus, 1e18);
        vm.stopPrank();

        uint256 amount = 1 ether;

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            userPk,
            tokenPermit.permitDigest(user, address(proxiedSubMgr), amount, 0, deadline) // helper in mock
        );

        vm.startPrank(user);

        proxiedSubMgr.subscribeWithPermit(
            address(tokenPermit),
            deadline,
            amount,
            SubscriptionManager.Tier.Plus,
            v,
            r,
            s
        );
    }

    function testFailSubscribeERC20WithPermit() public {
        uint256 amount = 1 ether;

        MockERC20Permit tokenPermit = new MockERC20Permit();

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(
            userPk,
            tokenPermit.permitDigest(user, address(proxiedSubMgr), amount, 0, deadline) // helper in mock
        );

        vm.startPrank(user);
        vm.expectRevert();
        proxiedSubMgr.subscribeWithPermit(address(token), deadline, amount, SubscriptionManager.Tier.Plus, v, r, s);
    }

    function testSubscribeNative() public {
        vm.prank(admin);
        proxiedSubMgr.setToken(address(0), SubscriptionManager.Tier.Plus, 0.1 ether);

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        (, , , SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Free);
        proxiedSubMgr.subscribeNative{ value: 0.1 ether }(SubscriptionManager.Tier.Plus);
        (uint256 expiresAt, , , SubscriptionManager.Tier newTier) = proxiedSubMgr.getSubscription(user);
        assertTrue(newTier == SubscriptionManager.Tier.Plus);
        assertGt(expiresAt, block.timestamp);
    }

    function testRenewERC20() public {
        vm.startPrank(user);
        token.approve(address(proxiedSubMgr), 2e18);
        proxiedSubMgr.subscribe(address(token), SubscriptionManager.Tier.Plus);
        (uint256 firstExpiry, , , ) = proxiedSubMgr.getSubscription(user);
        proxiedSubMgr.renew(address(token));
        (uint256 secondExpiry, , , ) = proxiedSubMgr.getSubscription(user);
        assertGt(secondExpiry, firstExpiry);
        vm.stopPrank();
    }

    function testRenewNative() public {
        vm.prank(admin);
        proxiedSubMgr.setToken(address(0), SubscriptionManager.Tier.Plus, 0.1 ether);

        vm.deal(user, 1 ether);
        vm.startPrank(user);
        proxiedSubMgr.subscribeNative{ value: 0.1 ether }(SubscriptionManager.Tier.Plus);

        (uint256 firstExpiry, , , ) = proxiedSubMgr.getSubscription(user);

        proxiedSubMgr.renewNative{ value: 0.1 ether }();
        (uint256 secondExpiry, , , ) = proxiedSubMgr.getSubscription(user);
        assertGt(secondExpiry, firstExpiry);
        vm.stopPrank();
    }

    function testSetAutoRenewAndRenewFor() public {
        vm.startPrank(user);
        token.approve(address(proxiedSubMgr), 2e18);
        proxiedSubMgr.subscribe(address(token), SubscriptionManager.Tier.Plus);
        proxiedSubMgr.setAutoRenew(true);
        vm.stopPrank();

        (uint256 expiresAt, , bool autoRenew, SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Plus);

        // Fast forward to within renew window
        vm.warp(block.timestamp + 29 days);

        (, , autoRenew, tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Plus);

        vm.prank(admin);
        proxiedSubMgr.renewFor(user);
        (expiresAt, , autoRenew, tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Plus);
        assertTrue(autoRenew);
        assertGt(expiresAt, block.timestamp);
    }

    function testFailedSetAutoRenewAndRenewFor() public {
        vm.startPrank(user);
        token.approve(address(proxiedSubMgr), 2e18);
        proxiedSubMgr.subscribe(address(token), SubscriptionManager.Tier.Plus);
        proxiedSubMgr.setAutoRenew(true);

        (uint256 expiresAt, , bool autoRenew, SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Plus);

        vm.stopPrank();
        // Fast forward to within renew window
        vm.warp(block.timestamp + 31 days);
        (expiresAt, , autoRenew, tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Free);

        vm.prank(admin);
        vm.expectRevert(bytes("CANNOT_RENEW"));
        proxiedSubMgr.renewFor(user);
    }

    function testSetAutoRenewAndRenewBatch() public {
        vm.startPrank(user);
        token.approve(address(proxiedSubMgr), 2e18);
        proxiedSubMgr.subscribe(address(token), SubscriptionManager.Tier.Plus);
        proxiedSubMgr.setAutoRenew(true);
        vm.stopPrank();

        (uint256 expiresAt, , bool autoRenew, SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Plus);

        // Fast forward to within renew window
        vm.warp(block.timestamp + 29 days);

        vm.prank(admin);
        proxiedSubMgr.renewBatch();
        (expiresAt, , autoRenew, tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Plus);
        assertTrue(autoRenew);
        assertGt(expiresAt, block.timestamp);
    }

    function testFailedSetAutoRenewAndRenewBatch() public {
        vm.startPrank(user);
        token.approve(address(proxiedSubMgr), 2e18);
        proxiedSubMgr.subscribe(address(token), SubscriptionManager.Tier.Plus);
        proxiedSubMgr.setAutoRenew(true);
        vm.stopPrank();

        (, , , SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Plus);

        vm.expectRevert(bytes("success renew"));
        vm.prank(admin);
        proxiedSubMgr.renewBatch();
    }

    function testFailSubscribeWithWrongValue() public {
        vm.prank(admin);
        proxiedSubMgr.setToken(address(0), SubscriptionManager.Tier.Plus, 0.1 ether);

        vm.deal(user, 1 ether);
        vm.prank(user);
        vm.expectRevert(SubscriptionManager.WrongValueSent.selector);
        proxiedSubMgr.subscribeNative{ value: 0.2 ether }(SubscriptionManager.Tier.Plus);
    }

    function testFailSubscribeWithUnacceptedToken() public {
        vm.prank(user);
        vm.expectRevert(SubscriptionManager.TokenNotAccepted.selector);
        proxiedSubMgr.subscribe(address(0xdead), SubscriptionManager.Tier.Plus);
    }

    function testUpgradeTier() public {
        vm.startPrank(user);
        token.approve(address(proxiedSubMgr), 3e18);
        proxiedSubMgr.subscribe(address(token), SubscriptionManager.Tier.Plus);
        (uint256 expiresAt, , , SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertGt(expiresAt, block.timestamp);

        assertTrue(tier == SubscriptionManager.Tier.Plus);
        // console.logUint(uint(tier));

        proxiedSubMgr.upgradeTier(SubscriptionManager.Tier.Enterprise);
        (uint256 newExpiresAt, , , SubscriptionManager.Tier newTier) = proxiedSubMgr.getSubscription(user);

        // console.logUint(uint(newTier));
        assertGt(newExpiresAt, block.timestamp);
        assertTrue(newTier == SubscriptionManager.Tier.Enterprise);

        vm.stopPrank();
    }

    function testUpgradeTierNative() public {
        vm.prank(admin);
        proxiedSubMgr.setToken(address(0), SubscriptionManager.Tier.Plus, 0.1 ether);
        vm.prank(admin);
        proxiedSubMgr.setToken(address(0), SubscriptionManager.Tier.Enterprise, 0.2 ether);

        vm.deal(user, 1 ether);
        vm.prank(user);
        proxiedSubMgr.subscribeNative{ value: 0.1 ether }(SubscriptionManager.Tier.Plus);
        (uint256 expiresAt, , , SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertGt(expiresAt, block.timestamp);
        assertTrue(tier == SubscriptionManager.Tier.Plus);

        vm.warp(block.timestamp + 15 days);
        vm.prank(user);
        proxiedSubMgr.upgradeTier{ value: 0.3 ether }(SubscriptionManager.Tier.Enterprise);
        (uint256 newExpiresAt, , , SubscriptionManager.Tier newTier) = proxiedSubMgr.getSubscription(user);
        assertTrue(user.balance == 0.75 ether);

        assertGt(newExpiresAt, block.timestamp);
        console.logUint(uint(newTier));
        assertTrue(newTier == SubscriptionManager.Tier.Enterprise);

        vm.stopPrank();
    }

    function testFailedUpgradeTier() public {
        vm.prank(admin);
        proxiedSubMgr.setToken(address(0), SubscriptionManager.Tier.Plus, 0.1 ether);

        vm.deal(user, 1 ether);
        vm.prank(user);
        proxiedSubMgr.subscribeNative{ value: 0.1 ether }(SubscriptionManager.Tier.Plus);
        (uint256 expiresAt, , , SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertGt(expiresAt, block.timestamp);
        assertTrue(tier == SubscriptionManager.Tier.Plus);

        vm.expectRevert(bytes("user exist"));
        proxiedSubMgr.upgradeTier{ value: 0.2 ether }(SubscriptionManager.Tier.Enterprise);
    }

    function testUpgrade() public {
        (, , bool autoRenew, SubscriptionManager.Tier tier) = proxiedSubMgr.getSubscription(user);
        assertTrue(tier == SubscriptionManager.Tier.Free);
        assertTrue(!autoRenew);

        // Deploy a new version of logic
        UpgradeContract newSubMgr = new UpgradeContract();

        vm.prank(admin);
        proxiedSubMgr.upgradeToAndCall(address(newSubMgr), "");

        (, , autoRenew, tier) = proxiedSubMgr.getSubscription(user);

        assertTrue(tier == SubscriptionManager.Tier.Enterprise);
        assertTrue(autoRenew);
    }
}
