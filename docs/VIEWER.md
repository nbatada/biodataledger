# Browse a local project snapshot

Use the browser snapshot to find a retained figure, see its recorded input and
plotting code, and copy a path. The viewer is available in source version 0.18.0. It uses the loaded R or Python project handle.

```python
p.view()
report = p.view("review.html", open_browser=False)
print(report["path"])
```

```r
p$view()
report <- p$view("review.html", open_browser = FALSE)
cat(report$path, "\n")
```

Search by name, topic, question, or recorded use. Select a record to see its
exact revision and follow its recorded references. Enable historical revisions
to find earlier versions. A recorded input link always identifies its original
revision, even if a newer revision is current. The timeline shows registration
dates and recorded wrapper runs in separate views, with their original evidence
qualifications.

The **Analysis log** is a five-column, newest-first view of recorded analysis
history: date, analysis, recorded inputs, retained outputs, and status/evidence.
An ordinary analysis uses its registration time, not an execution claim. A
qualified receipt uses its recorded wrapper-start time; missing or invalid
receipt timing remains unqualified. Exact links preserve historical revisions.
Associated figures are labelled separately: they are not observed generated
outputs. Directly linked metadata descriptors are shown as links only; the
snapshot does not read their table payloads. Registration, wrapper evidence,
and scientific acceptance remain distinct.

Dates render in the browser's local timezone. Group by day (default), week,
month, or leave rows ungrouped; unknown or unqualified dates remain last.
The log favors human-readable registered names and paths. Open a row's details
to inspect or copy its exact revision; a link outside the captured record cards
is marked unavailable rather than replaced by an ID.

Use **Contents — choose an analysis** to jump by readable analysis title.
Search titles or displayed dates, or expand a day/week/month to browse its work.
Contents includes all captured analyses, grouped according to Day/Week/Month;
a jump switches the displayed group page when necessary and selects the exact
analysis row. **Back to contents** appears after each group and at the bottom.
Historical entries are labelled earlier revisions. Snapshot omissions still apply.

Choose **Dependencies** beside an Analysis log row to inspect its bounded recorded
upstream and downstream relationships. The view keeps the selected analysis separate
from its graph anchor. When a qualifying local wrapper receipt is recorded, the graph
uses that receipt's exact producing run; it does not substitute a newer receipt
revision. A structurally valid imported receipt uses its recorded producing run too,
but is labelled as an untrusted imported claim, not execution evidence. Otherwise it
uses the selected analysis and says so. Relationship rows show
their recorded type, basis and source field. They are registry links, not proof of
file use, execution, causality, or scientific acceptance. Use **Return to analysis**
or **Back to contents** to resume the log.

The view captures depth three and at most 20 nodes in each direction. It reports graph
limits, unresolved items and cycle qualifications. Direct declared inputs remain a
separate list. Links whose record cards are outside the snapshot retain their readable
recorded name and are marked outside the snapshot rather than silently replaced.

## What the snapshot captures

The page shows the loaded registry revision, capture time, and unsaved changes
on that handle. Generate a fresh snapshot when the registry changes. Reopen the
project first to see changes saved by another process. The export leaves the
registry and pending edits as they are. Default paths are lexical local paths
from the registry, with availability unchecked. The page includes code
references and snapshot paths. It leaves code and registered data files unread.

Analysis-log and Dependencies paths can be copied. A safe absolute local path may
also have an **Open** `file:` link; paths are URL-encoded and never accept network,
script, data, relative or control-character URLs. A missing or size-capped path leaves
the recorded name and exact reference available. Paths refer to the computer that
created the export; availability and integrity remain unchecked.

Latest revisions appear first, followed by earlier revisions. Each group shows
newer stored entries first. Stored order can differ from recorded time.
The default limit is 5,000 exact revisions. Use `limit` from 1 to 5,000 for a
smaller capture. Cards above 16 KiB keep their identity and indicate omitted
details. Project fields above 4 KiB, current-purpose entries beyond a 64 KiB
budget, and records beyond a 16 MiB metadata budget are reported as omissions.
The timeline captures up to the smaller of `limit` and 1,000 rows in oldest-first
pages; the Analysis log captures the newest rows first. Both retain page-local timing relations. The optional Analysis log
is reduced first if needed to retain the snapshot's metadata-size bound. A reference outside the
capture is identified by its exact revision. Use the native
[`get_info()`](API.md#get_info) or [`timeline()`](API.md#timeline) to inspect
more metadata.

## Include selected figure previews

Pass up to 10 exact FIG references to embed selected image bytes.

```python
report = p.view(open_browser=False, preview_refs=["FIG-001@2"])
```

```r
report <- p$view(open_browser = FALSE, preview_refs = list("FIG-001@2"))
```

Full returned reference objects also work. Each file needs a recorded SHA-256
digest and must match it at capture. The limit is 2 MiB per file and 8 MiB
combined. The viewer supports PNG, JPEG, GIF, WebP and a restricted static SVG
subset. The browser can reject an SVG with active or unsupported markup even
when the exporter verified its digest. A missing file, a digest mismatch or an
unsupported preview leaves the associated metadata available. The final HTML
limit is 32 MiB. Lower the record limit or select fewer previews if the export
exceeds it.

## File and browser behavior

On supported local macOS filesystems, `path` writes one standalone HTML file
with owner-only permissions in an existing directory. Relative paths use the
project root. Choose a new filename for each snapshot. An omitted path creates
a private temporary directory that persists after the R or Python process
exits. Delete snapshots you no longer need. They can contain private metadata,
absolute paths, and selected figure bytes.

The return value contains `path`, `captured_at_utc`, `coverage`,
`preview_results`, `browser_open_requested` and `launch_error`. A failed
default-browser request leaves the written file available. Use
`open_browser=False` in Python or `open_browser = FALSE` in R to write the file
without requesting a browser. The standalone page works offline and reads
metadata from the capture. Review the recorded evidence before reusing an
artifact or making a scientific claim.
