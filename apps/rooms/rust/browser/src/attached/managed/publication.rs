//! Publication follows the established home of a held capability. Derivation
//! preserves that home. The receiving Host never substitutes its own route.
use super::*;
use rooms_glowcap::client::Deadline;
use std::future::IntoFuture;

#[derive(Clone)]
pub(super) enum PublicationHome {
	LocalOwner,
	Remote(Held<String>),
}
impl PublicationHome {
	pub(super) fn restored(driver: &Driver, uri: Option<String>) -> Result<Self> {
		uri.map_or(Ok(Self::LocalOwner), |uri| Self::remote(driver, uri))
	}
	/// One original URI is retained under Driver's handle/byte budget. Derived
	/// handles share that charge. Parsing is temporary publication scratch. No
	/// grant inventory, alternative authority map or route copy is retained.
	pub(super) fn remote(driver: &Driver, uri: String) -> Result<Self> {
		glowcap::parse_sturdyref(&uri, glowcap::CaptpVersion::V1_0).map_err(|e| e.to_string())?;
		let bytes = size_of::<String>() + uri.capacity();
		Ok(Self::Remote(driver.hold(uri, bytes)?))
	}
	pub(super) async fn recipe(&self, environment: &Environment, reference: &Ref) -> Result<Option<String>> {
		match self {
			Self::LocalOwner => Ok(None),
			Self::Remote(uri) => {
				let route = glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0).map_err(|e| e.to_string())?;
				let reply = environment
					.platform
					.within(
						rooms_application::room::authority::REQUEST_TIMEOUT_MS,
						environment
							.runtime
							.host()
							.send(reference, "durable-name", &[])
							.into_future(),
					)
					.await
					.ok_or("Original owner publication did not answer")?
					.map_err(|e| e.to_string())?;
				let name = reply
					.as_str()
					.filter(|name| !name.is_empty() && name.len() <= 64)
					.ok_or("Original owner returned no publication name")?;
				glowcap::format_sturdyref(&route.locator, name.as_bytes(), glowcap::CaptpVersion::V1_0)
					.map(Some)
					.map_err(|e| e.to_string())
			}
		}
	}
	pub(super) fn publish(&self, driver: &Driver, reference: &Ref) -> js_sys::Promise {
		let reference = reference.clone();
		let home = self.clone();
		driver.submit(0, move |environment| async move {
			let link = match home.recipe(&environment, &reference).await? {
				Some(link) => link,
				None => owner(&environment)?.publish(&environment, &reference).await?,
			};
			Ok(link.into())
		})
	}
}

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	/// Share this exact use endpoint, independently of its management control.
	pub fn publish(&self) -> js_sys::Promise {
		self.home.publish(&self.driver, self.workspace.reference())
	}
}
