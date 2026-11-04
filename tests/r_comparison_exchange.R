args <- commandArgs(TRUE)
library(BioDataLedger)
p <- ProjectBundle$open(args[[1]])
request <- jsonlite::fromJSON(args[[2]],simplifyVector=FALSE)
view <- p$get_comparison(request$ref)
if (isTRUE(request$read_only)) {
 cat(jsonlite::toJSON(list(view=view),auto_unbox=TRUE,null="null",digits=15,force=TRUE))
 quit(status=0)
}
new_ref <- p$record_comparison_assessment(request$plan,request$candidate,request$observations,"native evidence")
invisible(p$save_and_confirm())
cat(jsonlite::toJSON(list(view=view,new_ref=new_ref,new_view=p$get_comparison(new_ref)),auto_unbox=TRUE,null="null",digits=15,force=TRUE))
