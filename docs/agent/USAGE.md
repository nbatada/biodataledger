# Using BioDataLedger with an agent

Use the [current BioDataLedger API reference](../API.md) for Python and R signatures, return fields and call effects. Agents use the same native project object as scientists.

## Open and choose the input

- Open the explicit project root once per process. Read compact status once for the loaded package version, registry revision and unsaved state, then group the lookups the task needs. `print(p)` gives a project overview from loaded metadata. If the registry is absent, obtain authorization before creating it.
- Use the exact DATA ref or scientist-selected purpose. Discovery results may be partial, and a role may be ambiguous. Keep the chosen exact ref and ask for the missing selection when needed. An unchecked availability field means unknown.
- Before loading the selected input, use [strict resolution](../API.md#resolve_data) with `verify="sha256"`. Report missing baselines, mismatches, or unmet scope requirements. Keep the original input selector and return mapping when updating an older helper. See [updating a project](../UPDATING.md).
- Use the project's native loader. For new authorized work, the [retained input workflow](../RETAINED_INPUTS.md) pairs the loaded object with its exact source view. Apply that pattern when useful without retrofitting a nearly complete project solely for bookkeeping.

## Reuse a designated R session

If the scientist designated a live R session using the optional
[session helper](../R_SESSION.md), run ordinary analysis code in that process
and use `bdl_session_attach(project_dir)`. Do not replace a failed attachment
with a new `Rscript` process, call `start` automatically, or recover another live
owner. Report `USE_LIVE_R_SESSION` and use an executor connected to the designated
console. This package does not supply that execution connection.

In that console, keep `session` as the one master and use `session$project()` as
the canonical metadata handle. Do not repeatedly call `ProjectBundle$open()`;
each call creates another metadata handle and can become stale. Object names can
be aliases, and native R copy-on-modify or arbitrary code can still create copies.
The helper cannot enforce permissions or guarantee a single Variables-pane entry.
Never serialize `session` or save a workspace containing it with `saveRDS`,
`save`, or `save.image`; checkpoint retained scientific outputs explicitly and
save approved ledger edits separately through `session$project()$save()`.
Use `ProjectBundle$open()` only for an explicit independent metadata inspection
or a bounded Rscript batch, not as a managed-session per-turn shortcut.

Use `load_once` for the selected exact DATA reference and `get_data` for subsequent
work. Keep one canonical slot for each working dataset; use `replace_data` with
the expected generation and an explicit validation function to advance it.
Prepare small plotting tables from the current object instead of retaining whole
dataset clones for figure edits. Metadata generation is local session state, not
a scientific dataset revision. Source references remain origins after modification.
Native R aliases and internal copying remain possible outside this managed route.
If the metadata handle becomes stale, use the documented explicit `refresh_project`
procedure and retain its returned previous handle when pending edits exist. It
checks cached source identities and refreshes metadata without reloading datasets;
do not silently discard or automatically reconcile another writer's changes.

For an Rscript agent, use one bounded process for a complete related batch. Open
the project once, make authorized changes, save once, then exit. Separate Rscript
processes cannot reuse the Positron object's RAM. If a live session owns the
project, do not fall back to a new owner or reload: report `USE_LIVE_R_SESSION`
and route work to the owner. The synthetic command
`Rscript examples/session_R.R --synthetic-batch` is disposable-only and shows
the process boundary; it is not a live-session connection or a scientific run.
It closes only after its explicit successful save and otherwise retains its
disposable directory for inspection, including the owner marker if ownership
was started; it never recovers or replaces an owner.

Managed reuse also works in a supported long-lived terminal R process or kernel;
Positron is not required. The agent must already be able to execute code in that
same owner process. `bdl_session_attach()` is not an interprocess connection or
a package-provided R server, kernel manager, or command bridge. When that route
is unavailable, use a bounded whole-analysis Rscript batch, not one Rscript per
prompt.

## Retain work and confirm the save

- For an analysis already intended to be retained, stage its declaration with exact DATA inputs and known method, parameters, design and code before writing outputs. Inspect decisions separately. Use `code=` for script snapshots. Register saved files against the exact analysis and record figure rendering inputs separately when known.
- Obtain scientist authority for current input selections and scientific decisions. Preserve any external authority. Keep unknown provenance visible. Ordinary registration captures declared links. Explicit run receipts qualify wrapper activity, and file hashes identify checked bytes. Actual input consumption and scientific approval require separate evidence.
- Save once after a related registration batch or a completed critical input, design or decision change. [Save and confirm](../API.md#save_and_confirm) commits all pending edits. Use a returned `persisted` receipt with `registry_written` true to report a new durable write. Report any files left behind by failed registration, including which records remain unregistered or staged.
- On a stale write, preserve pending edits and saved files. Open a separate fresh handle and reconcile deliberately. A clean save does not check freshness. Reopen a clean handle when another writer's updates are needed.

## Projects requiring approved figure renderers

Source builds with the [approved renderer guard](../RENDERER_GUARD.md) expose
`figure_policy()`. If it returns `approved_renderers_v1`, retain figures with
`render_figure(renderer=..., data=..., plot_args=..., analysis=...)`. The package
renders and stages the figure itself; save at the normal batch checkpoint.

Do not work around `APPROVED_RENDERER_REQUIRED` by copying an image, changing its
metadata, using an older client or editing the registry. Use an approved renderer
and supported settings. If the intended figure is unsupported, report the missing
capability. Native edits remain available for exploration, but edited plots and
arbitrary callbacks are not accepted by the guarded retention route. Check the
saved bytes explicitly with `resolve_figure(..., verify="sha256")` when needed.
The policy does not establish data truth, scientific acceptance or visual quality.

## Share or resume

For a saved-project handoff, use the [resume procedure and agent prompt](../RESUMING.md).
For a reviewed ZIP handoff, use the [share procedure and agent prompt](../SHARING.md).
For an installation change around live work, use the [upgrade procedure and agent
prompt](../UPDATING.md).

For an explicitly requested local browser snapshot, use [`view()`](../VIEWER.md)
in the development checkout. Use the loaded handle and request previews only
for specified exact FIG revisions. Treat the generated file as private project
metadata.

Preview the complete registry metadata and history alongside the selected payloads before an authorized export. Use exact getters and explicit verification to determine readiness for a named next task after import. Import leaves scripts inert. See [sharing and recovery](../API.md#save-share-and-recover).

These instructions guide use of the registry. They do not restrict an unrestricted interpreter or require calls on every chat turn.
