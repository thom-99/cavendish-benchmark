library(ggplot2)

# Primary matching keeps INS and DUP distinct.

metrics <- read.delim("results/report/metrics.tsv")
primary <- subset(metrics, analysis == "primary")

plot_data <- rbind(
  data.frame(caller = primary$caller, metric = "Precision", value = primary$precision),
  data.frame(caller = primary$caller, metric = "Recall", value = primary$recall)
)

plot_data$caller <- factor(
  plot_data$caller,
  levels = c("dysgu", "cutesv", "sniffles"),
  labels = c("dysgu", "cuteSV", "Sniffles")
)

dot_plot <- ggplot(plot_data, aes(x = value, y = caller)) +
  geom_segment(
    aes(x = 0, xend = value, yend = caller),
    linewidth = 0.4, colour = "#4B0092"
  ) +
  geom_point(size = 3, colour = "#4B0092") +
  geom_text(
    aes(label = sprintf("%.1f%%", 100 * value)),
    nudge_x = 0.05, hjust = 0, size = 3.5
  ) +
  facet_wrap(~metric, nrow = 1) +
  scale_x_continuous(
    limits = c(0, 1), breaks = c(0, 0.5, 1),
    labels = c("0%", "50%", "100%"),
    expand = expansion(mult = c(0.02, 0.18))
  ) +
  labs(
    x = NULL, y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    panel.spacing.x = grid::unit(4, "lines"),
    axis.text.y = element_text(hjust = 0, margin = margin(r = 12)),
    strip.text = element_text(face = "bold"),
    plot.title = element_text(face = "bold", hjust = 0.5),
    plot.subtitle = element_text(hjust = 0.5)
  )

print(dot_plot)


# ALTERNATIVE PLOT, DUP and INS count as general sequence gain

duptoins <- subset(metrics, analysis == "dup-to-ins")

plot_data_duptoins <- rbind(
  data.frame(caller = duptoins$caller, metric = "Precision", value = duptoins$precision),
  data.frame(caller = duptoins$caller, metric = "Recall", value = duptoins$recall)
)
plot_data_duptoins$caller <- factor(
  plot_data_duptoins$caller,
  levels = c("dysgu", "cutesv", "sniffles"),
  labels = c("dysgu", "cuteSV", "Sniffles")
)

dot_plot_duptoins <- ggplot(plot_data_duptoins, aes(x = value, y = caller)) +
  geom_segment(
    aes(x = 0, xend = value, yend = caller),
    linewidth = 0.4, colour = "#156f15"
  ) +
  geom_point(size = 3, colour = "#156f15") +
  geom_text(
    aes(label = sprintf("%.1f%%", 100 * value)),
    nudge_x = 0.05, hjust = 0, size = 3.5
  ) +
  facet_wrap(~metric, nrow = 1) +
  scale_x_continuous(
    limits = c(0, 1), breaks = c(0, 0.5, 1),
    labels = c("0%", "50%", "100%"),
    expand = expansion(mult = c(0.02, 0.18))
  ) +
  labs(
    x = NULL, y = NULL
  ) +
  theme_minimal(base_size = 12) +
  theme(
    panel.grid.minor = element_blank(),
    panel.spacing.x = grid::unit(4, "lines"),
    axis.text.y = element_text(hjust = 0, margin = margin(r = 12)),
    strip.text = element_text(face = "bold"),
    plot.title = element_text(face = "bold", hjust = 0.5),
    plot.subtitle = element_text(hjust = 0.5)
  )

print(dot_plot_duptoins)
