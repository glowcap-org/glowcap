// Imperative routing for the browser controller, without pulling the session
// shell into the boot graph.
//
// `main.tsx` builds the controller before a session exists. The address mirror
// and the router live in the established chunk, which installs these functions
// when it loads. Until then a navigate is a programming error: SessionSetup
// never changes the address, it reloads.

let navigate = (path: string): void => {
	throw new Error(`rooms: navigation before the session UI is established (${path})`);
};
let address = (): string => "/";

export function installRouting(next: { navigateTo: (path: string) => void; addressOfActive: () => string }): void {
	navigate = next.navigateTo;
	address = next.addressOfActive;
}

export function navigateTo(path: string): void {
	navigate(path);
}

export function addressOfActive(): string {
	return address();
}
