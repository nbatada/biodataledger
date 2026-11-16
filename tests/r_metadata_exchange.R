args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc = args[[1L]])
action <- args[[2L]]; root <- args[[3L]]
json <- function(x) cat(jsonlite::toJSON(x, auto_unbox=TRUE, null="null", digits=NA))
if (action == "inspect") {
  p <- ProjectBundle$open(root); ref <- jsonlite::fromJSON(args[[4L]], simplifyVector=FALSE)
  json(list(metadata=p$get_metadata(ref), view=p$metadata_view(ref), check=p$check_metadata(ref)))
} else if (action == "create") {
  dir.create(root, recursive=TRUE); writeLines(c("sample,patient,note", "001,Pα,NA"), file.path(root,"samples.csv"), useBytes=TRUE)
  writeLines(c("library,sample", "L1,001"), file.path(root,"libraries.csv"), useBytes=TRUE); writeLines(c("x","1"), file.path(root,"raw.csv"))
  p <- ProjectBundle$create("R metadata",root); s <- p$register_metadata("samples.csv","sample_preparation",list("sample"),authority="R",reason="source",required_columns=list("patient"))
  l <- p$register_metadata("libraries.csv","acquisition",list("library"),authority="R",reason="link",links=list(list(ref=s,columns=list("sample"),target_columns=list("sample"))))
  d <- p$register_data("raw.csv","input",hash=TRUE); b <- p$bind_metadata(d,list(s,l),"attach"); s2 <- p$register_metadata("samples.csv","sample_preparation",list("sample"),authority="R",reason="correction",ref=s); p$save()
  json(list(samples=s,samples_revision=s2,libraries=l,bound=b))
} else if (action == "export") {
  p <- ProjectBundle$open(root); archive <- args[[4L]]; mode <- args[[5L]]; refs <- jsonlite::fromJSON(args[[6L]], simplifyVector=FALSE)
  plan <- p$preview_export(mode, include=refs); p$export_zip(plan, archive); cat("{}")
} else if (action == "import_check") {
  p <- ProjectBundle$import_zip(args[[4L]], root); ref <- jsonlite::fromJSON(args[[5L]], simplifyVector=FALSE)
  json(list(view=p$metadata_view(ref), check=p$check_metadata(ref)))
} else if (action == "graph") {
  p <- ProjectBundle$open(root); ref <- jsonlite::fromJSON(args[[4L]], simplifyVector=FALSE)
  json(p$export_graph(ref, depth=5L, format="structured"))
} else stop("unknown action", call.=FALSE)
