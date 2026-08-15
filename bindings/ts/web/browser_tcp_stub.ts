import { INVALID_ARGUMENT } from "@pancake/abi";
import type { DriverLoop } from "@pancake/runtime/transport";
import { PancakeError } from "@pancake/runtime";

/** Browser product boundary for the native-only TCP provider package. */
export function installProvider(_loop: DriverLoop): never {
	throw new PancakeError(INVALID_ARGUMENT, "the browser runtime has no native TCP provider");
}
