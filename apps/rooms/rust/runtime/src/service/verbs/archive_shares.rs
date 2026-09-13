//! Archive shares on a live facet: issue, list, and revoke the shares this
//! session grants, and read or drop the shares it has received.
use crate::directories::runtime::AcceptedDirect;
use crate::service::error::Error;
use crate::service::facet::Facet;
use crate::service::facet::Rights;
use crate::service::{Platform, revision::Prepared};
use glowcap::{Argument, CaptpVersion, Host, PendingWork, Ref, Session};
use rooms_application::{
	archive::{Access as ArchiveAccess, Filter, MAX_READ, ShareKind, shares::Share},
	session::verbs,
	text::DocumentText,
};
use rooms_glowcap::{
	archive as wire,
	client::{Client, archive::Archive},
};

pub fn dispatch<P: Platform>(
	facet: &Facet<P>,
	rights: &Rights,
	verb: &str,
	args: &[Argument],
) -> Result<Argument, Error> {
	if !rights.may_interact() {
		return Err(Error::refused("this Rooms session facet cannot share archive history"));
	}
	match verb {
		verbs::LIST_ARCHIVE_SHARES => list_issued(facet, args),
		verbs::REVOKE_ARCHIVE_SHARE => revoke_issued(facet, args),
		verbs::DROP_ARCHIVE_SHARE => drop_received(facet, args),
		verbs::READ_ARCHIVE_SHARE => read_received(facet, args),
		verbs::SHARE_ARCHIVE => offer(facet, verbs::SHARE_ARCHIVE, args),
		_ => offer(facet, verbs::OFFER_DURABLE_ARCHIVE, args),
	}
}

fn list_issued<P: Platform>(facet: &Facet<P>, args: &[Argument]) -> Result<Argument, Error> {
	if !args.is_empty() {
		return Err(Error::invalid("listArchiveShares takes no arguments"));
	}
	prepare_list(facet).wire_with(facet, verbs::LIST_ARCHIVE_SHARES, |listed| {
		let rows = listed
			.iter()
			.map(|view| wire::share_row(&view.share, &view.sturdyref).map_err(Error::invalid_by))
			.collect::<Result<Vec<_>, _>>()?;
		Ok(Argument::List(rows))
	})
}

pub(in crate::service) fn prepare_list<P: Platform>(
	facet: &Facet<P>,
) -> Prepared<Vec<rooms_glowcap::client::archive::ShareView>> {
	let archive = facet.0.archive.clone();
	Prepared::new(async move { archive.list_issued()?.wait().await })
}

fn revoke_issued<P: Platform>(facet: &Facet<P>, args: &[Argument]) -> Result<Argument, Error> {
	let id = match args {
		[Argument::String(id)] => id.clone(),
		_ => return Err(Error::invalid("revokeArchiveShare takes one share id")),
	};
	prepare_revoke(facet, id).wire_with(facet, verbs::REVOKE_ARCHIVE_SHARE, |revoked| {
		Ok(Argument::Boolean(revoked))
	})
}

pub(in crate::service) fn prepare_revoke<P: Platform>(facet: &Facet<P>, id: String) -> Prepared<bool> {
	let archive = facet.0.archive.clone();
	Prepared::new(async move { archive.revoke_share(id)?.wait().await })
}

fn drop_received<P: Platform>(facet: &Facet<P>, args: &[Argument]) -> Result<Argument, Error> {
	let id = match args {
		[Argument::String(id)] => id.as_str(),
		_ => return Err(Error::invalid("dropArchiveShare takes an archive share id")),
	};
	facet.0.shares.drop_share(id);
	Ok(Argument::Void)
}

fn read_received<P: Platform>(facet: &Facet<P>, args: &[Argument]) -> Result<Argument, Error> {
	const SHAPE: &str = "readArchiveShare takes an archive share id and optional revision cursor";
	let (id, after) = match args {
		[Argument::String(id)] => (id.as_str(), 0u64),
		[Argument::String(id), Argument::Integer(after)] if *after >= 0 => (id.as_str(), *after as u64),
		_ => return Err(Error::invalid(SHAPE)),
	};
	prepare_read(facet, id, after)?.wire_with(facet, verbs::READ_ARCHIVE_SHARE, |(view, page)| {
		let json = serde_json::to_string(&view).map_err(Error::invalid_by)?;
		let records = page
			.records
			.iter()
			.map(|entry| wire::record_row(&entry.record))
			.collect();
		Ok(Argument::List(vec![
			json.into(),
			Argument::Integer(page.next as i64),
			page.more.into(),
			Argument::List(records),
		]))
	})
}

pub type SharedPage = (
	rooms_application::session::snapshot::views::ArchiveShare,
	rooms_application::archive::index::Page,
);
pub(in crate::service) fn prepare_read<P: Platform>(
	facet: &Facet<P>,
	id: &str,
	after: u64,
) -> Result<Prepared<SharedPage>, Error> {
	let (view, archive, session) = facet
		.0
		.shares
		.get(id)
		.ok_or_else(|| Error::stale("that archive share is not in this Rooms session"))?;
	let filter = Filter::shared(
		view.kind,
		view.directory.text().clone(),
		view.scope_conversation.as_ref().cloned(),
	)
	.map_err(Error::invalid_by)?;
	let host = facet.0.host.clone();
	let platform = facet.0.platform.clone();
	let link = view.sturdyref.text().as_str().unwrap_or("").to_owned();
	Ok(Prepared::new(async move {
		let page = read_held(platform, archive, session, &filter, after, host, &link).await?;
		Ok((view, page))
	}))
}

fn offer<P: Platform>(facet: &Facet<P>, verb: &'static str, args: &[Argument]) -> Result<Argument, Error> {
	let (kind, conversation, peer) = match args {
		[Argument::String(kind), Argument::String(conversation)] => (kind.as_str(), conversation.as_str(), ""),
		[
			Argument::String(kind),
			Argument::String(conversation),
			Argument::String(peer),
		] => (kind.as_str(), conversation.as_str(), peer.as_str()),
		_ => {
			return Err(Error::invalid(format!(
				"{verb} takes a kind, conversation id, and optional peer"
			)));
		}
	};
	let kind =
		ShareKind::parse(kind).ok_or_else(|| Error::invalid("archive share kind must be direct, room, or standing"))?;
	prepare_offer(facet, kind, conversation, peer, verb == verbs::OFFER_DURABLE_ARCHIVE)?
		.wire_with(facet, verb, |()| Ok(Argument::Void))
}

pub(in crate::service) fn prepare_offer<P: Platform>(
	facet: &Facet<P>,
	kind: ShareKind,
	conversation: &str,
	peer: &str,
	durable: bool,
) -> Result<Prepared<()>, Error> {
	let (context, filter) = route(facet, kind, conversation, peer)?;
	let id = if durable { Some(share_id(facet)?) } else { None };
	let archive = facet.0.archive.clone();
	let routes = facet.0.routes.clone();
	let dispatcher = facet.0.dispatcher.clone();
	Ok(Prepared::new(async move {
		if !routes.live(&context) {
			dispatcher.ensure(&context)?.wait().await?;
		}
		let line = routes.live_line(&context)?;
		let directory = filter
			.directory
			.as_ref()
			.and_then(DocumentText::as_str)
			.unwrap_or("")
			.to_owned();
		let conversation = filter
			.conversation
			.as_ref()
			.and_then(DocumentText::as_str)
			.map(str::to_owned);
		if durable {
			let id = id.expect("durable share identifier");
			let share = Share::new(id.clone(), format!("{} archive share", kind.wire()).into(), filter)
				.map_err(Error::invalid_by)?;
			let link = archive.issue_share(share)?.wait().await?;
			if let Err(error) = line
				.offer_archive(&directory, kind, conversation.as_deref(), &link)
				.await
			{
				// The share was minted for an offer that never reached its
				// recipient; revoke it so it does not outlive the attempt.
				let revoked = match archive.revoke_share(id) {
					Ok(reply) => reply.wait().await.map(|_| ()),
					Err(refused) => Err(refused),
				};
				return Err(Error::peer(error).retain_result(revoked));
			}
		} else {
			let facet =
				rooms_application::archive::Facet::new(filter, ArchiveAccess::Read).map_err(Error::invalid_by)?;
			let proxy = archive.share(line.session().borrowed(), facet)?.wait().await?;
			let handed = line
				.hand_archive(&directory, kind, conversation.as_deref(), &proxy)
				.await
				.map_err(Error::peer);
			let released = line.session().release(proxy).map_err(Error::from);
			Error::fold(handed, released)?;
		}
		Ok(())
	}))
}

/// The direct conversation an offer travels over, and the filter it shares.
fn route<P: Platform>(
	facet: &Facet<P>,
	kind: ShareKind,
	conversation: &str,
	peer: &str,
) -> Result<(AcceptedDirect, Filter), Error> {
	let (pipe, filter) = facet.0.commands.view().read(|state| {
		let checkpoint = state.checkpoint()?;
		if kind == ShareKind::Direct {
			let intent = checkpoint
				.directs()
				.find(|direct| direct.id.text().as_str() == Some(conversation) && !direct.closed)
				.ok_or_else(|| Error::stale("that direct conversation is not connected in this Rooms session"))?;
			let filter = Filter::shared(kind, intent.directory.text().clone(), Some(intent.id.text().clone()))
				.map_err(Error::invalid_by)?;
			return Ok((conversation.to_owned(), filter));
		}
		let room = checkpoint
			.rooms()
			.find(|room| room.id.text().as_str() == Some(conversation))
			.ok_or_else(|| Error::stale("that room is not in this Rooms session"))?;
		if peer.trim().is_empty() {
			return Err(Error::invalid(
				"name the member who should receive this archive account",
			));
		}
		let pipe = checkpoint
			.directs()
			.find(|direct| {
				!direct.closed
					&& direct.directory.text() == room.directory.text()
					&& direct
						.peer
						.text()
						.as_str()
						.is_some_and(|name| name.eq_ignore_ascii_case(peer.trim()))
			})
			.ok_or_else(|| Error::stale("open a direct conversation with that member first"))?;
		let identity = if room.held {
			room.id.text().as_str().unwrap_or("").to_owned()
		} else {
			room.name.text().as_str().unwrap_or("").to_lowercase()
		};
		let filter =
			Filter::shared(kind, room.directory.text().clone(), Some(identity.into())).map_err(Error::invalid_by)?;
		Ok::<_, Error>((pipe.id.text().as_str().unwrap_or("").to_owned(), filter))
	})??;
	let context = facet.0.directories.intended_direct(&pipe)?;
	Ok((context, filter))
}

async fn read_held<P: Platform>(
	platform: P,
	archive: Option<Ref>,
	session: Option<Session>,
	filter: &Filter,
	after: u64,
	host: Host,
	link: &str,
) -> Result<rooms_application::archive::index::Page, Error> {
	if let (Some(archive), Some(session)) = (archive, session) {
		let client = Client::new(session, platform);
		return Archive::new(client, archive)
			.read(filter, after, MAX_READ)
			.await
			.map_err(Error::peer);
	}
	if link.is_empty() {
		return Err(Error::stale("that archive share has no live archive capability"));
	}
	let reference = host.enliven_for_version(link, CaptpVersion::V1_0).await?;
	let session = host
		.reference_session(&reference)?
		.ok_or_else(|| Error::closed("archive share capability has no live exporter"))?;
	let client = Client::new(session.borrowed(), platform);
	let page = Archive::new(client, reference)
		.read(&Filter::default(), after, MAX_READ)
		.await
		.map_err(Error::peer);
	let relinquished = session.relinquish(PendingWork::Cancel).await.map_err(Error::from);
	match (page, relinquished) {
		(Ok(page), Ok(())) => Ok(page),
		(Ok(_), Err(cleanup)) => Err(cleanup),
		(Err(error), cleanup) => Err(error.retain_result(cleanup)),
	}
}

/// A fresh share id: a version-4 UUID, the form the browser and the archive
/// peer already agree on.
fn share_id<P: Platform>(facet: &Facet<P>) -> Result<String, Error> {
	let mut bytes = [0u8; 16];
	facet
		.0
		.entropy
		.borrow_mut()
		.fill(&mut bytes)
		.map_err(|_| Error::closed("archive share identifier entropy is unavailable"))?;
	bytes[6] = (bytes[6] & 0x0f) | 0x40;
	bytes[8] = (bytes[8] & 0x3f) | 0x80;
	let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
	Ok(format!(
		"{}-{}-{}-{}-{}",
		&hex[0..8],
		&hex[8..12],
		&hex[12..16],
		&hex[16..20],
		&hex[20..32]
	))
}
