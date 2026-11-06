# Scientific graph export, version 1

Python and R expose the same read-only ProjectBundle method:

```text
export_graph(ref = NULL, direction = "upstream", depth = 3, limit = 100,
             format = "dot", filters = NULL, offset = 0,
             style = "detailed", lineage_roots = NULL)
```

Use `None` in Python and `NULL` in R. The default returns DOT text. Use
`format="structured"` for the versioned `biodataledger-graph/1` dict/list.
Both formats describe the same bounded view. They require no Graphviz, file writes,
payload reads, availability checks, hashing, or execution. Export is on demand.
Use the ordinary `dependencies()` method for its original, narrower edge contract.

## Presentation DOT

`style="presentation"` produces a top to bottom diagram from the same bounded
query. Exact revision IDs appear under distinct record types. The
header shows graph cutoffs, the visible cycle check and any imported or unsaved
state. The default `style="detailed"` and structured report are unchanged;
presentation styling is DOT only.

Focused diagrams hide revision links and records reachable only through those
links in the selected direction. Other links still show the exact revisions
they reference, including older revisions. The header counts the omitted
records and links and preserves cutoffs and the cycle check from the detailed
view. Overview diagrams keep revision links as context.

Pass up to six distinct exact local DATA references in the order you want them
numbered and colored. A selected root marks a new source boundary, even if it
descends from another selected root. Colors follow visible declared inputs,
results, transformations, dataset parents and figure rendering links. A figure
gets colors only from its declared rendering inputs. Standalone analytical
inputs, figure-to-analysis associations and revision links are dashed context.
The diagram marks unknown rendering inputs when none are recorded or the
descriptor is invalid. It marks links as unconfirmed when exact input
candidates are recorded without a declared rendering relationship.
Mixed nodes list their known selected sources and mixed
edges retain parallel strokes. Roots outside the selected view stay in the
legend without contributing colors. Colors do not establish input consumption,
cohort membership or scientific approval.

```python
from pathlib import Path

dot = project.export_graph(
    "FIG-001@1", depth=8, style="presentation",
    lineage_roots=["DATA-002@1", "DATA-003@1"],
)
Path("lineage.dot").write_text(dot, encoding="utf-8")
```

```r
dot <- project$export_graph(
  "FIG-001@1", depth = 8L, style = "presentation",
  lineage_roots = c("DATA-002@1", "DATA-003@1")
)
writeLines(enc2utf8(dot), "lineage.dot", useBytes = TRUE)
```

Render the file with an optional Graphviz installation: `dot -Tsvg lineage.dot
-o lineage.svg` (or use `-Tpng` for PNG). BioDataLedger returns text and does
not invoke the renderer. See the [synthetic lineage demo](../LINEAGE_DEMO.md).

Questions are optional recorded context on visible outputs. Plotting code
notes require a valid generating code selector for the exact figure. A note
shows the code filename when available, exact owner revision, zero based entry
index and digest prefix. Without a selector, the figure shows plotting code as
unknown. Neither note verifies execution. Review names and questions before
sharing. Titles and notes mark clipped text; at most eight distinct notes and
24 links to notes of each kind are shown. Omitted links are counted. Inspect
the full recorded metadata with `get_info()` or the detailed graph. If the
decorated DOT exceeds 128 KiB, request a narrower view.

- Omit `ref` for a project overview. `limit` is the node limit (1–100).
  Each page examines at most 1,000 registry slots in stored order, starting at the
  zero-based `offset`. Use `next_offset` to continue; stop at null. Pass the
  same filters and keep the loaded handle unchanged between pages. The snapshot
  identifies project, committed revision and transaction, record count, imported
  state, and whether staged edits are visible. It is not a snapshot of staged bytes.
- Supply an exact `ID@revision` or local reference object for focused lineage.
  Traverse `"upstream"` or `"downstream"` in breadth-first order to depth 1–10.
  The limit includes the root. Wrong-project, unknown or bare-ID selectors reject.
  Filters and pagination apply only to overview.
- Both modes return at most 100 edges. The overview examines at most 1,000
  outgoing indexed edges and returns **only** edges whose two endpoints are
  shown on that page. Filters and page boundaries therefore omit other
  relationships. A later page flags prior slots with `page_boundary` even when
  it has no continuation. Use focused lineage to inspect cross-page links.
- The report and DOT each stay within 128 KiB. Node titles retain up to 192
  UTF-8 bytes and mark clipped labels. Identity strings are never shortened.
  `truncated` and `truncation` identify scope cutoffs (depth, node, edge, scan,
  byte, and optional metadata limits). `next_offset` continues the record scan;
  it is not an edge cursor. The absence of a cutoff says nothing about
  unregistered work.

Overview filters are combined with AND. Pass a Python dict or named R list:

| Key | Match |
| --- | --- |
| `asset_type` | `DATA`, `ANA`, `FIG`, `DEC`, `DES`, or `RESULT`. DATA includes derived results; RESULT requires a recognized, valid derived-result declaration. |
| `query` | Literal case-insensitive terms in recorded name, title, purpose, description or tags, using the related-work bounds. No scientific inference. |
| `registered_on` | Canonical UTC registration day, `YYYY-MM-DD`. |
| `executed_on` | UTC start day of a validated terminal receipt with an ordered timing interval and code execution recorded. Open and blocked attempts do not match. Imported claims remain untrusted. |
| `revision` | `latest` or `historical` by numeric revision within an ID. |
| `record_status` | Exact stored lifecycle value: `active`, `inactive` or `superseded`. |
| `anchor` | An exact DATA or ANA revision, or a record one indexed link from it in either direction. Other filters still apply. |

`revision_status`, `record_status`, current-for-purpose DATA selection, and a
scientist's approval are separate. The graph does not enumerate purpose
bindings. Use the existing purpose selector to retrieve that exact DATA
reference, then use it as an anchor or root.

Nodes retain exact local `ref`, `kind`, `asset_type`, bounded display label, and
registration time when canonical. `superseded_at_utc` is null: this registry
does not record that event time separately. A typed decision may show its
submitted `scientific_status`; it is always unauthenticated. Generic decisions,
protocols and comparison records are not treated as scientific approval.
`code_owner_ref` and `code_count` point to recorded code candidates on the
analysis or standalone figure. For an explicitly declared generating script,
use the exact figure source view. No path or code bytes are returned. Review
the metadata before sharing; the export does not redact sensitive labels.

Edges retain exact `from` and `to` refs, `type`, `basis`, and `source_field`.
They point from referenced subject/input/context to the record which uses or
describes it, except that `revision_of` points from the older to the next
consecutive extant revision of the same ID. Revision numbering shows sequence,
not the actual edit base, time of supersession, or approval; gaps are preserved.
Computational declarations include input to analysis, result producer, and
figure rendering inputs. Other links include explicit dataset parents and
scope transformation context, standalone figure inputs, analytical association,
artifact containers, observation authority, clustering context, decision
targets, and design context/subjects. Decision and context edges are navigation
links, not causal claims. No edges are inferred from names, locators or times.

A node's execution section uses the exact revision's validated wrapper receipt
when one exists, with separate evidence, receipt outcome, timing qualification,
timestamps and code execution flag. A receipt's start can precede verification
and callback execution. Missing or invalid timestamps are null. Timing values
are not sorted into an execution order. Tied/overlapping times are preserved.
A recorded interval, an associated figure and a declared input link do not
prove input use, figure generation, reproducibility or scientific validity.

Optional broken metadata is flagged on its owning node. Legacy decision targets
report the first issue, count of inspected invalid/unresolved targets and count
left uninspected (over 1,000 targets per decision); the report flags the global
index limit where applicable. An oversized unresolved ID is omitted, not
shortened. Core dangling references can reject the registry at open. Cycles
are checked only on visible navigation edges, including noncausal links.
`cycle="detected"` reports a visible cycle, without declaring scientific error.
`unknown` means cutoffs or flagged records prevent a complete check of the
requested view. `not_detected_in_view` is limited to returned edges.

## CCF integration

BioDataLedger owns exact scientific identities, versions, recorded relationships,
provenance and evidence status, the bounded query, and DOT serialization. CCF
can consume the structured report to render overview and focused lineage,
provide zoom/pan and filters, and select exact `ref` values to open the relevant
BioDataLedger getter. Do not store a second authoritative graph or infer missing
relationships. Display scope cutoffs, unknowns, and the distinction between
recorded and imported execution claims. Graphviz rendering is optional and
belongs to the caller. CCF does not need to parse DOT for interactive navigation.
