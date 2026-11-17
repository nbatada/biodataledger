library(BioDataLedger)

main <- function() {
  root <- tempfile("helper-performance-"); dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  contract <- list(inputs="x", parameters="none", outputs="x",
                   example="check(x)", limitations="synthetic")
  fixture <- function(name) {
    a_root <- file.path(root, paste0(name, "-a")); dir.create(a_root)
    b_root <- file.path(root, paste0(name, "-b")); dir.create(b_root)
    a_root <- normalizePath(a_root); b_root <- normalizePath(b_root)
    source <- file.path(a_root, "helper.R"); writeLines("check <- function(x) x", source)
    a <- ProjectBundle$create("Synthetic source", a_root)
    ref <- a$register_helper("columns", "R", "columns", contract,
                             source=source, function_name="check")
    a$save()
    b <- ProjectBundle$create("Synthetic target", b_root)
    pending <- file.path(b_root, "pending.R"); writeLines("VALUE <- 1", pending)
    b$register_helper("pending", "R", "pending", contract,
                      source=pending, function_name="pending")
    candidate <- b$find_helpers("columns", sources=list(a_root))$helpers[[1L]]
    list(a=a, b=b, candidate=candidate, source_root=a_root,
         registry=file.path(a_root, ".nb_project_bundle", "project.json"),
         snapshot=file.path(a_root, a$get_helper(ref)$code[[1L]]$snapshot))
  }
  failures <- character()
  run_case <- function(name, action) {
    tryCatch({action(); cat(name, "PASS\n")}, error=function(e) {
      failures <<- c(failures, paste(name, conditionMessage(e)))
      cat(name, "FAIL:", conditionMessage(e), "\n")
    })
  }

  run_case("reuse validated indexes", function() {
    x <- fixture("indexes")
    assign(".bdl_performance_index_hits", 0L, .GlobalEnv)
    trace(".index_state", where=asNamespace("BioDataLedger"), print=FALSE,
          tracer=quote(.GlobalEnv$.bdl_performance_index_hits <-
                       .GlobalEnv$.bdl_performance_index_hits + 1L))
    on.exit({untrace(".index_state", where=asNamespace("BioDataLedger"));
             rm(".bdl_performance_index_hits", envir=.GlobalEnv)}, add=TRUE)
    x$b$find_helpers("columns", sources=list(x$source_root))
    discovery <- .GlobalEnv$.bdl_performance_index_hits
    .GlobalEnv$.bdl_performance_index_hits <- 0L
    adopted <- x$b$register_helper_from(x$candidate)
    adoption <- .GlobalEnv$.bdl_performance_index_hits
    stopifnot(discovery == 1L, adoption == 2L,
              identical(x$b$get_helper(adopted)$foreign_refs[[1L]]$ref, x$candidate$ref))
  })

  growth_case <- function(phase) {
    x <- fixture(paste0("growth-", phase))
    env <- environment(x$b$register_helper_from)
    json <- getFromNamespace(".json", "BioDataLedger")
    before_state <- json(get("state", env))
    before_code <- serialize(get("pending_code", env), NULL)
    requested <- numeric(); grew <- FALSE; reads <- 0L
    target <- if (phase == "snapshot") x$snapshot else x$registry
    selected_read <- if (phase == "final_registry") 2L else 1L
    limit <- if (phase == "snapshot") 1024L * 1024L else 20L * 1024L * 1024L
    hook <- function(con, n) {
      if (!is.character(con) || length(con) != 1L) return(invisible(NULL))
      if (identical(con, target)) {
        if (missing(n)) {
          reads <<- reads + 1L
          if (reads == selected_read) {
            grew <<- TRUE
            writeBin(rep(as.raw(120L), limit + 4096L), target)
          }
        } else requested <<- c(requested, n)
      }
    }
    assign(".bdl_performance_read_hook", hook, .GlobalEnv)
    trace("readBin", where=baseenv(), print=FALSE,
          tracer=quote({.GlobalEnv$.bdl_performance_read_hook(con)
                        .GlobalEnv$.bdl_performance_read_hook(con, n)}))
    on.exit({untrace("readBin", where=baseenv());
             rm(".bdl_performance_read_hook", envir=.GlobalEnv)}, add=TRUE)
    error <- try(x$b$register_helper_from(x$candidate), silent=TRUE)
    stopifnot(inherits(error, "try-error"), grew, length(requested) >= 1L,
              identical(json(get("state", env)), before_state),
              identical(serialize(get("pending_code", env), NULL), before_code),
              x$b$status()$unsaved, all(requested <= limit + 1L))
  }
  for (phase in c("initial_registry", "snapshot", "final_registry")) {
    run_case(paste(phase, "growth is bounded and preserves pending edits"),
             function() growth_case(phase))
  }
  if (length(failures)) stop(paste(failures, collapse="\n"))
}

main()
