import { createContext, type ReactNode, useCallback, useContext, useMemo, useRef, useState } from "react";

interface OperatorActivity {
	readonly sweeping: boolean;
	beginSweep(): boolean;
	endSweep(): void;
}

const OperatorActivityContext = createContext<OperatorActivity | null>(null);

/** One coordination owner for the operator pane. Search and bulk mutation are
 * different components but act on one server-side filter, so they serialize
 * through this provider rather than module state or DOM disabling guesses. */
export function OperatorActivityProvider({ children }: { children: ReactNode }) {
	const active = useRef(false);
	const [sweeping, setSweeping] = useState(false);
	const beginSweep = useCallback(() => {
		if (active.current) return false;
		active.current = true;
		setSweeping(true);
		return true;
	}, []);
	const endSweep = useCallback(() => {
		active.current = false;
		setSweeping(false);
	}, []);
	const value = useMemo(() => ({ sweeping, beginSweep, endSweep }), [sweeping, beginSweep, endSweep]);
	return <OperatorActivityContext.Provider value={value}>{children}</OperatorActivityContext.Provider>;
}

export function useOperatorActivity(): OperatorActivity {
	const activity = useContext(OperatorActivityContext);
	if (activity === null) throw new Error("operator activity was requested outside its pane");
	return activity;
}
