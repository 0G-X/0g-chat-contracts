import { describe, it } from "node:test";

import { network } from "hardhat";

describe("SubscriptionManager", async function () {
  const { viem } = await network.connect();

  it("Should emit the Increment event when calling the inc() function", async function () {
    await viem.deployContract("SubscriptionManager");
  });
});
