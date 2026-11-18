# Latest R package

[Download BioDataLedger for R (.tar.gz)](https://raw.githubusercontent.com/nbatada/biodataledger/main/latest/BioDataLedger.tar.gz)

Keep the downloaded file compressed. In a fresh R session, run the following and
select the downloaded `BioDataLedger.tar.gz` when prompted:

```r
install.packages(file.choose(), repos = NULL, type = "source")
library(BioDataLedger)
packageVersion("BioDataLedger")
```

The current download contains **0.22.0**. Its filename and download link stay the
same across updates. Local installation assumes the package's R dependencies
are already installed.
