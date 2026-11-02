# Synthetic display recipe; no clinical data or scientific inference.
main <- function() {
  labels <- c(library = "Synthetic library QC", genes = "Synthetic genes QC")
  for (name in names(labels)) {
    writeLines(paste0('<svg xmlns="http://www.w3.org/2000/svg" width="240" height="60"><text x="10" y="30">', labels[[name]], '</text></svg>'), paste0(name, ".svg"))
  }
}
# Call main() explicitly only when recreating these synthetic artwork files.
