library(BioDataLedger)

main <- function() {
  root <- tempfile('results-'); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  ledger <- ProjectBundle$create('Result lineage', root)
  stopifnot(is.function(ledger$register_result), is.function(ledger$check_result),
            is.function(ledger$dependencies))
  writeLines(c('sample_id,cell_id,x,y','S1,A,1.5,-2e1','S1,B,2,3'),file.path(root,'embedding.csv'))
  writeLines(c('sample_id,cell_id','S1,A','S1,B'),file.path(root,'members.csv'))
  member <- ledger$register_data('members.csv','membership',hash=TRUE)
  source <- ledger$register_data('embedding.csv','source',hash=TRUE)
  analysis <- ledger$register_analysis('Synthetic analysis',inputs=list(source))
  embed <- list(format='csv',coordinate_columns=list('x','y'),membership_ref=member)
  result <- ledger$register_result(source,analysis,embedding=embed)
  stopifnot(identical(ledger$get_data(ref=result)$result$status,'declared'),
            identical(ledger$check_result(result)$overall,'PASS'))
  edges <- ledger$dependencies(result,'upstream',depth=2)$edges
  stopifnot(any(vapply(edges,function(e) e$type=='produced_result',logical(1))),
            any(vapply(edges,function(e) e$type=='observation_authority',logical(1))),
            any(vapply(edges,function(e) e$type=='input_to_analysis',logical(1))))
  generic <- ledger$register_result('embedding.csv',NULL)
  stopifnot(is.null(ledger$get_data(ref=generic)$details[["biodataledger.result"]]$embedding),
            identical(ledger$check_result(generic)$overall,'UNKNOWN'))
  native <- ledger$register_result('embedding.csv',analysis,embedding=list(format='seurat',selector='umap'))
  stopifnot(identical(ledger$check_result(native)$fields$coordinates$reason,'adapter_not_available'))
  keyed <- ledger$register_result('embedding.csv',analysis,embedding=list(format='anndata',selector='X_umap',alignment='keyed',row_key_column='obs_id'))
  stopifnot(identical(ledger$get_data(ref=keyed)$details[["biodataledger.result"]]$embedding$row_key_column,'obs_id'))
  stopifnot(inherits(try(ledger$register_result('embedding.csv',analysis,
    embedding=list(format='anndata',selector='X_umap',alignment='keyed')),silent=TRUE),'try-error'))
  copied <- ledger$register_result('embedding.csv',analysis,copy=TRUE)
  stopifnot(file.exists(ledger$get_data(ref=copied)$path),
            identical(ledger$get_data(ref=copied)$details[["biodataledger.result"]]$storage$mode,'copy'))
  revised <- ledger$register_result('embedding.csv',analysis,ref=result,embedding=embed,hash=TRUE)
  stopifnot(identical(revised$id,result$id),revised$revision==result$revision+1L)
  writeLines(c('sample_id,cell_id,x,y','S1,A,invalid,3','S1,A,2,3'),file.path(root,'bad.csv'))
  bad <- ledger$register_result('bad.csv',analysis,embedding=embed)
  bad_check <- ledger$check_result(bad)
  stopifnot(identical(bad_check$fields$observation_identity$status,'FAIL'),
            identical(bad_check$fields$coordinates$status,'FAIL'))
  writeLines(c('sample_id,cell_id,x,y','S1,A,1,2','S1,A,2,3'),file.path(root,'keys_bad.csv'))
  keys_bad <- ledger$register_result('keys_bad.csv',analysis,embedding=embed)
  keys_check <- ledger$check_result(keys_bad)
  stopifnot(identical(keys_check$fields$observation_identity$status,'FAIL'),
            identical(keys_check$fields$coordinates$status,'PASS'))
  writeLines(c('sample_id,cell_id,x,y','S1,A,4,5'),file.path(root,'embedding.csv'))
  stopifnot(identical(ledger$check_result(result)$fields$file_integrity$reason,'digest_mismatch'),
            identical(ledger$check_result(result)$fields$observation_identity$status,'UNKNOWN'))
  writeLines(c('sample_id,cell_id,x,y','S1,A,1.5,-2e1','S1,B,2,3'),file.path(root,'embedding.csv'))
  before_counts <- ledger$summary()$counts
  rejected <- tryCatch(ledger$register_result('embedding.csv',source),error=identity)
  stopifnot(inherits(rejected,'error'),identical(before_counts,ledger$summary()$counts))
  rejected <- tryCatch(ledger$register_result('embedding.csv',analysis,
      embedding=list(format='anndata',selector='X_umap',alignment='keyed')),error=identity)
  stopifnot(inherits(rejected,'error'),identical(before_counts,ledger$summary()$counts))
  ns <- asNamespace('BioDataLedger')
  trace('.hash',where=ns,tracer=quote(stop('unexpected payload hash')),print=FALSE)
  traced <- TRUE
  on.exit(if (traced) untrace('.hash',where=ns),add=TRUE)
  cheap <- ledger$register_result('embedding.csv',analysis)
  ledger$get_data(ref=result);ledger$dependencies(result,'upstream',depth=3)
  ledger$check_result(native)
  untrace('.hash',where=ns);traced <- FALSE
  stopifnot(is.null(ledger$get_data(ref=cheap)$sha256))
  writeLines(c('sample_id,cell_id,x,y','S1,A,1,2','S1,A,3,4'),file.path(root,'duplicate.csv'))
  bad <- ledger$register_result('duplicate.csv',analysis,embedding=embed,hash=TRUE)
  stopifnot(ledger$check_result(bad)$fields$observation_identity$status=='FAIL',
            ledger$check_result(bad)$fields$coordinates$status=='PASS')
  files_before <- list.files(file.path(root,'.nb_project_bundle','outputs'),recursive=TRUE)
  trace('.hash',where=ns,tracer=quote(if (grepl('/outputs/',path,fixed=TRUE)) stop('injected copy failure')),print=FALSE)
  traced <- TRUE
  rejected <- tryCatch(ledger$register_result('embedding.csv',analysis,copy=TRUE),error=identity)
  untrace('.hash',where=ns);traced <- FALSE
  stopifnot(inherits(rejected,'error'),identical(files_before,
    list.files(file.path(root,'.nb_project_bundle','outputs'),recursive=TRUE)))
  ledger$save_and_confirm()
  reopened <- ProjectBundle$open(root)
  stopifnot(identical(reopened$check_result(result)$overall,'PASS'),
            any(vapply(reopened$dependencies(revised,'upstream')$edges,function(e) e$type=='produced_result',logical(1))))
}
main()
