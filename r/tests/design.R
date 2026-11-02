library(BioDataLedger)
root <- tempfile("design-r-"); dir.create(root)
writeLines("data", file.path(root, "data.txt"))
writeLines("figure", file.path(root, "figure.png"))
b <- ProjectBundle$create("Design test", root, purpose = "Compare treated and control")
stopifnot(is.null(b$get_design()), is.null(b$get_levels()), identical(b$get_design_summary(), NULL))
registry <- file.path(root, ".nb_project_bundle", "project.json")
stopifnot(jsonlite::fromJSON(registry)$schema_version == "0.1.0")
raw <- b$register_data("data.txt", "raw")
v1 <- b$set_design("condition", c("control", "treated", "excluded"), c("control", "treated"), "control", "donor", context = list(raw))
stopifnot(v1$id == "DES-001", v1$revision == 1L, b$get_condition() == "condition",
          identical(b$get_levels(), c("control", "treated", "excluded")),
          identical(b$get_selected_levels(), c("control", "treated")))
a <- b$register_analysis("test", list(raw))
f <- b$register_figure("figure.png", "png", analysis = a)
stopifnot(b$get_analysis(a)$design_ref$revision == 1L, b$get_figure(f)$design_ref$revision == 1L,
          length(b$get_design()$context) == 1L, is.null(names(b$get_design()$context)))
metadata <- data.frame(condition = factor(c("treated", "control", NA)), donor = c("d1", "d2", "d3"))
report <- b$check_design_metadata(metadata)
stopifnot(!report$valid, report$row_count == 3L, report$missing_condition_values == 1L,
          identical(unlist(report$observed_levels), c("treated", "control")),
          identical(unlist(report$missing_levels), "excluded"))
mixed <- b$check_design_metadata(list(condition = list("control", NULL, NA_character_), donor = list("d1", Inf, 3)))
stopifnot(!mixed$valid, mixed$missing_condition_values == 2L, mixed$missing_replicate_values == 1L)
stopifnot(inherits(try(b$check_design_metadata(list(condition = list(c("control", "treated")), donor = list("d1"))), silent = TRUE), "try-error"))
before <- b$get_design()
stopifnot(inherits(try(b$set_design("condition", c("control", "treated"), metadata = metadata), silent = TRUE), "try-error"),
          identical(b$get_design(), before))
v2 <- b$set_design("condition", c("control", "treated"), metadata = data.frame(condition = c("control", "treated")))
stopifnot(v2$revision == 2L, b$get_design()$evidence_source == "metadata-verified",
          b$get_design(v1)$ref$revision == 1L, b$get_analysis(a)$design_ref$revision == 1L,
          b$get_figure(f)$design_ref$revision == 1L,
          inherits(try(b$update_record(v1, list(name = "bad"), "reason"), silent = TRUE), "try-error"))
stopifnot(identical(names(b$get_design_summary()), c("condition", "selected_levels", "reference_level", "replicate", "revision", "truncated")),
          grepl("Design revision:  2", b$summary_text(), fixed = TRUE), b$summary()$counts$analysis == 1L)
long <- paste(rep("x", 200), collapse = "")
b$set_design(long, c(long, "other"), reference_level = long)
stopifnot(b$get_design_summary()$truncated, nchar(b$get_design_summary()$condition) == 64L,
          grepl("...", b$summary_text(), fixed = TRUE))
b$save()
reopened <- ProjectBundle$open(root)
persisted <- jsonlite::fromJSON(registry, simplifyVector = FALSE)
figure_record <- Filter(function(r) r$kind == "figure", persisted$records)[[1]]
stopifnot(!"design" %in% names(figure_record))
stopifnot(reopened$get_design()$ref$revision == 3L,
          reopened$get_analysis(a)$design_ref$revision == 1L,
          jsonlite::fromJSON(registry)$schema_version == "0.2.0")
saved <- readBin(registry, "raw", file.info(registry)$size)
text <- rawToChar(saved)
tampered <- sub('"evidence_source":"metadata-verified"', '"evidence_source":"scientist-declared"', text, fixed = TRUE)
stopifnot(!identical(tampered, text))
writeBin(charToRaw(tampered), registry)
stopifnot(inherits(try(ProjectBundle$open(root), silent = TRUE), "try-error"))
writeBin(saved, registry)
