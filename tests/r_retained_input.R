library(BioDataLedger)

example_path <- file.path(Sys.getenv("BDL_REPO_ROOT"), "examples", "retained_input.R")
stopifnot(nzchar(Sys.getenv("BDL_REPO_ROOT")), file.exists(example_path))
helpers <- new.env(parent = globalenv())
sys.source(example_path, envir = helpers)
stopifnot(length(ls(helpers)) == 3L)

root <- tempfile("retained-input-"); dir.create(root)
on.exit(unlink(root, recursive = TRUE), add = TRUE)
writeLines("first", file.path(root, "first.csv")); writeLines("second", file.path(root, "second.csv"))
writeLines("<svg/>", file.path(root, "plot.svg")); writeLines("# declared", file.path(root, "redraw.R"))
p <- ProjectBundle$create("synthetic retained input", root)
first <- p$register_data("first.csv", "input", hash = TRUE); second <- p$register_data("second.csv", "input", hash = TRUE)
selected <- p$set_current(first, "redraw", "synthetic selected input")
decision <- p$record_scientific_decision("Toy convention", "Synthetic context",
  subjects = list(list(ref = first)), scientific_status = "provisional")
saved <- p$save_and_confirm()

bare_id_error <- tryCatch(p$get_data(ref = first$id), error = conditionMessage)
stopifnot(grepl("Exact revision required: use ID@revision", bare_id_error, fixed = TRUE),
          identical(p$get_data(ref = paste0(first$id, "@", first$revision))$ref, first))

registry <- file.path(root, ".nb_project_bundle", "project.json")
before <- list(summary = p$summary(), bytes = readBin(registry, "raw", file.info(registry)$size))
output <- file.path(root, "retained.txt")
invalid_input_error <- tryCatch({
  selected_data <- p$resolve_data(ref = first, verify = "sha256")
  analysis <- p$register_analysis("Invalid inputs", list(selected_data$ref, decision), code = "redraw.R")
  writeLines(readLines(selected_data$path), output)
}, error = conditionMessage)
stopifnot(grepl("Analysis inputs must be data", invalid_input_error, fixed = TRUE),
          !file.exists(output), identical(before$summary, p$summary()),
          identical(before$bytes, readBin(registry, "raw", file.info(registry)$size)))

loaded <- helpers$load_retained_input(p, function(path) readLines(path), purpose = "redraw")
p$set_current(second, "redraw", "synthetic later choice")
kept <- helpers$register_redraw(p, loaded$source, "synthetic redraw", "plot.svg", "plot", "redraw.R", "synthetic", list(example = TRUE))
stopifnot(identical(loaded$object, "first"), identical(kept$source$ref, first), identical(p$get_analysis(kept$analysis)$inputs, list(first)))
figure <- p$get_figure(kept$figure)
stopifnot(identical(figure$rendering_inputs, list(first)), identical(figure$rendering_relationship, "declared"))

touched <- character()
chosen <- helpers$load_selected_redraw_input(p, list(first = list(ref = first), second = list(ref = second)), "second",
  function(path) { touched <<- c(touched, basename(path)); readLines(path) })
stopifnot(identical(chosen$object, "second"), identical(chosen$source$ref, second), identical(touched, "second.csv"))

called <- FALSE; loader <- function(path) { called <<- TRUE; readLines(path) }
stopifnot(inherits(try(helpers$load_retained_input(p, loader), silent = TRUE), "try-error"),
          inherits(try(helpers$load_retained_input(p, loader, first, "redraw"), silent = TRUE), "try-error"))
unlink(file.path(root, "first.csv"))
stopifnot(inherits(try(helpers$load_retained_input(p, loader, ref = first), silent = TRUE), "try-error"), !called)
