import { describe, expect, it } from "vitest";
import { initSimnet } from "@stacks/clarinet-sdk";
import { Cl } from "@stacks/transactions";

const simnet = await initSimnet();

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;

describe("honeycomb token tests", () => {
  it("ensures token metadata is correct", () => {
    const symbolResponse = simnet.callReadOnlyFn(
      "luckyhive-honeycomb",
      "get-symbol",
      [],
      wallet1
    );
    expect(symbolResponse.result).toEqual(Cl.ok(Cl.stringAscii("HCOMB")));

    const nameResponse = simnet.callReadOnlyFn(
      "luckyhive-honeycomb",
      "get-name",
      [],
      wallet1
    );
    expect(nameResponse.result).toEqual(Cl.ok(Cl.stringAscii("Honeycomb")));
  });

  it("prevents unauthorized minting", () => {
    const mintResponse = simnet.callPublicFn(
      "luckyhive-honeycomb",
      "mint",
      [
        Cl.uint(1000),
        Cl.principal(wallet1)
      ],
      wallet1
    );
    // Should fail with ERR-NOT-AUTHORIZED (u1000)
    expect(mintResponse.result).toEqual(Cl.error(Cl.uint(1000)));
  });
});
