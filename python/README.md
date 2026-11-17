# BioDataLedger — Python client

A lightweight local registry for finding retained results, tracing their recorded inputs and code, and reusing exact helper versions across projects. The package runs without an AI service.

The native public facade is ProjectBundle: create/open an explicit project root, query compact status, resolve registered inputs, register existing data/analyses/figures and save meaningful changes. Context and selected working ZIPs import without execution. Native RDS/H5AD objects are not loaded or converted by the registry.

## 0.21.1 source build

This source includes continuous metadata and explicit bounded helper
discovery/adoption. Published `main` or tags may differ; check the installed version and
available methods before using the shared-helper workflow.

## Shared-library workflow

Keep optional modules such as `nb_utils_general.py` directly in a selected library
root such as `~/git/lib`. Register helper cards there; an analysis project explicitly
finds, inspects and adopts an exact version. Save, verify its retained snapshot, then
load that copy and record its local helper reference on retained analyses. Later
library changes do not redirect those references. See the repository's `docs/HELPERS.md`
and runnable `examples/shared_library_python.py`; they use the existing native API.
The path and `nb_utils_*` names are optional conventions: other explicit roots and
helper names work equally, including multiple roots passed to `find_helpers(sources=...)`.

## Install a reviewed source revision

Requires Python 3.9 or newer. The package has no Python runtime dependencies.

```sh
python3 -m pip install "git+https://github.com/nbatada/biodataledger.git@main#subdirectory=python"
python3 -c 'import biodataledger; print(biodataledger.__version__)'
```

Use an isolated Python environment as needed. For an immutable installation,
resolve `main` and replace it with the full commit SHA. For an existing project or live
session, follow the [safe upgrade guide and agent prompt](https://github.com/nbatada/biodataledger/blob/main/docs/UPDATING.md).

The GitHub commands select `main`, which may differ from this local 0.21.1 checkout.
Check loaded capabilities before using helper adoption; no installation upgrades an
already imported Python module. Pin the source commit for reuse.

Use `print(p)` to see up to four oldest-first analysis
input/output chains, the project folder, current input choices, and the latest
figure's file and folder paths. Call `p.help()` for common commands or
`p.recent_figures()` for more figure paths. These views use loaded metadata and
leave file availability unchecked. Use `p.status()` for structured technical
metadata or `p.summary_text()` for the technical card. The
[current API reference](https://github.com/nbatada/biodataledger/blob/main/docs/API.md)
lists the supported features and their limits.

Presentation DOT shows exact revisions, optional source colors, and notes for
recorded questions and plotting code. The [synthetic lineage demo](https://github.com/nbatada/biodataledger/blob/main/docs/LINEAGE_DEMO.md)
generates a sample-count plot and recovers its exact recorded sources.
BioDataLedger also supports graph export as DOT or structured data, exact
input and design references, retained-result lineage, optional
execution receipts, scientific decisions, related-work retrieval,
ordered protocols, execution history and scoped reproduce/reapply/rerender
comparison evidence. Comparison outcomes never supply scientific approval.

The distribution includes API references through 0.11.0 and the versioned graph,
result, execution, decision, protocol, chronology, comparison and output discovery
contracts. The shared schema accepts legacy 0.1.0 projects and the 0.2.0
experimental-design, 0.3.0
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
