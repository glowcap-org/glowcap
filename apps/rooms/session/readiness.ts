// The operator-visible readiness mirror for one durable Rooms session.

export const SESSION_ADMIN_FILE = "admin.sturdyref";

export function sessionAdminPath(directory: string): string {
	return `${directory}/${SESSION_ADMIN_FILE}`;
}

/** Read the generated document as one copyable bearer token. This is a
 * presentation check, not the protocol parser: the session process authored
 * the sturdyref, while the readiness edge must refuse debris or extra lines. */
export function sessionAdminSturdyref(document: string): string {
	const sturdyref = document.trim();
	if (!/^ocapn:\/\/[\x21-\x7e]+\/s\/[\x21-\x7e]+$/.test(sturdyref)) {
		throw new Error("the administrator readiness file is not one sturdyref");
	}
	return sturdyref;
}
