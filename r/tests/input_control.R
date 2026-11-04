library(BioDataLedger)
local({
  root <- tempfile('object-check-synthetic-');dir.create(root)
  on.exit(unlink(root,recursive=TRUE),add=TRUE)
  ledger <- ProjectBundle$create('Synthetic live input verification',root)
  cells <- data.frame(sample_id=c('S1','S1','S2','S2'),cell_id=c('AA','BB','AA','CC'),
                      treatment=c('Vehicle','Vehicle','Drug','Drug'),donor=c('D1','D1','D2','D2'),
                      cluster=c('0','1','0','2'),assignment=c('hashed','unassigned','hashed','unassigned'),row.names=c('S1_AA','S1_BB','S2_AA','S2_CC'))
  authority <- function(name,table) {
    path<-file.path(root,name);utils::write.csv(table,path,row.names=FALSE)
    ledger$register_data(path,'authority',hash=TRUE)
  }
  member <- authority('membership.csv',cells[c('sample_id','cell_id')])
  samples <- authority('samples.csv',unique(cells[c('sample_id','treatment','donor')]))
  clusters <- authority('clusters.csv',cells[c('sample_id','cell_id','cluster')])
  writeLines('opaque synthetic dataset; never loaded by checker',file.path(root,'dataset.rds'))
  config <- list(version='biodataledger-object-requirements/1',membership_policy='exact',cluster_ref=clusters)
  data <- ledger$register_data('dataset.rds','analysis_ready',hash=TRUE,membership=member,object_check=config)
  design <- ledger$set_design('treatment',c('Vehicle','Drug'),replicate='donor')
  scope <- list(condition_values=list('Vehicle','Drug'),assay='RNA',layer='counts',sample_manifest_ref=samples)
  data <- ledger$set_data_scope(data,scope,'synthetic requirements',design)
  ledger$set_current(data,'comparison','synthetic approved input')
  ledger$save()
  matrix <- matrix(seq_len(nrow(cells)),nrow=1L,dimnames=list('feature',rownames(cells)))
  object <- list(cells=cells,assays=list(RNA=list(counts=matrix,data=matrix)))
  attr(object,'biodataledger_ref') <- data

  writeLines("run <- function(inputs,params,seeds,outputs) invisible(NULL)",file.path(root,"run.R"))
  analysis <- ledger$register_analysis("synthetic",list(data),code="run.R",method="synthetic",params=list(n=1))
  spec <- list(ref=data,get_object=function() object,assay="RNA",layer="counts")
  good <- ledger$run_analysis(analysis,"run",object_checks=list(spec))
  stopifnot(length(good$input_checkpoints$checks)==3L,good$input_consumption=="unknown",ledger$get_execution(good$receipt_ref)$status=="succeeded")
  object$cells$cell_id[[1]] <- "WRONG"
  failure <- tryCatch(ledger$run_analysis(analysis,"run",object_checks=list(spec)),error=identity)
  stopifnot(failure$receipt$status=="blocked",!failure$receipt$phases$callback_invoked, failure$receipt$input_checkpoints$checks[[1]]$objects[[1]]$overall=="BLOCKED")
  spec$get_object <- function() stop("unknown current object")
  failure <- tryCatch(ledger$run_analysis(analysis,"run",object_checks=list(spec)),error=identity)
  stopifnot(failure$receipt$status=="blocked",failure$receipt$input_checkpoints$checks[[1]]$objects[[1]]$overall %in% c("UNKNOWN","BLOCKED"))
  object$cells <- cells
  calls <- 0L
  spec$get_object <- function() { calls <<- calls+1L; if(calls==2L) object$cells$cell_id[[1]] <<- "WRONG"; object }
  failure <- tryCatch(ledger$run_analysis(analysis,"run",object_checks=list(spec)),error=identity)
  stopifnot(failure$receipt$status=="failed",!failure$receipt$phases$callback_invoked,length(failure$receipt$input_checkpoints$checks)==2L)
  writeLines("run <- function(inputs,params,seeds,outputs) { writeLines('changed',inputs[[1]]); stop('callback failure') }",file.path(root,"mutate.R"))
  mutated <- ledger$register_analysis("mutate",list(data),code="mutate.R",method="synthetic",params=list(n=1))
  failure <- tryCatch(ledger$run_analysis(mutated,"run"),error=identity)
  stopifnot(failure$receipt$status=="failed",failure$receipt$phases$callback_invoked,length(failure$receipt$input_checkpoints$checks)==3L,failure$receipt$inputs[[1]]$identity!="match",ledger$get_execution(failure$receipt$receipt_ref)$status=="failed")

})
local({
 root<-tempfile();dir.create(root);on.exit(unlink(root,recursive=TRUE),add=TRUE)
 writeLines('checked',file.path(root,'input'));writeLines('other',file.path(root,'other'))
 p<-ProjectBundle$create('synthetic boundaries',root);d<-p$register_data('input','input',hash=TRUE)
 inactive<-p$update_record(d,list(status='inactive'),'test')
 writeLines('run <- function(inputs,params,seeds,outputs) invisible(NULL)',file.path(root,'run.R'))
 a<-p$register_analysis('inactive',list(inactive),code='run.R')
 for(verify in c(TRUE,FALSE)) {
  e<-tryCatch(p$run_analysis(a,'run',verify_inputs=verify),error=identity)
  stopifnot(e$receipt$status=='blocked',!e$receipt$phases$callback_invoked)
 }
 # The historical active revision remains eligible in both strict resolution and execution.
 p$resolve_data(ref=d,verify='sha256')
 writeLines(sprintf('writeLines("changed", %s)\nrun <- function(inputs,params,seeds,outputs) stop("must not invoke")',dQuote(file.path(root,'input'),q=FALSE)),file.path(root,'top.R'))
 a<-p$register_analysis('top',list(d),code='top.R');e<-tryCatch(p$run_analysis(a,'run'),error=identity)
 stopifnot(e$receipt$status=='failed',!e$receipt$phases$callback_invoked,e$receipt$inputs[[1]]$identity!='match')
 writeLines('checked',file.path(root,'input'))
 writeLines(sprintf('run <- function(inputs,params,seeds,outputs) writeLines(readLines(%s),outputs[[1]])',dQuote(file.path(root,'other'),q=FALSE)),file.path(root,'ignore.R'))
 a<-p$register_analysis('ignore',list(d),code='ignore.R');r<-p$run_analysis(a,'run',list(list(path='out',kind='result')))
 stopifnot(r$input_consumption=='unknown',readLines(file.path(root,'out'))=='other')
 unlink(file.path(root,'input'));e<-tryCatch(p$run_analysis(a,'run'),error=identity)
 stopifnot(e$receipt$status=='blocked',!e$receipt$phases$callback_invoked)
})
