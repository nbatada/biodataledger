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
}
main()
