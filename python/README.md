# BioDataLedger — Python client

A lightweight local scientific project registry for finding retained figures and inspecting their recorded data, code and parameters. The package runs without an AI service.

The native public facade is ProjectBundle: create/open an explicit project root, query compact status, resolve registered inputs, register existing data/analyses/figures and save meaningful changes. Context and selected working ZIPs import without execution. Native RDS/H5AD objects are not loaded or converted by the registry.

This distribution contains API_0.5.0.md and a shared schema that accepts legacy 0.1.0 projects plus the optional 0.2.0 experimental-design, 0.3.0 dataset-scope and 0.4.0 explicit-input-mode/figure-copy extensions. The complete project repository includes the native R companion, scientist quick-start, tests and user guides. MIT license; copyright 2026 Nizar Batada.

Source repository: https://github.com/nbatada/biodataledger. Version 0.5.0 adds exact analysis designs, declared input consistency, strict figure verification and explicit managed figure copies; the R maintainer-contact issue remains open. File capture and matching hashes do not prove execution, scientific validity or reproduction. Metadata is not automatically anonymized. Initial tested write platform is local macOS; other-platform and network-volume guarantees are not established.
