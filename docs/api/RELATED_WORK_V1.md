# Related work — two bounded entry points

`related_work(input_ref=None, query=None, limit=5)` retrieves registered analyses
and their exact input, result and figure references. R uses `$`, `NULL` and lists.
Supply exactly one selector. `limit` is an integer from 1 to 20.

```python
by_input = project.related_work(input_ref=data_ref)
by_topic = project.related_work(query="TCR clonality")
```

```r
by_input <- project$related_work(input_ref = data_ref)
by_topic <- project$related_work(query = "TCR clonality")
```

The topic query answers the discovery part of “Have we performed TCR clonality
analyses?” without requiring a dataset in advance. Its results are candidates,
not a yes/no scientific conclusion. The package does not interpret natural-language
questions: supply topic keywords such as `TCR clonality`.

## Exact input or topic

The exact route resolves an existing DATA revision and uses recorded direct
input-to-analysis edges. It preserves the exact historical analysis revisions that
reference that input. It never substitutes another dataset or the latest analysis
revision. The exact route inspects at most 100 outgoing adjacency entries; further
entries make search incompleteness explicit. Invalid, missing, foreign or ambiguous
input references reject. An input
with no recorded direct analysis link returns no matching recorded analysis.

The text route searches latest active analysis metadata in stable ID order:
analysis `name`, optional `details.title`, `details.purpose`, `details.description`,
and `details.tags` (a string or list of strings). These are existing metadata fields;
no new registry fields or indexing service are introduced. For example, existing
`register_analysis` accepts `purpose="repertoire diversity"` and
`tags=["TCR", "clonality"]` in Python, or corresponding named arguments in R.

Search splits a nonblank query into casefolded, whitespace-separated terms and
requires every term to occur as a literal substring across the supported fields.
It does not use fuzzy matching, vector embeddings, an LLM or scientific equivalence.
Non-string legacy field values are ignored rather than converted into search evidence.
A query is limited to 256 UTF-8 bytes. Historical keyword-only search is outside this
initial slice; the report states its search scope, and exact-input lookup retains
historical links.

Each returned analysis identifies its `match_basis`: `exact_input_reference` or
`text_candidate`. Matching a declared input is not proof the analysis consumed it.
Matching text or parameters is never proof that two analyses are scientifically
equivalent or that a result is appropriate for a new purpose. Multiple candidates
remain visible; the method does not select a winner or change current inputs.

## Returned report and provenance

The detached JSON-compatible report includes its selector, registry revision and
unsaved flag; observed inspected/matched/returned/omitted counts; match-state and
truncation indicators; coverage limitations; and analysis entries. Each entry contains
an exact analysis reference/title, match basis, exact input references, linked
registered result/figure references, and compact qualified provenance.

A terminal execution receipt can reference artifacts bound to its started run
revision. The report retains the matched terminal analysis ref and exposes the
exact artifact-analysis anchor; it never rewrites the stored producer revision.

The report distinguishes declared/unknown relationships from the status of an exact
validated execution receipt. Absent receipts remain unknown; started, failed,
incomplete or blocked runs are never upgraded to successful completion. Imported
claims remain qualified. Scientific validity, actual input consumption and scientific
equivalence remain unknown. A registered analysis alone does not establish execution.

“Registered results” does not assert current file availability or a durable save of
pending edits. The unsaved flag distinguishes staged registry changes. Follow an exact
reference with `get_analysis`, `get_data` or `get_figure` when detailed parameters,
code or artifact locators are needed. Use existing explicit verification methods to
check selected bytes or supported live objects; this report does not perform them.

The query reports only recorded relationships within its declared scope and bounds.
No match is not proof that the scientific analysis has never been performed. Incomplete
search/content coverage cannot establish zero matches or unique relevance. Retained
historical artifacts are never silently replaced by newer revisions.

## Bounds and read-only behavior

- Compact output is at most 4096 UTF-8 bytes, with explicit omissions/truncation.
  Identifiers are kept whole or omitted; they are not shortened into different refs.
- Topic search inspects at most 1,000 analysis records. Search fields are bounded to
  4096 UTF-8 bytes each; tags to 32 strings of at most 128 UTF-8 bytes each. Content
  or record limits make search incompleteness explicit.
- Each entry includes at most 10 input, 10 result and 10 figure refs, with omissions.
  Artifact lookup uses existing downstream dependency bounds (depth 2, 100 edges).
- Exact lookup uses existing adjacency; topic lookup scans bounded metadata, not the
  dependency graph. Enumerating existing ID indexes and loading a project have their
  own costs; text search is not advertised as constant-time.

No payload reads/hashes, matrix loads, filesystem crawling, writes, copying,
re-registration, computation or graph rebuild occurs during the query. No new
external index service, embedding model, dependency or workflow engine is required.
The library can bound this method; it cannot force an unrestricted agent to call it,
record all previous work, reuse a result, or follow scientific approval requirements.

This is the related-work slice. It does not authenticate approved inputs, identify
canonical helpers automatically, compare approved ordered protocols, or implement
scientific readiness and automatic downstream invalidation.
