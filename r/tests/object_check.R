library(BioDataLedger)

main <- function() {
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
  check <- function(x=object,ref=data,...) ledger$check_object(x,ref=ref,assay='RNA',layer='counts',...)
  expect <- function(report,field,status,overall='BLOCKED') {
    stopifnot(identical(report$fields[[field]]$status,status),identical(report$overall,overall))
  }
  subset_object <- function(x,rows) {
    x$cells<-x$cells[rows,,drop=FALSE]
    x$assays<-lapply(x$assays,function(a) lapply(a,function(m) m[,rows,drop=FALSE]));x
  }
  registry <- file.path(root,'.nb_project_bundle','project.json')
  before <- readBin(registry,'raw',n=file.info(registry)$size)
  good <- check()
  stopifnot(good$overall=='PASS',all(vapply(good$fields,function(x) x$status=='PASS',logical(1))),
            ledger$check_object(object,purpose='comparison',assay='RNA',layer='counts')$overall=='PASS')
  numeric_ref <- object;attr(numeric_ref,'biodataledger_ref')$revision <- as.numeric(data$revision)
  stopifnot(check(numeric_ref)$overall=='PASS')
  foreign_ref <- object;attr(foreign_ref,'biodataledger_ref')$project_id <- '00000000-0000-0000-0000-000000000000'
  expect(check(foreign_ref),'dataset','FAIL')
  # Hash-only subset preserves treatment labels but loses approved unassigned cells.
  bad <- subset_object(object,which(object$cells$assignment=='hashed'))
  blocked <- check(bad)
  expect(blocked,'membership','FAIL');expect(blocked,'conditions','PASS')
  cat('\nACTUAL R OUTPUT -- correct synthetic object\n');print(good)
  cat('\nACTUAL R OUTPUT -- wrong membership, matching treatments\n');print(blocked)
  changed <- object;changed$cells$cell_id[2]<-'DIFFERENT'
  expect(check(changed),'membership','FAIL')
  changed <- object;changed$cells$treatment[2]<-'Drug'
  expect(check(changed),'conditions','FAIL')
  changed <- object;changed$cells$treatment<-'Other'
  expect(check(changed),'conditions','FAIL')
  changed <- object;changed$cells$donor[1]<-'D2'
  expect(check(changed),'replicates','FAIL')
  expect(ledger$check_object(object,ref=data,assay='RNA',layer='data'),'layer','FAIL')
  expect(ledger$check_object(object,ref=data,assay='RNA',layer='absent'),'representation','FAIL')
  expect(ledger$check_object(object,ref=data),'layer','UNKNOWN')
  changed <- object;changed$cells$cluster[1]<-'9'
  expect(check(changed),'clusters','FAIL')
  changed <- object;changed$cells$cell_id[2]<-'AA'
  expect(check(changed),'membership','FAIL')
  changed <- object;changed$cells$cell_id[2]<-NA
  expect(check(changed),'membership','UNKNOWN')
  changed <- object;attr(changed,'biodataledger_ref')<-NULL
  expect(check(changed),'dataset','UNKNOWN')
  changed <- object;attr(changed,'biodataledger_ref')<-member
  expect(check(changed),'dataset','FAIL')
  changed <- object;changed$assays$RNA$counts<-matrix[,1:2,drop=FALSE]
  expect(check(changed),'representation','FAIL')
  expect(check(list()),'membership','UNKNOWN')
  changed <- object;names(changed)[1] <- 'cells_backup'
  expect(check(changed),'membership','UNKNOWN')
  changed <- object;names(changed$cells)[2] <- 'sample_id'
  expect(check(changed),'membership','UNKNOWN')
  stopifnot(identical(before,readBin(registry,'raw',n=file.info(registry)$size)),!ledger$status()$unsaved,
            !grepl('S1_AA',paste(capture.output(print(good)),collapse=''),fixed=TRUE),
            grepl('declaration',paste(capture.output(print(good)),collapse=''),fixed=TRUE),
            grepl('Unverified:',paste(capture.output(print(good)),collapse=''),fixed=TRUE))
  revise <- function(config=config, membership=member, target=data) {
    details<-ledger$get_data(ref=target)$details
    details$object_check<-config;details['membership']<-list(membership)
    ledger$update_record(target,list(details=details),'synthetic requirement change')
  }
  check_revision <- function(ref,x=object) {attr(x,'biodataledger_ref')<-ref;check(x,ref=ref)}
  missing_member <- revise(config,membership=NULL)
  expect(check_revision(missing_member),'membership_reference','UNKNOWN')
  subset_ref <- revise(modifyList(config,list(membership_policy='subset')))
  stopifnot(check_revision(subset_ref,bad)$overall=='PASS')
  changed <- object;changed$cells$cell_id[2]<-'OUTSIDE'
  expect(check_revision(subset_ref,changed),'membership','FAIL')
  forbidden <- authority('forbidden.csv',data.frame(sample_id='S9',cell_id='AA'))
  exclude_ref <- revise(modifyList(config,list(membership_policy='exclude')),membership=forbidden)
  stopifnot(check_revision(exclude_ref)$overall=='PASS')
  exclude_bad <- revise(modifyList(config,list(membership_policy='exclude')),membership=member)
  expect(check_revision(exclude_bad),'membership','FAIL')
  forbidden_samples <- authority('forbidden-samples.csv',data.frame(sample_id='S1'))
  exclude_samples <- revise(modifyList(config,list(membership_policy='exclude')),membership=forbidden_samples)
  expect(check_revision(exclude_samples),'membership','FAIL')
  malformed_ref <- revise(modifyList(config,list(cluster_ref='not-an-exact-ref')))
  expect(check_revision(malformed_ref),'requirements','UNKNOWN')
  changed <- object;changed$cells$treatment[c(1,3)]<-changed$cells$treatment[c(3,1)]
  expect(check(changed),'conditions','FAIL')
  changed <- object;changed$cells$sample_id[1]<-'UNLISTED'
  expect(check(changed),'replicates','FAIL')
  changed <- object;changed$cells$cluster<-NULL
  expect(check(changed),'clusters','UNKNOWN')
  changed <- object;names(changed$cells)[names(changed$cells)=='cluster'] <- 'cluster_backup'
  expect(check(changed),'clusters','UNKNOWN')
  changed <- object;changed$assays$RNA<-list(counts=matrix,counts=matrix)
  expect(check(changed),'representation','UNKNOWN')
  ambiguous_samples <- authority('ambiguous-samples.csv',data.frame(sample_id_backup=c('S1','S2'),treatment=c('Vehicle','Drug'),donor=c('D1','D2')))
  ambiguous_scope <- scope;ambiguous_scope$sample_manifest_ref<-ambiguous_samples
  ambiguous_ref <- ledger$set_data_scope(data,ambiguous_scope,'synthetic missing exact column',design)
  expect(check_revision(ambiguous_ref),'conditions','UNKNOWN')
  missing_samples <- scope;missing_samples$sample_manifest_ref<-NULL
  no_samples <- ledger$set_data_scope(data,missing_samples,'synthetic missing mapping',design)
  expect(check_revision(no_samples),'replicates','UNKNOWN')
  unknown_scope <- ledger$set_data_scope(data,list(observation_unit='cell'),'synthetic optional absent scope')
  optional_object <- object;attr(optional_object,'biodataledger_ref')<-unknown_scope
  # Cluster remains required by explicit ref; unspecified condition/representation checks do not block.
  optional_report <- ledger$check_object(optional_object,ref=unknown_scope)
  expect(optional_report,'conditions','UNKNOWN','PASS')
  expect(optional_report,'layer','UNKNOWN','PASS')
  optional <- config;optional$cluster_ref<-NULL
  optional_ref <- revise(optional)
  expect(check_revision(optional_ref),'clusters','UNKNOWN','PASS')
  optional$required<-list('clusters')
  required_ref <- revise(optional)
  expect(check_revision(required_ref),'clusters','UNKNOWN')
  malformed_ref <- revise(list(version='future',required=list()))
  expect(check_revision(malformed_ref),'requirements','UNKNOWN')
  # Tampered authority bytes cannot be treated as approved expectations.
  writeLines('changed',file.path(root,'membership.csv'))
  expect(check(),'membership_reference','FAIL')
  utils::write.csv(cells[c('sample_id','cell_id')],file.path(root,'membership.csv'),row.names=FALSE)
  # Missing independent evidence is UNKNOWN; valid bytes with duplicate keys are not a usable authority.
  duplicate <- authority('duplicate.csv',cells[c(1,1),c('sample_id','cell_id')])
  duplicate_ref <- revise(config,membership=duplicate)
  expect(check_revision(duplicate_ref),'membership','UNKNOWN')
  unlink(file.path(root,'duplicate.csv'))
  expect(check_revision(duplicate_ref),'membership_reference','UNKNOWN')
  namespace <- asNamespace('BioDataLedger')
  trace('.read_json',where=namespace,tracer=quote(stop('registry reload during check')),print=FALSE)
  trace('.hash',where=namespace,tracer=quote(stop('dataset file hashing during check')),print=FALSE)
  check()
  untrace('.read_json',where=namespace);untrace('.hash',where=namespace)
  if(capabilities('profmem')) {
    memory_log <- capture.output({tracemem(object);tracemem(matrix);check();untracemem(object);untracemem(matrix)})
    stopifnot(!any(grepl('tracemem\\[',memory_log)))
  }
  # Existing operations and saved requirements are unchanged without a checker.
  ledger$save();reopened<-ProjectBundle$open(root)
  stopifnot(reopened$check_object(object,ref=data,assay='RNA',layer='counts')$overall=='PASS',
            identical(reopened$get_data(ref=data)$ref,data),!reopened$status()$unsaved)
  if (requireNamespace('SeuratObject',quietly=TRUE)) {
    assay <- SeuratObject::CreateAssay5Object(counts=matrix)
    seurat <- SeuratObject::CreateSeuratObject(counts=assay,meta.data=cells)
    attr(seurat,'biodataledger_ref')<-data
    stopifnot(check(seurat)$overall=='PASS')
    expect(ledger$check_object(seurat,ref=data,assay='RNA',layer='counts.missing'),'representation','FAIL')
    seurat[['cluster']] <- c('9','1','0','2')
    expect(check(seurat),'clusters','FAIL')
    cat('Optional SeuratObject adapter: PASS\n')
  } else cat('Optional SeuratObject adapter: SKIPPED (not installed)\n')
  cat('Synthetic live-object checks: PASS\n')
}
main()
