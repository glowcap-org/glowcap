// The operator capabilities a Rooms server can mint at boot. Rust owns the
// table and generates its TypeScript mirror in `application_data.ts`; this
// module preserves the client library's focused import surface.

import { ALL_BOOT_CAPS, BOOT_CAPS, OPERATIONS_CAPABILITIES } from "./application_data.ts";

export { ALL_BOOT_CAPS, BOOT_CAPS, OPERATIONS_CAPABILITIES };
export type { OperationsCapability } from "./application_data.ts";
export type BootCapDef = (typeof ALL_BOOT_CAPS)[number];
