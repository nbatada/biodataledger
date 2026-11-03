library(BioDataLedger)
root <- tempfile("status-r-"); dir.create(root)
writeLines("payload", file.path(root, "data.txt"))
writeLines("code", file.path(root, "code.R"))
b <- ProjectBundle$create(paste(rep("é", 100), collapse = ""), root)
d <- b$register_data("data.txt", "raw", hash = FALSE)
a <- b$register_analysis("analysis", list(d), code = "code.R", snapshot_code = FALSE)
for (i in seq_len(7)) b$set_current(d, paste0("purpose", i, paste(rep("é", 70), collapse = "")), "test")
b$set_context(list(next_task = paste(rep("é", 200), collapse = "")))
registry <- file.path(root, ".nb_project_bundle", "project.json")
before <- readBin(registry, "raw", n = file.info(registry)$size)
unlink(file.path(root, "data.txt")); unlink(file.path(root, "code.R"))
s <- b$status(check_files = TRUE)
json <- jsonlite::toJSON(s, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE)
stopifnot(nchar(json, type = "bytes") <= 4096L,
          identical(names(s), c("project", "registry_revision", "current", "active_question", "next_task", "missing", "availability_checked", "counts", "unsaved", "truncated", "evidence")),
          s$unsaved, s$truncated$current == 2L, s$truncated$text,
          s$missing$checked == 2L, s$missing$found == 2L,
          all(vapply(s$missing$items, function(x) x$reason == "missing", logical(1))),
          identical(before, readBin(registry, "raw", n = file.info(registry)$size)),
          inherits(try(b$status(FALSE), silent = TRUE), "try-error"))
# Inspection must not hash payloads, including a present file with a stale digest.
writeLines("changed", file.path(root, "data.txt"))
stopifnot(b$status(check_files = TRUE)$missing$found == 1L)
# A large candidate set is inspected only through the first 100 distinct paths.
for (i in seq_len(105)) {
  p <- paste0("data", i, ".txt"); writeLines("x", file.path(root, p)); b$register_data(p, "raw", hash = FALSE); unlink(file.path(root, p))
}
s <- b$status(check_files = TRUE)
stopifnot(s$missing$checked == 100L, s$missing$unchecked == 7L,
          s$missing$found == 99L, length(s$missing$items) <= 5L,
          s$truncated$missing == s$missing$found - length(s$missing$items),
          nchar(jsonlite::toJSON(s, auto_unbox = TRUE, null = "null", digits = 15, force = TRUE), type = "bytes") <= 4096L)
# Cached counts and purpose keys must reflect accepted mutations without file work.
stopifnot(b$status()$counts$data == 106L, b$status()$missing$checked == 0L,
          is.null(b$status()$missing$unchecked), !b$status()$availability_checked)
long_condition <- paste(rep('C', 80L), collapse = '')
design_ref <- b$set_design(long_condition, c('treated'))
scoped <- b$set_data_scope(d, list(condition_values = list('treated')), 'summary check', design_ref)
b$set_current(scoped, 'scope_summary', 'confirmed')
scoped_status <- b$status(purpose = 'scope_summary')
stopifnot(scoped_status$counts$data == 106L, scoped_status$dataset$design$truncated,
          scoped_status$truncated$text, identical(scoped_status$dataset$ref, scoped))
# Nested declarations remain metadata, not vectors to sort or scientific objects.
nested <- list(note=list(values=list(NULL,'é',list(levels=list('a','b')))))
b$register_analysis('nested',list(scoped),params=nested,details=nested)
b$save()
before <- readBin(registry,'raw',n=file.info(registry)$size)
for (args in list(list(),list(purpose='scope_summary'),list(check_files=TRUE))) {
  result <- do.call(b$status,args)
  stopifnot(nchar(jsonlite::toJSON(result,auto_unbox=TRUE,null='null'),type='bytes')<=4096L,
            !result$unsaved,identical(before,readBin(registry,'raw',n=file.info(registry)$size)))
}
