//! Pagination effects share the operator slot with snapshots and invalidations.
use super::*;
use rooms_application::server::operations::operator::{
	view::inventory::{Appended, Inventory},
	Category,
};

pub(super) async fn read(session: &super::super::endpoint::Endpoint, ticket: &Read) -> Result<Answer> {
	let scope = ticket
		.scope
		.as_deref()
		.ok_or("The operator capability is not available")?;
	if let Some((category, cursor)) = ticket.page {
		session
			.operator_page(scope, category, cursor, &ticket.filter.search, ticket.filter.reference)
			.await
			.map(Answer::Page)
			.map_err(|error| error.to_string())
	} else {
		session
			.operator_snapshot(scope, &ticket.filter.search, ticket.filter.reference)
			.await
			.map(Answer::Operator)
			.map_err(|error| error.to_string())
	}
}
impl Feed {
	pub(super) fn apply(&self, read: &Read, answer: Answer) -> Result<Option<JsValue>> {
		let mut state = self.state.borrow_mut();
		match answer {
			Answer::View(value) => return Ok(Some(value)),
			Answer::Operator(snapshot) => {
				if read.page.is_some() {
					return Err("Operator page received a snapshot answer".into());
				}
				state.operator = Some(Inventory::new(snapshot)?);
			}
			Answer::Page(page) => {
				let (category, cursor) = read.page.ok_or("Operator snapshot received a page answer")?;
				let inventory = state
					.operator
					.as_mut()
					.ok_or("Operator inventory retired during the page read")?;
				if inventory.append(category, cursor, page)? == Appended::Refresh {
					state.request(read.kind, None)?;
					return Ok(None);
				}
			}
		}
		state.operator.as_ref().map(view::json).transpose()
	}
	pub(super) async fn load_page(&self, category: Category) -> Result<()> {
		if self.listener.borrow().is_none() {
			return Err("Rooms operations view has not started".into());
		}
		let mut replaced = self.replaced.subscribe();
		let _serial = tokio::select! { biased;
			_ = replaced.changed() => return Err("Rooms operations listener retired".into()),
			serial = self.pages.lock() => serial,
		};
		let owner = self.owner.upgrade().ok_or("Rooms operations owner retired")?;
		owner.session()?;
		let kind = Kind::parse("operator").expect("operator inventory");
		let pending = self.state.borrow().pending(kind);
		if let Some(version) = pending {
			self.wait(kind, version, &mut replaced).await?;
		}
		// Observe one admitted refresh, then let shared page admission decide.
		// Continuous invalidations must return a busy refusal, not keep this
		// gesture alive waiting for the whole directory to become quiet.
		let version = self.state.borrow_mut().request_page(category)?;
		if let Some(version) = version {
			self.pump()?;
			self.wait(kind, version, &mut replaced).await?;
		}
		Ok(())
	}
}
#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = loadOperatorPage)]
	pub fn load_operator_page(&self, category: js_sys::JsString) -> js_sys::Promise {
		let bytes = 3 * category.length() as usize;
		let category = match super::super::actions::text(category)
			.and_then(|name| Category::parse(&name).ok_or_else(|| "Unknown operator category".into()))
		{
			Ok(category) => category,
			Err(error) => return super::super::rejected(error),
		};
		let owner = self.owner.clone();
		self.driver.submit(bytes, move |_| async move {
			let generation = owner.scope.generation();
			tokio::select! { biased;
				() = owner.scope.stopped() => return Err("Rooms attachment closed during operator pagination".into()),
				result = owner.operations.load_page(category) => result?,
			}
			owner.scope.current(generation)?;
			Ok(JsValue::UNDEFINED)
		})
	}
}
