import hre from "hardhat";
import { Address, zeroAddress, keccak256, toHex } from "viem";
import { zeroGConfig } from "./zeroGConfig.ts";

// ROLE=SERVICE_ROLE USER=0x182b64Ab8A5EfF1CCf3620b376F5788432BE8d11 SUBSCRIPTION=0x182b64Ab8A5EfF1CCf3620b376F5788432BE8d11 pnpm hardhat run scripts/set-role.ts --network localhost

async function main() {
  const subscriptionAddress = process.env.SUBSCRIPTION as Address | undefined;
  if (subscriptionAddress === undefined) {
    throw new Error("SUBSCRIPTION address undefined.");
  }
  console.log("subscription address:", subscriptionAddress);

  const roleName: string = process.env.ROLE ?? "SERVICE_ROLE";
  const userAddress = (process.env.USER ?? zeroAddress) as Address;

  const connection = await hre.network.connect();
  console.log("id", connection.id, connection.networkName);

  const viem = connection.viem;

  let networkCfg = undefined;
  if (connection.networkName === "zeroG") {
    const publicClient = await viem.getPublicClient({ chain: zeroGConfig });
    const [client] = await viem.getWalletClients({ chain: zeroGConfig });

    networkCfg = {
      client: {
        public: publicClient,
        wallet: client,
      },
    };
  }

  const subscription = await viem.getContractAt(
    "SubscriptionManager",
    subscriptionAddress,
    networkCfg,
  );

  const role = keccak256(toHex(roleName));
  console.log(`role ${role}`);

  const readRole = async () => {
    const value = await subscription.read.hasRole([role, userAddress]);
    console.log(`💰 grant ${userAddress} role ${roleName}: ${value}`);
    return value;
  };

  await readRole();

  await subscription.write.grantRole([role, userAddress]);

  await readRole();
}

main().catch(console.error);
