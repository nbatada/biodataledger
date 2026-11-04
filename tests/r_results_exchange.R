args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc=Sys.getenv('BDL_R_LIB'))
p <- ProjectBundle$open(args[2])
if (args[1] == 'register') {
  result <- p$register_result('umap.csv', 'ANA-001@1', hash=TRUE,
    embedding=list(format='csv', coordinate_columns=list('UMAP_1','UMAP_2'), membership_ref='DATA-002@1'))
  figure <- p$register_figure('plot.svg', 'umap', analysis='ANA-001@1',
    figure_sources=list(rendering_inputs=list(result), relationship='declared'))
  receipt <- p$save_and_confirm()
  cat(jsonlite::toJSON(list(result=result,figure=figure,receipt=receipt),auto_unbox=TRUE,null='null'))
} else if (args[1] == 'metadata_correction') {
  ref <- args[3]
  details <- p$get_data(ref=ref)$details
  block <- details[['biodataledger.result']]
  details[['biodataledger.result']] <- block[rev(names(block))]
  details$note <- 'synthetic annotation; result identity unchanged'
  revised <- p$update_record(ref,list(details=details),'metadata-only correction')
  p$save_and_confirm()
  cat(jsonlite::toJSON(revised,auto_unbox=TRUE,null='null'))
} else if (args[1] == 'bounded') {
  ns <- asNamespace('BioDataLedger')
  edge_calls <- 0L
  trace('.result_edge_id',where=ns,tracer=quote(edge_calls <<- edge_calls + 1L),print=FALSE)
  report <- p$dependencies('DATA-001@1','downstream',depth=1,limit=2)
  untrace('.result_edge_id',where=ns)
  stopifnot(report$truncated,edge_calls <= 5L)
  cat(jsonlite::toJSON(list(edge_calls=edge_calls),auto_unbox=TRUE))
} else {
  ref <- args[3]
  depth <- if (length(args)>=4) as.integer(args[4]) else 3L
  limit <- if (length(args)>=5) as.integer(args[5]) else 20L
  out <- list(check=p$check_result(ref), view=p$get_data(ref=ref)$result,
              descriptor=p$get_data(ref=ref)$details[['biodataledger.result']],
              upstream=p$dependencies(ref,'upstream',depth=depth,limit=limit),
              downstream=p$dependencies('DATA-001@1','downstream',depth=depth,limit=limit))
  cat(jsonlite::toJSON(out,auto_unbox=TRUE,null='null',digits=NA))
}
