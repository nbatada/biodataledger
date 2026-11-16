\name{continuous_metadata}
\alias{continuous_metadata}
\title{Continuous metadata tables}
\description{Versioned CSV or TSV metadata tables retained as exact DATA references.}
\details{A bundle provides \code{register_metadata(path, category, key_columns, authority, reason, ref = NULL, links = NULL, required_columns = NULL, units = NULL, name = NULL, delimiter = ",")}, \code{get_metadata(ref, limit = 20, offset = 0)}, \code{bind_metadata(ref, metadata_refs, reason)}, \code{metadata_view(ref)}, and \code{check_metadata(ref, required_categories = NULL)}. The six categories are sample_preparation, acquisition, processing_qc, analysis, annotation, and result. BioDataLedger-generated metadata output fields use the \code{bl_} namespace; CSV row names, units-map keys, link declaration keys, and exact reference members remain unchanged. Registration copies source bytes to a managed location and preserves all CSV text, including leading zeroes and literal NA. Views do not read table payloads. Checks validate file and table structure only; they do not establish row alignment, scientific acceptance, or biological correctness.}

\examples{
root <- tempfile("metadata-example-")
dir.create(root)
writeLines(c("sample_id,treatment", "001,control"), file.path(root, "samples.csv"))
p <- ProjectBundle$create("Synthetic samples", root)
samples <- p$register_metadata("samples.csv", "sample_preparation", "sample_id",
  authority = "Synthetic sample sheet", reason = "Record before sequencing")
p$save()
p$metadata_view(samples)
p$check_metadata(samples)
}
