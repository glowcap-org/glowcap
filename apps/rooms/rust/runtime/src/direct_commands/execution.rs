use super::*;
use crate::session_state::OrdinaryStatus;
use rooms_application::{
	direct::operation as identity,
	session::state::{Inspection, Outcome},
	text::DocumentText,
};

pub(super) async fn run<P: Platform>(
	platform: P,
	commands: SessionCommands,
	delivery: DirectOutgoing<P>,
	mut request: Request,
	mut stopping: watch::Receiver<bool>,
) {
	let result = execute(&platform, &commands, &delivery, &mut request, &mut stopping).await;
	let _ = request.answer.send(result.map_err(|e| CommandFailure {
		delivery: e.delivery,
		ledger: request.ledger.get(),
		reason: e.reason,
	}));
}
async fn execute<P: Platform>(
	platform: &P,
	commands: &SessionCommands,
	delivery: &DirectOutgoing<P>,
	request: &mut Request,
	stopping: &mut watch::Receiver<bool>,
) -> Result<Committed, Failure> {
	let prepared = tokio::select! {
		biased;
		_ = stopping.changed() => return Err(failed(Delivery::NotSent, "direct commands stopped during preparation")),
		result = freeze(platform, &mut request.command, &request.context) => result.map_err(|e| failed(Delivery::NotSent, &e))?,
	};
	let (material, files) = prepared;
	request.ledger.set(Ledger::Unknown);
	let inspection = commands
		.inspect_ordinary(request.operation.id.clone(), request.operation.base, material.clone())
		.map_err(|e| failed(Delivery::NotSent, &e.to_string()))?
		.send()
		.map_err(|e| failed(Delivery::NotSent, &e.to_string()))?
		.wait()
		.await
		.map_err(|e| failed(Delivery::NotSent, &e))?;
	let inspection = match inspection {
		Inspection::Committed(revision) => {
			request.ledger.set(Ledger::Committed);
			return Ok(Committed { revision, sent: None });
		}
		Inspection::New(inspection) => inspection,
	};
	request.ledger.set(Ledger::Unrecorded);
	if !request.context.current() || *stopping.borrow() {
		return Err(failed(Delivery::NotSent, "direct command retired before preparation"));
	}
	if let Some(line) = request.command.line() {
		delivery.require_line(line).map_err(|e| failed(Delivery::NotSent, &e))?;
	}
	request.ledger.set(Ledger::Unknown);
	let prepared = commands
		.prepare_inspected(inspection, material.clone())
		.map_err(|e| failed(Delivery::NotSent, &e.to_string()))?
		.send()
		.map_err(|e| failed(Delivery::NotSent, &e.to_string()))?
		.wait()
		.await
		.map_err(|e| failed(Delivery::NotSent, &e))?;
	if let OrdinaryStatus::Committed(revision) = prepared {
		request.ledger.set(Ledger::Committed);
		return Ok(Committed { revision, sent: None });
	}
	request.ledger.set(Ledger::Prepared);
	// The durable prepared boundary must be observed before any delivery is admitted.
	let sending = if *stopping.borrow() {
		Err("direct commands stopped before delivery".into())
	} else {
		request.command.deliver(delivery, &request.context, files)
	};
	let result = match sending {
		Err(error) => Err(failed(Delivery::NotSent, &error)),
		Ok(sending) => {
			// Delivery now has an independent owner and may proceed even if
			// this worker is aborted. Recovery must conservatively preserve it.
			request.progress.set(Delivery::Uncertain);
			sending.wait().await
		}
	};
	let evidence = result.as_ref().map_or_else(|e| e.delivery, |_| Delivery::Accepted);
	request.progress.set(evidence);
	if evidence == Delivery::Uncertain {
		return Err(result.unwrap_err());
	}
	request.ledger.set(Ledger::Unknown);
	let recorded = if evidence == Delivery::NotSent {
		commands.resolve(request.operation.id.clone(), Outcome::Abandoned)
	} else {
		commands.commit_ordinary(request.operation.id.clone(), material)
	};
	let revision = recorded
		.map_err(|e| failed(evidence, &e.to_string()))?
		.send()
		.map_err(|e| failed(evidence, &e.to_string()))?
		.wait()
		.await
		.map_err(|e| failed(evidence, &e))?;
	request.ledger.set(if evidence == Delivery::NotSent {
		Ledger::Abandoned
	} else {
		Ledger::Committed
	});
	result.map(|sent| Committed {
		revision,
		sent: Some(sent),
	})
}
async fn freeze<P: Platform>(
	platform: &P,
	command: &mut Command,
	context: &AcceptedDirect,
) -> Result<(DocumentText, Vec<Source>), String> {
	let frozen = crate::command_files::freeze(platform, command.take_files()).await?;
	let identities = frozen.identities();
	let intent = match command {
		Command::Send { text, .. } => identity::Command::Send {
			text,
			files: &identities,
		},
		Command::Edit { line, text } => identity::Command::Edit { line: *line, text },
		Command::Refile { line, text, keep, .. } => identity::Command::Refile {
			line: *line,
			text,
			keep,
			files: &identities,
		},
		Command::Withdraw { line } => identity::Command::Withdraw { line: *line },
	};
	let material = intent
		.material(identity::Context {
			directory: context.directory().text(),
			conversation: context.conversation().text(),
			peer: context.peer().text(),
			registration: context.registration().as_str(),
		})
		.map_err(|e| e.to_string())?;
	Ok((material, frozen.into_sources()))
}
impl Command {
	fn line(&self) -> Option<LineKey> {
		match self {
			Self::Send { .. } => None,
			Self::Edit { line, .. } | Self::Refile { line, .. } | Self::Withdraw { line } => Some(*line),
		}
	}
	fn deliver<P: Platform>(
		&self,
		delivery: &DirectOutgoing<P>,
		context: &AcceptedDirect,
		files: Vec<Source>,
	) -> Result<crate::direct_outgoing::Sending, String> {
		match self {
			Self::Send { text, .. } => delivery.send(context, text, files),
			Self::Edit { line, text } => delivery.edit(context, line.line, text),
			Self::Refile { line, text, keep, .. } => delivery.refile(context, line.line, text, keep, files),
			Self::Withdraw { line } => delivery.withdraw(context, line.line),
		}
	}
}
