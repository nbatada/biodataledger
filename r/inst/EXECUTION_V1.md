# Explicit native execution receipts — version 1

BioDataLedger 0.7.0 can observe one explicit native code invocation. Ordinary
registration still records declarations. Receipt observations are not scientific
approval, reproducibility, proof of input consumption or authenticated testimony.
No LLM, workflow scheduler, sandbox, database or new dependency is required.

## One explicit operation

Python:

```python
receipt = project.run_analysis(
    analysis_ref,
    entry_point="run",
    outputs=[{"path": "result.csv", "kind": "result"}],
    seeds={"random": 42},
)
print(project.execution_summary(receipt["receipt_ref"]))
```

R:

```r
receipt <- project$run_analysis(
  analysis_ref,
  entry_point = "run",
  outputs = list(list(path = "result.csv", kind = "result")),
  seeds = list(random = 42)
)
cat(project$execution_summary(receipt$receipt_ref))
```

The selected analysis must have exactly one snapshotted code file, at most 1 MiB.
Its language must match the calling client. Define the named function in that file:

```python
def run(inputs, params, seeds, outputs):
    # These arguments are paths and detached metadata, not loaded matrices.
    # Apply any requested RNG seeds explicitly in your scientific code.
    with open(outputs[0], "w", encoding="utf-8") as handle:
        handle.write("value\n1\n")
```

```r
run <- function(inputs, params, seeds, outputs) {
  # Apply requested RNG seeds explicitly here if your method uses them.
  writeLines(c("value", "1"), outputs[[1]])
}
```

These examples intentionally ignore their inputs. Their receipts must report
input consumption unknown even if input-file verification succeeded. Seeds and
parameters are captured declarations supplied to the function; the wrapper does
not verify that code applied them or set any RNG state automatically.

Snapshot bytes are read, checked against the registered digest and executed in a
new native namespace/environment. R retains access to the ordinary global/package
search environment; ambient objects and packages are not captured. Top-level code
in that file also executes.
Imports and indirect code are ordinary native execution and are not captured
transitively. Do not run untrusted code. The package does not restrict its effects,
change the working directory, install environments or load scientific objects.

`inputs` contains resolved local paths in the exact analysis input order. `params`
and `seeds` are detached metadata. `outputs` contains absolute paths in the requested
order. The function's return value is ignored. Output paths are relative to the
project root unless absolute; parent directories must already exist. Descriptors
use `kind="result"`, or `kind="figure"` with a nonempty `type`.
Preexisting files, duplicate destinations and registry-internal destinations are
rejected before invocation. At most 100 inputs and 100 outputs are accepted.

## Verification and persistence

`verify_inputs=True`/`TRUE` checks each selected DATA revision against its existing
SHA-256 baseline immediately before invocation. Missing baselines or mismatches
block execution; the runner does not silently establish a new baseline. This is
file identity verification, not live-object membership, biology or use by code.
With verification disabled, input identity remains unknown. No payload hashing
occurs during ordinary metadata queries.

`verify_code=True`/`TRUE` also compares the current original code file with its
registered baseline. Changed or missing originals block. Setting it false allows
execution of preserved snapshot bytes even if the original changed or disappeared;
snapshot integrity is always checked. The receipt identifies those exact bytes.

Each call creates a new ANA run copied from the exact template revision. It preserves
inputs, method, parameters, design and code snapshot references. It does not modify
the template or move current-purpose selections. A started revision is committed
through `save_and_confirm()` before verification and invocation. This saves **all
pending changes**, including unrelated staged edits in that loaded project.
A failed initial save prevents execution.

The terminal revision records the observed outcome and output checks, then uses
`save_and_confirm()` again. The returned receipt includes the exact terminal
`receipt_ref`, initial `run_ref` and the persistence confirmation. A getter retrieves
recorded execution evidence, not a freshly generated save confirmation. Save errors
propagate; never interpret an in-memory terminal record as confirmed durable output.
External files can remain after failure, and no cleanup or rollback is implied.

If the process dies after the initial save, its started receipt remains. It means
completion was not recorded, not that execution is still running or succeeded.
Historical started references remain started. Outputs point to that exact producer
revision; the terminal receipt explicitly lists output record references. Query the
returned terminal reference to inspect completion, without rewriting old links.

## Outcomes and evidence

The receipt uses `biodataledger-execution/1` in optional analysis details. Status is
`started`, `succeeded`, `failed`, `blocked` or `incomplete`. Success means the
invoked function returned and requested outputs were captured; it says nothing about
scientific validity. Failure, blocking and incomplete output capture raise a native
error/condition with the receipt attached. Inspect its status before using results.

For failures after a run has started, inspect the attached receipt:

```python
from biodataledger.execution import ExecutionError

try:
    receipt = project.run_analysis(analysis_ref, "run", outputs=outputs)
except ExecutionError as error:
    receipt = error.receipt
    print(project.execution_summary(receipt["receipt_ref"]))
```

```r
receipt <- tryCatch(
  project$run_analysis(analysis_ref, "run", outputs = outputs),
  BioDataLedgerExecutionError = function(error) error$receipt
)
```

Invalid call arguments can reject before a run is created. Persistence errors
propagate separately and do not supply a successful persistence confirmation.

Start/end timestamps concern the wrapper boundary. Phase fields distinguish code
invocation from invoking the named function. Invoking source code does not prove
every line executed. Inputs retain exact references and checked/unknown identity.
The receipt preserves code snapshot identity, method, parameters and seed declarations.

Present output files are explicitly hashed and registered through `register_result`
or `register_figure`. Missing or unreadable files remain visible; partial outputs
can be captured after failure. Hashes observe bytes at that boundary. A file appearing
during the operation does not prove the callback created it: concurrent processes
and unrestricted code can interfere. Source/input files can also change after a
check. No filesystem immutability, secure isolation or transitive provenance is claimed.

Always separate:

| Evidence | What it establishes |
| --- | --- |
| Exact registered inputs | Which revisions were supplied as declared inputs |
| Input digest match | Those file bytes matched the registered baseline at the check |
| Executed snapshot digest | Which captured source bytes the wrapper invoked |
| Function invocation and return | The named function was invoked and its observed outcome |
| Output digest and record ref | Captured file identity and exact retained record |
| Input/downstream consumption | Unknown; code can ignore arguments or use other inputs |
| Scientific validity | Unknown; requires scientific assessment |

## Retrieval, interoperability and limits

`get_execution(ref)` retrieves a detached receipt for one exact ANA revision.
Absent, unsupported or malformed metadata reports unknown. Imported receipt views
add `authenticity="untrusted_imported_claim"`. `execution_summary(ref)`
is bounded to 4096 UTF-8 bytes. Neither operation loads files, hashes payloads,
reloads the registry, scans unrelated records or writes. Ordinary generic
analysis/figure provenance views remain conservative; they do not automatically
promote declared producer links to verified consumption.

Both native clients preserve and inspect the same optional metadata through existing
save/import paths. Import never executes code. Raw edits, old clients and external
archives can forge or alter metadata: structurally valid receipt fields are recorded
observations, not cryptographic authentication. Normal current-client mutation APIs
protect run evidence/context; they cannot constrain an unrestricted interpreter.
Existing registry schemas, source snapshots and ZIP formats are unchanged. Older
clients preserve optional metadata but cannot validate or enforce this contract.

## Input-control checkpoints — 0.11.1 (local development)

Verified execution now reuses strict `resolve_data` eligibility and SHA-256 checks
at preflight, immediately after top-level code before callback invocation, and
after the callback, including callback errors. An inactive exact DATA revision is
ineligible even with `verify_inputs=False`; unchecked bytes otherwise stay unknown.
Missing or changed required files block before invocation. A later failed checkpoint
yields a failed run and preserves the invocation flag; outputs may already exist.
The latest `inputs` field reflects the latest check, not an earlier PASS.

R optionally accepts `object_checks=list(list(ref=data_ref,
get_object=function() current_object, assay="RNA", layer="counts"))`.
Each ref must be an exact template input. The getter supplies the current live
object at every checkpoint; the runner invokes existing `check_object` and requires
PASS. FAIL, required UNKNOWN or a getter/checker error blocks continuation.
No automatic object loading or Python live-object adapter is added. With no
configuration, no live-object verification is claimed. Getters are trusted caller
code, not an authenticated binding to the callback's objects.

Optional receipt metadata `input_checkpoints` uses version
`biodataledger-input-checkpoints/1`: ordered `checks` contain `phase`, `files` and
compact `objects` (`ref`, `overall`, `blockers`). Legacy receipts without this field
remain readable and do not acquire checkpoint evidence. File matches, object
checks, callback invocation and actual consumption remain separate; consumption,
scientific validity and downstream consumption are always unknown.

Default verified execution hashes each input three times rather than once. Object
checks additionally re-read their explicit authority references three times when
configured. Ordinary registration and metadata lookup are unchanged. Large files
therefore incur explicit additional verification I/O. Disabling file verification
does not imply a verified match or disable configured object checks.

These are checkpoint observations, not a sandbox. Native code can read another file,
ignore checked objects, race a check, or mutate and restore data between checks.
Fresh checks detect persistent changes at later governed boundaries; they cannot
prove every byte read, enforce arbitrary intermediate operations, or guarantee
scientific correctness. R's live checker observes its existing membership/design/
representation contract, not all expression values.
