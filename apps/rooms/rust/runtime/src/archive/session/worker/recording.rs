//! Capture completion retains its writer through every storage and file wait.
use super::*;

impl<B: Backend, P: Platform> Worker<B, P> {
	pub(super) async fn recording_writer(&self, destination: Option<Destination>) -> Result<Keeper<P>, Error> {
		match destination {
			None => self.selected_writer(),
			Some(Destination::Device) => Ok(Keeper::Local(Local {
				owner: Rc::downgrade(&self.state),
			})),
			Some(Destination::Held(reference)) => Ok(Keeper::Peer(Peer::held(
				self.targets.host(),
				self.state.platform.clone(),
				reference,
			))),
			Some(Destination::Restoring(target)) => Ok(Keeper::Peer(Peer::held(
				self.targets.host(),
				self.state.platform.clone(),
				target.reference().await?,
			))),
		}
	}
	pub(super) fn selected_writer(&self) -> Result<Keeper<P>, Error> {
		match &self.targets.selected {
			Selection::Local => Ok(Keeper::Local(Local {
				owner: Rc::downgrade(&self.state),
			})),
			Selection::Peer(peer) => Ok(Keeper::Peer(peer.lease())),
			Selection::Unavailable(_) => Err(peer_unavailable()),
		}
	}
	/// Store a recording whose capture landed. Bytes the source could not
	/// deliver leave the line archived without them, the same line the room
	/// keeps. A capture cut short by an erasure or by closing is refused.
	pub(super) async fn captured(
		&mut self,
		landed: Result<(Id, Result<Vec<capture::Captured>, Error>), JoinError>,
		report: &mut Report,
	) {
		let (id, outcome) = match landed {
			Ok((id, Ok(captured))) => (id, Ok(captured)),
			Ok((id, Err(reason))) => (id, Err(Cut::Failed(reason))),
			Err(error) if error.is_cancelled() => (error.id(), Err(Cut::Cancelled)),
			Err(error) => (error.id(), Err(Cut::Failed(Error::closed(error.to_string())))),
		};
		let Some(Capturing {
			erased,
			record,
			nick,
			writer,
			files,
			answer,
			_custody,
			..
		}) = self.capturing.remove(&id)
		else {
			unreachable!("every capture task parks its recording");
		};
		let outcome = if erased { Err(Cut::Cancelled) } else { outcome };
		let result = match outcome {
			Ok(captured) => self.store(&writer, record, &nick, captured, files, report).await,
			Err(Cut::Failed(reason)) => {
				let files = FileRecording::MetadataOnly(MetadataReason::SourceFailed(reason.to_string()));
				self.store(&writer, record, &nick, Vec::new(), files, report).await
			}
			Err(Cut::Cancelled) => Err(Error::closed(
				"the archive let this line go before its file bytes arrived",
			)),
		};
		recorded(answer, result, report);
	}
	pub(super) async fn local_ready(&mut self) -> Result<(), Error> {
		if let Some(source) = &self.erase_source_required {
			self.backend.clear_source(source).await?;
			self.standings.clear_source(source);
			self.erase_source_required = None;
			let _ = self.state.changes.send(rooms_application::archive::change::Change::All);
		}
		if self.erase_required {
			self.backend.clear().await?;
			self.standings.clear();
			self.erase_required = false;
			let _ = self.state.changes.send(rooms_application::archive::change::Change::All);
		}
		Ok(())
	}
	/// Whether the selected target can take a recording now.
	pub(super) async fn target_ready(&mut self, writer: &Keeper<P>) -> Result<(), Error> {
		match writer {
			Keeper::Local(_) => self.local_ready().await,
			Keeper::Peer(_) => Ok(()),
		}
	}
	/// Write one recording and its standing to the selected target.
	pub(super) async fn store(
		&mut self,
		writer: &Keeper<P>,
		record: Record,
		nick: &str,
		captured: Vec<capture::Captured>,
		files: FileRecording,
		report: &mut Report,
	) -> Result<Recorded, Error> {
		self.target_ready(writer).await?;
		let standing = match writer {
			Keeper::Local(_) => self.standings.prepare(&record, nick),
			Keeper::Peer(peer) => peer.target().standings.borrow().prepare(&record, nick),
		}
		.map_err(Error::invalid_by)?;
		let revision = self.put(writer, record, Files::Captured(captured), report).await?;
		let standing = match standing {
			None => Ok(None),
			Some(standing) => match self
				.put(writer, standing.clone(), Files::Live(Vec::new()), report)
				.await
			{
				Err(error) => Err(error),
				Ok(revision) => match writer {
					Keeper::Local(_) => self.standings.remember(standing),
					Keeper::Peer(peer) => peer.target().standings.borrow_mut().remember(standing),
				}
				.map(|()| Some(revision))
				.map_err(Error::invalid_by),
			},
		};
		Ok(Recorded {
			revision,
			standing,
			files,
		})
	}
	pub(super) async fn put(
		&mut self,
		writer: &Keeper<P>,
		record: Record,
		sources: Files<P>,
		report: &mut Report,
	) -> Result<u64, Error> {
		let change = rooms_application::archive::change::Change::of(&record);
		if matches!(writer, Keeper::Local(_)) {
			self.local_ready().await?;
		}
		let mut reads = ReadReplies {
			reads: self.backend.blob_access(),
			report,
			erase_required: self.erase_required,
		};
		let mut peer_failed = false;
		let result: Result<u64, Error> = match writer {
			Keeper::Peer(peer) => {
				let result = if sources.is_empty() {
					peer.target().archive.put(&record).await
				} else {
					match sources {
						Files::Live(sources) => {
							let attachments: Vec<_> = sources.iter().map(|s| s.attachment().clone()).collect();
							self.requests
								.during(peer.target().archive.put_files(&record, &attachments), &mut reads)
								.await
						}
						Files::Captured(sources) => {
							let sources = sources.into_iter().map(capture::Captured::into_source).collect();
							self.requests
								.during(
									peer.target().archive.put_sources(&self.sources, &record, sources),
									&mut reads,
								)
								.await
						}
					}
				};
				result.map_err(|error| {
					peer_failed = error.connection_failed();
					Error::peer(error)
				})
			}
			Keeper::Local(_) => {
				if sources.is_empty() {
					self.backend.put(record).await
				} else {
					match sources {
						Files::Live(sources) => {
							self.requests
								.during(self.backend.put_files(record, &sources), &mut reads)
								.await
						}
						Files::Captured(sources) => {
							self.requests
								.during(self.backend.put_files(record, &sources), &mut reads)
								.await
						}
					}
				}
			}
		};
		let result = result.map_err(|error| {
			if peer_failed && matches!(writer, Keeper::Peer(peer) if self.targets.selected_is(peer)) {
				self.selected_peer_unavailable(error)
			} else {
				error
			}
		});
		let revision = result.and_then(|revision| {
			rooms_application::fields::SafeInteger::<true>::new(revision)
				.map(|n| n.get())
				.ok_or_else(|| Error::storage_message("archive backend returned an invalid revision"))
		})?;
		if let Some(change) = change {
			let _ = self.state.changes.send(change);
		}
		Ok(revision)
	}
}
