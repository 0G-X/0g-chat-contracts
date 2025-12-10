import hre from "hardhat";
import { Address, zeroAddress } from "viem";
import { zeroGConfig } from "./zeroGConfig.ts";

// TOKEN=0x1234567890abcdef1234567890abcdef12345678 TIER=0 PRICE=100 SUBSCRIPTION=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512 pnpm hardhat run scripts/set-token.ts --network localhost

enum Tier {
  Free = 0,
  Plus = 1,
  Pro = 2,
  Enterprise = 3,
}

async function main() {
  const subscriptionAddress = process.env.SUBSCRIPTION as Address | undefined;
  if (subscriptionAddress === undefined) {
    throw new Error("SUBSCRIPTION address undefined.");
  }
  console.log("subscription address:", subscriptionAddress);

  const tokenAddress: Address = (process.env.TOKEN ?? zeroAddress) as Address;
  const price = process.env.PRICE ? BigInt(process.env.PRICE) : 1n;
  const tier = process.env.TIER ?? Tier.Plus;

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

  const readPrice = async () => {
    const value = await subscription.read.tokenPrice([tokenAddress, Number(tier)]);
    console.log(`💰 Token price: ${value}`);
    return value;
  };

  await readPrice();

  await subscription.write.setToken([tokenAddress, Number(tier), price]);

  await readPrice();
}

main().catch(console.error);
