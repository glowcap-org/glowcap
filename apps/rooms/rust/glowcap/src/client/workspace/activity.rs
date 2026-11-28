//! Session presentation retains its original callback authority on the owner.
//! Cursors select retained data only. Files are dependent read capabilities.
use super::{Acquisition, Caller, Deadline, Error, Workspace};
use glowcap::{Argument, Ref, loam};
use rooms_application::content::session::continuing::Method;
use rooms_application::content::session::{custody, workspace::Intent};

pub struct ActivityReader<D> {
	caller: Caller<D>,
	reference: Ref,
}
impl<D: Deadline> ActivityReader<D> {
	/// An empty cursor requests the initial backlog. Gap and unavailable replies
	/// require the consumer to invalidate cached presentation and resynchronize.
	pub async fn read(&self, cursor: &str, wait: bool) -> Result<String, Error> {
		if cursor.len() > 103 {
			return Err(loam::refusal("invalid activity cursor").into());
		}
		let reply = self
			.caller
			.call(
				&self.reference,
				"read",
				&[cursor.into(), wait.into()],
				"the activity reader did not answer",
			)
			.await?;
		match reply {
			Argument::String(data) => Ok(data),
			_ => Err(loam::refusal("invalid activity projection").into()),
		}
	}
}
impl<D: Deadline + Clone> Workspace<D> {
	pub async fn check_outgoing_line(&self, line: custody::FieldKey<custody::Line>) -> Result<(), Error> {
		let selected = serde_json::to_string(&line).map_err(|_| loam::refusal("invalid outgoing line coordinate"))?;
		match self.call("check-outgoing-line", &[selected.into()]).await? {
			Argument::Void => Ok(()),
			_ => Err(loam::refusal("invalid outgoing line admission").into()),
		}
	}
	pub async fn activity_reader(&self) -> Result<ActivityReader<D>, Error> {
		Ok(ActivityReader {
			caller: self.caller.clone(),
			reference: self.reader("activity-reader", &[]).await?,
		})
	}
	pub async fn activity_file(&self, token: &str, index: usize) -> Result<Ref, Error> {
		let index = i64::try_from(index).map_err(|_| loam::refusal("invalid activity file index"))?;
		self.reader("activity-file", &[token.into(), index.into()]).await
	}
	/// Reserve one immutable mutation identity before the gesture is submitted.
	/// The owner resolves the incoming occurrence privately and receipts replay
	/// the acquisition even after that occurrence expires from presentation.
	pub async fn prepare_activity_acquisition(
		&self,
		token: &str,
		destination: custody::Coordinate,
		source: Option<custody::Coordinate>,
		expected: u64,
		releases: &[custody::Coordinate],
		intent: &Intent,
	) -> Result<Acquisition<D>, Error> {
		self.activity_acquisition(None, token, (destination, source), expected, releases, intent)
			.await
	}

	/// The local operator's policy accepts one direct room offer on its original
	/// participating grant. Only the owner holds the private witness.
	pub async fn prepare_room_invitation(
		&self,
		owner: &Ref,
		directory: &Ref,
		token: &str,
		offer: &rooms_application::content::session::workspace::RoomInvitation,
		expected: u64,
		intent: &Intent,
	) -> Result<Acquisition<D>, Error> {
		let fields = (
			custody::Coordinate::new(custody::Role::RoomAccess, offer.access),
			Some(custody::Coordinate::new(custody::Role::SessionAccess, offer.source)),
		);
		self.activity_acquisition(Some((owner, directory)), token, fields, expected, &[], intent)
			.await
	}

	async fn invitation_call(
		&self,
		owner: Option<&Ref>,
		method: Method,
		args: Vec<Argument>,
	) -> Result<Argument, Error> {
		if let Some(owner) = owner {
			let mut request = vec![owner.clone().into(), method.wire().into()];
			request.extend(args);
			self.call("continue-workspace", &request).await
		} else {
			self.call(method.verb(), &args).await
		}
	}

	async fn activity_acquisition(
		&self,
		owner: Option<(&Ref, &Ref)>,
		token: &str,
		fields: (custody::Coordinate, Option<custody::Coordinate>),
		expected: u64,
		releases: &[custody::Coordinate],
		intent: &Intent,
	) -> Result<Acquisition<D>, Error> {
		let (destination, source) = fields;
		if token.len() > 103 {
			return Err(loam::refusal("invalid activity token").into());
		}
		let offered = self
			.invitation_call(owner.map(|(w, _)| w), Method::RoomInvitationRecipe, vec![token.into()])
			.await?;
		let acquired = match offered {
			Argument::Void => Argument::Void,
			Argument::String(uri) => {
				if uri.len() > loam::ReferenceRequest::MAX_URI_BYTES {
					return Err(loam::refusal("incoming recipe exceeds its bound").into());
				}
				glowcap::parse_sturdyref(&uri, glowcap::CaptpVersion::V1_0)?;
				let host = self.caller.host();
				self.caller
					.platform()
					.within(
						rooms_application::room::authority::REQUEST_TIMEOUT_MS,
						host.enliven(&uri),
					)
					.await
					.ok_or(Error::Timeout("the offered capability did not answer"))??
					.into()
			}
			_ => return Err(loam::refusal("invalid incoming recipe").into()),
		};
		if !matches!(acquired, Argument::Void) {
			self.invitation_call(
				owner.map(|(w, _)| w),
				Method::RetainRoomInvitation,
				vec![token.into(), acquired],
			)
			.await?;
		}

		let [expected, releases, intent] = super::acquisition::candidate_arguments(expected, releases, intent)?;
		let source = source
			.map(super::acquisition::coordinate)
			.transpose()?
			.unwrap_or(Argument::Void);
		let mut args = if let Some((owner, directory)) = owner {
			vec![
				owner.clone().into(),
				Method::AcceptRoomInvitation.wire().into(),
				directory.clone().into(),
			]
		} else {
			vec![
				i64::from(self.mutation_sequence().await?).into(),
				"acquire-activity".into(),
			]
		};
		args.extend([
			token.into(),
			super::acquisition::coordinate(destination)?,
			source,
			expected,
			releases,
			intent,
		]);
		Ok(Acquisition::prepared(
			self.caller.clone(),
			self.reference.clone(),
			args,
			if owner.is_some() {
				"continue-workspace"
			} else {
				"mutate"
			},
		))
	}
}
