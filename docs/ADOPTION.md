# Adopt an existing project

BioDataLedger records a scientist's selected files and declared links. It does not inspect a project tree or run an analysis.

1. Use the installed `ProjectBundle` client. Open an existing registry at the supplied root; if none exists, create it once with the confirmed project name and existing root. Read `status()` once and inspect exact records with `get_data(ref=...)`, `get_analysis(ref)` and `get_figure(ref)` (R uses `$`). Keep any existing scientific authority and foreign IDs. Do not create a second current choice for a purpose governed elsewhere.
2. Obtain a finite file list from the scientist. Review each candidate's path, kind, proposed source links, population, pinned design, evidence basis and unknown history. Candidate labels are not ledger IDs. A directory inventory is nonrecursive unless its roots, depth and count are explicitly bounded. Keep inferred relationships as notes until confirmed.
3. Register confirmed existing data in place, code snapshots, analyses and saved figures. Record known scope and design with their exact revisions. An existing QC file is evidence of a prior result; registration does not rerun QC. Do not move, rewrite or load scientific matrices for bookkeeping.
4. For a scientist-selected continuation input, capture a SHA-256 baseline with `register_data(..., hash=True)` or a reasoned file revision. This streams file bytes without deserializing the data. Confirm the exact scoped DATA revision, purpose and reason before `set_current`. A name or approval field is a declaration, not authentication. Leave an unresolved choice unset.
5. Save meaningful changes once. Reopen in the other native client and retrieve the purpose view, exact DATA revision, pinned design and known figure/QC sources. Check original paths and bytes when required. If intake fails partway, report what was staged or saved; do not silently retry, delete or replace source files.

A useful handoff names the purpose, exact DATA revision, scope and basis, pinned design and selected levels, known assay/layer/replicate, last integrity check and time, missing evidence, and one next action. It includes the strict native `resolve_data(purpose=..., verify="sha256", expected_scope=...)` call when the scope requirement is confirmed. Multiple plausible purposes need a scientist choice. A digest identifies bytes; it does not prove the analysis that produced them.

When adopting older input helpers, follow the
[native-resolution migration pattern](api/API_0.5.0.md#updating-older-input-helpers).
Unchecked metadata from `get_data()` is not an unavailable file. Preserve the
helper's original selection and return structure while using `resolve_data()`
for verification.
