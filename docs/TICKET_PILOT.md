# Measure a scientific ticket

Use this pilot for one question: how much time, rework and review does it take to get a figure you can accept? A project manager or scientist records ticket dispatch. The implementer records source retrieval, measurements and deliveries. The scientist reviews the figure and records the disposition. A fresh process can continue the same ticket. Keep the ticket identifier anonymous if you expect to share results.

## First project

Install the pilot on the computer where the analysis runs. In the intended Python environment:

```sh
python -m pip install --upgrade "git+https://github.com/nbatada/biodataledger.git@main#subdirectory=python"
```

For a fixed version, replace `main` with the full commit SHA for 0.22.0. The pilot needs Python 3.9 or newer with BioDataLedger installed. Use a fresh environment for this optional command. Your existing R console can remain open and continue using its loaded objects. All examples below are terminal commands unless labelled R. Check your selected interpreter with:

```sh
python -c 'import biodataledger; print(biodataledger.__version__)'
python -m biodataledger.pilot --help
```

Start with three to five ordinary tickets covering a straightforward task and at least one figure revision. Let corrections occur naturally. Choose a new log path per ticket in a private directory **outside** any measured data or results folder. Use the same log for the entire ticket, including retries. A returned log can reveal the ticket ID, references, locations and user-entered text. Share a reviewed summary first.

## Record a ticket

From an existing project working directory, choose a private location for the log.
Use the same terminal variables in the commands below, or give their absolute
values to the agents. The analytics receipt is separate from the scientific registry.

```sh
mkdir -p "$HOME/bdl-ticket-pilot"
ticket="$HOME/bdl-ticket-pilot/T001.json"
python -m biodataledger.pilot start --path "$ticket" --ticket T001 --arm bdl
```

For a paired trial add `--pair redraw-01` at start in both arms and use
`--arm baseline` for the Git/manifest copy. For optional storage measurements
add `--disk /absolute/path/to/results` at start. Choose a stable directory that
already exists and excludes the ticket log. A large folder traversal takes time;
select the same scope and endpoint measurements in both arms.

Once the implementer has retrieved the requested source, and again when it delivers
the actual figure, record those milestones. Replace the illustration references.

```sh
python -m biodataledger.pilot locate --path "$ticket" --evidence 'FIG-001@1'
python -m biodataledger.pilot deliver --path "$ticket" --evidence 'FIG-001@2'
```

If you request a correction to the original brief, the implementer continues this ticket:

```sh
python -m biodataledger.pilot correct --path "$ticket" --reason 'Original request specified larger labels'
python -m biodataledger.pilot deliver --path "$ticket" --evidence 'FIG-001@3'
```

When you accept the latest delivery, record that decision immediately. Omit
`--active-review-seconds` if you did not time your active reading and review.
Record each measured amount once. Supply units in usage and cost labels, such
as `--usage input_tokens=5400` or `--cost USD=0.12`, only when the value is known.

```sh
python -m biodataledger.pilot accept --path "$ticket" --decision accepted --active-review-seconds 42
python -m biodataledger.pilot summary --path "$ticket"
python -m biodataledger.pilot_report "$ticket" --out "$HOME/bdl-ticket-pilot/T001-review.html"
```

Open the HTML in a browser. For a compact comparison, pass multiple ticket paths
to `pilot_report` before `--out`. Choose a new file name each time.

## Measure selected resources

**Rscript or Python batch.** For an already authorized analysis command, use
`measure` in place of the normal launch. This actually executes the command
once. Its stdout and stderr go to their usual destinations. Use an open ticket.

```sh
python -m biodataledger.pilot measure --path "$ticket" -- Rscript --vanilla analysis.R
```

The recorded interval is the selected command's elapsed time. Supported systems
also report OS-accounted child CPU time, peak resident memory and block operations.
The operating system determines the accounting for children and subprocesses.
Block operations have units of operations, not bytes. File cache, concurrency and
runtime startup affect comparisons. The ticket duration also includes time outside
the command. A failed command still counts toward the attempt.

**Existing R console.** Run `Sys.getpid()` in that console. From a terminal, take
an explicit reading before and after a selected operation; replace 12345 with
the reported PID and keep the ticket open:

```sh
python -m biodataledger.pilot sample --path "$ticket" --pid 12345
```

The difference between readings includes other activity in that R process. A
sample can miss a transient peak. Keep the same R process throughout a ticket,
record its starting size and note other heavy applications. When the OS denies
a reading, retain the unknown. To investigate overall laptop pressure, attach a
separate observation of system memory pressure or swap from Activity Monitor.
The pilot does not estimate these quantities from RSS.

Use the JSON summary for resource details and the HTML table for a quick review.
Look at starting storage, ending storage and their signed difference. A growing
results directory can be desirable if keeping plotting inputs avoids expensive
recomputation. Logical file sizes do not measure physical disk allocation, total
I/O or exclusive ownership by the ticket.

## Review card

Put the revised figure or visual difference first. Keep the text below it short enough to support a decision.

| Show | Example of what to return |
| --- | --- |
| Result and change | Exact FIG revision; larger labels only |
| Retained input | Exact result-table revision and analysis or plotting source behind it |
| Scientific check | Approved and observed donor set, or the specific unverified step |
| Reuse | Plotting function and exact version; upstream computation rerun zero times if supported by evidence |
| Decision needed | Accept, request a correction to the original ticket, or open a new ticket for a change in preference |

The pilot records milestones. Use the ordinary BDL figure lookup, rendering sources, helper references and execution receipts for the scientific evidence. A manifest workflow can attach its own identifiers. A ticket marked accepted records a reviewer's decision. A missed donor or changed parameter can still require independent checking.

## Compare two workflows

1. Give both arms the same model and effort, skill, plan, selected data and parameter requirements, plotting library, saved tables and validation checks. Record model/version and process mode with your evaluation notes. Arm A uses Git plus a manifest. Arm B adds the ledger. Run the pilot in both.
2. Try a fresh-chat lookup starting from a figure, a cosmetic redraw, then a theme change affecting two related figures and leaving a third figure alone. Use matched project copies and alternate the order across repeated trials. Check the exact source and output, correct first delivery, unexpected reruns, wrapper use and unaffected output. Include one deliberate mismatch only in a separate synthetic control.
3. Compare the time from dispatch to the **delivery ultimately accepted**, elapsed time to the decision, elapsed time to the correct source, corrections and active review time. Include rejected, open and unresolved tickets in the denominator with their status; averaging only successful tickets can reward incomplete work. If a preference changes after delivery, start another ticket. Do not infer human reading time from a timestamp gap.
4. Include the cost of retaining the inputs, code and results at the outset. Record one-time setup separately, as well as the number of revisions over which that setup pays off. Compare wall time while waiting for the agent separately from human active minutes and cloud bills. Use provider-reported tokens and cost if available. Mark missing metrics unknown.

### What to return

For each ticket, share the summary, anonymous task label, workflow arm, model and effort, fresh/live process mode, expected and actual changed outputs, upstream rerun count if known, and a short note on your review or any error. Include the original acceptance conditions and how you checked them. If possible, include both an easy ticket and a correction or unresolved ticket. Review all paths, text and scientific identifiers before sharing. Raw data and full chats are unnecessary for the first assessment. With one observational arm we can identify delay or rework; a matched comparison is needed to attribute a saving to BDL.

## Use this with the agents

Give the same brief instructions to the manager and implementer. Set the ticket path and acceptance conditions for this task first.

```text
The scientist has enabled ticket timing for this task. The manager starts the
ticket at dispatch. Reuse the same local ticket path in the implementer chat.
Record lookup when you identify the requested exact source. Record delivery
when the figure and review card reach the scientist. Keep each correction on
the same ticket. Leave the decision open until the scientist gives it.
Preserve the intended data, plot-input revision and helper version. For a
cosmetic change, count any upstream rerun and explain why it was necessary.
Return the figure first and the short review card beneath it.
```

## Reading the measurements

- A ticket without a scientist disposition remains open. Rejection and an unknown final assessment should remain visible when comparing arms. The event times reflect when someone recorded the milestone. Record them immediately and use the same clock for the ticket.
- The final delivery-to-acceptance interval may include waiting, scheduling and other work. For active review, use a timer or a reported estimate labelled as such. Human attention, discomfort or frustration cannot be inferred from token count.
- Record known token counts and costs as **increments** at start or disposition. If you have a cumulative total, enter it only once. Use distinct labels for input/output tokens and currency. Leave them absent when your provider supplies no reliable totals.
- Start and finish disk snapshots capture totals for the chosen scope. A delta combines changes by every writer to that directory. Use comparable quiet folders. Do not sum overlapping scopes. OS accounting may report zero block operations when files were cached.
- A visual improvement is a measured outcome only when reviewed. A review card claiming zero upstream reruns or use of a trusted function needs corresponding evidence from a controlled command, harness or selected native receipt. Mark unavailable evidence unknown.

## Install from a local build

In a new Python environment (or in the terminal already prepared for the pilot),
install the wheel with `python -m pip install /absolute/path/to/biodataledger-0.22.0-py3-none-any.whl`.
The installed `bdl-pilot` and `bdl-pilot-report` commands are short forms of
the Python module commands above. R analyses can use the same terminal pilot without
any modification to the R package or live objects. To use the accompanying R client,
install its tarball into your chosen project library and check the loaded namespace
in a fresh R process. Keep live sessions with pending work open during installation.

Ticket files stay on the machine running the pilot until you explicitly transfer them.
On a headless server, copy the generated HTML to your laptop to open it offline.
Use server-local storage for ticket writes. Shared network-volume locking and concurrent writes across hosts are unqualified.
The standalone pilot can surround an Rscript command on Linux. The native R registry still requires macOS for create, changed save and import.

## If a measurement was interrupted

Inspect the ticket summary before doing anything else. A measurement reservation
with no result means the instrument has no confirmed exit status or resource
totals. Check that the original measurement and any child command have stopped.
Then run `bdl-pilot abandon-measure --path "$ticket" --reason "Confirmed stopped" --confirmed-stopped`. A known live measurement owner on the same host blocks recovery.
Never retry the scientific command merely to repair the log. A stale ticket-write
lock should be inspected by the operator after confirming that no writer is active.
Missing measurements stay unknown.

For cost and timing comparisons, use one machine clock per ticket. Backward clock
steps invalidate affected intervals; forward adjustments can inflate durations.
Use matched machines and comparable cache/load conditions. Child process elapsed
time uses a monotonic clock. Disk measurements count logical bytes at two selected
endpoints and can miss temporary files that appear and disappear between them.
