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

## What the snapshot captures

The page shows the loaded registry revision, capture time, and unsaved changes
on that handle. Generate a fresh snapshot when the registry changes. Reopen the
project first to see changes saved by another process. The export leaves the
registry and pending edits as they are. Default paths are lexical local paths
from the registry, with availability unchecked. The page includes code
references and snapshot paths. It leaves code and registered data files unread.

Latest revisions appear first, followed by earlier revisions. Each group shows
newer stored entries first. Stored order can differ from recorded time.
The default limit is 5,000 exact revisions. Use `limit` from 1 to 5,000 for a
smaller capture. Cards above 16 KiB keep their identity and indicate omitted
details. Project fields above 4 KiB, current-purpose entries beyond a 64 KiB
budget, and records beyond a 16 MiB metadata budget are reported as omissions.
The timeline captures up to the smaller of `limit` and 1,000 rows per view, in
oldest-first pages with page-local timing relations. A reference outside the
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
