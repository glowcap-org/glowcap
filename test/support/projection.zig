//! Read a local promise projection's stored settlement by its export.

const glowcap = @import("glowcap");

const model = glowcap.ocapn.model;
const session = glowcap.ocapn.session;

/// The resolution stored for the projection exported at `export_position`,
/// or null while it is pending or once it is collected.
pub fn resolution(state: *session.Session, export_position: model.ExportPosition) ?*const model.Resolution {
    const answer = state.answerForLocalPromiseExport(export_position) orelse return null;
    return state.peekResolutionNamed(answer);
}
