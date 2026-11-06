args <- commandArgs(TRUE)
library(BioDataLedger, lib.loc = Sys.getenv("BDL_R_LIB"))
p <- ProjectBundle$open(args[2L])
if (args[1L] == "write") {
  before <- p$get_info("F001r1")
  stopifnot(identical(before$presentation_status, "missing"))
  refuse <- function(expr, expected) {
    result <- tryCatch(force(expr), error = conditionMessage)
    stopifnot(is.character(result), grepl(expected, result, ignore.case = TRUE))
  }
  refuse(p$set_presentation("F001r1", "QC-samples", "umap_by_donor", "2026-11-05", reason = "Fixture"), "ASCII")
  refuse(p$set_presentation("F001r1", "QC-samples", "umap-by-donor", "2026-02-29", reason = "Fixture"), "date")
  ref <- p$set_presentation("F001r1", "QC-samples", "umap-by-donor", "2026-11-05",
                            topics = c("QC-filtering", "qc-samples"),
                            questions = c("Quels donneurs sont représentés ?", "Which samples were filtered?"),
                            uses = list(list(kind = "slide", document_id = "deck-2026",
                                             item_id = "slide-qc", title = "Échantillons γδ")),
                            title = "Donor view", reason = "Synthetic labels")
  stopifnot(identical(ref, p$set_presentation(ref, "QC-samples", "umap-by-donor", "2026-11-05",
                                             reason = "Preserve omitted metadata")))
  raw <- p$register_data("samples.csv", "null-path-fixture", hash = TRUE)
  tagged <- p$set_presentation(raw, "CONTROL", "samples", "2026-11-05", reason = "Synthetic labels")
  corrected <- p$update_record(tagged, list(path = NULL, name = "Metadata-only correction"), "Keep file identity")
  stopifnot(identical(p$output_name(corrected)$primary_topic, "CONTROL"),
            identical(p$get_info(corrected)$record$sha256, p$get_info(tagged)$record$sha256),
            identical(p$get_info(corrected)$record$locator, p$get_info(tagged)$record$locator))
  result_rerun <- p$register_result("samples.csv", "ANA-001@1", ref = "DATA-002@2", hash = TRUE)
  refuse(p$output_name(result_rerun), "missing")
  beyond <- p$find_outputs(offset = .Machine$integer.max)
  stopifnot(!length(beyond$items), is.null(beyond$next_offset), beyond$truncated)
  dest <- file.path(args[2L], "copies")
  r_name <- p$output_name(ref)
  target <- file.path(dest, r_name$filename)
  stopifnot(file.symlink("missing", target))
  refuse(p$export_named_output(ref, dest), "exists")
  stopifnot(Sys.readlink(target) == "missing")
  unlink(target)
  p$save()
  exported <- p$export_named_output(ref, dest)
  refuse(p$export_named_output(ref, dest), "exists")
  source <- p$get_figure(ref)$path
  writeLines("<svg>tampered</svg>", source, useBytes = TRUE)
  refuse(p$export_named_output(ref, args[2L]), "DIGEST_MISMATCH")
  writeChar("<svg>original</svg>", source, eos = NULL, useBytes = TRUE)
  stopifnot(identical(list.files(dest, all.files = TRUE, no.. = TRUE), r_name$filename))
  out <- list(ref = ref, python_name = p$output_name("D002r2"), r_name = r_name,
              r_info = p$get_info(ref), analysis_info = p$get_info("A001r1", limit = 1L, offset = 1L),
              large_info = p$get_info("A002r1"),
              qc = p$find_outputs(topic = "qc", historical = TRUE),
              by_question = p$find_outputs(question = "DIVERSITÉ γδ", document_id = "deck-2026"),
              export = exported)
} else {
  out <- list(latest = p$output_name("F001r3"), older = p$output_name("F001r2"),
              clonality = p$find_outputs(topic = "clonality"))
}
cat(BioDataLedger:::.json(out))
