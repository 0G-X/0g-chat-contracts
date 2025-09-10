import hre from "hardhat";
import DeploySubscriptionManagerModule from "../ignition/modules/DeploySubscriptionManager.ts";
import path from "path";

// pnpm hardhat ignition deploy --network localhost ignition/modules/DeploySubscriptionManager.ts --parameters test/parameters.json
// pnpm hardhat run scripts/deploy.ts --network localhost

async function main() {
  const connection = await hre.network.connect();
  console.log("id", connection.id, connection.networkName);
  const { instance } = await connection.ignition.deploy(
    DeploySubscriptionManagerModule,
    {
      // parameters: { treasury: { treasuryAddress } },
      parameters: path.resolve(import.meta.dirname, "../test/parameters.json"),
    },
  );

  console.log(`Subscription deployed to: ${instance.address}`);
  const treasury = await instance.read.treasury();
  console.log(`treasury address: ${treasury}`);
}

main().catch(console.error);
