// The page supplies its actual managed viewer once, alongside presentation.
import { createContext, useContext } from "react";
import type { ManagedRoomsSession } from "./session.ts";

const Context = createContext<ManagedRoomsSession | null>(null);
export const ManagedSessionProvider = Context.Provider;
export function useManagedSession(): ManagedRoomsSession {
	const session = useContext(Context);
	if (session == null) throw new Error("The managed workspace has not opened");
	return session;
}
