# Safely update an existing project

The **0.18.0 source version is on `main`**. Resolve the branch to a full commit
before installation; the latest existing release tag is v0.17.0. No v0.18.0 tag
is provided. Version 0.18.0 includes analysis input/output timelines, optional
plotting and renderer guards, a browser snapshot, and managed R session reuse.
See the [project overview](../README.md) and
[API reference](API.md).

Reopen your saved project with its existing registry schema, `.nb_project_bundle`
paths, code snapshots, exact references and ZIP format. Keep the previous
installation for rollback, since earlier clients can preserve optional newer
metadata without enforcing all its semantics.

An upgrade keeps saved exact references. Changing a scientific input is separate:
register the saved replacement as a new DATA record, or explicitly revise an
existing record when authorized. Select the replacement explicitly for future work. Earlier results retain their original input references.
BioDataLedger does not convert Seurat to AnnData (or the reverse), or upgrade a
live native object or handle.

Installing a package does not update a loaded R namespace, Python module or
existing `ProjectBundle` handle. Use a fresh process and reopen the saved project
after protecting pending work. Do not silently restart R/Jupyter, detach a package,
reload Python modules, overwrite objects or close the old session. An unsaved
Seurat/AnnData object is separate from the saved registry.

## Short procedure

1. In the current session, inspect `status()` once and protect pending registry
   edits, live objects, scripts and outputs. A registry save commits every pending
   registry edit; it does not save a live Seurat or AnnData object.
2. Keep the current installation and live session available. Install the chosen
   version separately, then start a fresh R or Python process.
3. In the fresh process, open the saved project, check `status()`, and use exact
   getters to compare the saved references you need. Resume only after the owner
   has resolved any pending work in the old session.

## Short agent prompt

```text
Safely upgrade this BioDataLedger project without changing scientific choices.

Project folder: [absolute path]
Task after upgrade: [specific next task]
Target package version or full commit: [version or SHA]

Protect the live R/Python session and its unsaved objects. Inspect saved state in
a fresh process, keep the old installation available, install the target separately,
then reopen and compare exact saved refs needed for the task. Do not auto-save,
convert Seurat/AnnData, replace live handles, or change input selection. Follow
the detailed procedure below for safeguards, synthetic checks and reporting.
```

## Source checkout installation

Apply the same live-session and saved-state safeguards above. Record the reviewed
checkout's full commit and verify its package version is 0.18.0. Install into
a new library/environment, preserving the current one. These commands assume
compatible dependencies and Python build tools are already available.

R, in a fresh process:

```r
package_source <- "/absolute/path/to/reviewed/biodataledger/r"
new_library <- "/absolute/path/to/new-biodataledger-0.18.0-library"
stopifnot(!dir.exists(new_library))
dir.create(new_library, recursive = TRUE)
install.packages(package_source, repos = NULL, type = "source", lib = new_library)
library(BioDataLedger, lib.loc = new_library)
stopifnot(as.character(getNamespaceVersion("BioDataLedger")) == "0.18.0")
```

Python, with an unused destination and the chosen compatible interpreter:

```sh
python3 -m venv --system-site-packages /absolute/path/to/new-biodataledger-0.18.0-env
/absolute/path/to/new-biodataledger-0.18.0-env/bin/python -m pip install --no-deps --no-build-isolation /absolute/path/to/reviewed/biodataledger/python
/absolute/path/to/new-biodataledger-0.18.0-env/bin/python -c 'import biodataledger; assert biodataledger.__version__ == "0.18.0"; print(biodataledger.__file__)'
```

The Python environment reuses installed dependencies rather than isolating them.
Plotting dependencies are optional; see the [plotting guide](PLOTTING.md).
Test with disposable synthetic files and compare saved project references before
resuming. An installation does not update the existing live session.

## Detailed agent procedure

Paste this into the agent helping with your existing project. It authorizes the
package installation and synthetic checks, while keeping scientific save decisions
with the owner.

```text
Safely upgrade this existing BioDataLedger project to source version 0.18.0 on main from
https://github.com/nbatada/biodataledger. Preserve the project and live analysis.
Use existing dependencies. Do not change the registry format or scientific choices.

1. Inspect the current setup before installing. Identify the project path, current
   Python executable/environment or R executable/.libPaths(), installed package
   path/version and loaded module/namespace version. Identify the ProjectBundle
   handles used by this analysis and their unsaved state; report anything you
   cannot inspect. Ask only for information needed to identify the correct project
   or session. Do not crawl unrelated folders or load scientific data for bookkeeping.

2. Protect work first. Identify pending registry changes and live unsaved scientific
   objects, scripts and outputs. Do not call save/save_and_confirm/run_analysis to
   flush pending work without the owner's clear authorization: a registry save
   commits ALL pending registry changes. Do not auto-serialize large Seurat/AnnData
   objects. Do not restart/detach/reload the live session or overwrite its handles.
   If pending work cannot safely be resolved, leave the old session running, install
   separately and report the exact handoff still required. Do not claim unsaved
   objects have been backed up merely because the registry was copied.

3. Before any project write, use a fresh process with the old installed client to
   record the SAVED baseline: UUID, schema/revision, counts, current-purpose refs
   and selected exact refs. Open and query only; do not call write methods or use
   a nonexistent read-only flag. A live handle may be stale or contain pending edits.
   Make a private, timestamped backup outside the project: copy the registry JSON,
   registered code snapshots and explicitly selected retained scripts/outputs.
   Do not blindly copy .nb_project_bundle: it may contain large managed files or
   an active writer lock. Confirm the registry and selected source bytes did not
   change during backup; if they changed, coordinate with the writer before retrying.
   Record versions, paths and source/backup SHA-256 checksums privately.
   Metadata is not a backup of external scientific files. Do not copy huge input
   files by default; record their locations and existing captured digests instead.
   Retain the old package environment/library and record how to launch it again.

4. Resolve main to its full Git commit and record it. Install that pinned version
   into a NEW R library or Python environment, preserving the old installation and
   dependency versions. Use the existing compatible interpreter and dependencies;
   do not upgrade dependencies or create a project workflow/migration utility.
   Use upgrade="never" for remotes, and --no-deps for pip with locally available
   build tools. If required dependencies are absent, report them before changing
   the environment. An environment that can reuse existing compatible dependencies
   is sufficient; no new scientific software stack is needed.

5. In fresh R/Python processes, verify loaded version 0.18.0 and package path against
   the new installation and pinned source commit. Test create/register/save/reopen
   with disposable synthetic files only. Verify the inspection card/status reports
   package version, registry revision and unsaved state, and save_and_confirm gives
   a persisted receipt followed by no_changes. Do not test-write the real project.

6. Open the SAVED real registry read-only with fresh ProjectBundle handles in the
   new process. Compare its bytes/SHA-256 before and after inspection, project UUID,
   schema/revision, counts, current-purpose references, selected exact record refs
   and their saved data/code/figure links with the recorded baseline. Use known
   exact getters; do not re-register inputs or regenerate scientific outputs. Do
   not change paths, biological labels, current choices, parameters or approvals.
   If an old session still has pending edits, this check covers saved state only.

7. Report the old/new versions, pinned commit, installation and backup locations,
   checks performed, saved-state equivalence and unresolved live-session work.
   Resume with new handles only when ownership of pending work is resolved. Keep
   the old session and package available until that handoff is accepted. For a
   failed check, stop project writes and return to the previous installation in a
   fresh process. Restore a registry backup only with explicit owner approval,
   because restoring it can overwrite work saved since the backup. Technical
   checks do not establish scientific validity or actual usability acceptance.
```

## Pinned installation examples

Set an unused destination and keep the previous library/environment. These are
installation commands, not commands to paste into an unresolved live session.
Replace main with its verified full commit SHA for an immutable source pin.

R, in a fresh process with existing dependencies available:

```r
new_library <- "/absolute/path/to/new-biodataledger-0.18.0-library"
stopifnot(!dir.exists(new_library))
dir.create(new_library, recursive = TRUE)
remotes::install_github("nbatada/biodataledger", subdir = "r", ref = "main",
                        lib = new_library, upgrade = "never", dependencies = FALSE)
library(BioDataLedger, lib.loc = new_library)
stopifnot(as.character(getNamespaceVersion("BioDataLedger")) == "0.18.0")
```

Python, using the chosen compatible interpreter with setuptools/wheel available:

```sh
python3 -m venv --system-site-packages /absolute/path/to/new-biodataledger-0.18.0-env
/absolute/path/to/new-biodataledger-0.18.0-env/bin/python -m pip install --no-deps --no-build-isolation "git+https://github.com/nbatada/biodataledger.git@main#subdirectory=python"
/absolute/path/to/new-biodataledger-0.18.0-env/bin/python -c 'import biodataledger; print(biodataledger.__version__, biodataledger.__file__)'
```

Choose a destination that does not already exist. `--system-site-packages` reuses
available interpreter packages; it does not provide dependency isolation. The
package itself has no Python runtime dependencies. See [installation](../README.md#install)
for package prerequisites.
