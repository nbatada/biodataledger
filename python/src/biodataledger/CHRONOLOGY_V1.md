# Evidence-qualified execution chronology — version 1

BioDataLedger 0.11.0 retrieves recorded execution history without running code,
loading scientific data, hashing files, scanning directories or changing the
registry. It reuses existing analysis records and execution receipts. There is
no new persisted format, workflow engine or registration requirement.

## Retrieve a bounded page

```python
history = project.execution_history(limit=10)
analysis_history = project.execution_history(analysis_ref=analysis_ref)
protocol_history = project.execution_history(protocol_ref=protocol_ref)
print(project.execution_history_summary(protocol_ref=protocol_ref))
```

```r
history <- project$execution_history(limit = 10)
analysis_history <- project$execution_history(analysis_ref = analysis_ref)
protocol_history <- project$execution_history(protocol_ref = protocol_ref)
cat(project$execution_history_summary(protocol_ref = protocol_ref))
```

Supply at most one selector. With neither, the scope is the loaded project.
The default limit is 10 entries; supported limits are 1–20.

- An exact **analysis reference** selects runs whose receipt names that exact
  template revision. Selecting a started or terminal run reference also selects
  that run's identity, shown at its latest recorded revision. This history view
  does not replace `get_execution(ref)`, which retrieves an exact historical
  receipt revision.
- An exact **protocol reference** selects receipts whose template references
  match the protocol's pinned analyses. It does not assign changed analyses to
  protocol steps by similarity, even if only a data-dependent value changed.
  Use `compare_protocol` with explicit selections for that comparison.
- Ordinary analysis registration is not execution and creates no history entry.
  Empty results mean no matching receipt was found in the scanned page; they do
  not prove that no analysis ran.

Started and terminal revisions of one run produce one entry, using the latest
ANA revision. A malformed latest revision remains unknown; the query never
silently replaces it with an older successful receipt. Malformed receipts with
an exact declared template link can be selected, but their evidence stays unknown.

## Keep four orders separate

The page is presented in reverse **registration-slot order**, for deterministic
retrieval. This is neither execution order nor a claim about the times at which
code ran. `registration_at_utc` is the selected record revision's creation time.

**Execution chronology** uses only qualified receipt intervals. `relations`
contains pairwise comparisons among displayed entries; `left` and `right` are
1-based entry indices. It never assigns an inferred total rank.

| Relation | Recorded interval evidence |
| --- | --- |
| `before` / `after` | One interval ends strictly before the other starts. |
| `overlap` | Valid intervals overlap without strict separation. |
| `tied` | Both recorded starts and ends are identical. |
| `tied_boundary` | One recorded end equals the other's start. |
| `unknown` | An interval is absent, open, invalid, blocked, malformed or imported. |

A same-second start/end is allowed as a coarse timestamp interval; it does not
prove zero runtime. Tied boundaries are not converted to a strict order. No clock
correction or cross-machine synchronization is inferred.

**Dependency order** remains in `dependencies()` and is not consulted to order
runs. **Protocol order** remains declared intent. Protocol selectors display
ordered step IDs and exact analysis references, with explicit omissions where
needed. They do not infer approval; declared approval and compliance comparison
remain separate operations.

## Outcomes and evidence

Each qualified entry retains exact receipt, started-run and template references,
original start/end timestamp strings, outcome and evidence classification.
Historical records and timestamps are never rewritten.

- `succeeded`, `failed` and `incomplete` preserve their distinct outcomes. A valid
  local failed or incomplete run can provide an observed operation interval; it
  does not become a successful analysis.
- `started` means completion is unknown and has an open interval. This record
  is persisted before verification and invocation; it does not prove code started.
- `blocked` is `not_executed`; its verification-attempt times do not establish
  analysis execution chronology.
- Invalid or reversed timestamps are retained as recorded, with `timing_status`
  set to `invalid` and pairwise relations unknown.
- Imported receipt claims retain their timestamps and outcome but are marked
  `untrusted_imported`; they cannot establish observed pairwise chronology.
- Unsupported or malformed receipts produce a compact unknown entry. Their raw
  claims are not promoted to validated run references or timing evidence.

The report qualifies evidence, not scientific validity, parameter use, input
consumption or reproducibility. Receipt authenticity is not established by this
package. Direct external changes and older clients can bypass receipt protections.

## Paging and limits

Each call scans at most 1,000 loaded record slots and returns at most `limit`
entries. It uses existing exact/latest indexes; it does not sort the full registry
or build a new index. Query bounds also apply when no receipt matches.

```python
page = project.execution_history(limit=10)
while page["scan"]["next_offset"] is not None:
    page = project.execution_history(limit=10, offset=page["scan"]["next_offset"])
```

```r
page <- project$execution_history(limit = 10)
while (!is.null(page$scan$next_offset)) {
  page <- project$execution_history(limit = 10, offset = page$scan$next_offset)
}
```

Keep the selector and loaded registry unchanged while paging. Offsets refer to
physical registration slots; they are not snapshot-isolation tokens. If you add
records, save new changes or reopen newer state between pages, restart retrieval.
`registry_revision` and `unsaved` expose the loaded state; the package cannot detect
all unsaved changes from a revision number alone.

`scan` reports the starting offset, processed slots, total loaded record slots,
continuation offset, truncation and stop reason. A limit, scan bound, metadata
budget or report-byte bound can stop a page before the end. Continuation points
to the first unreturned candidate; started/terminal revisions are not repeated on
later pages. `truncated=false` means the page reached the end of the loaded slots,
not that all actual execution was recorded.

Matching analysis records above 64 KiB yield an unknown `metadata_limit` entry
before receipt copying. At most 1 MiB of eligible matching record metadata is
expanded per page. Structured reports are at most 64 KiB. Protocol intent display
is at most 20 steps and 4 KiB, with `omitted_steps`; filtering still uses every
pinned step. A single entry that cannot fit gets a compact unknown `report_limit`
entry so pagination can advance. Unknown entries retain exact selected references;
raw omitted details remain accessible through existing exact getters.

The human-readable summary is at most 4,096 UTF-8 bytes. It shows complete entry
lines with exact local `ID@revision` references, timestamps, outcomes and evidence,
plus relations among shown rows. It omits whole trailing entries when necessary,
reports how many were omitted and preserves the structured page's continuation
offset. Omitted summary rows are still in `execution_history()` for that page;
advancing its cursor is not a way to retrieve those omitted rows. Identifiers and
timestamps are never shortened into different values.

## Read the project timeline

```python
print(project.timeline_summary())
page = project.timeline(view="runs", order="newest")
if page["next_cursor"] is not None:
    following = project.timeline(view="runs", order="newest", cursor=page["next_cursor"])
```

```r
cat(project$timeline_summary(), "\n")
page <- project$timeline(view = "runs", order = "newest")
if (!is.null(page$next_cursor)) {
  following <- project$timeline(view = "runs", order = "newest", cursor = page$next_cursor)
}
```

- `view="registration"` shows every exact record revision in the loaded registry
  by its `created_at` field, including separate started and terminal run revisions.
  Other project events, such as changes to the current input pointer, are outside
  this view. Execution evidence on a receipt-free analysis revision is `unknown`.
- `view="runs"` shows one row per latest analysis revision with a receipt field.
  The dated section sorts by wrapper start for local terminal receipts that report
  code execution and have valid intervals. Open, blocked, imported, malformed and
  invalid intervals appear in the unknown-order section. Recognized receipts
  retain their outcome and original wrapper timestamps where space permits.
  A wrapper start can precede code execution. Ordinary analysis templates appear
  in the registration view. Missing receipts leave actual execution unknown.

`order` is `oldest` (default) or `newest`. Both directions put unknown times last.
The timeline recognizes second-resolution UTC strings ending in `Z`. Unsupported
timestamps remain unknown, with no rounding or time zone conversion. Equal times
use the exact ID and numeric revision to make paging stable. A tie breaker carries
no timing evidence. Run `relations` retain the interval comparisons above for
rows on the same page. The original `execution_history()` order and selectors
remain available. The project inspection card is unchanged.

`timeline()` returns a `biodataledger-timeline/1` report. `rows` carry an exact `ref`,
name, record kind, qualified ordering time (`time_utc`), original registration
timestamp and available input links. Run rows also carry run/template refs,
outcome, evidence, original wrapper timestamps, timing status and registered
output refs. Each link list shows up to ten exact refs, with a count of omitted
links. Text fields above 256 UTF-8 bytes and unusually large link refs are
omitted with markers. Exact getters can retrieve the original metadata. The
text summary shows the rows and continuation of the same page.

`limit` defaults to 10 and accepts 1–20. Reports are bounded to 64 KiB. Pass
`next_cursor` back to the same loaded object, with the same view and order, to
continue. A staged edit, a new committed revision or a reopened object requires
restarting from the first page. A cursor is a local continuation marker.

The first request for a view qualifies and sorts the loaded metadata across the
whole view. Later pages reuse that in-memory order until the loaded state changes.
The timeline reads no payload files and saves no state.
