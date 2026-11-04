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
p$set_current(first, "redraw", "synthetic selected input"); p$save()

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
