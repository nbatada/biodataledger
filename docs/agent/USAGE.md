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


## Reuse functions before implementing another one

Prefer reuse -> a justified general extension -> a separate implementation for a
specific gap. In an approved shared-library workflow, modules can live directly in
`~/git/lib`, for example `nb_utils_general.R`/`.py`, `nb_utils_plotting.R`/`.py`,
`nb_utils_scrnaseq.R`/`.py` and `nb_utils_bulkrnaseq.R`/`.py`. Shared functions follow
`nb_utils_<domain>_<verb>_<object>`, such as `nb_utils_general_check_ids()` and
`nb_utils_plotting_draw_dotplots()`. This is a user convention, not a required API prefix
or evidence of validation. Keep project-specific paths and scientific choices in callers.

1. Reuse the current native handle and inspect actual loaded helper capabilities. Search
   registered metadata with `find_helpers`; include only explicitly selected library roots
   in `sources`. Keep one library-root registry, not a second catalogue or whole-disk scan.
2. Read coverage/errors and inspect the full contract with `get_helper` on the source
   handle. Review code, dependencies and scientific fit separately. Choose an exact source
   reference deliberately; never take the first/newest candidate automatically.
3. If no suitable local pin already exists, pass the intact selected card to the current
   project's `register_helper_from`. It stages a local ref with exact declared origin.
   Discovery/adoption does not authorize source-library edits or execution.
4. Save the approved pending batch **before** checking newly retained files. Then require
   `get_helper(local_ref, verify="snapshot")` to pass and load its returned retained path
   into a separate native namespace. Stop on missing/drifted source; do not fall back to
   mutable `~/git/lib` files. Snapshot copies preserve history; they are not editable forks.
5. Call the reviewed function explicitly in the authorized analysis process. Keep its
   local ref with the function used. Record `helper_refs` on the retained analysis and
   use `register_result`/`register_figure` to link saved outputs to that analysis. These
   records declare use; actual execution and scientific acceptance need separate evidence.
6. Extend a shared helper only with authority to edit its repository, one writer and
   focused old/new behavior checks. Register a new revision and adopt it deliberately.
   Earlier pins/results remain unchanged; bug-fix impact and reruns need scientist review.

For package helpers, `verify="identity"` is a qualified native version-metadata check;
it does not load or install the package or prove function/source identity. Neither Git
history nor a package pin switches the code currently loaded in a process. Do not rebuild
undeclared dependencies from snapshots or replace a live namespace to make a check pass.
See the [helper guide](../HELPERS.md) and runnable
[Python](../../examples/shared_library_python.py) / [R](../../examples/shared_library_R.R)
examples. The examples are disposable synthetic runs, not a transport for an existing
scientific session.

## Keep analysis skills aligned with the package

A skill system should maintain one BioDataLedger adapter that refers to this guide and
the [API reference](../API.md). Analysis, coding and plotting skills should route ledger
operations through that adapter instead of copying API recipes. Domain skills retain
scientific scope, live-kernel, execution permission and review/STOP rules; the package
owns record identities and persistence. No skill installation is required to use it.

For workflows that require BioDataLedger, missing required capabilities or an unconfigured
ledger stop dependent work and route to authorized setup; a raw-path or legacy-client
fallback must not silently bypass that requirement. Ordinary explanation needs no registry
calls, and transient exploration needs no forced registration. Existing legacy projects
retain their explicit authority and migration boundaries.

When changing the package or adapter, inspect the actual loaded version/signatures and
run the native shared-library examples in fresh synthetic workspaces. Record the tested
capabilities and selected revision; do not claim that unrelated legacy integration was
revalidated. Updating documentation does not update installed skills, libraries or live
sessions automatically. Avoid changing an active scientific environment for this check.
