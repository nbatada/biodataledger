# Using BioDataLedger with an agent

Use the [current BioDataLedger API reference](../API.md) for Python and R signatures, return fields and call effects. Agents use the same native project object as scientists.

## Open and choose the input

- Open the explicit project root once per process. Read compact status once for the loaded package version, registry revision and unsaved state, then group the lookups the task needs. `print(p)` gives a project overview from loaded metadata. If the registry is absent, obtain authorization before creating it.
- Use the exact DATA ref or scientist-selected purpose. Discovery results may be partial, and a role may be ambiguous. Keep the chosen exact ref and ask for the missing selection when needed. An unchecked availability field means unknown.
- Before loading the selected input, use [strict resolution](../API.md#resolve_data) with `verify="sha256"`. Report missing baselines, mismatches, or unmet scope requirements. Keep the original input selector and return mapping when updating an older helper. See [updating a project](../UPDATING.md).
- Use the project's native loader. For new authorized work, the [retained input workflow](../RETAINED_INPUTS.md) pairs the loaded object with its exact source view. Apply that pattern when useful without retrofitting a nearly complete project solely for bookkeeping.

## Retain work and confirm the save

- For an analysis already intended to be retained, stage its declaration with exact DATA inputs and known method, parameters, design and code before writing outputs. Inspect decisions separately. Use `code=` for script snapshots. Register saved files against the exact analysis and record figure rendering inputs separately when known.
- Obtain scientist authority for current input selections and scientific decisions. Preserve any external authority. Keep unknown provenance visible. Ordinary registration captures declared links. Explicit run receipts qualify wrapper activity, and file hashes identify checked bytes. Actual input consumption and scientific approval require separate evidence.
- Save once after a related registration batch or a completed critical input, design or decision change. [Save and confirm](../API.md#save_and_confirm) commits all pending edits. Use a returned `persisted` receipt with `registry_written` true to report a new durable write. Report any files left behind by failed registration, including which records remain unregistered or staged.
- On a stale write, preserve pending edits and saved files. Open a separate fresh handle and reconcile deliberately. A clean save does not check freshness. Reopen a clean handle when another writer's updates are needed.

## Share or resume

Preview the complete registry metadata and history alongside the selected payloads before an authorized export. Use exact getters and explicit verification to determine readiness for a named next task after import. Import leaves scripts inert. See [sharing and recovery](../API.md#save-share-and-recover).

These instructions guide use of the registry. They do not restrict an unrestricted interpreter or require calls on every chat turn.
