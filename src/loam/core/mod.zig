//! Portable record transactions and bounded residency. Stores emit explicit
//! read and write work. The embedding owns execution and completion delivery.
const records = @import("loam_records");

pub const Record = records.Record;
pub const RecordView = records.View;
pub const Edge = records.Edge;
pub const ObjectId = records.ObjectId;
pub const StoreId = records.StoreId;
pub const Schema = records.Schema;
pub const Metadata = @import("transaction.zig").Metadata;
pub const OpenMode = @import("transaction.zig").OpenMode;
pub const Ticket = @import("transaction.zig").Ticket;
pub const Batch = @import("transaction.zig").Batch;
pub const Mutation = @import("transaction.zig").Mutation;
pub const Outcome = @import("transaction.zig").Outcome;
pub const Resolution = @import("transaction.zig").Resolution;
pub const Read = @import("residency.zig").Read;
pub const ReadResult = @import("residency.zig").ReadResult;
pub const Lease = @import("residency.zig").Lease;
pub const Acquisition = @import("residency.zig").Acquisition;
pub const Ahead = @import("residency.zig").Ahead;
pub const metadata_key = @import("transaction.zig").metadata_key;
pub const Store = @import("store.zig").Store;
pub const CollectionRow = @import("collection.zig").Row;
pub const max_key_bytes = @import("collection.zig").max_key_bytes;
pub const Retention = @import("retention.zig").Retention;
pub const backend = @import("backend.zig");
pub const NameLookup = @import("names.zig").Lookup;
pub const NameResult = @import("names.zig").Result;
