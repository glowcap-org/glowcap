import { INVALID_ARGUMENT } from "@glowcap/abi";
import type { DriverLoop } from "@glowcap/runtime/transport";
import { GlowcapError } from "@glowcap/runtime";

/** Browser product boundary for the native-only TCP provider package. */
export function installProvider(_loop: DriverLoop): never {
	throw new GlowcapError(INVALID_ARGUMENT, "the browser runtime has no native TCP provider");
}
