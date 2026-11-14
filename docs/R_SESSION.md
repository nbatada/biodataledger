# Reuse an object in one live R session

This helper is available in **source version 0.18.0 on main**. The published
`v0.17.0` release-tag installation does not include it. Install the reviewed
checkout containing this helper into your chosen R library using the
[source-install instructions](../README.md#install); keep that checkout rather
than switching to the release tag.

The optional R session helper keeps one current native object per named slot in
one designated R process. It is separate from `ProjectBundle` metadata. It does
not connect to Positron, start an interpreter, or transport commands between
processes. An agent must already have a supported way to execute in the same live
R console as the scientist.

In the intended long-lived console, explicitly start once:

```r
library(BioDataLedger)
session <- bdl_session_start("/absolute/project/path")
session$load_once("analysis", "DATA-001@1", readRDS)
session
```

Use the exact scientist-selected DATA revision. `load_once()` first uses the
existing `resolve_data(..., verify = "sha256")`, then gives that resolved path to
the supplied native loader. It returns compact metadata, not the object. The
loader runs once for this slot and exact source. Repeating the call returns
`reused = TRUE` without checking the source file, hashing it, or invoking the
loader again, including when that file has subsequently become unavailable.
This checks source-file bytes before the loader runs; it does not prove that the
loader consumed those bytes, ongoing availability, or current object equality
with source bytes. The loader function is not retained by the helper.

Routine code running in that console attaches to the existing handle:

```r
session <- bdl_session_attach("/absolute/project/path")
metadata <- session$load_once("analysis", "DATA-001@1", readRDS)
current_data <- session$get_data("analysis")
```

Do not fall back to `start()` or `recover()` when an agent cannot attach. In the
owning process, repeated start or attach returns the same handle and the same
opened `ProjectBundle`. Another process receives `USE_LIVE_R_SESSION` with the
recorded host, PID and session ID. This error requires routing execution to the
owner; it does not establish such a connection. Forked or serialized copies of
the handle cannot operate as the live handle, even if the owner is still running.
Avoid serializing handles: they contain live native object references.

`get_data()` retrieves the current native object without loading, recomputation,
object hashing or defensive deep copies. `info(slot)` returns detached compact
metadata; `info()` reports the owner and all loaded slots. A second slot for the
same logical DATA ID is refused, including a different revision. A different
exact source in an occupied slot is refused. Different DATA IDs are distinct;
the helper does not infer biological equivalence from paths or file hashes.

## Replace or release deliberately

A replacement requires the observed generation, a reason and a validator that
returns exactly `TRUE`:

```r
observed <- session$info("analysis")
session$replace_data(
  "analysis",
  transform(session$get_data("analysis"), value = value + 1),
  expected_generation = observed$generation,
  reason = "Scientist-approved transformation of this synthetic example",
  validate = function(candidate) is.data.frame(candidate) && "value" %in% names(candidate)
)
```

The ownership and expected-generation checks occur before R evaluates the `value`
argument. A stale generation therefore cannot accidentally evaluate an expensive
candidate expression. While constructing or validating a candidate, read-only
`get_data()` and `info()` can inspect the previous current value. Recursive load,
replacement, release or close is refused for the busy slot (close is refused
while any slot is busy). A failed loader does not create a managed binding. A
failed validator leaves the previous binding and metadata unchanged for ordinary
value-semantic objects.

A successful replacement increments the generation and sets
`modified_since_load = TRUE`. Its `origin_ref` and `source_verified_at` still
identify the original source verification; they do **not** claim that the
modified object equals that source. The helper retains one current binding, no
object history, and no validator closure. A validator is a caller-supplied check,
not scientific acceptance. The helper does not mutate the ledger or save a
scientific result when loading or replacing.

```r
observed <- session$info("analysis")
session$release_data("analysis", observed$generation, "Finished using this object")
```

Release removes the helper's binding only. It does not delete source files,
remove aliases in the user's workspace, or save anything. A later explicit load
into the same slot receives a higher generation, so pre-release generations
remain stale. Normal native registration and explicit batch saves use the one
opened handle returned by `session$project()`.

## Refresh project metadata deliberately

If another native client saves the project, the opened ledger handle can become
stale. Do not reopen or reload the native scientific object. Refresh only the
project metadata:

```r
previous <- session$refresh_project(reason = "Read an external metadata update")
```

Refresh returns the previous native `ProjectBundle` handle and uses a newly
opened handle for `session$project()`. It requires the same project UUID and
matching recorded identity for every cached exact source, including digest,
size, role, scope and design binding. A matching ref string alone is insufficient:
two pending writers can assign the same ID/revision to different inputs. Missing
or changed origin metadata refuses before swapping handles. File-path rebinding
with the same recorded identity can remain valid. The check reads ledger metadata
without loading or rehashing source data; ordinary registry opening still reads
and hashes the small ledger file. Cached objects, generations and modified flags
remain unchanged.

Pending ledger edits refuse by default. When you explicitly choose to retain and
reconcile those edits separately, keep the returned handle:

```r
previous <- session$refresh_project(
  reason = "Reconcile an external metadata update",
  allow_pending = TRUE
)
# Inspect previous and deliberately reconcile its pending edits using native APIs.
# session$project() is now the fresh canonical metadata handle.
```

This does not mutate, discard or save `previous` and does not resolve conflicting
edits automatically. Retain the return value when it contains pending work; the
helper keeps no hidden history of old handles. A stale previous handle may still
refuse saving and require manual reconciliation into the fresh handle. A cached
source identity conflict must be resolved explicitly before refresh; deliberate
slot release does not delete source files or other aliases. Refresh is refused
while any loader or validator is running. These are explicit metadata operations,
not an automatic response to failed attachment or a data checkpoint.

## Close or recover explicitly

Checkpoint retained scientific results before closing:

```r
session$project()$save()  # only when there are deliberate registry edits to save
session$close()
```

`close()` checks the ownership marker, refuses pending unsaved ledger edits,
releases managed references, removes only its owner marker and empty ownership
directory, and invalidates the handle. It never removes user globals, deletes
source data, forces garbage collection or automatically saves an object. The
scientist remains responsible for checkpointing modified native data: the helper
cannot determine which in-memory changes should be retained.

Ownership is recorded separately in `.nb_project_bundle/r-session/owner.json`.
The small versioned marker records the canonical root, project identity, host,
PID, creation time and session/process nonces. It is outside ledger JSON and ZIP
payloads. Start/attach/close reject symbolic links, malformed owners and unexpected
ownership-directory contents. Ordinary retrieval checks the live process and
in-memory handle token, without repeated process probes or payload-file checks.
These are accidental-misuse safeguards, not a security boundary against an
unrestricted R process or shell.

An owner that exits without closing leaves a marker. Neither start nor attach
takes it over. After confirming that the intended owner stopped, recover with its
exact recorded session ID:

```r
bdl_session_recover(
  "/absolute/project/path",
  expected_session_id = "exact-session-UUID-from-owner.json",
  reason = "The owning disposable R process exited"
)
# Then, deliberately start in the selected long-lived R console if appropriate.
```

Recovery is currently limited to the same host on macOS. A signal-zero existence
probe does not terminate a process. Recovery requires an explicit absent-process
result; live processes, permission failures and uncertain results refuse and
preserve the marker. A reused PID is conservatively treated as live. Recovery
removes only expected helper metadata, never reloads data, and never creates a
new owner automatically. Incomplete markers left by a process crash are preserved
for inspection; ordinary start-publication errors clean only their new reservation.

## Limits

One managed binding does not guarantee one physical R allocation. Ordinary aliases,
copy-on-modify, Seurat/native object behavior and reference-semantic mutations
remain native R behavior. The helper cannot prevent a caller from separately
loading or copying an object, detect every mutation made through an alias, or
roll back arbitrary by-reference mutation. Validators must not mutate shared
reference-semantic objects. `modified_since_load` describes helper-mediated
replacement, not a universal mutation detector.

The optional [synthetic example](../examples/session_R.R) shows reusing current
cached values to prepare a small plotting table without another file load. It
only defines functions when sourced. Local tests use disposable R processes;
they do not demonstrate real Positron connectivity, physical memory savings,
scientific correctness or scientist usability.
