# Ordered analysis protocols — version 1

BioDataLedger 0.10.0 adds an optional record of intended work and a read-only
comparison against selected execution evidence. It does not schedule steps,
execute a protocol, install environments or evaluate parameter-selection rules.

## Record the intended work

First register analysis templates with exact DATA inputs, registered code, a method
and parameters. Unknown inputs, method, parameters or absent code are rejected.
A protocol pins those exact ANA revisions, including their code snapshots and
experimental-design context. Revising an analysis does not change an existing
protocol. No scientific data are embedded in the protocol. This initial contract requires
already registered exact inputs; it does not bind a future output slot to a later
step. It can retain ordered intended operations on known artifacts, but is not a
prospective pipeline description for artifacts that do not yet exist.

```python
protocol = project.register_protocol(
    "Synthetic clustering plan",
    steps=[{
        "step_id": "cluster",
        "analysis_ref": analysis_ref,
        "data_dependent_params": ["n_pcs"],
        "required_outputs": [{"kind": "result"}],
        "seeds": {"random": 42},
        "environment_ref": None,
    }],
    reason="Retain the scientist-selected method and order",
)
project.save_and_confirm()
```

```r
protocol <- project$register_protocol(
  "Synthetic clustering plan",
  steps = list(list(
    step_id = "cluster",
    analysis_ref = analysis_ref,
    data_dependent_params = list("n_pcs"),
    required_outputs = list(list(kind = "result")),
    seeds = list(random = 42),
    environment_ref = NULL
  )),
  reason = "Retain the scientist-selected method and order"
)
project$save_and_confirm()
```

These snippets assume `project` and `analysis_ref` already exist. In the pinned
analysis, `n_pcs` should describe the intended selection rule, for example
`"select from the retained variance diagnostic"`. Other parameters, such as
`resolution=0.5`, are fixed. A later run may report `n_pcs=12`; comparison exposes
that value without comparing it to the rule as though both were fixed numbers.
These are recorded values supplied to the invocation, not measured return values.
The package cannot establish that the scientist applied the selection rule or that
the function computed or used that value. Results calculated only inside the
function remain unknown unless separately retained.

Each step has a unique `step_id`, an exact `analysis_ref`, and an ordered
`required_outputs` list. Output descriptors use `kind="result"`, or
`kind="figure"` with a figure `type`. They describe required future outputs;
execution receipts supply the actual exact output revisions. They do not prescribe
future record IDs or establish scientific output content.

Optional `data_dependent_params` defaults to an empty list. `seeds` and
`environment_ref` default to null, explicitly leaving them unspecified.
An environment reference pins an existing record; the execution wrapper does not
capture or validate the environment. The same native metadata contract is used in
R and Python. Protocols use existing DEC records and versioned optional details;
legacy registry paths and archive formats are unchanged.

## Revision and declared approval

Use `register_protocol(..., ref=protocol)` to append a revision from the latest
exact protocol revision. Earlier revisions remain retrievable with
`get_protocol(old_ref)`. Generic record corrections cannot edit a protocol.
The protection applies through these APIs; it does not make files immutable to
external edits or enforce the contract in older clients.

Approval uses the existing scientific-decision API:

```python
approval = project.record_scientific_decision(
    text="Approved synthetic protocol",
    reason="Scientist-submitted approval",
    subjects=[{"ref": protocol}],
    scientific_status="approved",
)
project.save_and_confirm()
```

In R use `project$record_scientific_decision(...)` and
`subjects=list(list(ref=protocol))`. This records a submitted declaration; it does
not authenticate the scientist or grant authority to an agent. A decision on one
protocol revision does not approve a later revision. Comparison can pin the exact
approval decision with `approval_ref`; it does not search for or infer approval.

## Compare selected evidence

```python
report = project.compare_protocol(
    protocol,
    executions=[{"step_id": "cluster", "analysis_ref": receipt_ref}],
    approval_ref=approval,
)
```

```r
report <- project$compare_protocol(
  protocol,
  executions = list(list(step_id = "cluster", analysis_ref = receipt_ref)),
  approval_ref = approval
)
```

`receipt_ref` is an exact terminal ANA receipt returned by an earlier explicit
`run_analysis`; this call itself never executes anything. Ordinary analysis records
can also be selected, but declarations alone do not establish observed execution.

Comparison checks intended inputs, methods, fixed parameters, code identity,
seeds and required outputs against the selected records and scoped receipts.
It distinguishes missing, extra or reordered submitted steps from observed order.
Submitted list order, dependency order and registration order are not proof of
execution chronology. Receipt timestamps can establish order only when their
recorded intervals are strictly ordered; ties, overlaps and absent timing leave
order unknown. Timestamps and receipts are not authenticated testimony.

Unknown, malformed and imported evidence cannot establish an observed match.
An environment pin remains a declaration because current receipts do not observe
environments. Matched file identities are separate from actual consumption;
parameters and seeds passed to a function are separate from their use by its code.
Scientific validity, biological equivalence and reproduction remain unverified.
A comparison report is evidence for review, not a scientific compliance certificate.

Queries operate on bounded selected metadata. They do not load matrices, hash
files, crawl folders, write records or save. Save newly registered protocols and
approval decisions explicitly before handing them to another session.

Protocols and comparison reports are each limited to 64 KiB of JSON metadata.
At most 100 steps, selected executions and outputs per step are accepted.
Each pinned or selected analysis is limited to 64 KiB of metadata, with a 1 MiB
expanded-analysis budget per protocol or selection. These bounds apply before
receipt copies; ordinary payloads are never read. Oversized requests are rejected
explicitly; they are not silently truncated.

## Read the report

`steps` reports each expected step's exact analysis ref, selected receipt ref,
receipt template ref when available, `mismatches`, `unknown`, and recorded
`data_dependent_observations`. Missing steps have `missing_step`; extra submitted
steps appear in `extra_steps`. Duplicate step selections are rejected.
`approval.status` refers only to the submitted exact approval declaration.

`order` compares the submitted step IDs with intended order. `observed_order`
is `strict_nonoverlap_in_submitted_order`, `different_from_submitted_order`, or
`unknown`, based only on valid, successful local receipt intervals. A single step
has no inter-step chronology to establish and returns `unknown`. Imported evidence
is identified by `imported_claim` and cannot establish observed order.

An empty mismatch list means no differences were found in the compared recorded
fields. Always read `unknown` and `coverage`: they retain the limits on environment,
input identity/consumption, actual parameter use and scientific validity. There is
no aggregate scientific PASS or approval inferred from a metadata match.
