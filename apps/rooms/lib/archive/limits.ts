// Archive bounds shared by storage, protocol clients and managed presentation.
// The Rust archive owns each one, and `application_data.ts` mirrors it.
export {
	MAX_ARCHIVE_BLOB_READS_PER_SESSION,
	MAX_ARCHIVE_CONTEXT_BYTES,
	MAX_ARCHIVE_FACETS_PER_SESSION,
	MAX_ARCHIVE_ID_BYTES,
	MAX_ARCHIVE_READ,
	MAX_ARCHIVE_RECORDS,
} from "../application_data.ts";
