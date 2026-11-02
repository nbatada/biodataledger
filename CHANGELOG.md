# Changelog

## 0.3.0 — Experimental design

- Add ordered condition/levels, selected/reference levels, optional biological replicate and reason in both native clients.
- Preserve exact design revisions in analyses and figures; keep legacy projects readable without automatic migration.
- Add optional in-memory metadata checks and explicit declared/verified evidence with dataset/analysis context.
- Add compact project printing, actual inventory counts and bounded get_design_summary.
- Extend shared schema to 0.2.0 only when design is configured; older clients reject that extension. Legacy paths and ZIP format are unchanged.

## 0.2.0 — Native R and Python clients

- Independent Python `biodataledger` and R `BioDataLedger` packages; retained ProjectBundle facade.
- Preserved schema 0.1.0, legacy state/snapshot paths and ZIP marker without rewriting scientific records.
- Added bounded read-only compact status for scientists and optional agents.
- Added installed-package examples and cross-language regression tests.
- Compact status checks pinned current inputs before latest versions; R ZIP import rejects incomplete safety metadata and requires zip ≥3.0.2. Regression checks pass.
