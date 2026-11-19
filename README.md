# BioDataLedger

BioDataLedger helps you trace a saved figure back to its recorded data, code and parameters in R or Python. When you ask an agent to revise a figure, it can look up the original plotting function and reuse the saved result table. The record shows what was declared and which checks were performed.

## Install

**[Download the latest R package (.tar.gz)](https://raw.githubusercontent.com/nbatada/biodataledger/main/latest/BioDataLedger.tar.gz)**. Keep the file compressed. In a fresh R session, run:

```r
install.packages(file.choose(), repos = NULL, type = "source")
library(BioDataLedger)
```

Select the downloaded file when prompted. This assumes the R dependencies are installed. R registry writes require macOS. [Upgrade an existing project](docs/UPDATING.md).

## Try it

[Follow the R or Python walkthrough](examples/README.md) to register a dataset, link a figure to its analysis, and retrieve the code and parameters after reopening the project.

## Start a ticket on your analysis machine

To install the Python client and optional ticket timer, run this in the terminal on the machine doing the analysis:

```bash
python -m pip install "git+https://github.com/nbatada/biodataledger.git@f05c6e89d365d6f6092d6ce449c9f9dddfcd58d2#subdirectory=python"
```

At dispatch, start one log and pass its path to the implementer:

```bash
mkdir -p "$HOME/bdl-ticket-pilot"
bdl-pilot start --path "$HOME/bdl-ticket-pilot/T001.json" --ticket T001 --arm bdl
```

The timer works with Rscript or Python on macOS and Linux. [Copy the agent prompt and track the ticket through review](docs/TICKET_PILOT.md).

[Agent guide](docs/agent/USAGE.md) · [Reusable functions](docs/HELPERS.md) · [Share a result](docs/SHARING.md) · [API reference](docs/API.md)
