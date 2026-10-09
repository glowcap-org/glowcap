// Drive the exported application against its actual per-tab IndexedDB owner.
// Both phases run in different documents, with no fixture restoring authority.
export async function managedApplication(binding, tab, reopening) {
	const app = new binding.RoomsManagedApplication(tab, () => {});
	const workspace = await app.workspace();
	const management = await app.management();
	const held = [workspace, management];
	async function lifecycle(control, verb, revision) {
		const method = { pause: "preparePause", resume: "prepareResume", revoke: "prepareRevoke" }[verb];
		const request = await control[method](revision);
		held.push(request);
		await request.submit();
		return request;
	}

	try {
		const snapshot = await workspace.snapshot();
		if (typeof snapshot.revision !== "string") throw new Error("workspace revision lost precision");
		if (reopening) {
			const rows = await workspace.effects();
			if (rows.length !== 1 || rows[0].operation !== "standing" || rows[0].status !== "committed" || rows[0].resumable) {
				throw new Error("cold receipt inventory lost its exact original endpoint");
			}
			const recovered = await workspace.recoverEffect("standing");
			held.push(recovered);
			if (await recovered.status() !== "committed" || await recovered.result() !== null || await recovered.resume() !== "committed") {
				throw new Error("cold effect recovery changed the committed result");
			}
			const acquire = await recovered.prepareResultAcquisition(snapshot.revision, "[]", "[]", JSON.stringify(snapshot.intent));
			held.push(acquire);
			await acquire.submit();
			const adopted = await workspace.snapshot();
			if (JSON.stringify(adopted.intent) !== JSON.stringify(snapshot.intent)) {
				throw new Error("cold result acquisition changed workspace intent");
			}
			// First adoption records the receipt's consumed result atomically.
			// Replaying that adoption must perform no further workspace write.
			await acquire.submit();
			if ((await workspace.snapshot()).revision !== adopted.revision) throw new Error("cold result replay changed workspace intent");
		}
		if (!reopening) {
			const registering = await workspace.prepareObservation();
			held.push(registering);
			const observation = await registering.submit();
			held.push(observation);
			const first = await observation.poll();
			if (
				!(first.cursor instanceof Uint8Array) || first.cursor.length !== 56 || first.source.status !== "active"
			) {
				throw new Error("managed observation lost its exact cursor or source");
			}
			const receiving = observation.receive(first.cursor);
			const command = await workspace.prepareCommand("standing", snapshot.revision, "setStanding", [
				"Loam application",
			]);
			held.push(command);
			if (await command.submit() !== "committed" || await command.submit() !== "committed") {
				throw new Error("local command did not recover its committed receipt");
			}
			if (await command.status() !== "committed" || await command.result() !== null) {
				throw new Error("local command receipt differs from its result");
			}
			const changed = await receiving;
			if (!changed.changed || !changed.notices.target) {
				throw new Error("workspace commit did not wake its held observation");
			}
			await observation.cancel();
			await observation.cancel();
			const rights = ["observeWorkspace"];
			const powers = {
				inspect: true,
				pause: true,
				resume: true,
				revoke: true,
				delegateControl: false,
				editCeiling: rights,
				issueCeiling: null,
			};
			const issuing = await management.prepareIssue(
				(await management.inspect()).revision,
				JSON.stringify({ ceiling: rights, configured: rights }),
				"Saved observer",
				false,
				0,
				JSON.stringify(powers),
			);
			held.push(issuing);
			const issued = await issuing.submitOutcome();
			if (issued.status !== "committed") throw new Error(`issuance did not commit: ${JSON.stringify(issued)}`);
			const { access: use, control } = issued;
			held.push(use, control);
			const label = await control.prepareLabel((await control.inspect()).revision, "Saved observer renamed");
			held.push(label);
			await label.submit();
			await label.submit();
			if ((await control.inspect()).label !== "Saved observer renamed") {
				throw new Error("exact label edit did not replay");
			}
			const page = await management.inventory();
			// Inventory describes descendants. The held grant itself is inspected
			// separately and must not appear as its own child.
			if (
				!Array.isArray(page.rows) || page.rows.length !== 1 ||
				page.rows[0].label !== "Saved observer renamed" || page.cursor !== null
			) {
				throw new Error("managed inventory lost its bounded cursor or rows");
			}
			let malformed = false;
			try {
				await management.inventory(new Uint8Array(50));
			} catch {
				malformed = true;
			}
			if (!malformed) throw new Error("inventory copied an invalid cursor");
			const inspectionOnly = {
				inspect: true,
				pause: false,
				resume: false,
				revoke: false,
				delegateControl: false,
				editCeiling: null,
				issueCeiling: null,
			};
			const attenuation = await management.prepareAttenuation(JSON.stringify(inspectionOnly));
			held.push(attenuation);
			const narrow = await attenuation.submit();
			held.push(narrow);
			await narrow.inspect();
			const effective = await narrow.inspectEffective();
			if (effective.status !== "active" || !effective.effective.permissions.includes("observeWorkspace")) {
				throw new Error("inspection-only control lost effective resource access");
			}
			let widened = false;
			try {
				await lifecycle(narrow, "pause", (await narrow.inspect()).revision);
			} catch {
				widened = true;
			}
			if (!widened) throw new Error("control attenuation retained absent powers");
			const saving = await workspace.prepareSaveAccess("observer", use, control);
			held.push(saving);
			await saving.submit();
			await saving.submit();
			const saveControl = await workspace.prepareSaveControl("inspector", narrow);
			held.push(saveControl);
			await saveControl.submit();
			await saveControl.submit();
			const saveUse = await workspace.prepareSaveWorkspace("observer-use", use);
			held.push(saveUse);
			await saveUse.submit();
			await saveUse.submit();
			await lifecycle(control, "pause", (await control.inspect()).revision);
			const inspected = await control.inspect();
			if ((await control.inspectEffective()).status !== "paused") {
				throw new Error("effective inspection revived paused use");
			}
			if (inspected.status !== "paused" || inspected.configured.permissions.join() !== "observeWorkspace") {
				throw new Error("paused inspection lost configured authority");
			}
			let refused = false;
			try {
				await use.snapshot();
			} catch {
				refused = true;
			}
			if (!refused) throw new Error("paused use remained active");
			// Copies of immutable snapshots and every prepared handle stay under
			// separate count/byte budgets, including after their Promise resolves.
			const pressure = [];
			try {
				for (let at = 0; at < 80; at++) pressure.push(await app.workspace());
			} catch (error) {
				if (!error.message.includes("retained handle capacity")) throw error;
			}
			if (pressure.length >= 80) throw new Error("returned handles have no lifetime budget");
			for (const handle of pressure) handle.free();
			const recovered = await app.workspace();
			recovered.free();
		} else {
			if (snapshot.intent.standing !== "Loam application" || snapshot.intent.accesses.length !== 3) {
				throw new Error("application lost workspace or control selection on full reload");
			}
			const inspector = await app.savedControl("inspector");
			held.push(inspector);
			const inspectorState = await inspector.describe();
			if ((await inspector.inspectEffective()).status !== "active") {
				throw new Error("cold inspection-only control lost its effective view");
			}
			if (
				!inspectorState.available || !inspectorState.inspect || inspectorState.pause ||
				inspectorState.issueCeiling !== null || inspectorState.editCeiling !== null
			) {
				throw new Error("standalone control was substituted or widened on reload");
			}
			let substituted = false;
			try {
				const missing = await app.savedWorkspace("inspector");
				missing.free();
				substituted = true;
			} catch { /* absent use stays absent */ }
			if (substituted) throw new Error("control-only row acquired workspace use");
			try {
				const missing = await app.savedControl("observer-use");
				missing.free();
				substituted = true;
			} catch { /* absent control stays absent */ }
			if (substituted) throw new Error("use-only row acquired a management control");
			const standaloneUse = await app.savedWorkspace("observer-use");
			held.push(standaloneUse);
			let standaloneRefused = false;
			try {
				await standaloneUse.snapshot();
			} catch {
				standaloneRefused = true;
			}
			if (!standaloneRefused) throw new Error("standalone use lost its exact paused grant");
			const use = await app.savedWorkspace("observer");
			const control = await app.savedControl("observer");
			held.push(use, control);
			const inspected = await control.inspect();
			if (inspected.label !== "Saved observer renamed" || inspected.status !== "paused") {
				throw new Error("saved control was reissued or widened on reload");
			}
			let refused = false;
			try {
				await use.snapshot();
			} catch {
				refused = true;
			}
			if (!refused) throw new Error("reload revived paused use");
			await lifecycle(control, "resume", inspected.revision);
			await use.snapshot();
			await standaloneUse.snapshot();
			const stale = await control.preparePolicy((await control.inspect()).revision, "[]");
			held.push(stale);
			await lifecycle(control, "pause", (await control.inspect()).revision);
			const conflict = await stale.submitOutcome();
			if (conflict.status !== "conflict") {
				throw new Error(`a retained stale edit did not report its exact revision conflict: ${JSON.stringify(conflict)}`);
			}
			const oldRevision = inspected.revision;
			const staleRevision = await control.preparePolicy(oldRevision, "[]");
			held.push(staleRevision);
			const revisionConflict = await staleRevision.submitOutcome();
			if (revisionConflict.status !== "conflict" || !revisionConflict.reason.includes("RevisionConflict")) {
				throw new Error(`a stale expected revision did not retain its conflict: ${JSON.stringify(revisionConflict)}`);
			}
			await lifecycle(control, "resume", (await control.inspect()).revision);
			const home = JSON.parse(binding.inspectCapability(await app.publish())).authority;
			const useLink = await use.publish();
			const controlLink = await control.publish();
			if (useLink === controlLink || [useLink, controlLink].some((link) =>
				JSON.parse(binding.inspectCapability(link)).authority !== home)) {
				throw new Error("cold local publication lost its original owner or endpoint role");
			}
			if (await use.publish() !== useLink || await control.publish() !== controlLink) {
				throw new Error("cold local publication did not retain its exact endpoint");
			}
			const publishedUse = await app.attachWorkspace(useLink);
			const publishedControl = await app.attachControl(controlLink);
			held.push(publishedUse, publishedControl);
			if (JSON.stringify((await publishedUse.snapshot()).intent) !== JSON.stringify(snapshot.intent) ||
				(await publishedControl.inspect()).label !== "Saved observer renamed") {
				throw new Error("cold local publication selected replacement authority");
			}
			await lifecycle(control, "revoke", (await control.inspect()).revision);
			refused = false;
			try {
				await use.snapshot();
			} catch {
				refused = true;
			}
			if (!refused) throw new Error("revoked use remained active");
			const state = await control.describe();
			if (state.available) throw new Error("revoked management remained available");
		}
		for (const handle of held.splice(0).reverse()) handle.free();
		if (!reopening) {
			const original = IDBDatabase.prototype.close;
			let refused = false;
			IDBDatabase.prototype.close = function () {
				if (this.name === `rooms-session-${tab}` && !refused) {
					refused = true;
					IDBDatabase.prototype.close = original;
					throw new Error("injected managed database close refusal");
				}
				return original.call(this);
			};
			try {
				let observed = false;
				try {
					await Promise.race([
						app.close(),
						new Promise((_, reject) => setTimeout(() => reject(new Error("managed close stalled")), 5000)),
					]);
				} catch (error) {
					if (!error.message.includes("injected managed database close refusal")) throw error;
					observed = true;
				}
				if (!refused || !observed) throw new Error("managed close refusal was not observed");
				await Promise.all([app.close(), app.close()]);
			} finally {
				IDBDatabase.prototype.close = original;
			}
		}
	} finally {
		for (const handle of held.reverse()) handle.free();
		await app.close();
		app.free();
	}
}
