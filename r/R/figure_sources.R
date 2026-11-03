# Optional figure declarations reuse exact records and existing code snapshots.
.figure_sources_key <- 'biodataledger.figure_sources'
.figure_sources_version <- 'biodataledger-figure-sources/1'
.sources_known <- function(x) .is_obj(x) && identical(x$version, .figure_sources_version)
.sources_normalize <- function(state, value) {
  fields <- c('rendering_inputs','relationship','generating_code','dependencies','asset_id')
  if (!.is_obj(value) || !all(names(value) %in% c(fields,'version')) || !is.null(value$version) && !identical(value$version,.figure_sources_version)) .fail('Invalid figure_sources fields/version')
  out <- .obj(version=.figure_sources_version)
  for (key in fields) out[key] <- list(value[[key]])
  if (is.null(out$relationship)) out$relationship <- 'unknown'
  if (!.design_text(out$relationship) || !out$relationship %in% c('declared','unknown') || out$relationship == 'declared' && is.null(out$rendering_inputs)) .fail('Invalid rendering relationship')
  data_ref <- function(ref) {ref <- .ref(state,ref); if (.record_kind(state,ref) != 'data') .fail('Rendering/dependency reference must be DATA'); ref}
  if (!is.null(out$rendering_inputs)) {
    if (!.is_arr(out$rendering_inputs)) .fail('rendering_inputs must be an array or null')
    out$rendering_inputs <- .arr(lapply(out$rendering_inputs,data_ref))
  }
  code <- out$generating_code
  if (!is.null(code)) {
    if (!.is_obj(code) || !all(c('record','index') %in% names(code)) || !all(names(code) %in% c('record','index','sha256','registered_ref'))) .fail('Invalid generating code selector')
    owner <- .record(state,code$record); index <- code$index
    if (!owner$kind %in% c('analysis','figure') || !.is_int(index) || index < 0 || index >= length(owner$code)) .fail('Invalid code owner/index')
    entry <- owner$code[[index+1L]]
    if (is.null(entry$sha256) || !is.null(code$sha256) && !identical(code$sha256,entry$sha256)) .fail('Generating code digest conflict')
    registered <- code$registered_ref
    if (!is.null(registered)) {
      registered <- data_ref(registered)
      if (!identical(.record(state,registered)$sha256,entry$sha256)) .fail('Registered code digest conflict')
    }
    out$generating_code <- .obj(record=.make_ref(state,owner),index=index,sha256=entry$sha256,registered_ref=registered)
  }
  if (!is.null(out$dependencies)) {
    if (!.is_arr(out$dependencies)) .fail('dependencies must be an array or null')
    keys <- character()
    out$dependencies <- .arr(lapply(out$dependencies,function(x) {
      if (!.is_obj(x) || !setequal(names(x),c('path','ref')) || !.safe_rel(x$path)) .fail('Invalid dependency/path')
      key <- stringi::stri_trans_casefold(stringi::stri_trans_nfc(x$path))
      if (key %in% keys || any(startsWith(key,paste0(keys,'/')) | startsWith(keys,paste0(key,'/')))) .fail('Dependency path collision')
      keys <<- c(keys,key); .obj(path=x$path,ref=data_ref(x$ref))
    }))
  }
  if (!.design_text(out$asset_id,TRUE)) .fail('Invalid asset_id')
  out
}
.sources_describe <- function(root,state,rec,check_files,pending) {
  out <- .obj(rendering_inputs=NULL,relationship='unknown',generating_code=NULL,dependencies=NULL,asset_id=NULL,
              rendering_details=list(),code=NULL,dependency_details=list(),dependency_completeness='unknown',code_candidates=list(),missing=list(),contradictions=list())
  value <- rec$details[[.figure_sources_key]]
  if (.sources_known(value)) {
    value <- tryCatch(.sources_normalize(state,value),error=function(e) {out$contradictions <<- list(conditionMessage(e)); NULL})
    if (!is.null(value)) for (key in c('rendering_inputs','relationship','generating_code','dependencies','asset_id')) out[key] <- list(value[[key]])
  }
  for (key in c('rendering_inputs','generating_code','dependencies')) if (is.null(out[[key]])) out$missing <- c(out$missing,list(key))
  data_view <- function(ref) {
    data <- .record(state,ref); path <- .resolve(root,state,data$locator)
    .obj(ref=.copy(ref),path=path,available=if(check_files) !is.null(path) && file.exists(path) && !dir.exists(path) else NULL,
         availability_checked=check_files,parent=.copy(data$details$parent),transformation_ref=.copy(data$scope$transformation_ref))
  }
  out$rendering_details <- .arr(lapply(out$rendering_inputs,data_view))
  out$dependency_details <- .arr(lapply(out$dependencies,function(x) {v<-data_view(x$ref);v$relative_path<-x$path;v}))
  code_view <- function(selector) {
    entry <- .record(state,selector$record)$code[[selector$index+1L]]
    path <- if (!is.null(entry$snapshot)) .resolve(root,state,.obj(kind='project',value=entry$snapshot)) else .resolve(root,state,entry$locator)
    available <- if(check_files) (!is.null(entry$snapshot) && !is.null(pending[[entry$snapshot]])) || !is.null(path) && file.exists(path) && !dir.exists(path) else NULL
    .obj(selector=.copy(selector),locator=.copy(entry$locator),sha256=entry$sha256,snapshot=entry$snapshot,path=path,
         available=available,availability_checked=check_files,integrity='not_checked')
  }
  owner <- if(is.null(rec$analysis)) rec else .record(state,rec$analysis)
  out$code_candidates <- .arr(lapply(seq_along(owner$code),function(i) code_view(.obj(record=.make_ref(state,owner),index=i-1L,sha256=owner$code[[i]]$sha256,registered_ref=NULL))))
  if (!is.null(out$generating_code)) out['code'] <- list(code_view(out$generating_code))
  if (out$relationship == 'unknown') out$missing <- c(out$missing,list('rendering_relationship'))
  if (check_files) {
    for (key in c('rendering_details','dependency_details','code_candidates')) if(any(vapply(out[[key]],function(x) identical(x$available,FALSE),logical(1)))) out$missing<-c(out$missing,list(switch(key,rendering_details='rendering_file',dependency_details='dependency_file',code_candidates='code_candidate_file')))
    if (!is.null(out$code) && identical(out$code$available,FALSE)) out$missing<-c(out$missing,list('source_file'))
  }
  out
}
.sources_compact <- function(view) {
  sources <- view$figure_sources
  truncated <- .obj(analytical_inputs=0L,rendering_inputs=0L,dependencies=0L,code_candidates=0L,fields=list())
  mark <- function(key) truncated$fields <<- unique(c(truncated$fields,list(key)))
  text <- function(value,key,limit=384L) {if(!is.null(value) && nchar(as.character(value),type='chars')>limit) {mark(key);NULL} else value}
  ref <- function(value,key) {if(!is.null(value) && nchar(value$id,type='chars')>64L) {mark(key);NULL} else .copy(value)}
  refs <- function(values,key) {
    if(is.null(values)) return(NULL)
    result <- Filter(Negate(is.null),lapply(utils::head(values,3L),function(x) ref(x,key)))
    truncated[[key]] <<- length(values)-length(result); .arr(result)
  }
  params <- function(value,depth=0L) {
    if(depth>2L) {mark('params');return(NULL)}
    if(is.list(value)) {
      if(length(value)>3L) mark('params')
      selected <- utils::head(value,3L)
      if(.is_obj(value)) {
        keep <- nchar(names(selected),type='chars')<=64L
        if(any(!keep)) mark('params')
        selected <- selected[keep]
      }
      return(lapply(selected,function(x) params(x,depth+1L)))
    }
    if(is.character(value)) text(value,'params',80L) else value
  }
  short_code <- function(code) {
    if(is.null(code)) return(NULL)
    code$selector['record'] <- list(ref(code$selector$record,'generating_code'))
    code$selector['registered_ref'] <- list(ref(code$selector$registered_ref,'registered_ref'))
    code$locator['value'] <- list(text(code$locator$value,'code_locator'))
    code['path'] <- list(text(code$path,'code_path'));code
  }
  dependencies <- lapply(utils::head(sources$dependency_details,3L),function(x) .obj(path=text(x$relative_path,'dependency_path',128L),ref=ref(x$ref,'dependencies'),available=x$available))
  truncated$dependencies <- length(sources$dependency_details)-length(dependencies)
  selected <- sources$code$selector
  alternatives <- Filter(function(x) is.null(selected) || !(identical(x$selector$record,selected$record) &&
                         x$selector$index==selected$index && identical(x$selector$sha256,selected$sha256)),sources$code_candidates)
  candidates <- lapply(utils::head(alternatives,3L),short_code)
  truncated$code_candidates <- length(alternatives)-length(candidates)
  rendering <- lapply(utils::head(sources$rendering_details,3L),function(x) .obj(ref=ref(x$ref,'rendering_inputs'),parent=ref(x$parent,'parent'),transformation_ref=ref(x$transformation_ref,'transformation_ref'),available=x$available,integrity='not_checked'))
  entry_point <- view$details$entry_point
  if (!.design_text(entry_point)) entry_point <- NULL
  report <- .obj(asset_id=text(view$asset_id,'asset_id'),entry_point=text(entry_point,'entry_point'),ref=ref(view$ref,'ref'),path=text(view$path,'path'),available=view$available,availability_checked=view$availability_checked,integrity='not_checked',analysis=ref(view$analysis,'analysis'),
                 analytical_inputs=refs(view$inputs,'analytical_inputs'),rendering_inputs=refs(view$rendering_inputs,'rendering_inputs'),rendering_relationship=view$rendering_relationship,
                 generating_code=short_code(sources$code),code_candidates=.arr(candidates),rendering_details=.arr(rendering),dependencies=.arr(dependencies),dependency_completeness='unknown',
                 method=text(view$method,'method',128L),params=params(view$params),execution='unknown',execution_evidence='not_captured',
                 missing=.arr(unique(c(view$unknown,sources$missing))),contradictions=.arr(lapply(utils::head(sources$contradictions,3L),function(x) text(x,'contradictions',160L))),truncated=NULL)
  if(view$availability_checked && identical(view$available,FALSE)) report$missing<-c(report$missing,list('figure_file'))
  report$truncated<-truncated
  while(nchar(.json(report),type='bytes')>4096L) {
    if(!is.null(report$params)) {report['params']<-list(NULL);mark('params')
    } else if(length(report$dependencies)) {report$dependencies[[length(report$dependencies)]]<-NULL;truncated$dependencies<-truncated$dependencies+1L
    } else if(length(report$code_candidates)) {report$code_candidates[[length(report$code_candidates)]]<-NULL;truncated$code_candidates<-truncated$code_candidates+1L
    } else if(length(report$rendering_details)) {report$rendering_details[[length(report$rendering_details)]]<-NULL;mark('rendering_details')
    } else if(length(report$rendering_inputs)) {report$rendering_inputs[[length(report$rendering_inputs)]]<-NULL;truncated$rendering_inputs<-truncated$rendering_inputs+1L
    } else if(length(report$analytical_inputs)) {report$analytical_inputs[[length(report$analytical_inputs)]]<-NULL;truncated$analytical_inputs<-truncated$analytical_inputs+1L
    } else if(!is.null(report$generating_code)) {report['generating_code']<-list(NULL);mark('generating_code')
    } else {
      report <- .obj(ref=ref(view$ref,'ref'),execution='unknown',execution_evidence='not_captured',missing=list('report_fields_omitted'),truncated=.obj(all=TRUE))
      if(nchar(.json(report),type='bytes')>4096L) report['ref']<-list(NULL)
      return(report)
    }
    report$truncated<-truncated
  }
  report$truncated<-truncated;report
}
