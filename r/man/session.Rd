\name{bdl_session_start}
\alias{bdl_session_start}
\alias{bdl_session_attach}
\alias{bdl_session_recover}
\alias{print.BioDataLedgerSession}
\title{Reuse Native Objects in One Designated Live R Process}
\description{
Optional process-local object reuse alongside the native project registry.
There is no interpreter bridge, automatic takeover, data serialization or
scientific acceptance implied by a managed object.
}
\usage{
bdl_session_start(project_dir)
bdl_session_attach(project_dir)
bdl_session_recover(project_dir, expected_session_id, reason)
\method{print}{BioDataLedgerSession}(x, ...)
}
\arguments{
\item{project_dir}{Existing project root, resolved to its canonical local path.}
\item{expected_session_id}{Exact UUID from the stopped owner's ownership marker.}
\item{reason}{Nonempty explanation of deliberate ownership recovery.}
\item{x}{A live session handle.}
\item{...}{Reserved print arguments.}
}
\value{
Start and attach return the same \code{BioDataLedgerSession} handle within its
owning process. Recovery returns compact recovery metadata without loading data
or starting a new owner. Printing returns the handle invisibly.
}
\details{
Start is explicit initialization in the intended long-lived console. Routine code
attaches in that same process; attach does not connect to Positron or another
interpreter. Other processes, forked handles and serialized copies reject with
\code{USE_LIVE_R_SESSION}. The scientist or agent must already be able to execute
in the owner's R console. Support currently follows the package's macOS write
boundary. Use a reviewed package installation containing this helper; installing
a package does not update a namespace already loaded in a live R process.

Use \code{session$project()} for the canonical ledger handle in a managed session.
Repeated ordinary \code{ProjectBundle$open()} calls create independent metadata
handles. The helper cannot prevent arbitrary R aliases or copy-on-modify; do not
serialize the session handle or a workspace containing it. A separate
\code{Rscript} launch cannot reuse another process's memory. Use one process for
a complete batch, or an existing executor connected to the designated live owner.

The handle exposes these methods:
\describe{
\item{\code{project()}}{The current opened \code{ProjectBundle} for deliberate native registration and batch saves.}
\item{\code{load_once(slot, ref, loader)}}{Load one exact DATA revision using \code{resolve_data(verify = "sha256")} and the caller's native \code{loader(path)}. Returns compact metadata with \code{reused = FALSE}. The same slot/exact source returns metadata with \code{reused = TRUE}, without payload checks or loader calls. Another source in a loaded slot or another slot for the same logical DATA ID is refused.}
\item{\code{get_data(slot)}}{Return the current native object without loading, hashing or defensive copying.}
\item{\code{info(slot = NULL)}}{Detached compact metadata, including \code{origin_ref}, generation, \code{modified_since_load}, object class, source verification time and owner. Without a slot, return owner and all loaded slot metadata.}
\item{\code{replace_data(slot, value, expected_generation, reason, validate)}}{Check ownership and expected generation before forcing the \code{value} promise. Require \code{validate(value)} to return exactly \code{TRUE}, then replace the managed binding, increment generation and mark modified. Returns compact metadata. Origin identifies the original source, not equality of modified data with source bytes.}
\item{\code{release_data(slot, expected_generation, reason)}}{Release only the helper's binding; returns metadata with \code{released = TRUE}. Reloading a released slot advances its generation.}
\item{\code{refresh_project(reason, allow_pending = FALSE)}}{Explicitly reopen only project metadata from the same root/project UUID after an external save. Require matching cached source metadata identities, including digest, size, role, scope and design binding, before swapping handles. No native object reload or payload hash; ordinary opening reads/hashes the small ledger. Refuse pending edits by default. With explicit \code{allow_pending = TRUE}, return the previous native handle unchanged so the caller can retain and reconcile pending edits; the helper stores no old-handle history. Clean refresh also returns the previous handle. Cached objects and slot metadata remain unchanged.}
\item{\code{close()}}{Refuse busy slots or pending unsaved ledger edits; remove expected owner metadata, release managed references and invalidate the handle. No automatic data save, global deletion or garbage collection.}
}

Reasons are required for replacement, release and metadata refresh. Retain the
return value of an allowed pending refresh; it does not resolve stale writes or
conflicting edits automatically. A matching ref text alone does not establish
source identity when concurrent pending writers assign the same ID/revision. Recursive load, replacement and
release of a busy slot, or close/metadata refresh while any slot is busy, are refused. Read-only
retrieval can inspect the old current value during candidate evaluation or
validation. Failed validation preserves the binding and metadata for ordinary
value-semantic objects, but cannot undo arbitrary shared by-reference mutation.
Validators must not mutate shared reference-semantic objects and do not establish
scientific acceptance. Loader and validator closures are not retained.

The small exclusive \code{.nb_project_bundle/r-session/owner.json} marker remains
outside the ledger JSON and ZIP payload contract. Ownership paths reject symlinks,
collisions and malformed/unknown markers. Recovery is explicit, exact-token,
same-host macOS only, requiring a signal-zero probe's explicit absent-process
result. It never kills a process, automatically takes over, or reloads data.
Live or uncertain owners refuse. Incomplete crash markers require inspection.
Ordinary retrieval checks process/token identity without repeated liveness probes.

One managed binding is not a guarantee of one physical allocation. Native aliases,
copy-on-modify and reference semantics remain R behavior. Modified status tracks
helper-mediated replacement, not all possible alias mutations. Scientific
checkpointing and scientific/user acceptance remain the caller's responsibility.
}
\examples{
\dontrun{
# Explicitly initialize in the intended live R console once:
session <- bdl_session_start("/absolute/project")
session$load_once("analysis", "DATA-001@1", readRDS)
# Subsequent code must execute in that same console:
session <- bdl_session_attach("/absolute/project")
session$info("analysis")
session$get_data("analysis")
# Save deliberately staged ledger edits and checkpoint retained data before close.
session$close()
}
}
