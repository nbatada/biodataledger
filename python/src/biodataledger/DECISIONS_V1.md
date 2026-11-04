# Scientific decisions and annotations — version 1

Scientific decisions preserve a scientist's submitted interpretation and its evidence.
They do not establish truth or authenticate approval. Existing `record_decision`
remains available for untyped decisions; this optional contract reuses DEC identities,
revisions and the same project registry. It requires no scientific-object loading,
LLM, database, workflow engine or new dependency.

## Record and revise

Both native clients add:

```text
record_scientific_decision(text, reason, subjects, scientific_status,
                          supporting=None, contradictory=None, ref=None)
get_decision(ref)
```

R uses `$`, lists and `NULL`. `ref` is an exact DEC reference when revising an
existing decision. The writer stages a change; call `save_and_confirm()` to retain
it durably. That boundary saves all pending changes. It does not confer approval.

Each subject contains an exact record `ref` and optionally a `cluster_id` and
`annotation`. Cluster identifiers require a DATA result or ANA run reference and
must be nonempty strings. The identifier and biological annotation are separate:
cluster `"1"` in one run is not cluster `"1"` in another, and `"01"` is not `"1"`.
The package does not inspect assignments to establish that the cluster exists.
An annotation is a submitted label; it is never inferred from markers or names.

For example, given already registered exact `clustering_result` and `marker_table`
references:

```python
decision = project.record_scientific_decision(
    "Provisional cluster annotation",
    "Marker evidence supports the label; alternative interpretation remains open.",
    subjects=[{"ref": clustering_result, "cluster_id": "1",
               "annotation": "CD8 T cells"}],
    scientific_status="provisional",
    supporting=[marker_table],
)
project.save_and_confirm()
view = project.get_decision(decision)
```

```r
decision <- project$record_scientific_decision(
  "Provisional cluster annotation",
  "Marker evidence supports the label; alternative interpretation remains open.",
  subjects = list(list(ref = clustering_result, cluster_id = "1",
                       annotation = "CD8 T cells")),
  scientific_status = "provisional",
  supporting = list(marker_table)
)
project$save_and_confirm()
view <- project$get_decision(decision)
```

These are usage examples, not evidence that a real cluster has this identity.
The caller supplies `scientific_status` explicitly: `proposed`, `provisional`,
`approved` or `superseded`. It remains a recorded declaration. It does not change
the DEC record's separate active/inactive/superseded lifecycle or current inputs.
`approval` in the getter is always `not_authenticated`.

Supporting and contradictory evidence are separate ordered lists of exact existing
record refs. An omitted list means no such evidence was recorded, not that no such
evidence exists. The same source may appear in both lists if the scientist explicitly
records both interpretations. Evidence payloads are not loaded or judged. Subject
and evidence lists are bounded to 100 items each.

A typed revision preserves the DEC identity and every earlier revision. Supply the
exact latest DEC ref and the complete new text, reason, subjects, status and evidence.
Subject identities/order (exact ref plus cluster_id) stay fixed; annotations may
change with explicit rationale. A different subject requires a new DEC identity.
A stale revision rejects rather than silently selecting a newer interpretation.
An untyped decision may be explicitly enriched, while a malformed or unsupported
scientific descriptor cannot be silently rewritten.

## Retrieval and compatibility

`get_decision` resolves one exact DEC revision without payload reads, hashes, saves
or registry scans. It returns detached JSON-compatible fields:

- `ref`, `text`, `reason`, `targets`, `record_status`;
- `scientific`: the validated versioned descriptor, or null;
- `approval`: always `not_authenticated`;
- `unknown`: explicit legacy/unsupported/malformed or imported-evidence limits;
- `imported_claim`: `untrusted_imported_claim` for imports, otherwise null.

The optional descriptor is `details.scientific_decision`, version
`biodataledger-scientific-decision/1`. It contains `subjects`, `scientific_status`,
`supporting` and `contradictory`. Existing DEC name/reason/targets remain available
for older clients. An untyped legacy decision remains readable with unknown
scientific context; old metadata is not reinterpreted as approval.

Normal generic mutations cannot inject or rewrite typed scientific content. Use
the typed writer for an interpretation revision. A supported lifecycle-only update
preserves scientific content and does not change scientific approval. Current-client
validation does not constrain old clients, raw edits or an unrestricted interpreter.
Imported records are untrusted submitted claims, even when structurally consistent.

Both native clients preserve exact references and historical interpretations through
ordinary save/import paths. Existing registry schemas, ZIP format and snapshots are
unchanged; older clients can retain optional metadata but do not validate its meaning.
This feature does not implement chronology, automatic annotations, evidence scoring,
a pre-analysis query or a guarantee that an agent will record or follow decisions.
