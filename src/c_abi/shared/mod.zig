//! The shared C-ABI waist. Subject modules own each layout and mechanism. This
//! root re-exports the stable vocabulary every symbol-disjoint
//! archive and generated binding consumes.
//!
//! This leaf declares **no `export fn`**. The public `glowcap_*` entry points
//! live in the `c_abi/ocapn` families (context, frame, uri), the Host, and
//! the `c_abi/net_transport/{tcp,inproc}` transport families, and the
//! `glowcap_iroh_*` entry points in `c_abi_net_transport_iroh`. All reach this
//! vocabulary through `@import("c_abi_shared")`. Because importing the leaf pulls the
//! vocabulary without pulling either library's exported surface, `libglowcap_ocapn`
//! carries the core families and `libglowcap_net_transport_iroh` carries only
//! the iroh family, each reusing these types, and each from `glowcap_ocapn.h`
//! on the C side
//! (ADR-0055 companion split). The two artifacts therefore share no exported
//! core symbol. They share the layout of these types, as a C consumer
//! including both headers does.

/// Process signal handlers and alternate signal stacks belong to the embedder.
/// Each separately compiled archive otherwise contributes Zig's 256 KiB TLS
/// signal stack to every native thread, even threads created by another runtime.
/// On pthread hosts that storage consumes the thread's stack allocation. Linking
/// several archives can exhaust a Rust worker's stack before ordinary work runs.
/// Every public C-ABI archive root selects these standard-library options.
pub const library_options: @import("std").Options = .{
    .enable_segfault_handler = false,
    .signal_stack_size = null,
};

// A libc-linked shared archive stays mapped for its process lifetime: a dynamic
// library emits the loader entry in `archive_pin.zig`, everything else nothing.
comptime {
    _ = @import("archive_pin.zig");
}

/// The one cross-archive schema and bounded mechanics for failures with no
/// remaining return recipient (ADR-0115). This leaf owns no mutable global.
/// Storage belongs to an explicit Context, Host, or driver owner.
pub const failure_diagnostics = @import("failure_diagnostics.zig");
pub const GlowcapFailureEvent = failure_diagnostics.GlowcapFailureEvent;
pub const GlowcapFailureReport = failure_diagnostics.GlowcapFailureReport;
pub const GLOWCAP_FAILURE_EVENT_ABI_VERSION = failure_diagnostics.abi_version;
pub const GLOWCAP_FAILURE_LAYER_CORE: u32 = @backingInt(failure_diagnostics.Layer.core);
pub const GLOWCAP_FAILURE_LAYER_DRIVER: u32 = @backingInt(failure_diagnostics.Layer.driver);
pub const GLOWCAP_FAILURE_LAYER_TRANSPORT: u32 = @backingInt(failure_diagnostics.Layer.transport);
pub const GLOWCAP_FAILURE_LAYER_BINDING: u32 = @backingInt(failure_diagnostics.Layer.binding);
pub const GLOWCAP_FAILURE_LAYER_APPLICATION_OBSERVER: u32 = @backingInt(failure_diagnostics.Layer.application_observer);
pub const GLOWCAP_FAILURE_SCOPE_PROCESS: u32 = @backingInt(failure_diagnostics.ScopeKind.process);
pub const GLOWCAP_FAILURE_SCOPE_CONTEXT: u32 = @backingInt(failure_diagnostics.ScopeKind.context);
pub const GLOWCAP_FAILURE_SCOPE_HOST: u32 = @backingInt(failure_diagnostics.ScopeKind.host);
pub const GLOWCAP_FAILURE_SCOPE_SESSION: u32 = @backingInt(failure_diagnostics.ScopeKind.session);
pub const GLOWCAP_FAILURE_SCOPE_LISTENER: u32 = @backingInt(failure_diagnostics.ScopeKind.listener);
pub const GLOWCAP_FAILURE_SCOPE_TRANSPORT: u32 = @backingInt(failure_diagnostics.ScopeKind.transport);
pub const GLOWCAP_FAILURE_SCOPE_OPERATION: u32 = @backingInt(failure_diagnostics.ScopeKind.operation);
pub const GLOWCAP_FAILURE_TRUNCATED_OPERATION = failure_diagnostics.truncated_operation;
pub const GLOWCAP_FAILURE_TRUNCATED_PRIMARY_NAME = failure_diagnostics.truncated_primary_name;
pub const GLOWCAP_FAILURE_TRUNCATED_PRIMARY_MESSAGE = failure_diagnostics.truncated_primary_message;
pub const GLOWCAP_FAILURE_TRUNCATED_SECONDARY_NAME = failure_diagnostics.truncated_secondary_name;
pub const GLOWCAP_FAILURE_TRUNCATED_SECONDARY_MESSAGE = failure_diagnostics.truncated_secondary_message;

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
    archive_contract.layout("GLOWCAP_REFERENCE", GlowcapReference),
    archive_contract.layout("GLOWCAP_ARGUMENT", GlowcapArgument),
    archive_contract.layout("GLOWCAP_FRAME", GlowcapFrame),
    archive_contract.layout("GLOWCAP_MANAGED_FRAME", GlowcapManagedFrame),
    archive_contract.layout("GLOWCAP_LAST_ABORT", GlowcapLastAbort),
    archive_contract.layout("GLOWCAP_ALLOCATOR", GlowcapAllocator),
    archive_contract.layout("GLOWCAP_FAILURE_REPORT", GlowcapFailureReport),
    archive_contract.layout("GLOWCAP_FAILURE_EVENT", GlowcapFailureEvent),
    archive_contract.layout("GLOWCAP_CLOSE_OPTIONS", GlowcapCloseOptions),
    archive_contract.layout("GLOWCAP_LOCATOR_HINT_VIEW", GlowcapLocatorHintView),
    archive_contract.layout("GLOWCAP_LOCATOR_VIEW", GlowcapLocatorView),
    archive_contract.cOnlyLayout("GLOWCAP_TRANSPORT_PROFILE", GlowcapTransportProfile),
    archive_contract.layout("GLOWCAP_TRANSPORT_OPERATION_OPTIONS", GlowcapTransportOperationOptions),
    archive_contract.cOnlyLayout("GLOWCAP_DIAL_ORIGIN", GlowcapDialOrigin),
    archive_contract.cOnlyLayout("GLOWCAP_PROVIDER_FAILURE", GlowcapProviderFailure),
    archive_contract.cOnlyLayout("GLOWCAP_LISTEN_RESULT", GlowcapListenResult),
    archive_contract.cOnlyLayout("GLOWCAP_STREAM_TRANSPORT", GlowcapStreamTransport),
    archive_contract.cOnlyLayout("GLOWCAP_TRANSPORT_PROVIDER_ENTRY", GlowcapTransportProviderEntry),
    archive_contract.layout("GLOWCAP_TRANSPORT_PROVIDER", GlowcapTransportProvider),
    archive_contract.cOnlyLayout("GLOWCAP_MULTIPLEXED_READY_EVENT", GlowcapMultiplexedReadyEvent),
    archive_contract.cOnlyLayout("GLOWCAP_MULTIPLEXED_TRANSPORT", GlowcapMultiplexedTransport),
};

/// The multiplexed-transport table layout (ADR-0112): how a sidecar transport
/// archive plugs its multiplexed transport into the driver archive.
/// Layout only, no exports, like everything in this leaf.
pub const multiplexed_transport = @import("multiplexed_transport.zig");
pub const close = @import("close.zig");
pub const locator = @import("locator.zig");
pub const locator_adapter = @import("locator_adapter.zig");
pub const transport_provider = @import("transport_provider.zig");
pub const GlowcapMultiplexedTransport = multiplexed_transport.GlowcapMultiplexedTransport;
pub const GlowcapMultiplexedReadyEvent = multiplexed_transport.GlowcapMultiplexedReadyEvent;
pub const GlowcapCloseOptions = close.GlowcapCloseOptions;
pub const GlowcapListenResult = transport_provider.GlowcapListenResult;
pub const GlowcapStreamTransport = transport_provider.GlowcapStreamTransport;
pub const GlowcapLocatorHintView = locator.GlowcapLocatorHintView;
pub const GlowcapLocatorView = locator.GlowcapLocatorView;
pub const GlowcapTransportProfile = transport_provider.GlowcapTransportProfile;
pub const GlowcapTransportOperationOptions = transport_provider.GlowcapTransportOperationOptions;
pub const GlowcapDialOrigin = transport_provider.GlowcapDialOrigin;
pub const GlowcapProviderFailure = transport_provider.GlowcapProviderFailure;
pub const GlowcapTransportProviderEntry = transport_provider.GlowcapTransportProviderEntry;
pub const GlowcapTransportProvider = transport_provider.GlowcapTransportProvider;
pub const GlowcapStreamStartConnectFn = transport_provider.GlowcapStreamStartConnectFn;
pub const GlowcapStreamFinishConnectFn = transport_provider.GlowcapStreamFinishConnectFn;
pub const GlowcapStreamCancelConnectFn = transport_provider.GlowcapStreamCancelConnectFn;
pub const GlowcapStreamListenFn = transport_provider.GlowcapStreamListenFn;
pub const GlowcapStreamFinishListenFn = transport_provider.GlowcapStreamFinishListenFn;
pub const GlowcapStreamCancelListenFn = transport_provider.GlowcapStreamCancelListenFn;
pub const GLOWCAP_LISTEN_READY = transport_provider.GLOWCAP_LISTEN_READY;
pub const GLOWCAP_LISTEN_PENDING = transport_provider.GLOWCAP_LISTEN_PENDING;
pub const GlowcapStreamListenerWaitFn = transport_provider.GlowcapStreamListenerWaitFn;
pub const GlowcapStreamListenerReadinessFdFn = transport_provider.GlowcapStreamListenerReadinessFdFn;
pub const GlowcapLocatorSinkFn = locator.GlowcapLocatorSinkFn;
pub const GlowcapTransportListenerRestorationStateFn = transport_provider.GlowcapTransportListenerRestorationStateFn;
pub const GlowcapTransportListenerLocatorFn = transport_provider.GlowcapTransportListenerLocatorFn;
pub const GlowcapTransportListenerAdvertiseFn = transport_provider.GlowcapTransportListenerAdvertiseFn;
pub const GlowcapStreamAcceptFn = transport_provider.GlowcapStreamAcceptFn;
pub const GlowcapStreamListenerCloseFn = transport_provider.GlowcapStreamListenerCloseFn;
pub const GlowcapStreamTryReadFn = transport_provider.GlowcapStreamTryReadFn;
pub const GlowcapStreamTryWriteFn = transport_provider.GlowcapStreamTryWriteFn;
pub const GlowcapStreamConnCloseFn = transport_provider.GlowcapStreamConnCloseFn;
pub const GlowcapStreamConnTakeFailureFn = transport_provider.GlowcapStreamConnTakeFailureFn;
pub const GlowcapTransportProviderSameConfigurationFn = transport_provider.GlowcapTransportProviderSameConfigurationFn;
pub const GlowcapTransportRetainFn = transport_provider.GlowcapTransportRetainFn;
pub const GlowcapTransportReleaseFn = transport_provider.GlowcapTransportReleaseFn;
pub const GlowcapMultiplexedReadinessFdFn = multiplexed_transport.GlowcapMultiplexedReadinessFdFn;
pub const GlowcapMultiplexedDrainReadyFn = multiplexed_transport.GlowcapMultiplexedDrainReadyFn;
pub const GlowcapMultiplexedStartConnectFn = multiplexed_transport.GlowcapMultiplexedStartConnectFn;
pub const GlowcapMultiplexedFinishConnectFn = multiplexed_transport.GlowcapMultiplexedFinishConnectFn;
pub const GlowcapMultiplexedClaimExternalFn = multiplexed_transport.GlowcapMultiplexedClaimExternalFn;
pub const GlowcapMultiplexedListenFn = multiplexed_transport.GlowcapMultiplexedListenFn;
pub const GlowcapMultiplexedFinishListenFn = multiplexed_transport.GlowcapMultiplexedFinishListenFn;
pub const GlowcapMultiplexedFinishAcceptFn = multiplexed_transport.GlowcapMultiplexedFinishAcceptFn;
pub const GlowcapMultiplexedStopListenFn = multiplexed_transport.GlowcapMultiplexedStopListenFn;
pub const GlowcapMultiplexedSubjectFn = multiplexed_transport.GlowcapMultiplexedSubjectFn;
pub const GlowcapMultiplexedConnTakeFailureFn = multiplexed_transport.GlowcapMultiplexedConnTakeFailureFn;
pub const GlowcapMultiplexedTryReadFn = multiplexed_transport.GlowcapMultiplexedTryReadFn;
pub const GlowcapMultiplexedTryWriteFn = multiplexed_transport.GlowcapMultiplexedTryWriteFn;
pub const GlowcapMultiplexedConnRemoteKeyFn = multiplexed_transport.GlowcapMultiplexedConnRemoteKeyFn;
pub const GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION = transport_provider.GLOWCAP_TRANSPORT_PROVIDER_ABI_VERSION;
pub const GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION = transport_provider.GLOWCAP_TRANSPORT_PROFILE_ABI_VERSION;
pub const GLOWCAP_LOCATOR_VIEW_ABI_VERSION = locator.GLOWCAP_LOCATOR_VIEW_ABI_VERSION;
pub const GLOWCAP_STREAM_TRANSPORT_ABI_VERSION = transport_provider.GLOWCAP_STREAM_TRANSPORT_ABI_VERSION;
pub const GLOWCAP_TRANSPORT_EXEC_STREAM = transport_provider.GLOWCAP_TRANSPORT_EXEC_STREAM;
pub const GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED = transport_provider.GLOWCAP_TRANSPORT_EXEC_MULTIPLEXED;
pub const GLOWCAP_TRANSPORT_WOULD_BLOCK = transport_provider.GLOWCAP_TRANSPORT_WOULD_BLOCK;
pub const GLOWCAP_MULTIPLEXED_EV_READABLE = multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_READABLE;
pub const GLOWCAP_MULTIPLEXED_EV_WRITABLE = multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_WRITABLE;
pub const GLOWCAP_MULTIPLEXED_EV_CLOSED = multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CLOSED;
pub const GLOWCAP_MULTIPLEXED_EV_ACCEPT = multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_ACCEPT;
pub const GLOWCAP_MULTIPLEXED_EV_CONNECT = multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_CONNECT;
pub const GLOWCAP_MULTIPLEXED_EV_LISTEN = multiplexed_transport.GLOWCAP_MULTIPLEXED_EV_LISTEN;
pub const GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION = multiplexed_transport.GLOWCAP_MULTIPLEXED_TRANSPORT_ABI_VERSION;
pub const GLOWCAP_DESIGNATOR_SCHEME_ADDRESS = transport_provider.GLOWCAP_DESIGNATOR_SCHEME_ADDRESS;
pub const GLOWCAP_DESIGNATOR_SCHEME_KEY = transport_provider.GLOWCAP_DESIGNATOR_SCHEME_KEY;
pub const GLOWCAP_SEALED_CHANNEL_NONE = transport_provider.GLOWCAP_SEALED_CHANNEL_NONE;
pub const GLOWCAP_SEALED_CHANNEL_NOISE_XK = transport_provider.GLOWCAP_SEALED_CHANNEL_NOISE_XK;
pub const GLOWCAP_WIRE_FRAMING_BYTE_STREAM = transport_provider.GLOWCAP_WIRE_FRAMING_BYTE_STREAM;
pub const GLOWCAP_WIRE_FRAMING_MESSAGE = transport_provider.GLOWCAP_WIRE_FRAMING_MESSAGE;
pub const GLOWCAP_PENDING_CANCEL = close.GLOWCAP_PENDING_CANCEL;
pub const GLOWCAP_PENDING_FINISH = close.GLOWCAP_PENDING_FINISH;
pub const GLOWCAP_CLOSE_OPTIONS_ABI_VERSION = close.GLOWCAP_CLOSE_OPTIONS_ABI_VERSION;
pub const GLOWCAP_CLOSE_MAX_GRACE_MS = close.GLOWCAP_CLOSE_MAX_GRACE_MS;
pub const GLOWCAP_CLOSE_GRACE_UNSPECIFIED = close.GLOWCAP_CLOSE_GRACE_UNSPECIFIED;
pub const GLOWCAP_CLOSE_GRACE_FINITE = close.GLOWCAP_CLOSE_GRACE_FINITE;
pub const GLOWCAP_CLOSE_GRACE_UNBOUNDED = close.GLOWCAP_CLOSE_GRACE_UNBOUNDED;
pub const GLOWCAP_HINT_STRING = locator.GLOWCAP_HINT_STRING;
pub const GLOWCAP_HINT_BYTES = locator.GLOWCAP_HINT_BYTES;
pub const GLOWCAP_HINT_BOOLEAN = locator.GLOWCAP_HINT_BOOLEAN;
pub const GLOWCAP_HINT_INTEGER = locator.GLOWCAP_HINT_INTEGER;
pub const GLOWCAP_HINTS_MAP = locator.GLOWCAP_HINTS_MAP;
pub const GLOWCAP_HINTS_BOOLEAN_FALSE = locator.GLOWCAP_HINTS_BOOLEAN_FALSE;

pub const result = @import("result.zig");
pub const GLOWCAP_OK = result.GLOWCAP_OK;
pub const GLOWCAP_ERR_NULL_POINTER = result.GLOWCAP_ERR_NULL_POINTER;
pub const GLOWCAP_ERR_INVALID_ARGUMENT = result.GLOWCAP_ERR_INVALID_ARGUMENT;
pub const GLOWCAP_ERR_SESSION = result.GLOWCAP_ERR_SESSION;
pub const GLOWCAP_ERR_CODEC = result.GLOWCAP_ERR_CODEC;
pub const GLOWCAP_ERR_INTERNAL = result.GLOWCAP_ERR_INTERNAL;
pub const GLOWCAP_ERR_WOULD_BLOCK = result.GLOWCAP_ERR_WOULD_BLOCK;
pub const GLOWCAP_ERR_CLOSED = result.GLOWCAP_ERR_CLOSED;
pub const GLOWCAP_ERR_IO = result.GLOWCAP_ERR_IO;
pub const GLOWCAP_ERR_MALFORMED = result.GLOWCAP_ERR_MALFORMED;
pub const GLOWCAP_ERR_FRAME_TOO_LARGE = result.GLOWCAP_ERR_FRAME_TOO_LARGE;
pub const GLOWCAP_ERR_UNSUPPORTED_VALUE = result.GLOWCAP_ERR_UNSUPPORTED_VALUE;
pub const GLOWCAP_ERR_BROKEN = result.GLOWCAP_ERR_BROKEN;
pub const GLOWCAP_ERR_NOT_FOUND = result.GLOWCAP_ERR_NOT_FOUND;
pub const GLOWCAP_ERR_BUFFER_TOO_SMALL = result.GLOWCAP_ERR_BUFFER_TOO_SMALL;
pub const GLOWCAP_ERR_TIMEOUT = result.GLOWCAP_ERR_TIMEOUT;
pub const locatorAdapterErrorCode = result.locatorAdapterErrorCode;
pub const netlayerFailureCode = result.netlayerFailureCode;
pub const isStableFailureResult = result.isStableFailureResult;
pub const hasValidFailureCauses = result.hasValidFailureCauses;

pub const profile = @import("profile.zig");
pub const GLOWCAP_CODEC_UNKNOWN = profile.GLOWCAP_CODEC_UNKNOWN;
pub const GLOWCAP_CODEC_SYRUP = profile.GLOWCAP_CODEC_SYRUP;
pub const GLOWCAP_CODEC_CAPNP = profile.GLOWCAP_CODEC_CAPNP;
pub const GLOWCAP_CAPTP_V1_0 = profile.GLOWCAP_CAPTP_V1_0;
pub const GLOWCAP_CAPTP_NEXT = profile.GLOWCAP_CAPTP_NEXT;
pub const GLOWCAP_FEATURE_PIPELINING = profile.GLOWCAP_FEATURE_PIPELINING;
pub const GLOWCAP_FEATURE_HANDOFF = profile.GLOWCAP_FEATURE_HANDOFF;
pub const GLOWCAP_FEATURE_WIRE_DELTA = profile.GLOWCAP_FEATURE_WIRE_DELTA;
pub const GLOWCAP_FEATURE_STURDYREF = profile.GLOWCAP_FEATURE_STURDYREF;
pub const GLOWCAP_FEATURE_UNTAG = profile.GLOWCAP_FEATURE_UNTAG;
pub const GLOWCAP_FEATURE_MULTI_LOCATION = profile.GLOWCAP_FEATURE_MULTI_LOCATION;
pub const GLOWCAP_FEATURE_MINIMUM = profile.GLOWCAP_FEATURE_MINIMUM;
pub const GLOWCAP_FEATURE_FULL = profile.GLOWCAP_FEATURE_FULL;
pub const GLOWCAP_FEATURE_BASELINE = profile.GLOWCAP_FEATURE_BASELINE;
pub const GLOWCAP_DEFAULT_CODEC = profile.GLOWCAP_DEFAULT_CODEC;
pub const GLOWCAP_DEFAULT_CAPTP_VERSION = profile.GLOWCAP_DEFAULT_CAPTP_VERSION;
pub const GLOWCAP_DEFAULT_FEATURES = profile.GLOWCAP_DEFAULT_FEATURES;
pub const GLOWCAP_INTEROP_CODEC = profile.GLOWCAP_INTEROP_CODEC;
pub const GLOWCAP_INTEROP_CAPTP_VERSION = profile.GLOWCAP_INTEROP_CAPTP_VERSION;
pub const GLOWCAP_OWN_CODEC = profile.GLOWCAP_OWN_CODEC;
pub const GLOWCAP_OWN_CAPTP_VERSION = profile.GLOWCAP_OWN_CAPTP_VERSION;
pub const captpVersionToC = profile.captpVersionToC;
pub const captpVersionFromC = profile.captpVersionFromC;
pub const codecToC = profile.codecToC;
pub const codecFromC = profile.codecFromC;
pub const framingOptionsFromC = profile.framingOptionsFromC;
pub const featureSetToC = profile.featureSetToC;
pub const featureSetFromC = profile.featureSetFromC;

pub const frame = @import("frame.zig");
pub const GLOWCAP_FRAME_SHAPE_BYTE = frame.GLOWCAP_FRAME_SHAPE_BYTE;
pub const GLOWCAP_FRAME_SHAPE_WORD = frame.GLOWCAP_FRAME_SHAPE_WORD;
pub const frameShapeFromC = frame.shapeFromC;
pub const GlowcapFrame = frame.GlowcapFrame;
pub const ReleaseFn = frame.ReleaseFn;
pub const GlowcapManagedFrame = frame.GlowcapManagedFrame;
pub const managedFrame = frame.managed;

pub const context = @import("context.zig");
pub const GlowcapAllocFn = context.GlowcapAllocFn;
pub const GlowcapFreeFn = context.GlowcapFreeFn;
pub const GlowcapAllocator = context.GlowcapAllocator;
pub const GlowcapContext = context.GlowcapContext;
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
pub const GLOWCAP_ARG_INTEGER = value.GLOWCAP_ARG_INTEGER;
pub const GLOWCAP_ARG_FLOAT64 = value.GLOWCAP_ARG_FLOAT64;
pub const GLOWCAP_ARG_BOOLEAN = value.GLOWCAP_ARG_BOOLEAN;
pub const GLOWCAP_ARG_BYTES = value.GLOWCAP_ARG_BYTES;
pub const GLOWCAP_ARG_STRING = value.GLOWCAP_ARG_STRING;
pub const GLOWCAP_ARG_SYMBOL = value.GLOWCAP_ARG_SYMBOL;
pub const GLOWCAP_ARG_VOID = value.GLOWCAP_ARG_VOID;
pub const GLOWCAP_ARG_REFERENCE = value.GLOWCAP_ARG_REFERENCE;
pub const GLOWCAP_ARG_LIST = value.GLOWCAP_ARG_LIST;
pub const GLOWCAP_ARG_SET = value.GLOWCAP_ARG_SET;
pub const GLOWCAP_ARG_TAGGED = value.GLOWCAP_ARG_TAGGED;
pub const GLOWCAP_ARG_KEYWORD = value.GLOWCAP_ARG_KEYWORD;
pub const GLOWCAP_ARG_BIG_INTEGER = value.GLOWCAP_ARG_BIG_INTEGER;
pub const GLOWCAP_ARG_STRUCT = value.GLOWCAP_ARG_STRUCT;
pub const GLOWCAP_ARG_ERROR = value.GLOWCAP_ARG_ERROR;
pub const GLOWCAP_ARG_INTEGERS = value.GLOWCAP_ARG_INTEGERS;
pub const GLOWCAP_RESOLUTION_FULFILL = value.GLOWCAP_RESOLUTION_FULFILL;
pub const GLOWCAP_RESOLUTION_BREAK = value.GLOWCAP_RESOLUTION_BREAK;
pub const GLOWCAP_RESOLUTION_HANDOFF = value.GLOWCAP_RESOLUTION_HANDOFF;
pub const GlowcapReference = value.GlowcapReference;
pub const GlowcapArgument = value.GlowcapArgument;
pub const zero_reference = value.zero_reference;
pub const zero_argument = value.zero_argument;
pub const MarshalError = value.MarshalError;
pub const feedErrorToCode = value.feedErrorToCode;
pub const marshalErrorToCode = value.marshalErrorToCode;
pub const GLOWCAP_ABORT_DOMAIN_CODEC = value.GLOWCAP_ABORT_DOMAIN_CODEC;
pub const GLOWCAP_ABORT_DOMAIN_SESSION = value.GLOWCAP_ABORT_DOMAIN_SESSION;
pub const GLOWCAP_ABORT_DOMAIN_FOREIGN = value.GLOWCAP_ABORT_DOMAIN_FOREIGN;
pub const GlowcapLastAbort = value.GlowcapLastAbort;
pub const lastAbortToC = value.lastAbortToC;
pub const sliceFromC = value.sliceFromC;
pub const itemsFromC = value.itemsFromC;
pub const max_marshal_depth = value.max_marshal_depth;
pub const argumentFromCWith = value.argumentFromCWith;
pub const argsFromCWith = value.argsFromCWith;
pub const valuesFromCWith = value.valuesFromCWith;
pub const argumentToCWith = value.argumentToCWith;
pub const argsToCWith = value.argsToCWith;
pub const valueToCWith = value.valueToCWith;
pub const valuesToCWith = value.valuesToCWith;
pub const connection = @import("connection.zig");
pub const ForeignCallBarrier = connection.ForeignCallBarrier;
pub const ConnDirectionGates = connection.ConnDirectionGates;
pub const connection_read_buf_bytes = connection.connection_read_buf_bytes;
pub const connection_write_buf_bytes = connection.connection_write_buf_bytes;
pub const ConnLifecycle = connection.ConnLifecycle;
pub const ConnFrameOps = connection.ConnFrameOps;
