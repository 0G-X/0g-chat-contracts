import type { HardhatUserConfig } from "hardhat/config";

import hardhatToolboxViemPlugin from "@nomicfoundation/hardhat-toolbox-viem";
import hardhatIgnitionViemPlugin from "@nomicfoundation/hardhat-ignition-viem";
import hardhatAbiExporter from "@solidstate/hardhat-abi-exporter";
import { configVariable } from "hardhat/config";
import hardhatContractSizer from '@solidstate/hardhat-contract-sizer';

const config: HardhatUserConfig = {
  plugins: [
    hardhatToolboxViemPlugin,
    hardhatIgnitionViemPlugin,
    hardhatAbiExporter,
    hardhatContractSizer,
  ],
  solidity: {
    profiles: {
      default: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
      production: {
        version: "0.8.28",
        settings: {
          optimizer: {
            enabled: true,
            runs: 200,
          },
        },
      },
    },
    npmFilesToBuild: ["@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol"],
  },
  networks: {
    hardhatMainnet: {
      type: "edr-simulated",
      chainType: "l1",
    },
    hardhatOp: {
      type: "edr-simulated",
      chainType: "op",
    },
    sepolia: {
      type: "http",
      chainType: "l1",
      url: configVariable("SEPOLIA_RPC_URL"),
      accounts: [configVariable("SEPOLIA_PRIVATE_KEY")],
    },
    zeroG: {
      type: "http",
      chainType: "l1",
      url: "https://evmrpc-testnet.0g.ai",
      accounts: [configVariable("ZG_TEST_PRIVATE_KEY")],
    },
  },
  abiExporter: {
    path: "./abis",
    runOnCompile: true,
    clear: true,
    flat: true,
    format: "json",
    except: [/test.*/],
  },
  contractSizer: {
    alphaSort: false,
    runOnCompile: true,
    strict: false,
    flat: true,
    except: [/test.*/],
  },
};

export default config;
