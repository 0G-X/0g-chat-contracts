import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import DeploySubscriptionManagerModule from "./DeploySubscriptionManager.ts";

const UpgradeProxyModule = buildModule("UpgradeProxyModule", (m) => {
  const { instance, proxy } = m.useModule(DeploySubscriptionManagerModule);

  const newImplementation = m.contract("SubscriptionManager");

  m.call(instance, "upgradeToAndCall", [newImplementation, "0x"]);

  return { proxy };
});

const UpgradeSubscriptionManagerModule = buildModule(
  "UpgradeSubscriptionManagerModule",
  (m) => {
    const { proxy } = m.useModule(UpgradeProxyModule);

    const instance = m.contractAt("SubscriptionManager", proxy);

    return { instance, proxy };
  },
);

export default UpgradeSubscriptionManagerModule;
