import { IO } from "@pancake/abi";
import { driverFailureError } from "../internal/driver_failure.ts";
import { secondaryFailureCount, secondaryFailures } from "../errors.ts";

Deno.test("driver failure projection retains exact primary and counted consequence", () => {
	const error = driverFailureError({
		primaryResult: IO,
		primaryName: "ProviderConfigurationConflict",
		secondaryResult: IO,
		secondaryCount: 3,
		secondaryName: "PackageReleaseFailed",
		carrierFailure: {
			phase: "secureHandshake",
			verificationFlags: 0x21,
			peerAlert: 42,
			engineCode: -0x2700,
		},
	}, "install");
	if (error.detail !== "install failed: ProviderConfigurationConflict") {
		throw new Error(`lost primary identity: ${error.detail}`);
	}
	if (secondaryFailureCount(error) !== 3) throw new Error("lost consequence count");
	const secondary = secondaryFailures(error)[0];
	if (!(secondary instanceof Error) || !secondary.message.includes("PackageReleaseFailed")) {
		throw new Error(`lost first consequence: ${String(secondary)}`);
	}
	if (error.carrierFailure?.phase !== "secureHandshake" || error.carrierFailure.peerAlert !== 42) {
		throw new Error("lost carrier failure detail");
	}
});
