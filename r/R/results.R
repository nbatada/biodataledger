.result_key <- 'biodataledger.result'
.result_version <- 'biodataledger-result/1'
.result_fields <- c('version','artifact_source_ref','storage','embedding')
.result_exact <- function(x, fields) .is_obj(x) && !anyDuplicated(names(x)) && setequal(names(x), fields)
.result_equal <- function(a,b) {
  if (.is_obj(a) && .is_obj(b)) return(setequal(names(a),names(b)) &&
    all(vapply(names(a),function(key) .result_equal(a[[key]],b[[key]]),logical(1))))
  if (.is_arr(a) && .is_arr(b)) return(length(a)==length(b) &&
    all(vapply(seq_along(a),function(i) .result_equal(a[[i]],b[[i]]),logical(1))))
  identical(a,b)
}
.result_ref <- function(state, x, kind = 'data') {
  if (is.null(x)) return(NULL)
  x <- .ref(state, x)
  if (!identical(.record_kind(state, x), kind)) .fail(paste('Expected exact', kind, 'reference'))
  x
}
.result_array <- function(x, two = FALSE) {
  ok <- (is.character(x) || .is_arr(x)) && length(x) > 0L
  y <- if (is.character(x)) x else unlist(x, use.names = FALSE)
  ok && (!two || length(y) == 2L) && is.character(y) &&
    all(vapply(as.list(y), .design_text, logical(1))) && !anyDuplicated(y)
}
.result_embedding <- function(state, x) {
  if (is.null(x)) return(list(embedding = NULL, membership = NULL))
  fields <- c('format','selector','key_columns','coordinate_columns','alignment','comparison','membership_ref','row_key_column')
  if (!.is_obj(x) || anyDuplicated(names(x)) || !all(names(x) %in% fields) ||
      !.design_text(x$format) || !x$format %in% c('csv','seurat','anndata')) .fail('Invalid embedding')
  keys <- if (is.null(x$key_columns)) c('sample_id','cell_id') else x$key_columns
  if (!.result_array(keys, TRUE)) .fail('Invalid embedding keys')
  keys <- unname(as.list(unlist(keys, use.names = FALSE)))
  native <- x$format != 'csv'
  if (native) {
    if (!.design_text(x$selector) || !is.null(x$coordinate_columns)) .fail('Invalid native selector')
    alignment <- if (is.null(x$alignment)) 'ordered' else x$alignment
    if (!alignment %in% c('keyed','ordered')) .fail('Invalid native alignment')
    if (!is.null(x$row_key_column) && !.design_text(x$row_key_column) ||
        identical(alignment,'keyed') && !.design_text(x$row_key_column)) .fail('Native row key required')
    comparison <- if (is.null(x$comparison)) if (alignment == 'ordered') 'ordered_keys' else 'set_keys' else x$comparison
    columns <- NULL
  } else {
    if (!is.null(x$selector) || !is.null(x$row_key_column) || !is.null(x$alignment) && !identical(x$alignment,'same_row')) .fail('Invalid CSV alignment')
    columns <- x$coordinate_columns
    if (!.result_array(columns) || any(unlist(columns, use.names = FALSE) %in% unlist(keys, use.names = FALSE))) .fail('Invalid coordinate columns')
    columns <- unname(as.list(unlist(columns, use.names = FALSE)))
    alignment <- 'same_row'
    comparison <- if (is.null(x$comparison)) 'set_keys' else x$comparison
  }
  if (!identical(comparison, 'set_keys') && !identical(comparison, 'ordered_keys')) .fail('Invalid comparison')
  list(embedding = .obj(format = x$format, selector = if (native) x$selector else NULL,
    key_columns = keys, coordinate_columns = columns, alignment = alignment, comparison = comparison,
    row_key_column = if (native) x$row_key_column else NULL),
    membership = .result_ref(state, x$membership_ref))
}
.result_valid_impl <- function(state, rec) {
  x <- rec$details[[.result_key]]
  if (!identical(rec$kind,'data') || !identical(rec$role,'derived_result') ||
      !.result_exact(x,.result_fields) || !identical(x$version,.result_version) ||
      !.result_exact(x$storage,c('mode','source_locator')) ||
      !x$storage$mode %in% c('reference','copy') ||
      !identical(x$storage$mode == 'reference', .result_equal(rec$locator,x$storage$source_locator))) return(FALSE)
  if (!tryCatch({.validate_locator(x$storage$source_locator);TRUE},error=function(e) FALSE) ||
      !.is_obj(rec$scope) || !.result_exact(rec$scope,.scope_fields)) return(FALSE)
  if (identical(x$storage$mode,'copy') &&
      (!identical(rec$locator$kind,'project') ||
       !grepl('^\\.nb_project_bundle/outputs/result-[^/]+/[^/]+$',rec$locator$value))) return(FALSE)
  if (!is.null(x$artifact_source_ref) &&
      !tryCatch(identical(.record_kind(state,x$artifact_source_ref),'data'), error=function(e) FALSE)) return(FALSE)
  if (!is.null(x$artifact_source_ref)) {
    source <- .record(state,x$artifact_source_ref)
    if (.result_equal(.make_ref(state,rec),x$artifact_source_ref) ||
        !.result_equal(source$locator,x$storage$source_locator) ||
        !is.null(source$sha256) && !identical(tolower(source$sha256),tolower(rec$sha256))) return(FALSE)
  }
  if (identical(x$storage$mode,'copy') && is.null(rec$sha256)) return(FALSE)
  if (!is.null(x$embedding)) {
    candidate <- c(x$embedding,list(membership_ref=rec$details$membership))
    if (!tryCatch(.result_equal(.result_embedding(state,candidate)$embedding,x$embedding),error=function(e) FALSE)) return(FALSE)
  }
  if (!is.null(rec$details$membership) && .result_equal(rec$details$membership,.make_ref(state,rec))) return(FALSE)
  if (!is.null(rec$scope$transformation_ref) &&
      !tryCatch(identical(.record_kind(state,rec$scope$transformation_ref),'analysis'),error=function(e) FALSE)) return(FALSE)
  TRUE
}
.result_valid <- function(state, rec) tryCatch(isTRUE(.result_valid_impl(state,rec)),error=function(e) FALSE)
.result_summary <- function(state, rec) {
  x <- rec$details[[.result_key]]
  if (is.null(x)) return(NULL)
  if (!.is_obj(x) || !identical(x$version,.result_version))
    return(.obj(status='unknown',missing=list('unrecognized_result'),execution='unknown'))
  if (!.result_valid(state,rec)) return(.obj(status='unknown',missing=list('invalid_result'),execution='unknown'))
  .obj(status='declared', missing=.arr(c('artifact_integrity_not_checked',
       if (is.null(rec$scope$transformation_ref)) 'producer_unknown',
       if (is.null(x$embedding)) 'embedding_unknown' else 'alignment_not_checked',
       if (is.null(rec$details$membership)) 'membership_unknown')),execution='unknown')
}
.result_field <- function(status='UNKNOWN', reason='not_checked') .obj(status=status,reason=reason)
.result_table <- function(path, expected, keys, coordinates = NULL, active = TRUE) {
  if (!active) return(list(status='UNKNOWN',integrity='FAIL',reason='inactive_artifact'))
  if (is.null(path) || !file.exists(path) || dir.exists(path))
    return(list(status='UNKNOWN',integrity='UNKNOWN',reason='artifact_unavailable'))
  before <- file.info(path)
  if (is.na(before$size) || before$size > 20971520)
    return(list(status='UNKNOWN',integrity='UNKNOWN',reason='size_limit'))
  bytes <- tryCatch(readBin(path,'raw',n=20971521L),error=function(e) NULL)
  if (is.null(bytes)) return(list(status='UNKNOWN',integrity='UNKNOWN',reason='artifact_unavailable'))
  after <- file.info(path)
  if (length(bytes)>20971520) return(list(status='UNKNOWN',integrity='UNKNOWN',reason='size_limit'))
  if (length(bytes)!=before$size || !identical(before$size,after$size) ||
      !identical(before$mtime,after$mtime) || !identical(before$ctime,after$ctime))
    return(list(status='UNKNOWN',integrity='FAIL',reason='artifact_changed_during_read'))
  digest <- digest::digest(bytes,algo='sha256',serialize=FALSE)
  if (!is.null(expected) && !identical(tolower(digest),tolower(expected)))
    return(list(status='UNKNOWN',integrity='FAIL',reason='digest_mismatch',digest=digest))
  integrity <- if (is.null(expected)) 'UNKNOWN' else 'PASS'
  base <- list(integrity=integrity,reason=if (is.null(expected)) 'baseline_missing' else 'digest_match',digest=digest)
  txt <- tryCatch(rawToChar(bytes),error=function(e) NA_character_)
  if (length(txt)!=1L || is.na(txt) || !stringi::stri_enc_isutf8(txt) || any(bytes==as.raw(0)))
    return(c(base,list(status='FAIL',parse_reason='invalid_csv')))
  txt <- sub('\\r?\\n$','',txt,perl=TRUE)
  conn <- textConnection(txt,open='r',local=TRUE)
  on.exit(close(conn),add=TRUE)
  rows <- tryCatch(utils::read.csv(conn,header=FALSE,check.names=FALSE,colClasses='character',
     na.strings=character(),strip.white=FALSE,blank.lines.skip=FALSE,fill=FALSE,
     comment.char='',row.names=NULL),error=function(e) NULL)
  if (is.null(rows) || !nrow(rows)) return(c(base,list(status='FAIL',parse_reason='invalid_csv')))
  header <- as.character(rows[1L,,drop=TRUE])
  if (any(is.na(header)) || any(!nzchar(trimws(header))) || anyDuplicated(header) ||
      any(is.na(rows))) return(c(base,list(status='FAIL',parse_reason='invalid_csv')))
  width_conn <- textConnection(txt,open='r',local=TRUE)
  on.exit(close(width_conn),add=TRUE)
  widths <- tryCatch(utils::count.fields(width_conn,sep=',',quote='"',blank.lines.skip=FALSE,comment.char=''),error=function(e) NULL)
  if (is.null(widths) || any(!is.na(widths) & widths!=length(header)))
    return(c(base,list(status='FAIL',parse_reason='invalid_csv')))
  data <- rows[-1L,,drop=FALSE];names(data) <- header
  if (!nrow(data)) return(c(base,list(status='PASS',rows=0L,keys=NULL,coordinates='FAIL')))
  ids <- NULL
  if (all(keys %in% names(data))) {
    ids <- data[,keys,drop=FALSE]
    if (any(is.na(ids)) || any(!nzchar(trimws(as.matrix(ids)))) || anyDuplicated(ids)) ids <- NULL
  }
  coord_ok <- !is.null(coordinates) && all(coordinates %in% names(data))
  if (coord_ok) for (column in coordinates) {
    values <- trimws(data[[column]])
    valid <- grepl('^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$',values,perl=TRUE)
    if (any(!valid) || any(!is.finite(suppressWarnings(as.numeric(values))))) coord_ok <- FALSE
  }
  c(base,list(status='PASS',rows=nrow(data),keys=ids,coordinates=if (coord_ok) 'PASS' else 'FAIL'))
}
.result_check <- function(root,state,ref) {
  rec <- .record(state,ref)
  if (rec$kind!='data') .fail('Result must be DATA')
  x <- rec$details[[.result_key]]
  fields <- .obj(contract=.result_field(),file_integrity=.result_field(),observation_identity=.result_field(),
                 coordinates=.result_field(),alignment=.result_field(),membership=.result_field())
  adapter <- NULL; observed <- NULL; rows <- NULL
  if (is.null(x) || !.result_valid(state,rec)) {
    fields$contract <- .result_field('UNKNOWN','unsupported_or_invalid_result')
  } else {
    fields$contract <- .result_field('PASS','recognized_result')
    adapter <- if (is.null(x$embedding)) NULL else x$embedding$format
    if (!is.null(adapter) && adapter!='csv') {
      for (key in setdiff(names(fields),'contract')) fields[[key]] <- .result_field('UNKNOWN','adapter_not_available')
    } else if (!is.null(adapter)) {
      embed <- x$embedding; keys <- unlist(embed$key_columns,use.names=FALSE)
      columns <- unlist(embed$coordinate_columns,use.names=FALSE)
      subject <- .result_table(.resolve(root,state,rec$locator),rec$sha256,keys,columns,identical(rec$status,'active'))
      observed <- subject$digest
      fields$file_integrity <- .result_field(subject$integrity,subject$reason)
      if (identical(subject$status,'FAIL')) {
        for (key in c('observation_identity','coordinates','alignment')) fields[[key]] <- .result_field('FAIL','invalid_csv')
      } else if (identical(subject$status,'PASS')) {
        rows <- subject$rows
        valid_keys <- !is.null(subject$keys)
        valid_coords <- identical(subject$coordinates,'PASS')
        fields$observation_identity <- .result_field(if (valid_keys) 'PASS' else 'FAIL',
          if (valid_keys) 'unique_qualified_keys' else 'invalid_observation_keys')
        fields$coordinates <- .result_field(if (valid_coords) 'PASS' else 'FAIL',
          if (valid_coords) 'finite_coordinates' else 'invalid_coordinates')
        fields$alignment <- .result_field(if (valid_keys && valid_coords) 'PASS' else 'FAIL',
          if (valid_keys && valid_coords) 'same_row' else 'invalid_row_alignment')
        member_ref <- rec$details$membership
        if (is.null(member_ref)) fields$membership <- .result_field('UNKNOWN','authority_missing')
        else if (!valid_keys) fields$membership <- .result_field('UNKNOWN','subject_keys_invalid')
        else {
          member <- .record(state,member_ref)
          if (is.null(member$sha256)) fields$membership <- .result_field('UNKNOWN','authority_baseline_missing')
          else {
            authority <- .result_table(.resolve(root,state,member$locator),member$sha256,keys,
                                       active=identical(member$status,'active'))
            if (authority$status!='PASS' || authority$integrity!='PASS') {
              status <- if (authority$status=='FAIL') 'FAIL' else authority$integrity
              fields$membership <- .result_field(status,
                if (authority$status=='FAIL') 'invalid_csv' else authority$reason)
            } else if (is.null(authority$keys)) fields$membership <- .result_field('FAIL','invalid_authority_keys')
            else {
              left <- subject$keys;right <- authority$keys
              same <- if (identical(embed$comparison,'ordered_keys')) identical(unname(as.matrix(left)),unname(as.matrix(right))) else
                nrow(left)==nrow(right) && identical(
                  unname(as.matrix(left[do.call(order,c(left,method='radix')), ,drop=FALSE])),
                  unname(as.matrix(right[do.call(order,c(right,method='radix')), ,drop=FALSE])))
              fields$membership <- .result_field(if (same) 'PASS' else 'FAIL',
                                                if (same) 'membership_match' else 'membership_mismatch')
            }
          }
        }
      }
    }
  }
  statuses <- vapply(fields,function(z) z$status,character(1))
  .obj(ref=ref,report_version='biodataledger-result-check/1',adapter=adapter,fields=fields,
       observed_sha256=observed,rows=rows,execution='UNKNOWN',
       unverified=list('scientific_validity','downstream_use'),
       overall=if ('FAIL' %in% statuses) 'FAIL' else if ('UNKNOWN' %in% statuses) 'UNKNOWN' else 'PASS')
}
.result_id <- function(ref) paste0(ref$id,'@',ref$revision)
.result_sort_edges <- function(edges) {
  if (length(edges)<2L) return(edges)
  edges[order(vapply(edges,function(e)e$from$id,character(1)),
              vapply(edges,function(e)e$from$revision,numeric(1)),
              vapply(edges,function(e)e$to$id,character(1)),
              vapply(edges,function(e)e$to$revision,numeric(1)),
              vapply(edges,function(e)e$type,character(1)),method='radix')]
}
.result_edge_id <- function(e) paste(.result_id(e$from),.result_id(e$to),e$type,sep='|')
.result_graph <- function(state) {
  graph <- new.env(hash=TRUE,parent=emptyenv())
  graph$forward <- new.env(hash=TRUE,parent=emptyenv())
  graph$backward <- new.env(hash=TRUE,parent=emptyenv())
  graph$indexed <- new.env(hash=TRUE,parent=emptyenv())
  graph$edges <- new.env(hash=TRUE,parent=emptyenv())
  for (rec in state$records) .result_index_record(graph,state,rec)
  graph
}
.result_index_record <- function(graph,state,rec) {
  target <- .make_ref(state,rec); id <- .result_id(target)
  if (exists(id,graph$indexed,inherits=FALSE)) return(invisible(NULL))
  add <- function(from,to,type,basis='declared',source_field) {
    edge_key <- paste(.result_id(from),.result_id(to),type,sep='|')
    if (exists(edge_key,graph$edges,inherits=FALSE)) return(invisible(NULL))
    edge <- .obj(from=from,to=to,type=type,basis=basis,source_field=source_field)
    for (side in c('forward','backward')) {
      key <- .result_id(if (side=='forward') from else to)
      env <- graph[[side]]
      bucket <- if (exists(key,env,inherits=FALSE)) get(key,env) else list()
      assign(key,.result_sort_edges(c(bucket,list(edge))),env)
    }
    assign(edge_key,TRUE,graph$edges)
  }
  if (rec$kind=='analysis' && length(rec$inputs)) for (source in rec$inputs)
    add(source,target,'input_to_analysis',source_field='inputs')
  if (rec$kind=='data' && .result_valid(state,rec)) {
    producer <- rec$scope$transformation_ref
    if (!is.null(producer)) add(producer,target,'produced_result',source_field='scope.transformation_ref')
    source <- rec$details[[.result_key]]$artifact_source_ref
    if (!is.null(source)) add(source,target,'artifact_container',source_field='details.biodataledger.result.artifact_source_ref')
    member <- rec$details$membership
    if (!is.null(member)) add(member,target,'observation_authority',source_field='details.membership')
  }
  if (rec$kind=='figure') {
    if (!is.null(rec$analysis)) add(rec$analysis,target,'analytical_association',source_field='analysis')
    sources <- rec$details[[.figure_sources_key]]
    if (.sources_known(sources)) {
      valid <- tryCatch(.sources_normalize(state,sources),error=function(e) NULL)
      if (!is.null(valid)) for (source in valid$rendering_inputs)
        add(source,target,'rendered_in_figure',valid$relationship,'figure_sources.rendering_inputs')
    }
  }
  assign(id,TRUE,graph$indexed)
  invisible(NULL)
}
.result_dependencies <- function(state,graph,ref,direction,depth=1,limit=20) {
  if (!identical(direction,'upstream') && !identical(direction,'downstream')) .fail('Invalid direction')
  if (!.is_int(depth,TRUE) || depth>3 || !.is_int(limit,TRUE) || limit>100) .fail('Invalid depth or limit')
  env <- if (direction=='downstream') graph$forward else graph$backward
  queue <- list(list(ref=ref,level=0L)); seen <- new.env(hash=TRUE,parent=emptyenv());
  seen_edges <- new.env(hash=TRUE,parent=emptyenv())
  assign(.result_id(ref),TRUE,seen); edges <- list(); unknown <- list(); truncated <- FALSE; stopped <- FALSE
  while (length(queue)) {
    item <- queue[[1L]];queue <- queue[-1L]
    id <- .result_id(item$ref); rec <- .record(state,item$ref)
    if (rec$kind=='data') {
      summary <- .result_summary(state,rec)
      reasons <- if (is.null(summary)) 'result_relationships_unknown' else unlist(summary$missing,use.names=FALSE)
      for (reason in reasons) unknown[[length(unknown)+1L]] <- .obj(ref=item$ref,reason=reason)
    } else if (rec$kind=='analysis' && is.null(rec$inputs)) {
      unknown[[length(unknown)+1L]] <- .obj(ref=item$ref,reason='inputs_unknown')
    } else if (rec$kind=='figure') {
      source <- rec$details[[.figure_sources_key]]
      if (!.sources_known(source)) unknown[[length(unknown)+1L]] <- .obj(ref=item$ref,reason='rendering_inputs_unknown')
      else {
        valid <- tryCatch(.sources_normalize(state,source),error=function(e) NULL)
        if (is.null(valid)) unknown[[length(unknown)+1L]] <- .obj(ref=item$ref,reason='rendering_relationship_invalid')
        else {
          if (is.null(valid$rendering_inputs)) unknown[[length(unknown)+1L]] <- .obj(ref=item$ref,reason='rendering_inputs_unknown')
          if (identical(valid$relationship,'unknown')) unknown[[length(unknown)+1L]] <- .obj(ref=item$ref,reason='rendering_relationship_unknown')
        }
      }
    }
    adj <- if (exists(id,env,inherits=FALSE)) get(id,env) else list()
    if (item$level>=depth) {
      for (edge in adj) if (!exists(.result_edge_id(edge),seen_edges,inherits=FALSE)) {
        truncated <- TRUE
        break
      }
      next
    }
    for (edge in adj) {
      edge_id <- .result_edge_id(edge)
      if (exists(edge_id,seen_edges,inherits=FALSE)) next
      if (length(edges)>=limit) {truncated <- TRUE;stopped <- TRUE;break}
      edges[[length(edges)+1L]] <- edge
      assign(edge_id,TRUE,seen_edges)
      next_ref <- if (direction=='downstream') edge$to else edge$from
      key <- .result_id(next_ref)
      if (!exists(key,seen,inherits=FALSE)) {assign(key,TRUE,seen);queue[[length(queue)+1L]] <- list(ref=next_ref,level=item$level+1L)}
    }
    if (stopped) break
  }
  response <- .obj(ref=ref,direction=direction,depth=depth,edges=.arr(edges),unknown=.arr(unknown),
                   execution='unknown',coverage='recorded_only',truncated=truncated)
  while (nchar(.json(response),type='bytes')>16384L) {
    response$truncated <- TRUE
    if (length(response$unknown)) response$unknown[[length(response$unknown)]] <- NULL
    else if (length(response$edges)) response$edges[[length(response$edges)]] <- NULL
    else {response$ref <- NULL;break}
  }
  response
}
