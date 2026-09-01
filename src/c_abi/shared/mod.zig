//! The shared C-ABI waist. Subject modules own each layout and mechanism; this
//! root deliberately re-exports the stable vocabulary every symbol-disjoint
//! archive and generated binding consumes.
//!
//! This leaf declares **no `export fn`**. The public `pancake_*` entry points
//! live in the `c_abi/ocapn` families (context, frame, uri), the Host, and
//! the `c_abi/net_transport/{tcp,inproc}` transport families, and the
//! `pancake_iroh_*` entry points in `c_abi_net_transport_iroh`; all reach this
//! vocabulary through `@import("c_abi_shared")`. Because importing the leaf pulls the
//! vocabulary without pulling either library's exported surface, `libpancake_ocapn`
//! carries the core families and `libpancake_net_transport_iroh` carries only
//! the iroh family, each reusing these types, and each from `pancake_ocapn.h`
//! on the C side
//! (ADR-0055 companion split). The two artifacts therefore share no exported
//! core symbol; they share the *layout* of these types, exactly as a C consumer
//! including both headers does.

/// The one cross-archive schema and bounded mechanics for failures with no
/// remaining return recipient (ADR-0115). This leaf owns no mutable global;
/// storage belongs to an explicit Context, Host, or driver owner.
pub const failure_diagnostics = @import("failure_diagnostics.zig");
pub const PancakeFailureEvent = failure_diagnostics.PancakeFailureEvent;
pub const PancakeFailureReport = failure_diagnostics.PancakeFailureReport;
pub const PANCAKE_FAILURE_EVENT_ABI_VERSION = failure_diagnostics.abi_version;
pub const PANCAKE_FAILURE_LAYER_CORE: u32 = @backingInt(failure_diagnostics.Layer.core);
pub const PANCAKE_FAILURE_LAYER_DRIVER: u32 = @backingInt(failure_diagnostics.Layer.driver);
pub const PANCAKE_FAILURE_LAYER_TRANSPORT: u32 = @backingInt(failure_diagnostics.Layer.transport);
pub const PANCAKE_FAILURE_LAYER_BINDING: u32 = @backingInt(failure_diagnostics.Layer.binding);
pub const PANCAKE_FAILURE_LAYER_APPLICATION_OBSERVER: u32 = @backingInt(failure_diagnostics.Layer.application_observer);
pub const PANCAKE_FAILURE_SCOPE_PROCESS: u32 = @backingInt(failure_diagnostics.ScopeKind.process);
pub const PANCAKE_FAILURE_SCOPE_CONTEXT: u32 = @backingInt(failure_diagnostics.ScopeKind.context);
pub const PANCAKE_FAILURE_SCOPE_HOST: u32 = @backingInt(failure_diagnostics.ScopeKind.host);
pub const PANCAKE_FAILURE_SCOPE_SESSION: u32 = @backingInt(failure_diagnostics.ScopeKind.session);
pub const PANCAKE_FAILURE_SCOPE_LISTENER: u32 = @backingInt(failure_diagnostics.ScopeKind.listener);
pub const PANCAKE_FAILURE_SCOPE_TRANSPORT: u32 = @backingInt(failure_diagnostics.ScopeKind.transport);
pub const PANCAKE_FAILURE_SCOPE_OPERATION: u32 = @backingInt(failure_diagnostics.ScopeKind.operation);
pub const PANCAKE_FAILURE_TRUNCATED_OPERATION = failure_diagnostics.truncated_operation;
pub const PANCAKE_FAILURE_TRUNCATED_PRIMARY_NAME = failure_diagnostics.truncated_primary_name;
pub const PANCAKE_FAILURE_TRUNCATED_PRIMARY_MESSAGE = failure_diagnostics.truncated_primary_message;
pub const PANCAKE_FAILURE_TRUNCATED_SECONDARY_NAME = failure_diagnostics.truncated_secondary_name;
pub const PANCAKE_FAILURE_TRUNCATED_SECONDARY_MESSAGE = failure_diagnostics.truncated_secondary_message;

// ── Return codes ─────────────────────────────────────────────────────────────

/// The annotated-symbol vocabulary the per-archive inventories share
/// (`symbols.zig`): crossing semantics per export, for the binding FFI-table
/// generators.
pub const symbols = @import("symbols.zig");
pub const archive_contract = @import("archive_contract.zig");

/// Canonical reflected layouts shared by the core, host, driver, and transport
/// archives. This inventory drives both archive identity and every generated
/// language-binding layout expectation.
pub const contract_layouts = [_]archive_contract.Layout{
    archive_contract.layout("PANCAKE_REFERENCE", PancakeReference),
    archive_contract.layout("PANCAKE_ARGUMENT", PancakeArgument),
    archive_contract.layout("PANCAKE_FRAME", PancakeFrame),
    archive_contract.layout("PANCAKE_MANAGED_FRAME", PancakeManagedFrame),
    archive_contract.layout("PANCAKE_LAST_ABORT", PancakeLastAbort),
    archive_contract.layout("PANCAKE_ALLOCATOR", PancakeAllocator),
    archive_contract.layout("PANCAKE_FAILURE_REPORT", PancakeFailureReport),
    archive_contract.layout("PANCAKE_FAILURE_EVENT", PancakeFailureEvent),
    archive_contract.layout("PANCAKE_CLOSE_OPTIONS", PancakeCloseOptions),
    archive_contract.layout("PANCAKE_LOCATOR_HINT_VIEW", PancakeLocatorHintView),
    archive_contract.layout("PANCAKE_LOCATOR_VIEW", PancakeLocatorView),
    archive_contract.cOnlyLayout("PANCAKE_TRANSPORT_PROFILE", PancakeTransportProfile),
    archive_contract.layout("PANCAKE_TRANSPORT_OPERATION_OPTIONS", PancakeTransportOperationOptions),
    archive_contract.cOnlyLayout("PANCAKE_PROVIDER_FAILURE", PancakeProviderFailure),
    archive_contract.cOnlyLayout("PANCAKE_LISTEN_RESULT", PancakeListenResult),
    archive_contract.cOnlyLayout("PANCAKE_STREAM_TRANSPORT", PancakeStreamTransport),
    archive_contract.cOnlyLayout("PANCAKE_TRANSPORT_PROVIDER_ENTRY", PancakeTransportProviderEntry),
    archive_contract.layout("PANCAKE_TRANSPORT_PROVIDER", PancakeTransportProvider),
    archive_contract.cOnlyLayout("PANCAKE_MULTIPLEXED_READY_EVENT", PancakeMultiplexedReadyEvent),
    archive_contract.cOnlyLayout("PANCAKE_MULTIPLEXED_TRANSPORT", PancakeMultiplexedTransport),
};

/// The multiplexed-transport table layout (ADR-0112): how a sidecar transport
/// archive plugs its multiplexed transport into the driver archive.
/// Layout only, no exports, like everything in this leaf.
pub const multiplexed_transport = @import("multiplexed_transport.zig");
pub const close = @import("close.zig");
pub const locator = @import("locator.zig");
pub const locator_adapter = @import("locator_adapter.zig");
pub const transport_provider = @import("transport_provider.zig");
pub const PancakeMultiplexedTransport = multiplexed_transport.PancakeMultiplexedTransport;
pub const PancakeMultiplexedReadyEvent = multiplexed_transport.PancakeMultiplexedReadyEvent;
pub const PancakeCloseOptions = close.PancakeCloseOptions;
pub const PancakeListenResult = transport_provider.PancakeListenResult;
pub const PancakeStreamTransport = transport_provider.PancakeStreamTransport;
pub const PancakeLocatorHintView = locator.PancakeLocatorHintView;
pub const PancakeLocatorView = locator.PancakeLocatorView;
pub const PancakeTransportProfile = transport_provider.PancakeTransportProfile;
pub const PancakeTransportOperationOptions = transport_provider.PancakeTransportOperationOptions;
pub const PancakeProviderFailure = transport_provider.PancakeProviderFailure;
pub const PancakeTransportProviderEntry = transport_provider.PancakeTransportProviderEntry;
pub const PancakeTransportProvider = transport_provider.PancakeTransportProvider;
pub const PancakeStreamStartConnectFn = transport_provider.PancakeStreamStartConnectFn;
pub const PancakeStreamFinishConnectFn = transport_provider.PancakeStreamFinishConnectFn;
pub const PancakeStreamCancelConnectFn = transport_provider.PancakeStreamCancelConnectFn;
pub const PancakeStreamListenFn = transport_provider.PancakeStreamListenFn;
pub const PancakeStreamFinishListenFn = transport_provider.PancakeStreamFinishListenFn;
pub const PancakeStreamCancelListenFn = transport_provider.PancakeStreamCancelListenFn;
pub const PANCAKE_LISTEN_READY = transport_provider.PANCAKE_LISTEN_READY;
pub const PANCAKE_LISTEN_PENDING = transport_provider.PANCAKE_LISTEN_PENDING;
pub const PancakeStreamListenerWaitFn = transport_provider.PancakeStreamListenerWaitFn;
pub const PancakeStreamListenerReadinessFdFn = transport_provider.PancakeStreamListenerReadinessFdFn;
pub const PancakeLocatorSinkFn = locator.PancakeLocatorSinkFn;
pub const PancakeTransportListenerRestorationStateFn = transport_provider.PancakeTransportListenerRestorationStateFn;
pub const PancakeTransportListenerLocatorFn = transport_provider.PancakeTransportListenerLocatorFn;
pub const PancakeTransportListenerAdvertiseFn = transport_provider.PancakeTransportListenerAdvertiseFn;
pub const PancakeStreamAcceptFn = transport_provider.PancakeStreamAcceptFn;
pub const PancakeStreamListenerCloseFn = transport_provider.PancakeStreamListenerCloseFn;
pub const PancakeStreamReadFn = transport_provider.PancakeStreamReadFn;
pub const PancakeStreamWriteAllFn = transport_provider.PancakeStreamWriteAllFn;
pub const PancakeStreamConnCloseFn = transport_provider.PancakeStreamConnCloseFn;
pub const PancakeStreamConnTakeFailureFn = transport_provider.PancakeStreamConnTakeFailureFn;
pub const PancakeTransportProviderSameConfigurationFn = transport_provider.PancakeTransportProviderSameConfigurationFn;
pub const PancakeTransportRetainFn = transport_provider.PancakeTransportRetainFn;
pub const PancakeTransportReleaseFn = transport_provider.PancakeTransportReleaseFn;
pub const PancakeMultiplexedReadinessFdFn = multiplexed_transport.PancakeMultiplexedReadinessFdFn;
pub const PancakeMultiplexedDrainReadyFn = multiplexed_transport.PancakeMultiplexedDrainReadyFn;
pub const PancakeMultiplexedStartConnectFn = multiplexed_transport.PancakeMultiplexedStartConnectFn;
pub const PancakeMultiplexedFinishConnectFn = multiplexed_transport.PancakeMultiplexedFinishConnectFn;
pub const PancakeMultiplexedClaimExternalFn = multiplexed_transport.PancakeMultiplexedClaimExternalFn;
pub const PancakeMultiplexedListenFn = multiplexed_transport.PancakeMultiplexedListenFn;
pub const PancakeMultiplexedFinishListenFn = multiplexed_transport.PancakeMultiplexedFinishListenFn;
pub const PancakeMultiplexedFinishAcceptFn = multiplexed_transport.PancakeMultiplexedFinishAcceptFn;
pub const PancakeMultiplexedStopListenFn = multiplexed_transport.PancakeMultiplexedStopListenFn;
pub const PancakeMultiplexedSubjectFn = multiplexed_transport.PancakeMultiplexedSubjectFn;
pub const PancakeMultiplexedConnTakeFailureFn = multiplexed_transport.PancakeMultiplexedConnTakeFailureFn;
pub const PancakeMultiplexedTryReadFn = multiplexed_transport.PancakeMultiplexedTryReadFn;
pub const PancakeMultiplexedTryWriteFn = multiplexed_transport.PancakeMultiplexedTryWriteFn;
pub const PancakeMultiplexedConnRemoteKeyFn = multiplexed_transport.PancakeMultiplexedConnRemoteKeyFn;
pub const PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION = transport_provider.PANCAKE_TRANSPORT_PROVIDER_ABI_VERSION;
pub const PANCAKE_TRANSPORT_PROFILE_ABI_VERSION = transport_provider.PANCAKE_TRANSPORT_PROFILE_ABI_VERSION;
pub const PANCAKE_LOCATOR_VIEW_ABI_VERSION = locator.PANCAKE_LOCATOR_VIEW_ABI_VERSION;
pub const PANCAKE_STREAM_TRANSPORT_ABI_VERSION = transport_provider.PANCAKE_STREAM_TRANSPORT_ABI_VERSION;
pub const PANCAKE_TRANSPORT_EXEC_STREAM = transport_provider.PANCAKE_TRANSPORT_EXEC_STREAM;
pub const PANCAKE_TRANSPORT_EXEC_MULTIPLEXED = transport_provider.PANCAKE_TRANSPORT_EXEC_MULTIPLEXED;
pub const PANCAKE_MULTIPLEXED_WOULD_BLOCK = multiplexed_transport.PANCAKE_MULTIPLEXED_WOULD_BLOCK;
pub const PANCAKE_MULTIPLEXED_EV_READABLE = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_READABLE;
pub const PANCAKE_MULTIPLEXED_EV_WRITABLE = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_WRITABLE;
pub const PANCAKE_MULTIPLEXED_EV_CLOSED = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_CLOSED;
pub const PANCAKE_MULTIPLEXED_EV_ACCEPT = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_ACCEPT;
pub const PANCAKE_MULTIPLEXED_EV_CONNECT = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_CONNECT;
pub const PANCAKE_MULTIPLEXED_EV_LISTEN = multiplexed_transport.PANCAKE_MULTIPLEXED_EV_LISTEN;
pub const PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION = multiplexed_transport.PANCAKE_MULTIPLEXED_TRANSPORT_ABI_VERSION;
pub const PANCAKE_DESIGNATOR_SCHEME_ADDRESS = transport_provider.PANCAKE_DESIGNATOR_SCHEME_ADDRESS;
pub const PANCAKE_DESIGNATOR_SCHEME_KEY = transport_provider.PANCAKE_DESIGNATOR_SCHEME_KEY;
pub const PANCAKE_SEALED_CHANNEL_NONE = transport_provider.PANCAKE_SEALED_CHANNEL_NONE;
pub const PANCAKE_SEALED_CHANNEL_NOISE_XK = transport_provider.PANCAKE_SEALED_CHANNEL_NOISE_XK;
pub const PANCAKE_WIRE_FRAMING_BYTE_STREAM = transport_provider.PANCAKE_WIRE_FRAMING_BYTE_STREAM;
pub const PANCAKE_WIRE_FRAMING_MESSAGE = transport_provider.PANCAKE_WIRE_FRAMING_MESSAGE;
pub const PANCAKE_PENDING_CANCEL = close.PANCAKE_PENDING_CANCEL;
pub const PANCAKE_PENDING_FINISH = close.PANCAKE_PENDING_FINISH;
pub const PANCAKE_CLOSE_OPTIONS_ABI_VERSION = close.PANCAKE_CLOSE_OPTIONS_ABI_VERSION;
pub const PANCAKE_CLOSE_MAX_GRACE_MS = close.PANCAKE_CLOSE_MAX_GRACE_MS;
pub const PANCAKE_CLOSE_GRACE_UNSPECIFIED = close.PANCAKE_CLOSE_GRACE_UNSPECIFIED;
pub const PANCAKE_CLOSE_GRACE_FINITE = close.PANCAKE_CLOSE_GRACE_FINITE;
pub const PANCAKE_CLOSE_GRACE_UNBOUNDED = close.PANCAKE_CLOSE_GRACE_UNBOUNDED;
pub const PANCAKE_HINT_STRING = locator.PANCAKE_HINT_STRING;
pub const PANCAKE_HINT_BYTES = locator.PANCAKE_HINT_BYTES;
pub const PANCAKE_HINT_BOOLEAN = locator.PANCAKE_HINT_BOOLEAN;
pub const PANCAKE_HINT_INTEGER = locator.PANCAKE_HINT_INTEGER;
pub const PANCAKE_HINTS_MAP = locator.PANCAKE_HINTS_MAP;
pub const PANCAKE_HINTS_BOOLEAN_FALSE = locator.PANCAKE_HINTS_BOOLEAN_FALSE;

pub const result = @import("result.zig");
pub const PANCAKE_OK = result.PANCAKE_OK;
pub const PANCAKE_ERR_NULL_POINTER = result.PANCAKE_ERR_NULL_POINTER;
pub const PANCAKE_ERR_INVALID_ARGUMENT = result.PANCAKE_ERR_INVALID_ARGUMENT;
pub const PANCAKE_ERR_SESSION = result.PANCAKE_ERR_SESSION;
pub const PANCAKE_ERR_CODEC = result.PANCAKE_ERR_CODEC;
pub const PANCAKE_ERR_INTERNAL = result.PANCAKE_ERR_INTERNAL;
pub const PANCAKE_ERR_WOULD_BLOCK = result.PANCAKE_ERR_WOULD_BLOCK;
pub const PANCAKE_ERR_CLOSED = result.PANCAKE_ERR_CLOSED;
pub const PANCAKE_ERR_IO = result.PANCAKE_ERR_IO;
pub const PANCAKE_ERR_MALFORMED = result.PANCAKE_ERR_MALFORMED;
pub const PANCAKE_ERR_FRAME_TOO_LARGE = result.PANCAKE_ERR_FRAME_TOO_LARGE;
pub const PANCAKE_ERR_UNSUPPORTED_VALUE = result.PANCAKE_ERR_UNSUPPORTED_VALUE;
pub const PANCAKE_ERR_BROKEN = result.PANCAKE_ERR_BROKEN;
pub const PANCAKE_ERR_NOT_FOUND = result.PANCAKE_ERR_NOT_FOUND;
pub const PANCAKE_ERR_BUFFER_TOO_SMALL = result.PANCAKE_ERR_BUFFER_TOO_SMALL;
pub const PANCAKE_ERR_TIMEOUT = result.PANCAKE_ERR_TIMEOUT;
pub const locatorAdapterErrorCode = result.locatorAdapterErrorCode;
pub const isStableFailureResult = result.isStableFailureResult;
pub const hasValidFailureCauses = result.hasValidFailureCauses;

pub const profile = @import("profile.zig");
pub const PANCAKE_CODEC_UNKNOWN = profile.PANCAKE_CODEC_UNKNOWN;
pub const PANCAKE_CODEC_SYRUP = profile.PANCAKE_CODEC_SYRUP;
pub const PANCAKE_CODEC_CAPNP = profile.PANCAKE_CODEC_CAPNP;
pub const PANCAKE_CAPTP_V1_0 = profile.PANCAKE_CAPTP_V1_0;
pub const PANCAKE_CAPTP_NEXT = profile.PANCAKE_CAPTP_NEXT;
pub const PANCAKE_FEATURE_PIPELINING = profile.PANCAKE_FEATURE_PIPELINING;
pub const PANCAKE_FEATURE_HANDOFF = profile.PANCAKE_FEATURE_HANDOFF;
pub const PANCAKE_FEATURE_WIRE_DELTA = profile.PANCAKE_FEATURE_WIRE_DELTA;
pub const PANCAKE_FEATURE_STURDYREF = profile.PANCAKE_FEATURE_STURDYREF;
pub const PANCAKE_FEATURE_UNTAG = profile.PANCAKE_FEATURE_UNTAG;
pub const PANCAKE_FEATURE_MULTI_LOCATION = profile.PANCAKE_FEATURE_MULTI_LOCATION;
pub const PANCAKE_FEATURE_MINIMUM = profile.PANCAKE_FEATURE_MINIMUM;
pub const PANCAKE_FEATURE_FULL = profile.PANCAKE_FEATURE_FULL;
pub const PANCAKE_FEATURE_BASELINE = profile.PANCAKE_FEATURE_BASELINE;
pub const PANCAKE_DEFAULT_CODEC = profile.PANCAKE_DEFAULT_CODEC;
pub const PANCAKE_DEFAULT_CAPTP_VERSION = profile.PANCAKE_DEFAULT_CAPTP_VERSION;
pub const PANCAKE_DEFAULT_FEATURES = profile.PANCAKE_DEFAULT_FEATURES;
pub const PANCAKE_INTEROP_CODEC = profile.PANCAKE_INTEROP_CODEC;
pub const PANCAKE_INTEROP_CAPTP_VERSION = profile.PANCAKE_INTEROP_CAPTP_VERSION;
pub const PANCAKE_NATIVE_CODEC = profile.PANCAKE_NATIVE_CODEC;
pub const PANCAKE_NATIVE_CAPTP_VERSION = profile.PANCAKE_NATIVE_CAPTP_VERSION;
pub const captpVersionToC = profile.captpVersionToC;
pub const captpVersionFromC = profile.captpVersionFromC;
pub const codecToC = profile.codecToC;
pub const codecFromC = profile.codecFromC;
pub const framingOptionsFromC = profile.framingOptionsFromC;
pub const featureSetToC = profile.featureSetToC;
pub const featureSetFromC = profile.featureSetFromC;

pub const frame = @import("frame.zig");
pub const PANCAKE_FRAME_SHAPE_BYTE = frame.PANCAKE_FRAME_SHAPE_BYTE;
pub const PANCAKE_FRAME_SHAPE_WORD = frame.PANCAKE_FRAME_SHAPE_WORD;
pub const frameShapeFromC = frame.shapeFromC;
pub const PancakeFrame = frame.PancakeFrame;
pub const ReleaseFn = frame.ReleaseFn;
pub const PancakeManagedFrame = frame.PancakeManagedFrame;
pub const managedFrame = frame.managed;

pub const context = @import("context.zig");
pub const PancakeAllocFn = context.PancakeAllocFn;
pub const PancakeFreeFn = context.PancakeFreeFn;
pub const PancakeAllocator = context.PancakeAllocator;
pub const PancakeContext = context.PancakeContext;
pub const library_allocator = context.library_allocator;
pub const ContextAllocator = context.ContextAllocator;
pub const default_failure_capacity = context.default_failure_capacity;
pub const default_failure_payload_cap = context.default_failure_payload_cap;
pub const LifecycleIds = context.LifecycleIds;
pub const Context = context.Context;
pub const ctxFromOpaque = context.fromOpaque;

pub const last_error = @import("last_error.zig");
pub const setLastError = last_error.set;
pub const setLastErrorChain = last_error.setChain;
pub const failInternal = last_error.failInternal;
pub const failIo = last_error.failIo;
pub const lastErrorRead = last_error.read;
pub const lastErrorClear = last_error.clear;
pub const captureCallError = last_error.captureCall;
pub const optionalCallErrorOutputIsValid = last_error.optionalOutputIsValid;

pub const value = @import("value.zig");
pub const PANCAKE_ARG_INTEGER = value.PANCAKE_ARG_INTEGER;
pub const PANCAKE_ARG_FLOAT64 = value.PANCAKE_ARG_FLOAT64;
pub const PANCAKE_ARG_BOOLEAN = value.PANCAKE_ARG_BOOLEAN;
pub const PANCAKE_ARG_BYTES = value.PANCAKE_ARG_BYTES;
pub const PANCAKE_ARG_STRING = value.PANCAKE_ARG_STRING;
pub const PANCAKE_ARG_SYMBOL = value.PANCAKE_ARG_SYMBOL;
pub const PANCAKE_ARG_VOID = value.PANCAKE_ARG_VOID;
pub const PANCAKE_ARG_REFERENCE = value.PANCAKE_ARG_REFERENCE;
pub const PANCAKE_ARG_LIST = value.PANCAKE_ARG_LIST;
pub const PANCAKE_ARG_SET = value.PANCAKE_ARG_SET;
pub const PANCAKE_ARG_TAGGED = value.PANCAKE_ARG_TAGGED;
pub const PANCAKE_ARG_KEYWORD = value.PANCAKE_ARG_KEYWORD;
pub const PANCAKE_ARG_BIG_INTEGER = value.PANCAKE_ARG_BIG_INTEGER;
pub const PANCAKE_ARG_STRUCT = value.PANCAKE_ARG_STRUCT;
pub const PANCAKE_ARG_ERROR = value.PANCAKE_ARG_ERROR;
pub const PANCAKE_RESOLUTION_FULFILL = value.PANCAKE_RESOLUTION_FULFILL;
pub const PANCAKE_RESOLUTION_BREAK = value.PANCAKE_RESOLUTION_BREAK;
pub const PANCAKE_RESOLUTION_HANDOFF = value.PANCAKE_RESOLUTION_HANDOFF;
pub const PancakeReference = value.PancakeReference;
pub const PancakeArgument = value.PancakeArgument;
pub const zero_reference = value.zero_reference;
pub const zero_argument = value.zero_argument;
pub const MarshalError = value.MarshalError;
pub const feedErrorToCode = value.feedErrorToCode;
pub const marshalErrorToCode = value.marshalErrorToCode;
pub const PANCAKE_ABORT_DOMAIN_CODEC = value.PANCAKE_ABORT_DOMAIN_CODEC;
pub const PANCAKE_ABORT_DOMAIN_SESSION = value.PANCAKE_ABORT_DOMAIN_SESSION;
pub const PANCAKE_ABORT_DOMAIN_FOREIGN = value.PANCAKE_ABORT_DOMAIN_FOREIGN;
pub const PancakeLastAbort = value.PancakeLastAbort;
pub const lastAbortToC = value.lastAbortToC;
pub const sliceFromC = value.sliceFromC;
pub const max_marshal_depth = value.max_marshal_depth;
pub const argumentFromCWith = value.argumentFromCWith;
pub const argsFromCWith = value.argsFromCWith;
pub const valuesFromCWith = value.valuesFromCWith;
pub const argumentToCWith = value.argumentToCWith;
pub const argsToCWith = value.argsToCWith;
pub const connection = @import("connection.zig");
pub const ForeignCallBarrier = connection.ForeignCallBarrier;
pub const ConnDirectionGates = connection.ConnDirectionGates;
pub const connection_read_buf_bytes = connection.connection_read_buf_bytes;
pub const connection_write_buf_bytes = connection.connection_write_buf_bytes;
pub const ConnLifecycle = connection.ConnLifecycle;
pub const ConnFrameOps = connection.ConnFrameOps;
