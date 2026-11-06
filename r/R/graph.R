# Bounded views of the registry's existing exact-revision lineage index.
.graph_kind <- c(data="DATA",analysis="ANA",figure="FIG",decision="DEC",design="DES")
.graph_edge_types <- c("input_to_analysis","produced_result","artifact_container","observation_authority",
                       "analytical_association","rendered_in_figure","revision_of","parent_data",
                       "clustering_context","transformation_context","input_to_figure","decision_concerns",
                       "design_context","design_subject")
.graph_scan_limit <- 1000L
.graph_edge_limit <- 100L
.graph_byte_limit <- 131072L

.index_graph_record <- function(state,rec,ref,result_valid,add) {
  details <- rec$details
  link <- function(source,target,type,field,basis="declared") {
    if (!is.null(source)) add(source,target,type,basis,field,graph_only=TRUE)
  }
  # Physical slots of imported records need not be in revision order.
  for (delta in c(-1,1)) {
    adjacent <- ref; adjacent$revision <- as.numeric(ref$revision)+delta
    if (!is.null(.lookup_record(state,adjacent))) {
      if (delta<0) link(adjacent,ref,"revision_of","id/revision","record_identity")
      else link(ref,adjacent,"revision_of","id/revision","record_identity")
    }
  }
  link(rec$design,ref,"design_context","design")
  if (rec$kind=="design") for (subject in details[["context"]])
    link(subject,ref,"design_subject","details.context")
  if (rec$kind=="data") {
    link(details[["parent"]],ref,"parent_data","details.parent")
    link(details[["clustering_run"]],ref,"clustering_context","details.clustering_run")
    if (!result_valid) {
      link(details[["membership"]],ref,"observation_authority","details.membership")
      link(rec$scope$transformation_ref,ref,"transformation_context","scope.transformation_ref")
    }
  }
  if (rec$kind=="figure" && is.null(rec$analysis)) for (source in rec$inputs)
    link(source,ref,"input_to_figure","inputs")
  issue <- NULL; count <- 0L
  if (rec$kind=="decision" && "targets" %in% names(details)) {
    targets <- details[["targets"]]
    if (!.is_arr(targets)) return(.obj(reason="invalid_decision_targets",related_ref=NULL,
                                      identity_omitted=FALSE,count=1L,uninspected=0L))
    for (source in utils::head(targets,.graph_scan_limit)) {
      valid <- tryCatch({.validate_ref_shape(state,source); TRUE},error=function(e) FALSE)
      reason <- NULL; related <- NULL; omitted <- FALSE
      if (valid) {
        target <- if (nchar(.result_id(source),type="bytes")<=10000L) .lookup_record(state,source) else NULL
        if (is.null(target)) {
          reason <- "unresolved_decision_target"
          omitted <- nchar(source$id,type="bytes")>128L || source$revision>2147483647
          if (!omitted) related <- source
        } else link(source,ref,"decision_concerns","details.targets")
      } else reason <- "invalid_decision_target"
      if (!is.null(reason)) {
        count <- count+1L
        if (is.null(issue)) issue <- .obj(reason=reason,related_ref=related,identity_omitted=omitted)
      }
    }
    uninspected <- max(0L,length(targets)-.graph_scan_limit)
    if (!is.null(issue) || uninspected>0L) {
      if (is.null(issue)) issue <- .obj(reason="decision_target_limit",related_ref=NULL,identity_omitted=FALSE)
      issue$count <- count; issue$uninspected <- uninspected
    }
  }
  issue
}
.graph_connected <- function(graph,left,right) {
  left <- .result_id(left); right <- .result_id(right)
  keys <- c(paste(left,right,.graph_edge_types,sep="|"),paste(right,left,.graph_edge_types,sep="|"))
  any(vapply(keys,exists,logical(1),envir=graph$edges,inherits=FALSE))
}
.graph_ref <- function(state,ref,kinds=names(.graph_kind)) {
  rec <- .record(state,ref)
  if (!rec$kind %in% kinds) .fail("Reference kind outside graph selection")
  .make_ref(state,rec)
}
.graph_text <- function(x) is.character(x) && length(x)==1L && !is.na(x)
.graph_timestamp <- function(x) if (is.na(.protocol_timestamp(x))) NULL else x
.graph_filters <- function(state,filters) {
  if (is.null(filters) || is.list(filters) && !length(filters)) return(.obj())
  fields <- c("asset_type","query","registered_on","executed_on","revision","record_status","anchor")
  if (!.is_obj(filters) || anyDuplicated(names(filters)) || !all(names(filters) %in% fields)) .fail("Invalid graph filters")
  choice <- function(field,choices) {
    if (field %in% names(filters) && (!.graph_text(filters[[field]]) || !filters[[field]] %in% choices))
      .fail(paste("Invalid",field))
  }
  choice("asset_type",c(unname(.graph_kind),"RESULT"))
  choice("revision",c("latest","historical"))
  choice("record_status",c("active","inactive","superseded"))
  if ("query" %in% names(filters)) {
    query <- .related_clip(filters$query,256L)
    if (is.null(query$value) || !nzchar(stringi::stri_trim_both(query$value)) || query$clipped)
      .fail("Query must be nonblank and at most 256 UTF-8 bytes")
  }
  for (field in intersect(c("registered_on","executed_on"),names(filters))) {
    date <- filters[[field]]
    if (!.graph_text(date) || nchar(date,type="bytes")!=10L || is.null(.graph_timestamp(paste0(date,"T00:00:00Z"))))
      .fail(paste(field,"must be a UTC date YYYY-MM-DD"))
  }
  if ("anchor" %in% names(filters)) filters$anchor <- .graph_ref(state,filters$anchor,c("data","analysis"))
  filters
}
.graph_execution <- function(state,rec) {
  receipt <- rec$details[["execution_receipt"]]
  if (rec$kind!="analysis" || is.null(receipt) || !.execution_receipt_valid(state,rec,receipt))
    return(.obj(evidence="unknown",status="unknown",timing_status="unknown",
                started_at_utc=NULL,ended_at_utc=NULL,code_executed=NULL))
  .obj(evidence=if (isTRUE(state$imported)) "untrusted_imported" else "recorded",
       status=receipt$status,timing_status=.receipt_timing(receipt),
       started_at_utc=.graph_timestamp(receipt$started_at_utc),ended_at_utc=.graph_timestamp(receipt$ended_at_utc),
       code_executed=receipt$phases$code_executed)
}
.graph_asset_type <- function(graph,rec,ref) {
  if (exists(.result_id(ref),graph$result_records,inherits=FALSE)) "RESULT" else unname(.graph_kind[[rec$kind]])
}
.graph_node <- function(state,graph,ref) {
  rec <- .record(state,ref); id <- .result_id(ref)
  label <- .related_clip(rec$name,192L)
  owner <- if (rec$kind=="figure" && !is.null(rec$analysis)) .record(state,rec$analysis) else rec
  scientific_status <- "unknown"
  if (rec$kind=="decision" && "scientific_decision" %in% names(rec$details)) {
    descriptor <- .scientific_decision_for_record(state,rec,copy_out=FALSE)$scientific
    if (!is.null(descriptor)) scientific_status <- descriptor$scientific_status
  }
  latest <- state$records[[get(rec$id,attr(state,"record_index")$latest)]]
  .obj(ref=ref,kind=unname(.graph_kind[[rec$kind]]),asset_type=.graph_asset_type(graph,rec,ref),
       label=label$value,label_truncated=label$clipped,record_status=rec$status,
       revision_status=if (rec$revision==latest$revision) "latest" else "historical",
       registration_at_utc=.graph_timestamp(rec$created_at),superseded_at_utc=NULL,
       execution=.graph_execution(state,rec),scientific_status=scientific_status,
       approval="not_authenticated",code_owner_ref=if (length(owner$code)) .make_ref(state,owner) else NULL,
       code_count=length(owner$code),unknown=.result_unknown(state,graph,ref,rec),
       issue=get0(id,graph$graph_issues,inherits=FALSE,ifnotfound=NULL))
}
.graph_overview <- function(state,graph,filters,offset,limit) {
  anchor <- filters$anchor
  terms <- if (is.null(filters$query)) character() else
    stringi::stri_split_regex(stringi::stri_trans_casefold(stringi::stri_trim_both(filters$query)),"\\s+")[[1L]]
  records <- state$records
  latest <- attr(state,"record_index")$latest
  cursor <- offset; stops <- if (offset>0L) "page_boundary" else character(); refs <- list(); slots <- integer()
  while (cursor<length(records) && cursor-offset<.graph_scan_limit && length(refs)<limit) {
    cursor <- cursor+1L
    rec <- records[[cursor]]
    ref <- .make_ref(state,rec)
    if (!is.null(filters$asset_type) && !filters$asset_type %in% c(.graph_kind[[rec$kind]],.graph_asset_type(graph,rec,ref))) next
    revision <- if (get(rec$id,latest)==cursor) "latest" else "historical"
    if (!is.null(filters$revision) && filters$revision!=revision ||
        !is.null(filters$record_status) && filters$record_status!=rec$status) next
    if (!is.null(anchor) && !.related_ref_equal(anchor,ref) && !.graph_connected(graph,anchor,ref)) next
    if (!is.null(filters$registered_on)) {
      stamp <- .graph_timestamp(rec$created_at)
      if (is.null(stamp) || substr(stamp,1L,10L)!=filters$registered_on) next
    }
    if (length(terms)) {
      found <- .related_match(rec,terms)
      if (found$clipped) stops <- c(stops,"topic_metadata_limit")
      if (!found$match) next
    }
    if (!is.null(filters$executed_on)) {
      execution <- .graph_execution(state,rec)
      if (execution$timing_status!="valid_interval" || !isTRUE(execution$code_executed) ||
          substr(execution$started_at_utc,1L,10L)!=filters$executed_on) next
    }
    refs[[length(refs)+1L]] <- ref; slots <- c(slots,cursor-1L)
  }
  if (cursor<length(records)) stops <- c(stops,if (length(refs)==limit) "node_limit" else "scan_limit")
  keys <- vapply(refs,.result_id,character(1)); edges <- list(); scanned <- 0L
  for (ref in refs) {
    for (edge in .result_adjacent(graph,ref,"downstream",TRUE)) {
      if (scanned>=.graph_scan_limit) {stops <- c(stops,"edge_scan_limit");break}
      scanned <- scanned+1L
      if (.result_id(edge$to) %in% keys) {
        if (length(edges)>=.graph_edge_limit) {stops <- c(stops,"edge_limit");break}
        edges[[length(edges)+1L]] <- edge
      }
    }
    if (any(c("edge_limit","edge_scan_limit") %in% stops)) break
  }
  list(refs=refs,edges=edges,stops=unique(stops),cursor=cursor,slots=slots)
}
.graph_cycle <- function(nodes,edges,incomplete) {
  ids <- vapply(nodes,function(node).result_id(node$ref),character(1))
  from <- match(vapply(edges,function(edge).result_id(edge$from),character(1)),ids)
  to <- match(vapply(edges,function(edge).result_id(edge$to),character(1)),ids)
  degree <- tabulate(to,nbins=length(ids))
  queue <- which(degree==0L); cursor <- 1L
  while (cursor<=length(queue)) {
    for (target in to[from==queue[[cursor]]]) {
      degree[[target]] <- degree[[target]]-1L
      if (degree[[target]]==0L) queue <- c(queue,target)
    }
    cursor <- cursor+1L
  }
  if (length(queue)<length(ids)) "detected" else if (incomplete) "unknown" else "not_detected_in_view"
}
.graph_quote <- function(value) {
  value <- gsub("[\\x01-\\x09\\x0b-\\x1f\\x7f]"," ",value,perl=TRUE)
  value <- gsub("\\","\\\\",value,fixed=TRUE)
  value <- gsub('"','\\"',value,fixed=TRUE)
  paste0('"',gsub("\n","\\n",value,fixed=TRUE),'"')
}
.graph_dot <- function(report) {
  snap <- report$snapshot
  flags <- if (length(report$truncation)) paste(unlist(report$truncation),collapse=", ") else "none"
  summary <- paste0("Recorded graph; ",report$mode,"; omissions: ",flags,"; cycle: ",report$cycle,"; edge scope: ",report$edge_scope)
  if (!is.null(report$next_offset)) summary <- paste0(summary,"; next_offset=",report$next_offset)
  lines <- c("digraph biodataledger {",paste0("  graph [label=",.graph_quote(summary),
    ", project_id=",.graph_quote(snap$project_id),", registry_revision=",.graph_quote(as.character(snap$registry_revision)),
    ", transaction=",.graph_quote(snap$last_transaction),", truncated=",.graph_quote(tolower(as.character(report$truncated))),"];"))
  stamp <- function(value) if (is.null(value)) "unknown" else value
  for (node in report$nodes) {
    execution <- node$execution
    label <- paste0(.result_id(node$ref)," [",node$asset_type,"] ",node$label,
      if (node$label_truncated) "\u2026" else "", "\n",node$revision_status,"/",node$record_status,
      "; registered: ",stamp(node$registration_at_utc),"; superseded: ",stamp(node$superseded_at_utc),
      "\nexecution: ",execution$evidence,"/",execution$status,"/",execution$timing_status,
      "; receipt start: ",stamp(execution$started_at_utc),"; receipt end: ",stamp(execution$ended_at_utc))
    unknown <- unlist(node$unknown,use.names=FALSE)
    if (!is.null(node$issue)) unknown <- c(unknown,paste0(node$issue$reason,if (!is.null(node$issue$related_ref)) paste0(" ",.result_id(node$issue$related_ref))))
    if (length(unknown)) label <- paste0(label,"\n",paste(unknown,collapse=", "))
    lines <- c(lines,paste0("  ",.graph_quote(.result_id(node$ref))," [label=",.graph_quote(label),"];"))
  }
  for (edge in report$edges) lines <- c(lines,paste0("  ",.graph_quote(.result_id(edge$from))," -> ",.graph_quote(.result_id(edge$to)),
    " [label=",.graph_quote(edge$type),", basis=",.graph_quote(edge$basis),", source_field=",.graph_quote(edge$source_field),"];"))
  paste(c(lines,"}",""),collapse="\n")
}
.export_graph <- function(state,graph,dirty,ref,direction,depth,limit,format,filters,offset,style,lineage_roots) {
  if (!.graph_text(direction) || !direction %in% c("upstream","downstream")) .fail("Direction must be upstream or downstream")
  if (!.is_int(depth,TRUE) || depth>10L || !.is_int(limit,TRUE) || limit>100L) .fail("Depth 1..10 and limit 1..100 required")
  if (!.graph_text(format) || !format %in% c("dot","structured")) .fail("Format must be dot or structured")
  if (!.graph_text(style) || !style %in% c("detailed","presentation")) .fail("Style must be detailed or presentation")
  if (style=="presentation" && format!="dot") .fail("Presentation style requires DOT format")
  if (style!="presentation" && !is.null(lineage_roots)) .fail("lineage_roots requires presentation style")
  if (style=="presentation") roots <- .diagram_roots(state,lineage_roots)
  if (!.is_int(offset) || offset<0 || offset>2147483647) .fail("Offset must be a nonnegative 32-bit integer")
  if (!is.null(ref) && (!is.null(filters) || offset!=0L)) .fail("Filters and offset are overview-only")
  filters <- .graph_filters(state,filters)
  if (is.null(ref)) {
    page <- .graph_overview(state,graph,filters,offset,limit)
  } else {
    ref <- .graph_ref(state,ref)
    page <- .result_walk(graph,ref,direction,depth,.graph_edge_limit,node_limit=limit,extended=TRUE)
  }
  nodes <- lapply(page$refs,function(item).graph_node(state,graph,item))
  total <- length(state$records); stops <- page$stops
  report <- .obj(report_version="biodataledger-graph/1",mode=if (is.null(ref)) "overview" else "lineage",
    ref=ref,direction=if (!is.null(ref)) direction else NULL,depth=if (!is.null(ref)) depth else NULL,
    filters=filters,limit=limit,offset=if (is.null(ref)) offset else NULL,
    scanned_record_slots=if (is.null(ref)) page$cursor-offset else NULL,
    snapshot=.obj(project_id=state$project$id,registry_revision=state$state_revision,last_transaction=state$last_transaction,
                  unsaved=dirty,record_slots=total,imported=state$imported),
    next_offset=if (is.null(ref) && page$cursor<total) page$cursor else NULL,
    coverage="recorded_only",edge_scope=if (is.null(ref)) "induced_page" else "directional_walk",
    cycle_scope="visible_navigation_edges",nodes=.arr(nodes),edges=.arr(page$edges))
  repeat {
    report$truncation <- .arr(sort(unique(c(stops,if (graph$target_limit) "decision_target_limit")),method="radix"))
    report$truncated <- length(report$truncation)>0L
    unresolved <- any(vapply(report$nodes,function(node) !is.null(node$issue) ||
      any(unlist(node$unknown) %in% c("invalid_result","unrecognized_result","rendering_relationship_invalid")),logical(1)))
    report$cycle <- .graph_cycle(report$nodes,report$edges,report$truncated || unresolved)
    dot <- .graph_dot(report)
    if (nchar(.json(report),type="bytes")<=.graph_byte_limit && nchar(dot,type="bytes")<=.graph_byte_limit) {
      if (style=="presentation") return(.diagram_dot(state,report,roots))
      return(if (format=="dot") dot else report)
    }
    n <- length(report$nodes)
    if (!n) .fail("Graph selector exceeds byte limit")
    if (!is.null(ref) && n==1L) .fail("Graph root exceeds byte limit")
    if (is.null(ref)) {
      slot <- page$slots[[n]]
      if (n==1L) {slot <- slot+1L; stops <- c(stops,"oversized_node")}
      report["next_offset"] <- list(if (slot<total) slot else NULL)
      report$scanned_record_slots <- slot-offset
    }
    dropped <- .result_id(report$nodes[[n]]$ref)
    report$nodes[[n]] <- NULL
    report$edges <- .arr(Filter(function(edge) !dropped %in% c(.result_id(edge$from),.result_id(edge$to)),report$edges))
    stops <- c(stops,"byte_limit")
  }
}
