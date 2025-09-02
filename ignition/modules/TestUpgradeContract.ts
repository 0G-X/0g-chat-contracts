import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

import DeploySubscriptionManagerModule from "./DeploySubscriptionManager.ts";

const TestUpgradeContractModule = buildModule(
  "TestUpgradeContractModule",
  (m) => {
    const { instance, proxy } = m.useModule(DeploySubscriptionManagerModule);

    const newImplementation = m.contract("UpgradeContract");

    m.call(instance, "upgradeToAndCall", [newImplementation, "0x"]);

    const newInstance = m.contractAt("UpgradeContract", proxy, {
      id: "TestUpgradeContractModule_UpgradeContract1",
    });

    return { newInstance, proxy };
  },
);

export default TestUpgradeContractModule;
