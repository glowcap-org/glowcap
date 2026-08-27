// The operator capabilities a rooms server can mint at boot, as one table.
//
// Each capability is one fact with several faces: the flag that asks for it,
// the flag's env twin, the state file its swiss persists in, the token line
// an operator greps for, and the label the serving block prints. The room
// server mints and publishes; its web supervisor forwards the flags and
// re-reads the persisted swiss numbers. Both read this table, so a new
// capability is one row here plus its publish arm — never two lists that
// drift. The rows sit in the order the boot output prints them:
// alphabetical, so an operator scanning the block finds a line by name.

export interface BootCapDef {
	/** Stable state-bundle and UI identifier. */
	id: OperationsCapability;
	/** The argv flag that asks for it, e.g. `--diagnostics`. */
	flag: string;
	/** The flag's env twin, set to `1`. */
	env: string;
	/** The file under `PANCAKE_ROOMS_STATE` its swiss persists in. */
	file: string;
	/** The flush-left token line the swiss prints under. */
	token: string;
	/** The label the supervisor's serving block prints. */
	label: string;
}

export type OperationsCapability = "listeners" | "diagnostics" | "irc" | "operator" | "peering" | "viz";

export const BOOT_CAPS = {
	adminListeners: {
		id: "listeners",
		flag: "--admin-listeners",
		env: "PANCAKE_ROOMS_ADMIN_LISTENERS",
		file: "admin-listeners",
		token: "ROOMS-ADMIN-LISTENERS",
		label: "admin-listeners",
	},
	diagnostics: {
		id: "diagnostics",
		flag: "--diagnostics",
		env: "PANCAKE_ROOMS_DIAGNOSTICS",
		file: "diagnostics",
		token: "ROOMS-DIAGNOSTICS",
		label: "diagnostics",
	},
	irc: {
		id: "irc",
		flag: "--irc",
		env: "PANCAKE_ROOMS_IRC",
		file: "irc",
		token: "ROOMS-IRC",
		label: "irc",
	},
	operator: {
		id: "operator",
		flag: "--operator",
		env: "PANCAKE_ROOMS_OPERATOR",
		file: "operator",
		token: "ROOMS-OPERATOR",
		label: "operator",
	},
	peering: {
		id: "peering",
		flag: "--peering",
		env: "PANCAKE_ROOMS_PEERING",
		file: "peering",
		token: "ROOMS-PEERING",
		label: "peering",
	},
	viz: {
		id: "viz",
		flag: "--viz",
		env: "PANCAKE_ROOMS_VIZ",
		file: "viz",
		token: "ROOMS-VIZ",
		label: "viz",
	},
} as const satisfies Record<string, BootCapDef>;

/** Every capability, in print order. */
export const ALL_BOOT_CAPS: readonly BootCapDef[] = Object.values(BOOT_CAPS);

export const OPERATIONS_CAPABILITIES: readonly OperationsCapability[] = ALL_BOOT_CAPS.map((capability) =>
	capability.id
);
