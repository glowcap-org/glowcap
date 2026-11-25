//! Publication follows the established home of a held capability. Derivation
//! preserves that home. The receiving Host never substitutes its own route.
use super::*;
use rooms_runtime::Error as RuntimeError;

/// A held use or control, asked for its publication name over its own route,
/// so a link lost under the question is named as one.
#[derive(Clone)]
enum Published {
	Workspace(Held<Workspace<Platform>>),
	Control(Held<Control<Platform>>),
}
impl Published {
	fn reference(&self) -> &Ref {
		match self {
			Self::Workspace(workspace) => workspace.reference(),
			Self::Control(control) => control.reference(),
		}
	}
	async fn durable_name(&self) -> Result<String> {
		match self {
			Self::Workspace(workspace) => workspace.durable_name().await,
			Self::Control(control) => control.durable_name().await,
		}
		.map_err(RuntimeError::from)
	}
}

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
		glowcap::parse_sturdyref(&uri, glowcap::CaptpVersion::V1_0).map_err(RuntimeError::from)?;
		let bytes = size_of::<String>() + uri.capacity();
		Ok(Self::Remote(driver.hold(uri, bytes)?))
	}
}

/// A held use or control with the home it is published from, which a share
/// and a saved row both read.
#[derive(Clone)]
pub(super) struct Publication {
	held: Published,
	home: PublicationHome,
}
impl Publication {
	pub(super) fn reference(&self) -> &Ref {
		self.held.reference()
	}
	/// The link that redeems the capability at its original home, or none
	/// when this page's own session owns it.
	pub(super) async fn recipe(&self) -> Result<Option<String>> {
		match &self.home {
			PublicationHome::LocalOwner => Ok(None),
			PublicationHome::Remote(uri) => {
				let route = glowcap::parse_sturdyref(uri, glowcap::CaptpVersion::V1_0).map_err(RuntimeError::from)?;
				let name = self.held.durable_name().await?;
				glowcap::format_sturdyref(&route.locator, name.as_bytes(), glowcap::CaptpVersion::V1_0)
					.map(Some)
					.map_err(RuntimeError::from)
			}
		}
	}
	pub(super) fn publish(self, driver: &Driver) -> js_sys::Promise {
		driver.submit(0, move |environment| async move {
			let link = match self.recipe().await? {
				Some(link) => link,
				None => owner(&environment)?.publish(&environment, self.reference()).await?,
			};
			Ok(link.into())
		})
	}
}

impl RoomsManagedWorkspace {
	pub(super) fn publication(&self) -> Publication {
		Publication {
			held: Published::Workspace(self.workspace.clone()),
			home: self.home.clone(),
		}
	}
}
impl RoomsManagedControl {
	pub(super) fn publication(&self) -> Publication {
		Publication {
			held: Published::Control(self.control.clone()),
			home: self.home.clone(),
		}
	}
}

#[wasm_bindgen]
impl RoomsManagedWorkspace {
	/// Share this exact use endpoint, independently of its management control.
	pub fn publish(&self) -> js_sys::Promise {
		self.publication().publish(&self.driver)
	}
}
