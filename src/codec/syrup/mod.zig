//! Syrup codec barrel. See [`core`] for the codec body — the byte-record
//! encode/decode of the codec-neutral [`model`] message tree. Mirrors the
//! [`codec.capnp`] barrel shape: one `core` implementation, re-exported here.

pub const core = @import("core.zig");

pub const AdmittedMessage = core.AdmittedMessage;
pub const CodecDescriptor = core.CodecDescriptor;
pub const descriptor = core.descriptor;
pub const admits = core.admits;

pub const Error = core.Error;
pub const decodeView = core.decodeView;
pub const decodeBody = core.decodeBody;
pub const decodePrefix = core.decodePrefix;
pub const decodeOwned = core.decodeOwned;
pub const ownedFromView = core.ownedFromView;

pub const encodeMessage = core.encodeMessage;
pub const encodeMessageForProfile = core.encodeMessageForProfile;
pub const canonicalLocationSignedBytes = core.canonicalLocationSignedBytes;

pub const AbortView = core.AbortView;
pub const ArgumentListView = core.ArgumentListView;
pub const ArgumentView = core.ArgumentView;
pub const DeliverView = core.DeliverView;
pub const GcAnswerView = core.GcAnswerView;
pub const GcExportView = core.GcExportView;
pub const GetView = core.GetView;
pub const HandoffView = core.HandoffView;
pub const IndexView = core.IndexView;
pub const ListenView = core.ListenView;
pub const MessageView = core.MessageView;
pub const PositionListView = core.PositionListView;
pub const ReferenceView = core.ReferenceView;
pub const ResolutionView = core.ResolutionView;
pub const SignatureView = core.SignatureView;
pub const StartSessionView = core.StartSessionView;
