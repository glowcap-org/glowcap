// Two actual application Hosts share exact issued use and control through the
// production Noise relay. Descriptive grant IDs never reconstruct authority.
export async function managedSharing({ moduleUrl = "/rooms_contract_proofs.js" } = {}) {
	const binding = await import(moduleUrl);
	await binding.default();
	const first = new binding.RoomsManagedApplication(crypto.randomUUID(), () => {});
	const receiverTab = crypto.randomUUID();
	let second = new binding.RoomsManagedApplication(receiverTab, () => {});
	const held = [];
	let failure;
	async function lifecycle(control, verb, revision) {
		const method = { pause: "preparePause", resume: "prepareResume", revoke: "prepareRevoke" }[verb];
		const request = await control[method](revision);
		held.push(request);
		await request.submit();
		return request;
	}

	try {
		const root = await first.management();
		held.push(root);
		const permissions = ["observeWorkspace"];
		const powers = {
			inspect: true,
			pause: true,
			resume: true,
			revoke: true,
			delegateControl: false,
			editCeiling: permissions,
			issueCeiling: null,
		};
		const request = await root.prepareIssue(
			(await root.inspect()).revision,
			JSON.stringify({ ceiling: permissions, configured: permissions }),
			"Shared observer",
			false,
			0,
			JSON.stringify(powers),
		);
		held.push(request);
		const [use, control] = await request.submit();
		held.push(use, control);
		const useLink = await use.publish();
		const controlLink = await control.publish();
		const rootLink = await first.publishManagement();
		if (new Set([useLink, controlLink, rootLink]).size !== 3) {
			throw new Error("issued publication substituted a use endpoint or root control");
		}
		if (await control.publish() !== controlLink || await use.publish() !== useLink) {
			throw new Error("sharing reissued the held branch");
		}
		let remoteUse = await second.attachWorkspace(useLink);
		let remoteControl = await second.attachControl(controlLink);
		held.push(remoteUse, remoteControl);
		await remoteUse.snapshot();
		if ((await remoteControl.inspect()).label !== "Shared observer") {
			throw new Error("shared control attached to another grant");
		}
		if (await remoteUse.publish() !== useLink || await remoteControl.publish() !== controlLink) {
			throw new Error("foreign capability lost its original publication home");
		}
		const localCustody = await second.workspace();
		held.push(localCustody);
		const savingForeign = await localCustody.prepareSaveAccess("foreign", remoteUse, remoteControl);
		held.push(savingForeign);
		await savingForeign.submit();
		await savingForeign.submit();
		const restoredUse = await second.savedWorkspace("foreign");
		const restoredControl = await second.savedControl("foreign");
		held.push(restoredUse, restoredControl);
		await restoredUse.snapshot();
		if ((await restoredControl.inspect()).label !== "Shared observer") throw new Error("saved foreign control changed its exact target");
		if (await restoredUse.publish() !== useLink || await restoredControl.publish() !== controlLink) {
			throw new Error("restored foreign capability lost its canonical publication home");
		}
		await second.close();
		second.free();
		second = new binding.RoomsManagedApplication(receiverTab, () => {});
		remoteUse = await second.savedWorkspace("foreign");
		remoteControl = await second.savedControl("foreign");
		held.push(remoteUse, remoteControl);
		await remoteUse.snapshot();
		if (await remoteUse.publish() !== useLink || await remoteControl.publish() !== controlLink ||
			(await remoteControl.inspect()).label !== "Shared observer") {
			throw new Error("cold foreign restoration changed authority or publication home");
		}
		const inspection = {
			inspect: true,
			pause: false,
			resume: false,
			revoke: false,
			delegateControl: false,
			editCeiling: null,
			issueCeiling: null,
		};
		const narrowing = await root.prepareAttenuation(JSON.stringify(inspection));
		held.push(narrowing);
		const narrow = await narrowing.submit();
		held.push(narrow);
		const narrowLink = await narrow.publish();
		if (narrowLink === rootLink) throw new Error("control sharing widened an attenuated branch");
		const remoteNarrow = await second.attachControl(narrowLink);
		held.push(remoteNarrow);
		const narrowState = await remoteNarrow.describe();
		if (!narrowState.inspect || narrowState.pause || narrowState.delegateControl) {
			throw new Error("shared attenuated control changed its powers");
		}
		const remoteRoot = await second.attachControl(rootLink);
		held.push(remoteRoot);
		const foreignNarrowing = await remoteRoot.prepareAttenuation(JSON.stringify(inspection));
		held.push(foreignNarrowing);
		const foreignNarrow = await foreignNarrowing.submit();
		held.push(foreignNarrow);
		const foreignNarrowLink = await foreignNarrow.publish();
		if (new URL(foreignNarrowLink).host !== new URL(rootLink).host || foreignNarrowLink === rootLink) {
			throw new Error("foreign derivation lost its publication owner or widened its endpoint");
		}
		const foreignIssuing = await remoteRoot.prepareIssue((await remoteRoot.inspect()).revision,
			JSON.stringify({ ceiling: permissions, configured: permissions }), "Issued through remote management", false, 0, JSON.stringify(powers));
		held.push(foreignIssuing);
		const foreignIssued = await foreignIssuing.submitOutcome();
		if (foreignIssued.status !== "committed") throw new Error(`foreign issuance failed: ${JSON.stringify(foreignIssued)}`);
		held.push(foreignIssued.access, foreignIssued.control);
		const foreignIssuedLink = await foreignIssued.access.publish();
		const foreignIssuedControlLink = await foreignIssued.control.publish();
		if (new URL(foreignIssuedLink).host !== new URL(rootLink).host || new URL(foreignIssuedControlLink).host !== new URL(rootLink).host) {
			throw new Error("foreign issuance published at the receiving Host");
		}
		const checkForeignIssued = await second.attachControl(foreignIssuedControlLink);
		held.push(checkForeignIssued);
		if ((await checkForeignIssued.inspect()).label !== "Issued through remote management") throw new Error("foreign issuance changed its target");
		const ownIssued = await first.attachControl(foreignIssuedControlLink);
		held.push(ownIssued);
		if ((await ownIssued.inspect()).label !== "Issued through remote management") throw new Error("own-Host fetch changed the foreign-issued target");
		let refused = false;
		try {
			await lifecycle(remoteNarrow, "pause", (await remoteNarrow.inspect()).revision);
		} catch {
			refused = true;
		}
		if (!refused) throw new Error("shared inspector paused its target");
		const pause = await lifecycle(control, "pause", (await control.inspect()).revision);
		const paused = await remoteControl.inspect();
		if (paused.status !== "paused") throw new Error("shared control lost the pause");
		await pause.submit();
		if ((await control.inspect()).revision !== paused.revision) throw new Error("pause replay changed revision");
		refused = false;
		try {
			await remoteUse.snapshot();
		} catch {
			refused = true;
		}
		if (!refused) throw new Error("shared use ignored the pause");
		const resume = await lifecycle(remoteControl, "resume", paused.revision);
		const resumed = await remoteControl.inspect();
		await resume.submit();
		await pause.submit();
		if ((await control.inspect()).revision !== resumed.revision || (await control.inspect()).status !== "active") {
			throw new Error("old lifecycle replay invoked the target again");
		}
		const stale = await control.preparePause(paused.revision);
		held.push(stale);
		refused = false;
		try { await stale.submit(); } catch { refused = true; }
		if (!refused) throw new Error("fresh lifecycle ignored its expected revision");
		await use.snapshot();
		await remoteUse.snapshot();
		const revoke = await lifecycle(control, "revoke", (await control.inspect()).revision);
		await revoke.submit();
		refused = false;
		try {
			await remoteUse.snapshot();
		} catch {
			refused = true;
		}
		if (!refused || (await remoteControl.describe()).available) {
			throw new Error("shared capabilities survived revocation");
		}
	} catch (error) {
		failure = error;
	} finally {
		for (const handle of held.reverse()) handle.free();
		const results = await Promise.allSettled([second.close(), first.close()]);
		second.free();
		first.free();
		const failed = results.find((result) => result.status === "rejected");
		if (failed) failure = failure ? new AggregateError([failure, failed.reason], "Sharing and cleanup failed") : failed.reason;
	}
	if (failure) throw failure;
}
