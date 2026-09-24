library(ggplot2)

# Count ALT alleles in the truth genotypes, not the caller genotypes.
count_dosages <- function(path) {
  connection <- gzfile(path, "rt")
  on.exit(close(connection))
  lines <- readLines(connection)
  records <- strsplit(lines[!startsWith(lines, "#")], "\t")

  dosages <- vapply(records, function(record) {
    gt_index <- match("GT", strsplit(record[9], ":", fixed = TRUE)[[1]])
    genotype <- strsplit(record[10], ":", fixed = TRUE)[[1]][gt_index]
    if (is.na(genotype)) stop("Missing truth genotype in ", path)
    alleles <- strsplit(genotype, "[|/]")[[1]]
    if (length(alleles) != 3L || any(!alleles %in% c("0", "1"))) {
      stop("Expected a complete, biallelic triploid truth genotype in ", path)
    }
    dosage <- sum(alleles == "1")
    if (dosage == 0L) stop("Truth variant has no ALT alleles in ", path)
    as.integer(dosage)
  }, integer(1))

  tabulate(dosages, nbins = 3)
}

callers <- c("dysgu", "cutesv", "sniffles")
analyses <- c("primary", "dup-to-ins")

metrics <- do.call(rbind, lapply(analyses, function(analysis) {
  do.call(rbind, lapply(callers, function(caller) {
    directory <- file.path("results/truvari", caller, analysis)
    tp <- count_dosages(file.path(directory, "tp-base.vcf.gz"))
    fn <- count_dosages(file.path(directory, "fn.vcf.gz"))

    # TP and FN partition the evaluated truth set for each dosage.
    data.frame(
      caller = caller, analysis = analysis, dosage = 1:3,
      TP = tp, FN = fn, recall = ifelse(tp + fn > 0, tp / (tp + fn), NA_real_)
    )
  }))
}))

metrics$caller <- factor(
  metrics$caller,
  levels = callers,
  labels = c("dysgu", "cuteSV", "Sniffles")
)
metrics$dosage <- factor(
  metrics$dosage,
  levels = 1:3,
  labels = c("ALT dosage: 1/3", "ALT dosage: 2/3", "ALT dosage: 3/3")
)

plot_recall <- function(plot_data, colour) {
  ggplot(plot_data, aes(x = recall, y = caller)) +
    geom_segment(
      aes(x = 0, xend = recall, yend = caller),
      linewidth = 0.4, colour = colour
    ) +
    geom_point(size = 3, colour = colour) +
    geom_text(
      aes(label = sprintf("%.1f%%", 100 * recall)),
      nudge_x = 0.05, hjust = 0, size = 3.5
    ) +
    facet_wrap(~dosage, nrow = 1) +
    scale_x_continuous(
      limits = c(0, 1), breaks = c(0, 0.5, 1),
      labels = c("0%", "50%", "100%"),
      # Keep nudged labels visible when recall is close to 100%.
      oob = scales::oob_keep,
      expand = expansion(mult = c(0.02, 0.18))
    ) +
    labs(x = "Recall", y = NULL) +
    theme_minimal(base_size = 12) +
    theme(
      panel.grid.minor = element_blank(),
      panel.spacing.x = grid::unit(4, "lines"),
      axis.title.x = element_text(size = 14, margin = margin(t = 18)),
      axis.text.y = element_text(hjust = 0, margin = margin(r = 12)),
      strip.text = element_text(face = "bold", size = 14),
      plot.title = element_text(face = "bold", hjust = 0.5),
      plot.subtitle = element_text(face = "bold", hjust = 0.5)
    )
}

# Primary matching keeps INS and DUP distinct.
# primary <- subset(metrics, analysis == "primary")
# dot_plot <- plot_recall(primary, "#4B0092")
# print(dot_plot)

# Alternative matching allows DUP and INS to match.
duptoins <- subset(metrics, analysis == "dup-to-ins")
dot_plot_duptoins <- plot_recall(duptoins, "#116070")
print(dot_plot_duptoins)
