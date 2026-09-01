// The session UI: router, shell, overlays. The boot graph does not import
// this module, so the opening screen and a first-time session choice do not
// download the conversation. `main.tsx` starts this import as soon as it
// knows a session exists, beside the connect, so the splash covers both.

import { ErrorBoundary } from "./ErrorBoundary.tsx";
import { CapabilitySetProvider } from "./settings/CapabilitySetModel.tsx";
import { CommitmentPrompt, CommitmentProvider } from "./commitment.tsx";
import { RoomsSessionProvider } from "./controller/session.ts";
import { bindRoomsRouting, RoomsRouter } from "./router.tsx";
import type { RoomsSessionController } from "./controller/session.ts";
import type { RoomsPageContext } from "./page.ts";

export function bindEstablishedRouting(page: RoomsPageContext): void {
	bindRoomsRouting(page);
}

export function EstablishedSession({ session }: { session: RoomsSessionController }) {
	return (
		<RoomsSessionProvider value={session}>
			<CommitmentProvider>
				<CapabilitySetProvider>
					<ErrorBoundary part="page">
						<RoomsRouter />
					</ErrorBoundary>
				</CapabilitySetProvider>
				<CommitmentPrompt />
			</CommitmentProvider>
		</RoomsSessionProvider>
	);
}
