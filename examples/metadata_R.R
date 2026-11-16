# Synthetic continuous metadata lifecycle; creates a new directory only.
main <- function(root) {
  if (dir.exists(root) || file.exists(root) || !dir.exists(dirname(root))) stop("Choose a new directory in an existing parent")
  if (!dir.create(root)) stop("Cannot create example directory")
  root <- normalizePath(root)
  p <- BioDataLedger::ProjectBundle$create("Synthetic metadata lifecycle", root)
  table <- function(filename, text, category, keys, links = NULL, ref = NULL, units = NULL) {
    writeLines(text, file.path(root, filename), useBytes = TRUE)
    p$register_metadata(filename, category, keys,
      authority = "Synthetic example: supplied fixture, not biological evidence",
      reason = "Demonstrate continuous metadata history", links = links, ref = ref, units = units)
  }
  link <- function(ref, columns, targets = columns) list(ref = ref, columns = columns, target_columns = targets)
  samples <- table("samples.csv", "sample_id,donor_id,treatment,tissue\n001,D01,control,tissue_A\n002,D02,treated,tissue_A",
                   "sample_preparation", "sample_id")
  p$set_current(samples, "sample_sheet", "Select the synthetic sample sheet")
  acquisition <- table("libraries.csv", "library_id,sample_id,rna_input\nL1,001,3\nPOOL,001,1.5\nPOOL,002,1.5",
                       "acquisition", c("library_id", "sample_id"), list(link(samples, "sample_id")), units = list(rna_input = "ng"))
  qc <- table("qc.csv", "sample_id,cell_id,library_id,included,reason\n001,C1,L1,true,\n001,C2,POOL,false,no paired receptor\n002,C1,POOL,true,",
              "processing_qc", c("sample_id", "cell_id"), list(link(acquisition, c("library_id", "sample_id"))))
  writeLines("sample_id,cell_id,value\n001,C1,1\n002,C1,2", file.path(root, "analysis_ready.csv"))
  data <- p$register_data("analysis_ready.csv", "analysis_ready", hash = TRUE)
  data <- p$bind_metadata(data, list(qc), "Context for the retained synthetic subset")
  analysis <- p$register_analysis("Synthetic assignment example", list(data),
    method = "Supplied illustrative assignments; no clustering was executed",
    params = list(illustrative_resolution = 0.4))
  clusters <- table("clusters.csv", "sample_id,cell_id,cluster,resolution\n001,C1,0,0.4\n002,C1,1,0.4",
                    "analysis", c("sample_id", "cell_id"), list(link(qc, c("sample_id", "cell_id"))))
  labels <- table("labels.csv", "sample_id,cell_id,label\n001,C1,population A\n002,C1,provisional B",
                  "annotation", c("sample_id", "cell_id"), list(link(clusters, c("sample_id", "cell_id"))))
  previous_analysis <- p$bind_metadata(analysis, list(labels), "Original illustrative annotation")
  revised_labels <- table("labels_corrected.csv", "sample_id,cell_id,label\n001,C1,population A\n002,C1,population B",
                          "annotation", c("sample_id", "cell_id"), list(link(clusters, c("sample_id", "cell_id"))), ref = labels)
  current_analysis <- p$bind_metadata(previous_analysis, list(revised_labels), "Illustrate an annotation correction")
  result_metadata <- table("result_meaning.csv", "measure,observation_unit,denominator,summary\nretained_count,cells,eligible cells,count",
                           "result", "measure")
  writeLines("measure,value\nretained_count,2", file.path(root, "result.csv"))
  result <- p$register_result("result.csv", current_analysis, hash = TRUE)
  result <- p$bind_metadata(result, list(result_metadata), "Meaning of the retained quantity")
  p$save_and_confirm()
  q <- BioDataLedger::ProjectBundle$open(root)
  report <- q$check_metadata(result, required_categories = c("sample_preparation", "acquisition", "processing_qc", "analysis", "annotation", "result"))
  stopifnot(report$bl_status == "PASS",
            q$get_metadata(labels)$bl_rows[[2L]]$label == "provisional B",
            q$get_metadata(revised_labels)$bl_rows[[2L]]$label == "population B",
            identical(q$metadata_view(previous_analysis)$bl_categories$annotation[[1L]]$bl_ref, labels),
            q$get_metadata(qc)$bl_row_count == 3L)
  receipt <- list(project = root, samples = samples, result = result, previous_analysis = previous_analysis,
                  current_analysis = current_analysis, metadata_check = report, scientific_acceptance = "not_assessed")
  json <- jsonlite::toJSON(receipt, auto_unbox = TRUE, null = "null", pretty = TRUE, force = TRUE)
  writeLines(json, file.path(root, "metadata_example_receipt.json"))
  cat(json, "\n")
}
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 1L) stop("Usage: Rscript examples/metadata_R.R NEW_PROJECT_DIR")
main(args[[1L]])
