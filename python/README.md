# BioDataLedger — Python client

A lightweight local scientific project registry for finding retained figures and inspecting their recorded data, code and parameters. The package runs without an AI service.

The native public facade is ProjectBundle: create/open an explicit project root, query compact status, resolve registered inputs, register existing data/analyses/figures and save meaningful changes. Context and selected working ZIPs import without execution. Native RDS/H5AD objects are not loaded or converted by the registry.

## Install 0.13.0

Requires Python 3.9 or newer. The package has no Python runtime dependencies.

```sh
python3 -m pip install "git+https://github.com/nbatada/biodataledger.git@v0.13.0#subdirectory=python"
python3 -c 'import biodataledger; print(biodataledger.__version__)'
```

Use an isolated Python environment as needed. For an immutable installation,
replace `v0.13.0` with the release's full commit SHA. For an existing project or live
session, follow the [safe upgrade guide and agent prompt](https://github.com/nbatada/biodataledger/blob/v0.13.0/docs/UPDATING.md).

Version 0.13.0 adds read-only project graph export as DOT or structured data.
It includes exact input/design references, retained-result lineage, optional
execution receipts, scientific decisions, related-work retrieval,
ordered protocols, execution history and scoped reproduce/reapply/rerender
comparison evidence. Comparison outcomes never supply scientific approval.

The distribution includes API references through 0.11.0 and the versioned graph,
result, execution, decision, protocol, chronology and comparison contracts. The
shared schema accepts legacy 0.1.0 projects and the 0.2.0 experimental-design, 0.3.0
dataset-scope and 0.4.0 explicit-input-mode/figure-copy extensions.

The [source repository and scientist quick-start](https://github.com/nbatada/biodataledger)
include the native R companion, synthetic examples, tests and sharing/recovery
guides. MIT license; copyright 2026 Nizar Batada.

File capture and matching hashes do not prove execution, scientific validity or
reproduction. Ordinary registration does not execute an analysis; optional
`run_analysis` receipts record invocation while input consumption remains unknown.
Metadata is not automatically anonymized. Local macOS writes are tested;
other-platform and network-volume guarantees are not established. The R
maintainer-contact placeholder remains unresolved; no PyPI or CRAN release has
been published.
