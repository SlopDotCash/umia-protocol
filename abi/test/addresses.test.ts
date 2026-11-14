import assert from "node:assert/strict";
import { test } from "node:test";
import {
  addresses,
  getChainAddresses,
  getChainAddressesById,
  getContractAddress,
  type Environment,
} from "../src/addresses";

test("configured chains and both contract namespaces resolve", () => {
  for (const env of Object.keys(addresses) as Environment[]) {
    for (const [name, chain] of Object.entries(addresses[env])) {
      assert.equal(getChainAddresses(env, name), chain);
      assert.equal(getChainAddressesById(env, chain.chainId), chain);
      for (const [contract, address] of Object.entries(chain.umia)) {
        assert.equal(getContractAddress(env, chain.chainId, contract), address);
      }
      for (const [contract, address] of Object.entries(chain.uniswap)) {
        assert.equal(getContractAddress(env, chain.chainId, contract), address);
      }
    }
  }
});

test("unknown chains and contracts return null", () => {
  assert.equal(getChainAddresses("mainnet", "missing-chain"), null);
  assert.equal(getChainAddressesById("mainnet", -1), null);
  assert.equal(getContractAddress("mainnet", -1, "hub"), null);
  assert.equal(getContractAddress("mainnet", 8453, "missing-contract"), null);
});

test("inherited object properties are not chain names", () => {
  for (const name of ["toString", "constructor", "__proto__", "hasOwnProperty"]) {
    assert.equal(getChainAddresses("mainnet", name), null, name);
  }
});

test("inherited object properties are not contract names", () => {
  for (const name of ["toString", "constructor", "__proto__", "hasOwnProperty"]) {
    assert.equal(getContractAddress("mainnet", 8453, name), null, name);
  }
});
