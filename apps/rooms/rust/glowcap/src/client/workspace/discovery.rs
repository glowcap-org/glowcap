//! A bounded directory reader over its original managed workspace source.
use super::*;
use rooms_application::directory;

pub struct DirectoryReader<D> {
	caller: Caller<D>,
	reference: Ref,
}
impl<D: Deadline + Clone> Workspace<D> {
	/// Request fresh directory snapshots after an activity gap. The owner retires
	/// and drains existing discovery observers; membership admission is preserved.
	pub async fn resynchronize_discovery(&self) -> Result<(), Error> {
		let reply = self
			.caller
			.call(
				&self.reference,
				"resynchronize-discovery",
				&[],
				"discovery resynchronization did not answer",
			)
			.await?;
		if reply != Argument::Void {
			return Err(loam::refusal("invalid discovery resynchronization acknowledgment").into());
		}
		Ok(())
	}
	pub async fn check_discovery(&self, selected: &workspace::DiscoverySelection) -> Result<(), Error> {
		let encoded = serde_json::to_string(selected).map_err(|_| loam::refusal("invalid discovery selection"))?;
		let reply = self
			.caller
			.call(
				&self.reference,
				"check-discovery",
				&[encoded.into()],
				"discovery admission did not answer",
			)
			.await?;
		if reply != Argument::Void {
			return Err(loam::refusal("invalid discovery admission acknowledgment").into());
		}
		Ok(())
	}
	pub async fn directory_reader(&self, id: &str) -> Result<DirectoryReader<D>, Error> {
		if !rooms_application::fields::Text::<1024, true>::accepts_utf16(id.encode_utf16()) {
			return Err(loam::refusal("invalid directory row identity").into());
		}
		let reference = self.reader("directory-reader", &[id.into()]).await?;
		Ok(DirectoryReader {
			caller: self.caller.clone(),
			reference,
		})
	}
}
impl<D: Deadline> DirectoryReader<D> {
	/// Resolve public names, including dormant managed rooms. The ordinary list
	/// describes occupancy and cannot prove a durable name is unclaimed.
	pub async fn named_rooms(&self, name: &str) -> Result<Vec<directory::RoomInfo>, Error> {
		if !rooms_application::fields::Text::<32, true>::accepts_utf16(name.encode_utf16()) {
			return Err(loam::refusal("invalid public room name").into());
		}
		let reply = self.call(directory::LIST, &[name.into()]).await?;
		Ok(directory::rooms(&crate::Value(&reply))?)
	}
	pub async fn list(&self) -> Result<Vec<directory::RoomInfo>, Error> {
		let reply = self.call(directory::LIST, &[]).await?;
		Ok(directory::rooms(&crate::Value(&reply))?)
	}
	pub async fn advertised_location(&self) -> Result<String, Error> {
		let reply = self.call(directory::creation::LOCATION, &[]).await?;
		let Argument::String(location) = reply else {
			return Err(directory::Error::Location.into());
		};
		if location.is_empty() || location.len() > 16384 {
			return Err(directory::Error::Location.into());
		}
		// The directory protocol advertises a TCP designator to baseline
		// callers and a full locator URI for other transports.
		crate::routes::Address::directory(&location)
			.map_err(Error::Binding)?
			.ok_or(directory::Error::Location)?;
		Ok(location)
	}
	pub async fn member_registration(&self, peer: &str) -> Result<directory::registration::Id, Error> {
		if !rooms_application::room::inbox::valid_nick(peer) {
			return Err(directory::registration::Error::Peer.into());
		}
		let reply = self.call(directory::registration::MEMBER, &[peer.into()]).await?;
		Ok(directory::registration::Id::parse(reply.as_str().unwrap_or(""))?)
	}
	async fn call(&self, verb: &'static str, args: &[Argument]) -> Result<Argument, Error> {
		self.caller
			.call(&self.reference, verb, args, "the directory reader did not answer")
			.await
	}
}
