import { NetworkName, ChainType } from "@railgun-community/shared-models";

export const CHAINS = {
  ethereum: {
    networkName: NetworkName.Ethereum,
    chain: { type: ChainType.EVM, id: 1 },
  },
  polygon: {
    networkName: NetworkName.Polygon,
    chain: { type: ChainType.EVM, id: 137 },
  },
  bsc: {
    networkName: NetworkName.BNBChain,
    chain: { type: ChainType.EVM, id: 56 },
  },
  arbitrum: {
    networkName: NetworkName.Arbitrum,
    chain: { type: ChainType.EVM, id: 42161 },
  },
  sepolia: {
    networkName: NetworkName.EthereumSepolia,
    chain: { type: ChainType.EVM, id: 11155111 },
  },
  amoy: {
    networkName: NetworkName.PolygonAmoy,
    chain: { type: ChainType.EVM, id: 80002 },
  },
};

export function chainForName(name) {
  const entry = CHAINS[name];
  if (!entry) {
    throw new Error(
      `Unknown chain: ${name}. Supported: ${Object.keys(CHAINS).join(", ")}`
    );
  }
  return entry;
}
