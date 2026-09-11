use super::{actions::text, files, scalar, view, RoomsBrowserSession};
use rooms_application::archive::{ConversationKind, Record, ShareKind};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
impl RoomsBrowserSession {
	#[wasm_bindgen(js_name = readHistory)]
	pub fn read_history(
		&self,
		kind: js_sys::JsString,
		directory: js_sys::JsString,
		conversation: js_sys::JsString,
	) -> js_sys::Promise {
		let bytes = 3 * (kind.length() + directory.length() + conversation.length()) as usize;
		let input = (|| {
			let kind = match text(kind)?.as_str() {
				"room" => ConversationKind::Room,
				"direct" => ConversationKind::Direct,
				_ => return Err("Invalid Rooms history kind".into()),
			};
			Ok((kind, text(directory)?, text(conversation)?))
		})();
		self.action(input, bytes, |session, (kind, directory, conversation)| async move {
			let history = session
				.history(kind, &directory, &conversation)
				.await
				.map_err(|e| e.to_string())?;
			view::json(&history.records)
		})
	}
	#[wasm_bindgen(js_name = archivedAttachment)]
	pub fn archived_attachment(&self, record: js_sys::JsString, index: u32) -> js_sys::Promise {
		let bytes = record.length() as usize * 3;
		let scope = self.scope.clone();
		let driver = self.driver.clone();
		self.action(scalar(record, 512 * 1024), bytes, move |session, json| async move {
			let record: Record = serde_json::from_str(&json).map_err(|e| e.to_string())?;
			let file = session
				.archived_attachment(&record, index as usize)
				.await
				.map_err(|e| e.to_string())?;
			Ok(files::hold(&driver, &scope, file)?.into())
		})
	}
	#[wasm_bindgen(js_name = shareArchive)]
	pub fn share_archive(
		&self,
		kind: js_sys::JsString,
		conversation: js_sys::JsString,
		peer: Option<js_sys::JsString>,
		durable: bool,
	) -> js_sys::Promise {
		let bytes = 3
			* (kind.length() as usize
				+ conversation.length() as usize
				+ peer.as_ref().map_or(0, |p| p.length() as usize));
		let input = (|| {
			Ok((
				ShareKind::parse(&text(kind)?).ok_or("Invalid Rooms archive share kind")?,
				text(conversation)?,
				peer.map(text).transpose()?,
			))
		})();
		self.observed_mutation(input, bytes, move |session, (kind, conversation, peer)| async move {
			if durable {
				session
					.offer_durable_archive(kind, &conversation, peer.as_deref())
					.await
			} else {
				session.share_archive(kind, &conversation, peer.as_deref()).await
			}
			.map_err(|e| e.to_string())?;
			Ok(JsValue::UNDEFINED)
		})
	}
	#[wasm_bindgen(js_name = readArchiveShare)]
	pub fn read_archive_share(&self, id: js_sys::JsString) -> js_sys::Promise {
		let bytes = id.length() as usize * 3;
		self.action(text(id), bytes, |session, id| async move {
			let history = session.read_archive_share(&id).await.map_err(|e| e.to_string())?;
			let output = js_sys::Object::new().into();
			view::set(&output, "view", view::json(&history.view)?)?;
			view::set(&output, "records", view::json(&history.records)?)?;
			Ok(output)
		})
	}
	#[wasm_bindgen(js_name = dropArchiveShare)]
	pub fn drop_archive_share(&self, id: js_sys::JsString) -> js_sys::Promise {
		let bytes = id.length() as usize * 3;
		self.observed_mutation(text(id), bytes, |session, id| async move {
			session.drop_archive_share(&id).await.map_err(|e| e.to_string())?;
			Ok(JsValue::UNDEFINED)
		})
	}
	#[wasm_bindgen(js_name = revokeIssuedArchiveShare)]
	pub fn revoke_issued_archive_share(&self, id: js_sys::JsString) -> js_sys::Promise {
		let bytes = id.length() as usize * 3;
		self.observed_mutation(text(id), bytes, |session, id| async move {
			Ok(session
				.revoke_archive_share(&id)
				.await
				.map_err(|e| e.to_string())?
				.into())
		})
	}
	#[wasm_bindgen(js_name = listIssuedArchiveShares)]
	pub fn list_issued_archive_shares(&self) -> js_sys::Promise {
		self.action(Ok(()), 0, |session, ()| async move {
			let output = js_sys::Array::new();
			for share in session.issued_archive_shares().await.map_err(|e| e.to_string())? {
				let row = js_sys::Object::new().into();
				view::set(&row, "id", share.share.id().into())?;
				view::set(&row, "label", view::json(share.share.label())?)?;
				view::set(&row, "filter", view::json(share.share.filter())?)?;
				view::set(&row, "sturdyref", share.sturdyref.into())?;
				output.push(&row);
			}
			Ok(output.into())
		})
	}
}
