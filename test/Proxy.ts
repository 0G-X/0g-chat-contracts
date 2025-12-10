import hre from "hardhat";
import path from "path";

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import DeploySubscriptionManagerModule from "../ignition/modules/DeploySubscriptionManager.ts";
import TestUpgradeContractModule from "../ignition/modules/TestUpgradeContract.ts";

enum Tier {
  Free = 0,
  Plus = 1,
  Pro = 2,
  Enterprise = 3,
}

describe("Test Proxy", async function () {
  const { ignition } = await hre.network.connect();

  describe("Proxy interaction", function () {
    it("Should be interactable via proxy", async function () {
      const { instance } = await ignition.deploy(
        DeploySubscriptionManagerModule,
        {
          parameters: path.resolve(import.meta.dirname, "./parameters.json"),
        },
      );

      assert.equal(await instance.read.subscriptionDuration(), 2592000n);

      assert.equal(
        await instance.read.treasury(),
        "0x36b70baCc1F488C7bCD4933083aE27E3D4eED7Dd",
      );

      const [, , autoRenew, tier] = await instance.read.getSubscription([
        "0x36b70baCc1F488C7bCD4933083aE27E3D4eED7Dd",
      ]);

      assert.equal(tier, Tier.Free);
      assert.equal(autoRenew, false);
    });
  });

  describe("Upgrading", function () {
    it("Should have upgraded the proxy to UpgradeContract", async function () {
      const { newInstance: instance } = await ignition.deploy(
        TestUpgradeContractModule,
        {
          parameters: path.resolve(import.meta.dirname, "./parameters.json"),
        },
      );

      const [, , autoRenew, tier] = await instance.read.getSubscription([
        "0x36b70baCc1F488C7bCD4933083aE27E3D4eED7Dd",
      ]);
      assert.equal(tier, Tier.Enterprise);
      assert.equal(autoRenew, true);
    });
  });
});
