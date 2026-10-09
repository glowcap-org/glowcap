//! Signaling retains the original source and exact registered name facade.
use super::super::directory::signaling::Route;
use super::*;

impl<D: Deadline + Clone> Workspace<D> {
	pub async fn signaling(&self, selected: &workspace::SignalingSelection) -> Result<Route<D>, Error> {
		let encoded = serde_json::to_string(selected).map_err(|_| loam::refusal("invalid signaling selection"))?;
		let reference = self.reader("signaling-route", &[encoded.into()]).await?;
		Ok(Route::through(self.caller.clone(), reference))
	}
}
