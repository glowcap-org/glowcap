// The page supplies its actual managed viewer once, alongside presentation.
import { invariant } from "../../../../lib/invariant.ts";
import { createContext, useContext } from "react";
import type { ManagedRoomsSession } from "./session.ts";

const Context = createContext<ManagedRoomsSession | null>(null);
export const ManagedSessionProvider = Context.Provider;
export function useManagedSession(): ManagedRoomsSession {
	const session = useContext(Context);
	invariant(session != null, "the managed workspace has not opened");
	return session;
}
