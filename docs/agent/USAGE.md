# Using BioDataLedger with an agent

The package works without agents. Use the installed native R/Python API and the same project object as a scientist. At task start, open the explicit project root once and query compact status. Use exact registered paths/revisions; if lookup is missing or ambiguous, report it and ask for the needed selection rather than guessing or crawling unrelated files.

Ordinary getters and status are metadata-only. Unknown availability is not a missing file. Before using a selected input, explicitly call `resolve_data(purpose=..., verify="sha256")`; this streams that file and refuses a missing baseline, changed bytes or contradictory required scope. Use `check_files=True`/`TRUE` only when existence checks are wanted. Do not repeatedly reopen or send the whole registry into context. A loaded object must be reopened deliberately to see another writer's changes.

For an older input helper, replace its metadata lookup and unchecked-availability
rejection with native `resolve_data(..., verify="sha256")`. Keep the original
exact reference/purpose, function signature and return mapping. Do not substitute
an existence check, auto-register a new digest or fall back to another dataset.
The [migration guide](../api/API_0.5.0.md#updating-older-input-helpers) covers role
selectors and missing digests.

There is no mandatory operation on every chat turn. Keep one project object in
the current R session or Python process and query it only when the task needs
registered information. If each tool call starts a fresh process, open once in
that process and group related lookups in that call. The package does not keep
an object alive across processes.

| When | Smallest useful action |
| --- | --- |
| Start or resume a task | Open the supplied root and read compact `status()` once. |
| Inspect a known result | Use its exact getter; return only the fields needed for the question. |
| Use a selected scientific input | Call strict `resolve_data` before reading that input; do not hash it for unrelated conversation. |
| Retain an analysis and related figures | Register one analysis, link the saved figures, then save once. |
| Another writer saved | Reopen when its new records are needed. If local edits exist, preserve and reconcile them first. |

A loaded object describes its loaded revision. It does not promise the newest
registry state. Before committing changes, the existing writer lock and full
registry-byte digest detect another writer's update, including edits that keep
the same revision number. A clean `save()` performs no I/O; it is not a freshness
check. These checks read registry metadata, not scientific payloads.

Let native analysis remain native. Register actual saved retained outputs with known input/code/method/parameters, sharing one analysis reference across related figures. Unknown provenance stays unknown; file capture is not execution proof. Save meaningful staged changes, not every message. On stale state, preserve edits and reconcile; never silently merge or steal locks.

Use the returned `evidence` fields to report declared input/code relationships
and missing execution evidence. Complete registration, matching file hashes,
code snapshots and successful imports do not establish that the declared
analysis ran. The current API always reports execution as unknown and execution
evidence from ordinary registration as not captured; explicit run receipts are
queried separately. Free-form labels in stored `details` remain caller
declarations, including labels that say "observed" or "verified".

Obtain actual scientist authority before changing current-for-purpose inputs or scientific decisions. Preserve external scientific owners. Preview all files and metadata before an authorized export. Import is inert. Distinguish inspectability, readiness for a named next task, and an actual verified rerun.

This is short guidance, not a security boundary against an unrestricted shell/interpreter, not an LLM-session recorder and not a required agent integration.

## Persistence boundary

In a build providing save_and_confirm, use `p.save_and_confirm()` (Python) or
`p$save_and_confirm()` (R) immediately after a completed critical input/design/
decision change, or once after a related registration batch. It commits every
pending edit, not just the last record. Only a returned `persisted` receipt with
registry_written true confirms this write; include its revision/transaction when
reporting durable retention. A clean `no_changes` result does not check freshness.
Propagate save errors and preserve pending edits for reconciliation. Do not claim
scientific verification or approval from the receipt. Older builds still require
explicit `save()`; do not claim a helper is installed without checking that build.

## Derived results in 0.6.0

Use register_result for an existing derived file or exact DATA source; it references
the file by default. Declare the exact producer and embedding selector/observation
reference. Do not claim validation from registration. check_result explicitly
measures CSV evidence; native Seurat/AnnData selectors remain UNKNOWN until an
adapter measures them. Use exact rendering_inputs for figures, dependencies for
bounded metadata lookup, and save_and_confirm once after a retained-result batch.
Unknown provenance must remain unknown; never reconstruct historical links from
filenames, equal counts or registration order. See docs/api/RESULTS_V1.md.


## Explicit execution in 0.7.0

Only an explicit authorized `run_analysis` invokes code. It executes one registered
snapshot function and persists started/terminal receipts; see
[the execution contract](../api/EXECUTION_V1.md). Registration, import and queries
never execute code. Use the exact terminal `receipt_ref` with `get_execution` or
`execution_summary`. A successful callback or matching input digest never proves
actual input consumption, scientific validity or downstream use. Started means
completion was not recorded. Do not promote declarations or recreate missing history.


## Scientific decisions in 0.8.0

Record only scientist-submitted decisions using `record_scientific_decision`, with
exact subject/evidence refs and separate cluster identifiers and annotation labels.
Scientific status is distinct from record lifecycle; the package does not authenticate
approval. Use `get_decision` for exact revisions and `save_and_confirm` for retention.
Do not infer missing decisions or biological labels. See [the contract](../api/DECISIONS_V1.md).
