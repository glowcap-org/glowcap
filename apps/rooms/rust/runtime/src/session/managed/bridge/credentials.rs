//! Opaque owner and witness identities address the existing credential journal.
//! Only private committed Loam witnesses decide candidate adoption or erasure.
use crate::{documents::Document, session::bridge_secrets::BridgeSecrets};
use glowcap::{Result, loam};
use rooms_application::{
	fields::{Hex, SafeInteger},
	text::DocumentText,
};

pub(in crate::session::managed) struct Credentials {
	domain: DocumentText,
	journal: BridgeSecrets,
	serial: tokio::sync::Mutex<()>,
}
fn error(failure: impl core::fmt::Display) -> glowcap::Error {
	loam::refusal(failure.to_string())
}
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub(in crate::session::managed) struct Witness {
	pub id: SafeInteger,
	pub credentials: Option<Hex<16>>,
}
fn key(witness: &Witness) -> DocumentText {
	format!("{:016x}", witness.id.get()).into()
}
fn nonce(witness: &Witness) -> Option<DocumentText> {
	witness.credentials.as_ref().map(|nonce| nonce.encode().into())
}
impl Credentials {
	pub(super) async fn stage(
		&self,
		id: SafeInteger,
		nonce: Option<Hex<16>>,
		secrets: rooms_application::bridge::Answers,
	) -> Result<()> {
		let _serial = self.serial.lock().await;
		let key: DocumentText = format!("{:016x}", id.get()).into();
		self.journal
			.stage(
				self.domain.clone(),
				key,
				secrets,
				nonce.map(|nonce| nonce.encode().into()),
			)
			.await
			.map(|_| ())
			.map_err(error)
	}
	pub(super) async fn answers(&self, id: SafeInteger, nonce: &Hex<16>) -> Result<rooms_application::bridge::Answers> {
		let _serial = self.serial.lock().await;
		let key: DocumentText = format!("{:016x}", id.get()).into();
		let expected: DocumentText = nonce.encode().into();
		match self.journal.answers(&self.domain, &key).await.map_err(error)? {
			Some((answers, Some(revision))) if revision == expected => Ok(answers),
			_ => Err(loam::refusal("original bridge credentials are unavailable")),
		}
	}
	pub(super) async fn open(domain: DocumentText, document: impl Document + 'static) -> Result<Self> {
		if !domain.as_str().is_some_and(|owner| {
			owner.len() == 32
				&& owner
					.bytes()
					.all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
		}) {
			return Err(loam::refusal("invalid private credential owner"));
		}
		let journal = BridgeSecrets::open(document).await.map_err(error)?;
		journal.bind_owner(&domain).await.map_err(error)?;
		Ok(Self {
			domain,
			journal,
			serial: tokio::sync::Mutex::new(()),
		})
	}
	/// Hold the journal admission fence before reading Loam witnesses. A new
	/// credential write cannot appear behind an older snapshot and be erased.
	/// The caller retains this complete future across observation deadlines.
	pub(super) async fn reconcile(&self, writer: &super::super::executor::Writer) -> Result<()> {
		let _serial = self.serial.lock().await;
		let raw = writer.idempotent("bridge-witnesses", &[]).await?;
		let snapshot: super::Snapshot = serde_json::from_str(
			raw.as_str()
				.ok_or_else(|| glowcap::loam::refusal("invalid private bridge witnesses"))?,
		)
		.map_err(|_| glowcap::loam::refusal("invalid private bridge witnesses"))?;
		if snapshot.owner != self.domain {
			return Err(glowcap::loam::refusal("bridge credential owner changed"));
		}
		self.recover(&snapshot.witnesses).await
	}
	pub(super) async fn recover(&self, witnesses: &[Witness]) -> Result<()> {
		let wanted = witnesses
			.iter()
			.map(|witness| (self.domain.clone(), key(witness), nonce(witness)))
			.collect::<Vec<_>>();
		self.journal.recover(&wanted).await.map_err(error)?;
		let wanted = wanted
			.into_iter()
			.filter_map(|(owner, key, nonce)| nonce.map(|_| (owner, key)))
			.collect::<Vec<_>>();
		self.journal.retain_witnesses(&wanted).await.map_err(error)
	}
}
