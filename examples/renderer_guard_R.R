library(BioDataLedger)

# A new synthetic project; no existing project or image is overwritten.
root <- tempfile("biodataledger-renderer-example-")
dir.create(root)
p <- ProjectBundle$create("Native rendering example", root)
p$require_approved_figures("Retain figures rendered through BioDataLedger")
prepared <- data.frame(sample = c("s1", "s2", "s3"),
                       PC1 = c(-2, 0, 3), PC2 = c(1, -1, 2))
f <- p$render_figure("pca", data = prepared,
                     plot_args = list(x = "PC1", y = "PC2", sample_id = "sample"),
                     name = "Prepared PCA coordinates", format = "pdf",
                     width = 5, height = 3, dpi = 150)
p$save()
print(p$get_figure(f)$details$renderer_receipt)
cat("Project:", root, "\n")
# This observes native rendering; it does not assess the supplied coordinates.
