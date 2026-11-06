# Presentation DOT for one bounded, already selected graph report.
.diagram_stroke <- c("#17628D","#A24520","#356B44","#744681","#866019","#1C6C70")
.diagram_fill <- c("#DCEEF9","#FCE6DA","#E2F0E4","#EFE3F2","#FAEECF","#DBF1F0")
.diagram_neutral <- "#64748B"
.diagram_types <- c(DATA="DATA",ANA="ANALYSIS",RESULT="RESULT",FIG="FIGURE",DEC="DECISION",DES="DESIGN")
.diagram_shapes <- c(DATA="box",ANA="ellipse",RESULT="cylinder",FIG="note",DEC="hexagon",DES="folder")
.diagram_flow <- c(input_to_analysis="DATA ANA",produced_result="ANA DATA",transformation_context="ANA DATA",
                   parent_data="DATA DATA",rendered_in_figure="DATA FIG")
.diagram_context <- c(analytical_association="associated",revision_of="revision",design_context="design",
                      design_subject="design subject",decision_concerns="concerns",clustering_context="clustering",
                      artifact_container="container",observation_authority="membership",
                      rendered_in_figure="rendering unconfirmed",input_to_figure="analytical input")

.diagram_roots <- function(state,values) {
  if (is.null(values)) return(character())
  if (is.character(values) && is.null(names(values))) values <- as.list(values)
  if (!.is_arr(values) || length(values)>length(.diagram_stroke))
    .fail("lineage_roots must be an ordered list of up to six exact local DATA references")
  roots <- vapply(values,function(value) .result_id(.graph_ref(state,value,"data")),character(1))
  if (anyDuplicated(roots)) .fail("lineage_roots must be distinct")
  roots
}
.diagram_short <- function(text,limit,truncated=FALSE) {
  out <- .related_clip(gsub("[\r\n]"," ",text),limit)
  paste0(out$value,if (out$clipped || truncated) "\u2026")
}
.diagram_selector <- function(state,rec,node) {
  descriptor <- rec$details[[.figure_sources_key]]
  # The index already validated the whole descriptor; recheck only the selector.
  if (!.sources_known(descriptor) || "rendering_relationship_invalid" %in% node$unknown) return(NULL)
  tryCatch(.sources_normalize(state,.obj(generating_code=descriptor$generating_code))$generating_code,
           error=function(e) NULL)
}
.diagram_focus <- function(report,ids,edges) {
  if (is.null(report$ref) || !any(vapply(edges,function(edge) edge$kind=="revision_of",logical(1))))
    return(list(ids=ids,edges=edges))
  edges <- Filter(function(edge) edge$kind!="revision_of",edges)
  downstream <- report$direction=="downstream"
  start <- if (downstream) "source" else "target"
  end <- if (downstream) "target" else "source"
  neighbors <- split(vapply(edges,`[[`,character(1),end),vapply(edges,`[[`,character(1),start))
  queue <- .result_id(report$ref); cursor <- 1L
  while (cursor<=length(queue)) {
    queue <- c(queue,setdiff(neighbors[[queue[[cursor]]]],queue))
    cursor <- cursor+1L
  }
  list(ids=ids[ids %in% queue],edges=Filter(function(edge) all(c(edge$source,edge$target) %in% queue),edges))
}
.diagram_dot <- function(state,report,roots) {
  ids <- vapply(report$nodes,function(node) .result_id(node$ref),character(1))
  nodes <- stats::setNames(report$nodes,ids)
  edge_info <- lapply(report$edges,function(edge) {
    source <- .result_id(edge$from); target <- .result_id(edge$to)
    flow <- edge$basis=="declared" &&
      isTRUE(unname(.diagram_flow[edge$type])==paste(nodes[[source]]$kind,nodes[[target]]$kind))
    list(source=source,target=target,kind=edge$type,flow=flow)
  })
  focus <- .diagram_focus(report,ids,edge_info)
  ids <- focus$ids; nodes <- nodes[ids]; edge_info <- focus$edges
  omitted_nodes <- length(report$nodes)-length(ids)
  omitted_edges <- length(report$edges)-length(edge_info)
  sources <- stats::setNames(lapply(ids,function(id) which(roots==id)),ids)
  # Propagation is monotone and terminates even when visible records form a cycle.
  repeat {
    changed <- FALSE
    for (edge in edge_info) {
      from <- sources[[edge$source]]; to <- sources[[edge$target]]
      if (edge$flow && !edge$target %in% roots && !all(from %in% to)) {
        sources[[edge$target]] <- sort(union(to,from))
        changed <- TRUE
      }
    }
    if (!changed) break
  }

  node_lines <- notes <- note_links <- character()
  seen <- list(question=list(),code=list())
  omissions <- links <- c(question=0L,code=0L)
  add_note <- function(kind,identity,label,target) {
    ids <- seen[[kind]]
    if (links[[kind]]>=24L || is.null(ids[[identity]]) && length(ids)>=8L) {
      omissions[[kind]] <<- omissions[[kind]]+1L
      return(FALSE)
    }
    id <- ids[[identity]]
    if (is.null(id)) {
      id <- paste0("annotation-",kind,"-",length(ids)+1L)
      seen[[kind]][[identity]] <<- id
      notes <<- c(notes,paste0("  ",.graph_quote(id),' [shape=note, style="filled,dashed", ',
                               'fillcolor="#F8FAFC", fontsize=11, label=',.graph_quote(label),"];"))
    }
    note_links <<- c(note_links,paste0("  ",.graph_quote(target)," -> ",.graph_quote(id),
                                       ' [style=dashed, dir=none, color="',.diagram_neutral,'"];'))
    links[[kind]] <<- links[[kind]]+1L
    TRUE
  }
  for (id in ids) {
    node <- nodes[[id]]
    rec <- .record(state,node$ref)
    desc <- .presentation_read(rec)$descriptor
    if (!is.null(desc)) for (question in unique(desc$questions))
      add_note("question",question,paste0("Question context\n",.diagram_short(question,112L)),id)
    type <- node$asset_type
    label <- paste0(.diagram_types[[type]],"  \u00b7  ",id,"\n",.diagram_short(node$label,72L,node$label_truncated))
    color <- "#475569"; fill <- "#F1F5F9"
    groups <- sources[[id]]
    if (length(groups)) {
      marker <- if (id %in% roots) "Source boundary " else if (length(groups)>1L) "Sources " else "Source "
      label <- paste0(label,"\n",marker,paste(groups,collapse=" + "))
      if (length(groups)==1L) {
        color <- .diagram_stroke[[groups]]; fill <- .diagram_fill[[groups]]
      } else label <- paste0(label," (mixed)")
    }
    if (type=="FIG") {
      if (any(c("rendering_inputs_unknown","rendering_relationship_invalid") %in% node$unknown)) {
        label <- paste0(label,"\nRendering inputs unknown")
      } else if ("rendering_relationship_unknown" %in% node$unknown) {
        inputs <- rec$details[[.figure_sources_key]]$rendering_inputs
        label <- paste0(label,if (length(inputs)) "\nRendering link unconfirmed" else "\nRendering inputs unknown")
      }
      selector <- .diagram_selector(state,rec,node)
      if (is.null(selector)) label <- paste0(label,"\nPlotting code unknown")
      else {
        owner <- .result_id(selector$record); index <- selector$index; digest <- selector$sha256
        locator <- .record(state,selector$record)$code[[index+1L]]$locator
        basename <- if (locator$kind=="uri") "" else sub("^.*/","",chartr("\\","/",locator$value))
        callout <- paste0("Declared plotting code\n",
                          if (nzchar(stringi::stri_trim_both(basename)) && !basename %in% c(".",".."))
                            paste0(.diagram_short(basename,64L),"\n"),
                          owner," \u00b7 entry ",index," \u00b7 sha256 ",substr(digest,1L,12L))
        if (!add_note("code",paste(owner,index,digest),callout,id))
          label <- paste0(label,"\nPlotting code note omitted")
      }
    }
    node_lines <- c(node_lines,paste0("  ",.graph_quote(id)," [shape=",.diagram_shapes[[type]],
                                      ', color="',color,'", fillcolor="',fill,'", label=',.graph_quote(label),"];"))
  }
  edge_lines <- vapply(edge_info,function(edge) {
    if (edge$flow) {
      groups <- sources[[edge$source]]
      colors <- if (length(groups)) paste(.diagram_stroke[groups],collapse=":") else .diagram_neutral
      attrs <- paste0('color="',colors,'"')
    } else {
      label <- unname(.diagram_context[edge$kind])
      if (is.na(label)) label <- gsub("_"," ",edge$kind,fixed=TRUE)
      attrs <- paste0('style=dashed, constraint=false, color="',.diagram_neutral,'", label=',.graph_quote(label))
    }
    paste0("  ",.graph_quote(edge$source)," -> ",.graph_quote(edge$target)," [",attrs,"];")
  },character(1))

  snapshot <- report$snapshot
  scope <- if (is.null(report$ref)) "Project page (on-page links only)" else
    paste0(if (report$direction=="upstream") "Upstream" else "Downstream",
           " of ",.result_id(report$ref)," (depth ",report$depth,")")
  flags <- if (length(report$truncation)) paste(unlist(report$truncation),collapse=", ") else "none"
  cycle <- if (omitted_edges) "Detailed view cycle check" else "Visible cycle check"
  header <- c("Recorded lineage",scope,
              "Solid: recorded computational links   |   Dashed: context or unconfirmed links",
              "Declarations do not establish execution or approval.",
              paste0("Omissions: ",flags,"   |   ",cycle,": ",report$cycle))
  if (omitted_edges) header <- c(header,paste0("Revision history omitted (records: ",omitted_nodes,
                                              "; links: ",omitted_edges,"). See detailed view."))
  if (!is.null(report$next_offset)) header <- c(header,paste0("Next page offset: ",report$next_offset))
  if (snapshot$imported) header <- c(header,"Imported records; execution claims unverified")
  if (snapshot$unsaved) header <- c(header,"Includes unsaved edits")
  if (report$cycle=="unknown" || any(vapply(nodes,function(node) !is.null(node$issue),logical(1))))
    header <- c(header,"See detailed graph for unresolved links or view limits.")
  if (any(omissions>0L))
    header <- c(header,paste0("Annotation links omitted: questions ",omissions[["question"]],
                              "; plotting code ",omissions[["code"]]))
  for (i in seq_along(roots)) {
    root <- roots[[i]]
    desc <- if (root %in% ids) paste0(" \u2014 ",.diagram_short(nodes[[root]]$label,72L,nodes[[root]]$label_truncated))
      else " (not in view)"
    header <- c(header,paste0("Source ",i,": ",root,desc))
  }
  lines <- c("digraph biodataledger {",
             paste0('  graph [rankdir=TB, labelloc=t, labeljust=l, bgcolor="white", fontname="Helvetica",',
                    ' fontsize=15, pad=0.24, nodesep=0.32, ranksep=0.60, label=',.graph_quote(paste(header,collapse="\n")),
                    ', project_id=',.graph_quote(snapshot$project_id),
                    ', registry_revision=',.graph_quote(as.character(snapshot$registry_revision)),
                    ', transaction=',.graph_quote(snapshot$last_transaction),'];'),
             '  node [fontname="Helvetica", fontsize=13, style=filled, fontcolor="#0F172A", margin="0.16,0.10", penwidth=1.4];',
             '  edge [fontname="Helvetica", fontsize=10, fontcolor="#475569", arrowsize=0.7, penwidth=1.6];')
  dot <- paste(c(lines,node_lines,notes,edge_lines,note_links,"}",""),collapse="\n")
  if (nchar(dot,type="bytes")>.graph_byte_limit) .fail("Presentation DOT exceeds 128 KiB; request a narrower view")
  dot
}
