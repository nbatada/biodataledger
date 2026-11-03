# Using BioDataLedger with an agent

The package works without agents. Use the installed native R/Python API and the same project object as a scientist. At task start, open the explicit project root once and query compact status. Use exact registered paths/revisions; if lookup is missing or ambiguous, report it and ask for the needed selection rather than guessing or crawling unrelated files.

Ordinary getters and status are metadata-only. Unknown availability is not a missing file. Before using a selected input, explicitly call `resolve_data(purpose=..., verify="sha256")`; this streams that file and refuses a missing baseline, changed bytes or contradictory required scope. Use `check_files=True`/`TRUE` only when existence checks are wanted. Do not repeatedly reopen or send the whole registry into context. A loaded object must be reopened deliberately to see another writer's changes.

Let native analysis remain native. Register actual saved retained outputs with known input/code/method/parameters, sharing one analysis reference across related figures. Unknown provenance stays unknown; file capture is not execution proof. Save meaningful staged changes, not every message. On stale state, preserve edits and reconcile; never silently merge or steal locks.

Obtain actual scientist authority before changing current-for-purpose inputs or scientific decisions. Preserve external scientific owners. Preview all files and metadata before an authorized export. Import is inert. Distinguish inspectability, readiness for a named next task, and an actual verified rerun.

This is short guidance, not a security boundary against an unrestricted shell/interpreter, not an LLM-session recorder and not a required agent integration.
