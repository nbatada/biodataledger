library(BioDataLedger)
main <- function() {
  root <- tempfile("graph-")
  dir.create(root)
  on.exit(unlink(root,recursive=TRUE),add=TRUE)
  p <- ProjectBundle$create("Synthetic graph",root)
  writeLines("synthetic",file.path(root,"raw.txt"))
  a <- p$register_data("raw.txt","raw",name='a "quote" \\N')
  b <- p$register_analysis("QC",inputs=list(a))
  writeLines("synthetic",file.path(root,"result.csv"))
  result <- p$register_result("result.csv",b)
  writeLines("<svg/>",file.path(root,"figure.svg"))
  fig <- p$register_figure("figure.svg","umap",analysis=b,figure_sources=list(rendering_inputs=list(result),relationship="declared"))
  d <- p$record_decision("Retained for review","synthetic",list(fig))
  a2 <- p$update_record(a,list(name="New name"),"synthetic edit")
  p$save()
  unlink(file.path(root,c("raw.txt","result.csv","figure.svg")))
  p <- ProjectBundle$open(root)
  graph <- p$export_graph(fig,depth=6L,format="structured")
  kinds <- vapply(graph$nodes,function(x)x$asset_type,character(1))
  types <- vapply(graph$edges,function(x)x$type,character(1))
  stopifnot(setequal(kinds,c("DATA","ANA","RESULT","FIG")),
            setequal(types,c("input_to_analysis","produced_result","analytical_association","rendered_in_figure")),
            all(vapply(graph$nodes,function(x)x$execution$evidence=="unknown",logical(1))),
            identical(p$export_graph(fig),p$export_graph(fig)),
            grepl('a \\"quote\\" \\\\N',p$export_graph(fig),fixed=TRUE))
  page <- p$export_graph(limit=2L,format="structured")
  history <- p$export_graph(filters=list(revision="historical"),format="structured")
  stopifnot(page$truncated,page$next_offset==2L,length(page$nodes)==2L,length(history$nodes)==1L,
            identical(history$nodes[[1L]]$ref,a),
            identical(p$export_graph(d,format="structured")$edges[[1L]]$type,"decision_concerns"),
            identical(p$export_graph(a2,format="structured")$edges[[1L]]$type,"revision_of"))

  writeLines(c("sample,patient", "001,P1"), file.path(root, "samples.csv"))
  samples <- p$register_metadata("samples.csv", "sample_preparation", "sample", authority = "lab", reason = "synthetic")
  writeLines(c("library,sample", "L1,001"), file.path(root, "acquisition.csv"))
  acquisition <- p$register_metadata("acquisition.csv", "acquisition", "library", authority = "instrument", reason = "synthetic",
                                     links = list(list(ref = samples, columns = "sample", target_columns = "sample")))
  writeLines(c("x", "1"), file.path(root, "metadata-raw.csv"))
  raw <- p$register_data("metadata-raw.csv", "input", hash = TRUE)
  bound_data <- p$bind_metadata(raw, list(samples, acquisition), "synthetic data binding")
  analysis <- p$register_analysis("metadata-aware analysis", list(bound_data))
  bound_analysis <- p$bind_metadata(analysis, list(acquisition), "synthetic analysis binding")
  writeLines(c("sample,patient", "001,P2"), file.path(root, "samples-revised.csv"))
  revised_samples <- p$register_metadata("samples-revised.csv", "sample_preparation", "sample", authority = "lab", reason = "correction", ref = samples)
  writeLines(c("library,sample", "L1,001"), file.path(root, "acquisition-revised.csv"))
  revised_acquisition <- p$register_metadata("acquisition-revised.csv", "acquisition", "library", authority = "instrument", reason = "correction", ref = acquisition,
                                             links = list(list(ref = samples, columns = "sample", target_columns = "sample")))
  rebound_analysis <- p$bind_metadata(bound_analysis, list(revised_acquisition), "synthetic binding correction")
  legacy_before <- p$dependencies(bound_analysis, "upstream", depth = 3L)
  p$save()
  metadata_paths <- vapply(list(samples, acquisition, revised_samples, revised_acquisition),
                           function(ref) p$get_data(ref)$path, character(1))
  stopifnot(all(file.exists(metadata_paths)))
  unlink(metadata_paths)
  stopifnot(!any(file.exists(metadata_paths)))
  p <- ProjectBundle$open(root)
  legacy <- p$dependencies(bound_analysis, "upstream", depth = 3L)
  stopifnot(identical(legacy, legacy_before))
  metadata_graph <- p$export_graph(bound_analysis, depth = 5L, format = "structured")
  edge_rows <- vapply(metadata_graph$edges, function(edge) paste(edge$from$id, edge$from$revision, edge$to$id, edge$to$revision, edge$type, edge$basis, edge$source_field, sep = "|"), character(1))
  stopifnot(
    paste(samples$id, samples$revision, acquisition$id, acquisition$revision, "metadata_table_link", "declared", "details.bl_metadata_table.links", sep = "|") %in% edge_rows,
    paste(acquisition$id, acquisition$revision, bound_data$id, bound_data$revision, "metadata_binding", "declared", "details.bl_metadata_bindings.refs", sep = "|") %in% edge_rows,
    paste(acquisition$id, acquisition$revision, bound_analysis$id, bound_analysis$revision, "metadata_binding", "declared", "details.bl_metadata_bindings.refs", sep = "|") %in% edge_rows,
    !paste0(revised_samples$id, "@", revised_samples$revision) %in% vapply(metadata_graph$nodes, function(node) paste0(node$ref$id, "@", node$ref$revision), character(1)),
    !paste0(revised_acquisition$id, "@", revised_acquisition$revision) %in% vapply(metadata_graph$nodes, function(node) paste0(node$ref$id, "@", node$ref$revision), character(1)),
    !paste0(rebound_analysis$id, "@", rebound_analysis$revision) %in% vapply(metadata_graph$nodes, function(node) paste0(node$ref$id, "@", node$ref$revision), character(1)),
    !any(vapply(legacy$edges, function(edge) startsWith(edge$type, "metadata_"), logical(1))))
}
main()
