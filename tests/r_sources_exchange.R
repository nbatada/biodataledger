args<-commandArgs(TRUE);library(BioDataLedger,lib.loc=args[[1]])
p<-ProjectBundle$open(args[[2]]);ref<-args[[3]]
report<-p$get_figure(ref,compact=TRUE)
source<-p$read_figure_source(ref)
old<-p$get_figure(ref);sources<-old$details[['biodataledger.figure_sources']]
revised<-p$update_record(ref,list(figure_sources=sources),'native source metadata roundtrip');invisible(p$save())
cat(jsonlite::toJSON(list(report=report,revised=revised,source_sha256=source$sha256),auto_unbox=TRUE,null='null',digits=15))
