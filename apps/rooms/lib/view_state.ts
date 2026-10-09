// Browser preferences carry presentation choices and no session authority.
import * as z from "zod/mini";
import { OPERATIONS_CAPABILITIES, type OperationsCapability } from "./boot_caps.ts";

export const RoomsViewStateSchema = z.strictObject({
	theme: z.enum(["light", "dark"]),
	notifyOn: z.boolean(),
	railOpen: z.boolean(),
	rosterOpen: z.boolean(),
	settingsTab: z.enum(["session", "holdings", "reachability"]),
	opsPane: z.custom<OperationsCapability>((value) => (OPERATIONS_CAPABILITIES as readonly unknown[]).includes(value)),
	remembered: z.strictObject({ room: z.string(), locator: z.string(), nick: z.string() }),
});
export type RoomsViewState = z.infer<typeof RoomsViewStateSchema>;
export type RoomsSettingsTab = RoomsViewState["settingsTab"];

export const DEFAULT_ROOMS_VIEW_STATE: RoomsViewState = {
	// Syrup is the first-visit face. A missing preference preserves that face.
	theme: "dark",
	notifyOn: false,
	railOpen: true,
	rosterOpen: true,
	settingsTab: "session",
	opsPane: "listeners",
	remembered: { room: "", locator: "", nick: "" },
};

export function parseRoomsViewState(value: unknown): RoomsViewState {
	const parsed = z.safeParse(RoomsViewStateSchema, value);
	if (!parsed.success) throw new Error("Invalid browser view preferences");
	return parsed.data;
}
