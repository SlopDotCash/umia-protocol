import { addresses } from "./generated-addresses";

export { addresses };

export type Environment = keyof typeof addresses;
export type ChainName<E extends Environment = Environment> = keyof (typeof addresses)[E];

export type ChainAddresses = {
  chainId: number;
  /** Block the protocol was first deployed at on this chain — an indexer's start height. */
  startBlock: number;
  umia: Record<string, string>;
  uniswap?: Record<string, string>;
  moneyToken?: string;
  moneyTokenDecimals?: number;
};

const asChains = (env: Environment) =>
  addresses[env] as unknown as Record<string, ChainAddresses | undefined>;

/** Every chain configured for an environment, keyed by chain name. */
export function getChains(env: Environment): Record<string, ChainAddresses> {
  return asChains(env) as Record<string, ChainAddresses>;
}

/** Addresses for one chain, by name (`"base"`, `"base-sepolia"`). */
export function getChainAddresses(env: Environment, chainName: string): ChainAddresses | null {
  return asChains(env)[chainName] ?? null;
}

/** Addresses for one chain, by id. Prefer this when you already hold a chain id. */
export function getChainAddressesById(env: Environment, chainId: number): ChainAddresses | null {
  for (const chain of Object.values(asChains(env))) {
    if (chain?.chainId === chainId) return chain;
  }
  return null;
}

/**
 * A single contract address, or null when the chain does not have one.
 * Returns null rather than throwing so callers can gate a feature on it.
 */
export function getContractAddress(env: Environment, chainId: number, name: string): string | null {
  const chain = getChainAddressesById(env, chainId);
  return chain?.umia[name] ?? chain?.uniswap?.[name] ?? null;
}
