//! One preparation plan restores exact workspace custody before invocation.
use super::*;

impl<P: Tasks + Deadline + Clone + 'static> SessionContent<P> {
	pub(super) fn reference_requests(&self, input: Invocation<'_>) -> Result<Vec<ReferenceRequest>> {
		if input.verb == "restore-custody" {
			return super::super::retained::references(input, &self.owner(input.verb)?.writer.root()?);
		}
		if matches!(
			input.verb,
			"file-reader"
				| "resource-key"
				| "bridge-witnesses"
				| "activity-reader"
				| "activity-file"
				| "resynchronize-discovery"
		) {
			return Ok(Vec::new());
		}
		input.graph.ok_or_else(|| refuse("session graph is not prepared"))?;
		let metadata = if input.verb == "initialize" {
			None
		} else {
			Some(records::metadata(input)?)
		};
		let selected = metadata.as_ref().and_then(|record| {
			input.args.first().and_then(Argument::as_str).and_then(|id| {
				record
					.effects
					.as_slice()
					.iter()
					.find(|receipt| receipt.operation.text().as_str() == Some(id))
			})
		});
		let mut requests: Vec<_> = match input.verb {
			"retire-room-authority" => {
				authority::requirement(input, &self.owner(input.verb)?.writer.root()?)?;
				authority::references(input, metadata.as_ref().expect("initialized record"))?
			}
			"record-inbox" => {
				recording::authorize(input, &self.owner(input.verb)?.writer.root()?)?;
				let record = metadata.as_ref().expect("initialized record");
				inbox::references(recording::callback(input)?, record)?
			}
			"acquire-activity" | "activity-recipe" | "retain-incoming" => activity::references(
				&self.owner(input.verb)?,
				input,
				metadata.as_ref().expect("initialized record"),
			)?,
			"typing-sender" => presence::references(input, metadata.as_ref().expect("initialized record"))?,
			"signaling-route" => signaling::references(input, metadata.as_ref().expect("initialized record"))?,
			"directory-reader" => discovery::references(input, metadata.as_ref().expect("initialized record"))?,
			"check-discovery" => {
				discovery::admission_references(input, metadata.as_ref().expect("initialized record"))?
			}
			"sendFiles" | "refileLine" => uploads::references(input, metadata.as_ref().expect("initialized record"))?,
			"submit-bridge" | "bridge-reapplication" => {
				bridge::references(input, metadata.as_ref().expect("initialized record"))?
			}
			"archive-reader"
			| "history-reader"
			| "bridge-form-reader"
			| "workspace-history-reader"
			| "custody-recipe"
			| "export-configuration"
			| "archive-issuer-reader"
			| "operations-reader"
			| "trace-snapshot"
			| "room-identity-reader"
			| "room-publication-identity" => reads::references(input, metadata.as_ref().expect("initialized record"))?,
			"observe-archive-connection" => {
				archive_connection::references(metadata.as_ref().expect("initialized record"))?
			}
			"observe-direct-connection" => {
				connection::references(input, metadata.as_ref().expect("initialized record"))?
			}
			"check-inbox" => inbox::references(input, metadata.as_ref().expect("initialized record"))?,
			"check-outgoing-line" => outgoing_line::references(input, metadata.as_ref().expect("initialized record"))?,
			"accept-direct-introduction" | "adopt-direct-route" => {
				introduction::references(input, metadata.as_ref().expect("initialized record"))?
			}
			"snapshot"
			| "discovery-selected"
			| "signaling-selected"
			| "initialize"
			| "retire-host-registrations"
			| "replaceWorkspace"
			| "release"
			| "forget-bridge"
			| "settle-history-erasure"
			| "retention-intent" => Vec::new(),
			"import" | "import-bundle" | "acquire-workspace" => {
				acquisition::references(input, metadata.as_ref().expect("initialized record"))?
			}
			"effect-status" | "effect-result" | "effect-reader" | "settle-effect" => {
				let receipt = selected.ok_or_else(|| refuse("unknown effect"))?;
				vec![restore_source(receipt)?]
			}
			"effect-intent" | "release-effect" => selected.map(restore_source).transpose()?.into_iter().collect(),
			"effect-adopted" | "resume-effect" => {
				vec![restore_source(selected.ok_or_else(|| refuse("unknown effect"))?)?]
			}
			"effect-inventory" => metadata
				.as_ref()
				.expect("initialized record")
				.effects
				.as_slice()
				.iter()
				.map(restore_source)
				.collect::<Result<_>>()?,
			"import-result" | "acquire-result-workspace" | "acquire-created-room" => {
				imports::references(input, metadata.as_ref().expect("initialized record"))?
			}
			"command" if selected.is_some() => vec![restore_source(selected.expect("selected receipt"))?],
			"command" => {
				let record = metadata.as_ref().expect("initialized record");
				let declared = values(input.args);
				let request = Request::parse(&declared).map_err(|error| loam::refusal(error.to_string()))?;
				if local::recognizes(request.route()) {
					return Ok(Vec::new());
				}
				if super::super::archive_sharing::recognizes(request.route()) {
					return super::super::archive_sharing::references(input, record);
				}
				let dispatch = dispatch(input.args)?;
				let revocation = dispatch.revokes_selected();
				let targets = dispatch
					.targets(&record.intent)
					.map_err(|_| refuse("effect target is not selected in this workspace"))?;
				let outgoing = super::super::outgoing::references(record, targets[0])?;
				let mut restored = targets
					.into_iter()
					.enumerate()
					.map(|(index, coordinate)| {
						let target = record
							.custody
							.get(coordinate)
							.ok_or_else(|| refuse("effect target custody is absent"))?;
						let location = records::location(&target);
						let page = location
							.page
							.checked_sub(1)
							.ok_or_else(|| refuse("invalid effect target page"))?;
						Ok(if revocation && index == 1 {
							ReferenceRequest::RestorePageWithUri {
								page,
								field: location.field,
							}
						} else {
							ReferenceRequest::RestorePage {
								page,
								field: location.field,
							}
						})
					})
					.collect::<Result<Vec<_>>>()?;
				restored.extend(outgoing);
				restored
			}
			_ => return Err(refuse("unknown session method")),
		};
		if matches!(input.verb, "effect-result" | "settle-effect") {
			let receipt = selected.ok_or_else(|| refuse("unknown effect"))?;
			requests.extend(results::result_requests(&receipt.outcome)?);
		}
		if input.verb == "settle-effect" {
			let [_, source, _, outcome, _] = input.args else {
				return Err(refuse("invalid private settlement"));
			};
			let source = Ref::try_from(source).map_err(|_| refuse("original source required"))?;
			let committed = matches!(selected.expect("selected receipt").outcome, Outcome::Committed { .. });
			requests.extend(results::saves(outcome, &source, committed)?);
		}
		let restores = requests
			.iter()
			.filter(|request| {
				matches!(
					request,
					ReferenceRequest::Restore(_)
						| ReferenceRequest::RestorePage { .. }
						| ReferenceRequest::RestorePageWithUri { .. }
						| ReferenceRequest::InspectPageUri { .. }
				)
			})
			.count();
		if restores > super::super::profile::MAX_RESTORES
			|| requests.len() - restores > session::records::FIELDS_PER_PAGE
		{
			return Err(refuse("reference preparation exceeds the session profile"));
		}
		Ok(requests)
	}
}
