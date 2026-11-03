# Live checks read metadata and pinned authorities, never expression values.
.object_fields <- c('requirements','dataset','membership_reference','membership','conditions',
                    'replicates','representation','assay','layer','clusters')
.object_text <- function(x, limit=100L) {
  if (is.null(x)) return('unavailable')
  values <- as.character(x)
  text <- paste(substr(utils::head(values,6L),1L,limit),collapse=', ')
  if(length(values)>6L) text <- paste0(text,', ...')
  text <- gsub('[[:cntrl:]]',' ',text)
  if (nchar(text)>limit) paste0(substr(text,1L,limit-3L),'...') else text
}
.object_values <- function(x) {
  if (!is.atomic(x) || !is.null(dim(x))) return(NULL)
  values <- as.character(x)
  if (!length(values) || anyNA(values) || any(!nzchar(trimws(values)))) return(NULL)
  values
}
.object_keys <- function(cells) {
  if (!is.data.frame(cells) || anyDuplicated(names(cells)) || !all(c('sample_id','cell_id') %in% names(cells))) return(NULL)
  sample <- .object_values(cells[['sample_id',exact=TRUE]]); cell <- .object_values(cells[['cell_id',exact=TRUE]])
  if (is.null(sample) || is.null(cell)) return(NULL)
  # Length prefixes avoid collisions when identifiers contain separators.
  paste0(nchar(sample,type='bytes'),':',sample,nchar(cell,type='bytes'),':',cell)
}
.object_manifest <- function(root,state,ref) {
  unknown <- function(reason) list(status='UNKNOWN',reason=reason,table=NULL)
  if (is.null(ref)) return(unknown('No registered authority reference'))
  rec <- tryCatch(.record(state,ref),error=function(e) NULL)
  if (is.null(rec) || rec$kind!='data') return(unknown('Authority DATA revision unavailable'))
  if (rec$status!='active') return(list(status='FAIL',reason='Authority revision is inactive',table=NULL))
  path <- .resolve(root,state,rec$locator)
  if (is.null(path) || !file.exists(path) || dir.exists(path) || is.null(rec$sha256))
    return(unknown('Authority file or registered SHA-256 unavailable'))
  size <- file.info(path)$size
  if (is.na(size) || size>.metadata_limit) return(unknown('Authority exceeds 20 MiB metadata limit'))
  bytes <- tryCatch(readBin(path,'raw',n=.metadata_limit+1L),error=function(e) NULL)
  if (is.null(bytes)) return(unknown('Authority file cannot be read'))
  if (length(bytes)>.metadata_limit || !identical(.hash_raw(bytes),rec$sha256))
    return(list(status='FAIL',reason='Authority SHA-256 mismatch',table=NULL))
  table <- tryCatch(utils::read.csv(text=rawToChar(bytes),colClasses='character',
                                  check.names=FALSE,na.strings='',stringsAsFactors=FALSE),error=function(e) NULL)
  if (is.null(table) || !nrow(table) || anyDuplicated(names(table))) return(unknown('Authority CSV is empty or malformed'))
  list(status='PASS',reason='Registered CSV bytes verified by SHA-256',table=table)
}
.object_observe <- function(object,assay,layer) {
  out <- list(cells=NULL,identity=attr(object,'biodataledger_ref',exact=TRUE),
              representation='UNKNOWN',representation_reason='Select an assay and layer',source='unsupported object')
  generic_cells <- if(is.list(object)) object[['cells',exact=TRUE]] else NULL
  generic_assays <- if(is.list(object)) object[['assays',exact=TRUE]] else NULL
  if (inherits(object,'Seurat')) {
    out$source <- 'Seurat metadata; assay/layer cell names'
    if (!requireNamespace('SeuratObject',quietly=TRUE)) return(out)
    out$cells <- object[[]]
    if (is.null(assay) || is.null(layer)) return(out)
    if (!assay %in% SeuratObject::Assays(object)) {
      out$representation <- 'FAIL';out$representation_reason <- 'Selected assay absent';return(out)
    }
    selected <- object[[assay]]
    if (!layer %in% SeuratObject::Layers(selected,search=NA)) {
      out$representation <- 'FAIL';out$representation_reason <- 'Selected exact layer absent';return(out)
    }
    columns <- if (inherits(selected,'Assay5')) SeuratObject::Cells(selected,layer=layer) else colnames(selected)
  } else if (is.list(object) && is.data.frame(generic_cells)) {
    out$source <- 'generic object$cells; selected matrix dimensions/names'
    out$cells <- generic_cells
    if (is.null(assay) || is.null(layer)) return(out)
    if (is.list(generic_assays) && anyDuplicated(names(generic_assays))) {
      out$representation_reason <- 'Duplicate assay names are ambiguous';return(out)
    }
    if (!is.list(generic_assays) || !assay %in% names(generic_assays)) {
      out$representation <- 'FAIL';out$representation_reason <- 'Selected assay absent';return(out)
    }
    layers <- generic_assays[[assay]]
    if (is.list(layers) && anyDuplicated(names(layers))) {
      out$representation_reason <- 'Duplicate layer names are ambiguous';return(out)
    }
    if (!is.list(layers) || !layer %in% names(layers)) {
      out$representation <- 'FAIL';out$representation_reason <- 'Selected exact layer absent';return(out)
    }
    matrix <- layers[[layer]]
    if (!(is.matrix(matrix) || inherits(matrix,'Matrix')) || length(dim(matrix))!=2L) {
      out$representation_reason <- 'Selected layer is not a supported matrix';return(out)
    }
    columns <- colnames(matrix)
  } else return(out)
  if (is.null(columns)) {out$representation_reason <- 'Selected layer cell names unavailable';return(out)}
  match <- !anyDuplicated(columns) && length(columns)==nrow(out$cells) && setequal(columns,rownames(out$cells))
  out$representation <- if (match) 'PASS' else 'FAIL'
  out$representation_reason <- if(match) 'Selected layer exists and covers the observed cells' else 'Layer cells differ from object metadata'
  out
}
.check_object <- function(root,state,object,ref,assay,layer) {
  for (value in list(assay,layer)) if (!is.null(value) && !.design_text(value)) .fail('assay/layer must be one nonblank string or NULL')
  rec <- .record(state,ref)
  if (rec$kind!='data') .fail('check_object requires an exact DATA reference')
  ref <- .make_ref(state,rec)
  config <- rec$details$object_check
  allowed <- c('version','membership_policy','cluster_ref','required')
  valid <- is.null(config) || .is_obj(config) && !anyDuplicated(names(config)) && all(names(config) %in% allowed) &&
    identical(config$version,'biodataledger-object-requirements/1') &&
    (is.null(config$membership_policy) || .design_text(config$membership_policy) && config$membership_policy %in% c('exact','subset','exclude')) &&
    (is.null(config$cluster_ref) || tryCatch({.validate_ref_shape(state,config$cluster_ref);TRUE},error=function(e) FALSE)) &&
    (is.null(config$required) || .is_arr(config$required) && all(vapply(config$required,function(x) .design_text(x) && x %in% .object_fields,logical(1))))
  if (!valid) config <- NULL
  policy <- if(is.null(config$membership_policy)) 'exact' else config$membership_policy
  design <- if(is.null(rec$design)) NULL else .record(state,rec$design)$details
  scope <- rec$scope
  refs <- list(dataset=ref,design=rec$design,membership=rec$details$membership,
               samples=scope$sample_manifest_ref,clusters=config$cluster_ref)
  required <- unique(c('requirements','dataset','membership_reference','membership',unlist(config$required,use.names=FALSE),
                       if(!is.null(design$condition) || !is.null(scope$condition_values)) 'conditions',
                       if(!is.null(design$replicate)) 'replicates',if(!is.null(scope$assay)) c('representation','assay'),
                       if(!is.null(scope$layer)) c('representation','layer'),if(!is.null(config$cluster_ref)) 'clusters'))
  fields <- lapply(.object_fields,function(key) .obj(status='UNKNOWN',required=key %in% required,
                requirement='dataset',expected='not specified',observed='unavailable',source='not measured',reason='Evidence unavailable'))
  names(fields) <- .object_fields
  put <- function(key,status,requirement,expected,observed,source,reason) {
    fields[[key]] <<- .obj(status=status,required=key %in% required,requirement=requirement,
                          expected=.object_text(expected),observed=.object_text(observed),source=source,reason=reason)
  }
  put('requirements',if(valid) 'PASS' else 'UNKNOWN','dataset','supported registered requirements',
      if(valid) policy else 'invalid configuration','DATA details/scope and pinned DES',
      if(valid) 'Requirements read from registered revisions' else 'Unsupported or malformed object_check declaration')
  if(!is.null(scope$condition_values) && !is.null(design)) {
    available <- unlist(design$levels,use.names=FALSE); selected <- unlist(design$selected_levels,use.names=FALSE)
    declared <- unlist(scope$condition_values,use.names=FALSE)
    if(!all(declared %in% available) || !all(selected %in% declared))
      put('requirements','FAIL','dataset.scope + design','consistent declared conditions',declared,
          'DATA scope and pinned DES','Scope conflicts with pinned design')
  }
  observed <- tryCatch(.object_observe(object,assay,layer),error=function(e)
    list(cells=NULL,identity=NULL,representation='UNKNOWN',representation_reason='Object adapter could not inspect the supplied object',source='adapter unavailable'))
  identity <- observed$identity
  identity_valid <- tryCatch({
    if(!.design_text(identity$project_id)) stop('Missing project identity')
    .validate_ref_shape(list(project=list(id=identity$project_id)),identity);TRUE
  },error=function(e) FALSE)
  identity_match <- identity_valid && identical(identity$project_id,ref$project_id) &&
    identical(identity$id,ref$id) && identity$revision==ref$revision
  put('dataset',if(rec$status!='active') 'FAIL' else if(!identity_valid) 'UNKNOWN' else if(identity_match) 'PASS' else 'FAIL',
      'dataset',.ref_text(ref),if(identity_valid) paste(.ref_text(identity),identity$project_id) else NULL,'object attribute biodataledger_ref (declaration)',
      if(rec$status!='active') 'Required DATA revision is inactive' else if(identity_match) 'Declared exact reference matches; origin not proven' else 'Missing or different declared DATA reference')
  # Authorities are read at most once within this check; nothing is cached across calls.
  authorities <- list()
  load <- function(which) {
    target <- refs[[which]]
    key <- if(is.null(target)) which else .json(target)
    if (is.null(authorities[[key]])) authorities[[key]] <<- .object_manifest(root,state,target)
    authorities[[key]]
  }
  membership <- load('membership')
  put('membership_reference',membership$status,'membership','registered membership CSV',
      if(!is.null(membership$table)) paste(nrow(membership$table),'authority rows') else NULL,
      'registered membership file bytes',membership$reason)
  cells <- observed$cells; keys <- .object_keys(cells)
  usable <- !is.null(keys) && !anyDuplicated(keys)
  if (!is.null(keys) && anyDuplicated(keys)) {
    put('membership','FAIL','membership',policy,paste(length(keys),'rows; duplicate qualified IDs'),observed$source,'Observed sample-qualified IDs are not unique')
  } else if (is.null(keys)) {
    put('membership','UNKNOWN','membership',policy,NULL,observed$source,'Complete nonempty sample_id/cell_id columns required')
  } else if (membership$status=='PASS') {
    approved <- membership$table
    sample_only <- policy=='exclude' && !'cell_id' %in% names(approved)
    authority_keys <- if(sample_only) .object_values(approved[['sample_id',exact=TRUE]]) else .object_keys(approved)
    if (is.null(authority_keys) || anyDuplicated(authority_keys)) {
      put('membership','UNKNOWN','membership',policy,paste(length(keys),'observed cells'),observed$source,'Authority keys are missing or duplicated')
    } else {
      actual <- if(sample_only) as.character(cells[['sample_id',exact=TRUE]]) else keys
      extra <- sum(!actual %in% authority_keys); missing <- sum(!authority_keys %in% actual); forbidden <- sum(actual %in% authority_keys)
      pass <- switch(policy,exact=extra==0L && missing==0L,subset=extra==0L,exclude=forbidden==0L)
      result <- if(policy=='exclude') paste(forbidden,'forbidden matches') else paste(extra,'outside;',missing,'approved absent')
      put('membership',if(pass) 'PASS' else 'FAIL','membership',paste(policy,if(sample_only) 'samples' else 'qualified cells'),
          paste(length(keys),'cells;',result),observed$source,
          if(policy=='subset') 'Containment checked; scientific selection rule unverified' else 'Sample-qualified membership compared with verified authority')
    }
  } else {
    put('membership',membership$status,'membership',policy,paste(length(keys),'observed cells'),observed$source,membership$reason)
  }
  samples <- if(!is.null(refs$samples)) load('samples') else list(status='UNKNOWN',reason='No registered sample mapping',table=NULL)
  compare_mapping <- function(field,column) {
    values <- if(is.data.frame(cells) && !is.null(column)) .object_values(cells[[column]]) else NULL
    expected <- if(field=='conditions') scope$condition_values else NULL
    if(is.null(expected) && field=='conditions') expected <- design$selected_levels
    if(is.null(column) || is.null(values) || !usable) {
      put(field,'UNKNOWN','design + samples',column,NULL,observed$source,'Metadata column or usable cell identifiers unavailable');return()
    }
    levels <- if(is.null(expected)) NULL else as.character(unlist(expected,use.names=FALSE))
    if(field=='conditions' && !is.null(levels) && !setequal(unique(values),levels)) {
      put(field,'FAIL','dataset.scope + design',levels,unique(values),observed$source,'Observed condition levels differ');return()
    }
    mapping <- samples$table
    ids <- if(is.data.frame(mapping)) .object_values(mapping[['sample_id',exact=TRUE]]) else NULL
    wanted <- if(is.data.frame(mapping)) .object_values(mapping[[column]]) else NULL
    if(samples$status!='PASS' || is.null(ids) || anyDuplicated(ids) || is.null(wanted)) {
      put(field,if(samples$status=='FAIL') 'FAIL' else 'UNKNOWN','design + samples',column,unique(values),observed$source,
          if(samples$status!='PASS') samples$reason else 'Independent sample mapping missing or ambiguous');return()
    }
    positions <- match(as.character(cells[['sample_id',exact=TRUE]]),ids)
    match <- !anyNA(positions) && all(values==wanted[positions])
    put(field,if(match) 'PASS' else 'FAIL','design + samples',column,
        paste(length(values),'cell values;',.object_text(unique(values),50L)),observed$source,
        if(match) 'Values match independent sample mapping' else 'Sample-to-value mapping differs or sample is absent')
  }
  compare_mapping('conditions',design$condition)
  compare_mapping('replicates',design$replicate)
  put('representation',observed$representation,'dataset.scope','selected layer covers metadata cells',
      paste(.object_text(assay),.object_text(layer),sep='/'),observed$source,observed$representation_reason)
  for(field in c('assay','layer')) {
    selected <- if(field=='assay') assay else layer; expected <- scope[[field]]
    status <- if(is.null(selected) || is.null(expected)) 'UNKNOWN' else if(identical(selected,expected)) 'PASS' else 'FAIL'
    put(field,status,'dataset.scope',expected,selected,'explicit check_object selection (declaration)',
        'Selection compared; downstream consumption unverified')
  }
  clusters <- if(!is.null(refs$clusters)) load('clusters') else list(status='UNKNOWN',reason='No registered cluster assignment reference',table=NULL)
  values <- if(is.data.frame(cells)) .object_values(cells[['cluster',exact=TRUE]]) else NULL
  authority_keys <- .object_keys(clusters$table)
  assigned <- if(is.data.frame(clusters$table)) .object_values(clusters$table[['cluster',exact=TRUE]]) else NULL
  if(clusters$status=='FAIL') {
    put('clusters','FAIL','clusters','exact cell-to-cluster assignments',NULL,observed$source,clusters$reason)
  } else if(!usable || is.null(values) || is.null(authority_keys) || anyDuplicated(authority_keys) || is.null(assigned)) {
    put('clusters','UNKNOWN','clusters','exact cell-to-cluster assignments',NULL,observed$source,'Independent assignments or observed cluster values unavailable')
  } else {
    positions <- match(keys,authority_keys)
    match <- !anyNA(positions) && all(values==assigned[positions])
    put('clusters',if(match) 'PASS' else 'FAIL','clusters','exact assignments for observed qualified cells',
        paste(length(values),'cell assignments'),observed$source,
        if(match) 'Assignments match independent reference' else 'Assignments differ or reference cells are missing')
  }
  blockers <- names(Filter(function(x) x$required && x$status!='PASS',fields))
  report <- .obj(report_version='biodataledger-object-check/1',requirement_ref=ref,references=refs,
                 checker='BioDataLedger/R check_object/1',checked_at=.now(),fields=fields,
                 overall=if(length(blockers)) 'BLOCKED' else 'PASS',blockers=.arr(blockers),
                 unverified=list('File-to-object origin binding and expression values',
                                 'Scientific validity and subset selection rule',
                                 'Downstream representation consumption and output provenance'))
  class(report) <- c('BioDataLedgerInputCheck','list');report
}
print.BioDataLedgerInputCheck <- function(x, ...) {
  cat('BioDataLedger -- Input Check\n')
  cat('Requirement: ',.ref_text(x$requirement_ref),' | project ',x$requirement_ref$project_id,'\n',sep='')
  cat('Checker: ',x$checker,' | ',x$checked_at,'\n',sep='')
  for(name in setdiff(names(x$references),'dataset')) {
    ref <- x$references[[name]]
    cat('Reference ',name,': ',if(is.null(ref)) 'unavailable' else .ref_text(ref),'\n',sep='')
  }
  for(name in names(x$fields)) {
    field <- x$fields[[name]]
    cat(sprintf('%-22s %-7s [%s]\n',name,field$status,if(field$required) 'required' else 'optional'))
    cat('  Expected: ',field$expected,' | Observed: ',field$observed,'\n',sep='')
    cat('  Source: ',field$source,' | Requirement: ',field$requirement,'\n',sep='')
    cat('  ',field$reason,'\n',sep='')
  }
  cat('Overall: ',x$overall,'\n',sep='')
  if(length(x$blockers)) cat('Reason: required checks not PASS: ',paste(unlist(x$blockers),collapse=', '),'\n',sep='')
  cat('Unverified: ',paste(unlist(x$unverified),collapse='; '),'.\n',sep='')
  invisible(x)
}
