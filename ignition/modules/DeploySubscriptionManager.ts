import { buildModule } from "@nomicfoundation/hardhat-ignition/modules";

const ProxyModule = buildModule("ProxyModule", (m) => {
  const subscriptionManager = m.contract("SubscriptionManager");
  const treasury = m.getParameter(
    "treasury",
    "0x0000000000000000000000000000000000000000",
  );

  const initialize = m.encodeFunctionCall(subscriptionManager, "initialize", [
    treasury,
  ]);

  const proxy = m.contract("ERC1967Proxy", [subscriptionManager, initialize]);

  return { proxy };
});

const DeploySubscriptionManagerModule = buildModule(
  "DeploySubscriptionManagerModule",
  (m) => {
    const { proxy } = m.useModule(ProxyModule);

    const instance = m.contractAt("SubscriptionManager", proxy);

    return { instance, proxy };
  },
);

export default DeploySubscriptionManagerModule;
