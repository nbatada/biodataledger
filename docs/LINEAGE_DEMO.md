# Trace a saved sample-count figure

**Which samples and cells are included in this comparison?** The example starts
with a figure linked to a synthetic slide deck. A fresh process finds the figure
by its recorded topic and question, retrieves the exact count table and plotting
script, and traces the two cohorts that supplied the counts.

## Run the example

Use local macOS and an installed BioDataLedger build that supports
`export_graph(style="presentation")`. Run one of these pairs from the source
checkout. Use a new project directory with an existing parent.

**Python**

```sh
python3 examples/lineage_demo.py create /tmp/bdl-lineage-python
python3 examples/lineage_demo.py inspect /tmp/bdl-lineage-python > /tmp/bdl-lineage-python/lineage.dot
```

**R**

```sh
Rscript examples/lineage_demo.R create /tmp/bdl-lineage-r
Rscript examples/lineage_demo.R inspect /tmp/bdl-lineage-r > /tmp/bdl-lineage-r/lineage.dot
```

`create` saves the synthetic project and `cells-by-sample.svg`. `inspect` prints
the exact references and paths to standard error and sends the lineage DOT to
standard output. The inspection leaves the registry bytes intact. With Graphviz
installed, render the DOT to SVG. Use the directory for the client you ran.

```sh
dot -Tsvg /tmp/bdl-lineage-python/lineage.dot -o /tmp/bdl-lineage-python/lineage.svg
```

The graph starts from the retained figure and traces upstream. Blue marks the
path from cohort A and orange marks the path from cohort B. The two colors meet
where the count table draws from both cohorts. The raw table and selection steps
are also visible. The presentation view leaves out links between revisions and
records reached only through those links. The default graph shows those links.

## Check the counts and exact sources

Cohort A keeps hashed cells from Vehicle and Low. Cohort B keeps hashed and
unassigned cells across Vehicle, Low and High. The retained `cells-by-sample.csv`
contains these counts from the 22 invented cell rows.

| Sample | Treatment label | Cohort A | Cohort B |
| --- | --- | ---: | ---: |
| S01 | Vehicle | 5 | 7 |
| S02 | Low | 3 | 6 |
| S03 | High | 0 | 5 |

These are descriptive inclusion counts for three invented samples.

`FIG-001@2` is the figure revision with the recorded slide use and question.
It names `DATA-004@1` as its rendering input and selects entry `0` of `ANA-004@1`
as its plotting script. The count table's producer records `DATA-002@1` and
`DATA-003@1` as its two input cohorts. The later `DATA-002@2` is current for the
next cohort A review. The retained table still refers to `DATA-002@1` through its
producer.

The creation script filters and counts rows. The separate plotting script reads
the retained count table and draws the bars from those numbers. In a fresh
process, `inspect` uses exact metadata for lookup, then explicitly verifies the
figure file, count table and selected code snapshot against their saved digests.
To redraw the plot, run the printed code snapshot with the matching interpreter
and pass the printed count table path and a new SVG path.

The graph and registry show declared relationships. The demo runs the native
scripts directly and records no BioDataLedger execution receipt.

[Python example](../examples/lineage_demo.py) · [R example](../examples/lineage_demo.R) ·
[Output discovery reference](api/OUTPUT_DISCOVERY_V1.md) · [Graph reference](api/GRAPH_V1.md)
