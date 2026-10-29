//! A scoped read waits on durable changes and the original live executor.
use super::*;
use glowcap::loam::{ReadInterface, ReadMethod};
use std::rc::Rc;

pub(super) fn reader<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
	call: &mut Call<'_>,
	input: Invocation<'_>,
) -> Result<Argument> {
	let [id, canonical] = input.args else {
		return Err(refuse("effect-reader takes operation id and original intent"));
	};
	let id = operation(id)?;
	let source = call.source()?;
	let record = records::metadata(input)?;
	authenticate(call, input, &record, &id, &source)?;
	let intent = Text::new(text(canonical)?.into()).ok_or_else(|| refuse("invalid original intent"))?;
	effects::inspect(&record.effects, &id, &location(&record, &id)?, &intent)
		.map_err(|_| refuse("original source and intent required"))?
		.ok_or_else(|| refuse("unknown effect"))?;
	let reader = owner.effect_reader.borrow();
	let actor = reader
		.as_ref()
		.ok_or_else(|| refuse("session effect observer is not initialized"))?;
	call.disclose_reads_copying(
		actor,
		&[ReadInterface {
			methods: &[ReadMethod {
				verb: "read",
				results: &[],
			}],
		}],
		0,
	)
	.map(Argument::Reference)
}

/// One session actor shares the existing two change feeds and bounded read
/// queue. Each call retains only its operation ID and exact source witness.
/// Startup creates it outside the Loam callback, where Host access is permitted.
pub(in crate::session::managed) fn initialize<P: Tasks + Deadline + Clone + 'static>(
	owner: &Rc<State<P>>,
) -> Result<()> {
	let mut reader = owner.effect_reader.borrow_mut();
	if reader.is_some() {
		return Ok(());
	}
	let weak = Rc::downgrade(owner);
	*reader = Some(owner.writer.host.spawn(move |verb, args| {
		let [Argument::String(id), Argument::Reference(source)] = args else {
			return Err("effect observation takes operation id and original source witness".into());
		};
		if verb != Some("read") {
			return Err("effect observation accepts only read".into());
		}
		if !rooms_application::session::state::OperationId::accepts_utf16(id.encode_utf16()) {
			return Err("invalid operation id".into());
		}
		let owner = weak.upgrade().ok_or("session owner has closed")?;
		let mut wake = owner.changes.subscribe(&owner).map_err(|e| e.to_string())?;
		let host = owner.writer.host.clone();
		let id = id.clone();
		let source = source.clone();
		let platform = owner.platform.clone();
		super::super::activity::reader::answer(
			&Rc::downgrade(&owner.activity),
			&owner.writer.host,
			&owner.platform,
			async move {
				let observed = platform
					.within(20_000, async {
						loop {
							let status = host
								.send(&source, "effect-status", &[id.as_str().into(), source.clone().into()])
								.await
								.map_err(|e| refuse(&e.to_string()))?;
							if status.as_str() != Some("pending") {
								return Ok(status);
							}
							wake.changed().await?;
						}
					})
					.await;
				// A finite parked read can end while the actual executor remains
				// pending. It owns no dispatch and grants no retry authority.
				observed.unwrap_or_else(|| Ok("pending".into()))
			},
		)
	})?);
	Ok(())
}
