import { describe, expect, it } from "vitest";
import { initSimnet } from "@stacks/clarinet-sdk";

const simnet = await initSimnet();

const accounts = simnet.getAccounts();
const deployer = accounts.get("deployer")!;
const wallet1 = accounts.get("wallet_1")!;

describe("honeycomb token tests", () => {
  it("ensures token metadata is correct", () => {
    const symbolResponse = simnet.callReadOnlyFn(
      "honeycomb-token",
      "get-symbol",
      [],
      wallet1
    );
    expect(symbolResponse.result).toBeAscii("HNY");

    const nameResponse = simnet.callReadOnlyFn(
      "honeycomb-token",
      "get-name",
      [],
      wallet1
    );
    expect(nameResponse.result).toBeAscii("Honeycomb Receipt Token");
  });

  it("prevents unauthorized minting", () => {
    const mintResponse = simnet.callPublicFn(
      "honeycomb-token",
      "mint",
      [
        simnet.valueToClarityValue("u1000", "uint"),
        simnet.valueToClarityValue(`'${wallet1}`, "principal")
      ],
      wallet1
    );
    // Should fail with ERR-NOT-AUTHORIZED (u1000)
    expect(mintResponse.result).toBeErr(simnet.valueToClarityValue("u1000", "uint"));
  });
});
