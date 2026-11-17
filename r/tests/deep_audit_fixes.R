library(BioDataLedger)
fail <- function(expr) stopifnot(inherits(try(force(expr), silent = TRUE), "try-error"))
root <- tempfile("deep-audit-"); dir.create(root); on.exit(unlink(root, recursive = TRUE), add = TRUE)
writeLines("input", file.path(root, "input.txt")); writeLines("old", file.path(root, "old.R")); writeLines("new", file.path(root, "new.R")); writeLines("missing", file.path(root, "missing.R")); writeLines("<svg/>", file.path(root, "figure.svg"))
p <- ProjectBundle$create("deep audit", root)
d <- p$register_data("input.txt", "input")
a <- p$register_analysis("analysis", list(d), code = "old.R")
p$save()
digest <- digest::digest(file.path(root, "new.R"), algo = "sha256", serialize = FALSE, file = TRUE)
code <- list(list(locator = list(kind = "project", value = "new.R"), sha256 = digest, snapshot = paste0(".nb_project_bundle/code/", digest)))
updated <- p$update_record(a, list(code = code), "replace captured source")
p$save(); stopifnot(file.exists(file.path(root, code[[1]]$snapshot)), identical(ProjectBundle$open(root)$get_analysis(updated)$code[[1]]$snapshot, code[[1]]$snapshot))
bad <- code; bad[[1]]$snapshot <- ".nb_project_bundle/code/not-the-digest"
fail(p$update_record(updated, list(code = bad), "reject noncanonical snapshot"))
bad <- code; bad[[1]]$sha256 <- NULL; bad[[1]]$snapshot <- ".nb_project_bundle/code/"
fail(p$update_record(updated, list(code = bad), "reject missing snapshot digest"))
missing_digest <- digest::digest(file.path(root, "missing.R"), algo = "sha256", serialize = FALSE, file = TRUE)
missing_code <- list(list(locator = list(kind = "project", value = "missing.R"), sha256 = missing_digest, snapshot = paste0(".nb_project_bundle/code/", missing_digest)))
unlink(file.path(root, "missing.R")); before <- p$status()$unsaved
fail(p$update_record(updated, list(code = missing_code), "reject missing source atomically")); stopifnot(identical(p$status()$unsaved, before))
for (i in seq_len(25L)) p$register_figure("figure.svg", "plot", name = paste0("panel ", i))
legacy <- p$find_figures("panel"); first <- p$find_figures("panel", limit = 20L); second <- p$find_figures("panel", limit = 20L, offset = first$next_offset)
stopifnot(length(legacy) == 25L, first$matched == 25L, first$returned == 20L, first$omitted == 5L, isTRUE(first$truncated), is.null(second$next_offset),
          isTRUE(all.equal(unname(lapply(c(first$items, second$items), `[[`, "ref")), unname(lapply(legacy, `[[`, "ref")), check.attributes = FALSE)), nchar(BioDataLedger:::.json(second), type = "bytes") <= 4096L)
fail(p$find_figures(offset = 1L))
for (i in seq_len(25L)) p$register_figure("figure.svg", paste(rep("é", 200L), collapse = ""), name = paste0(paste(rep("γ", 200L), collapse = ""), i))
seen <- list(); offset <- 0L
repeat {
  page <- p$find_figures(limit = 20L, offset = offset)
  stopifnot(nchar(BioDataLedger:::.json(page), type = "bytes") <= 4096L)
  seen <- c(seen, page$items)
  if (is.null(page$next_offset)) break
  offset <- page$next_offset
}
stopifnot(length(seen) == 50L)
cat("PASS: deep-audit snapshot and compact figure regressions\n")

# A growing source is rejected before staging; unrelated pending edits survive.
growth_source <- file.path(root, "growing.R"); writeLines("x <- 1", growth_source)
state_env <- environment(p$status)
before_state <- BioDataLedger:::.json(get("state", state_env))
before_pending <- serialize(get("pending_code", state_env), NULL)
grew <- FALSE; requested <- numeric()
hook <- function(con, n) {
  if (!is.character(con) || length(con) != 1L || !identical(con, normalizePath(growth_source))) return(invisible(NULL))
  if (missing(n) && !grew) {writeBin(rep(as.raw(120), 1048576L + 4096L), growth_source); grew <<- TRUE}
  else if (!missing(n)) requested <<- c(requested, n)
}
assign(".bdl_deep_growth_hook", hook, .GlobalEnv)
trace("readBin", where = baseenv(), print = FALSE,
      tracer = quote({.GlobalEnv$.bdl_deep_growth_hook(con); .GlobalEnv$.bdl_deep_growth_hook(con, n)}))
failure <- try(p$register_analysis("growing source", list(d), code = growth_source), silent=TRUE)
untrace("readBin", where=baseenv()); rm(".bdl_deep_growth_hook", envir=.GlobalEnv)
stopifnot(inherits(failure, "try-error"), grew, length(requested) > 0L, all(requested <= 1048577L),
          identical(BioDataLedger:::.json(get("state", state_env)), before_state),
          identical(serialize(get("pending_code", state_env), NULL), before_pending))
cat("PASS: ordinary code growth is bounded and preserves pending work\n")
