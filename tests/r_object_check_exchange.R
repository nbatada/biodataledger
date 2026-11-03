args <- commandArgs(TRUE)
library(BioDataLedger,lib.loc=Sys.getenv('BDL_R_LIB'))
p <- ProjectBundle$open(args[[1]])
ref <- p$get_data(purpose='object_check')$ref
cells <- data.frame(sample_id=c('S1','S2'),cell_id=c('AA','AA'),treatment=c('Vehicle','Drug'),
                    donor=c('D1','D2'),cluster=c('0','1'),row.names=c('S1_AA','S2_AA'))
m <- matrix(c(1,2),nrow=1,dimnames=list('feature',rownames(cells)))
object <- list(cells=cells,assays=list(RNA=list(counts=m)))
attr(object,'biodataledger_ref') <- ref
report <- p$check_object(object,purpose='object_check',assay='RNA',layer='counts')
stopifnot(report$overall=='PASS')
p$set_context(list(next_task='R checked synthetic object'));invisible(p$save())
cat(jsonlite::toJSON(unclass(report),auto_unbox=TRUE,null='null',digits=15))
