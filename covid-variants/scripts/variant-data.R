options(scipen = 999)
Sys.setenv(TZ = "America/Toronto")

library(dplyr)
library(tidyr)
library(readr)
library(janitor)
library(stringr)
library(lubridate)
library(scales)
library(ggplot2)
library(RColorBrewer)
library(jsonlite)
library(purrr)

cutoff_week <- "2020-03-01"
output_data_file <- "covid-variants/data/covid-19-variants-canada.json"

# PHAC variant prevalence data
variant_data_original <- read_csv(
  "https://health-infobase.canada.ca/src/data/covidLive/covid19-epiSummary-variants.csv"
) %>% clean_names

# PHAC variant sample size data
variant_sample_size <- read_csv(
  "https://health-infobase.canada.ca/src/data/covidLive/covid19-epiSummary-variants-sampleSize.csv"
) %>% 
  clean_names %>% 
  rename(week = collection_date, n_samples = count_of_sample_number)

data_max_week <- max(variant_data_original$collection_week)
sample_max_week <- max(variant_sample_size$week)
current_data_max_week <- read_json(output_data_file) %>%
  pluck("data", length(.$data), "week")

# Only proceed if the two datasets have the same date range
# and the latest date is more recent than the current data
dataset_date_match <- data_max_week == sample_max_week
new_date_update <- data_max_week > current_data_max_week

if (dataset_date_match & new_date_update) {
  variant_data <- variant_data_original %>% 

    # Keep variants of concern as individual categories, 
    # group variants of interest into a single category,
    # and collapse everything else into "other"
    mutate(variant_group = case_when(
      variant_grouping == "Omicron" ~ str_remove(identifier, "\\.") %>%
                                        str_remove(" Omicron") %>%
                                        paste("omicron", ., sep = "_") %>%
                                        tolower,
      variant_grouping %in% c("Alpha", "Beta", "Gamma", "Delta") ~ tolower(identifier),
      TRUE ~ "other"
    )) %>% 
    group_by(week = collection_week, variant_group) %>% 
    summarize(percent = sum(percent_ct_count_of_sample_number)) %>% 

    # Weekly percentages don't always total exactly 100 — this step normalizes them
    mutate(percent_normalized = round(percent / sum(percent), digits = 3)) %>% 
    filter(week >= cutoff_week)

  # Format and write the JSON data
  variant_data_output <- variant_data %>% 
    select(-percent) %>% 
    pivot_wider(
      names_from = variant_group, 
      values_from = percent_normalized, 
      values_fill = 0
    ) %>% 
    ungroup %>% 
    left_join(variant_sample_size, by = "week") %>% 
    select(week, n_samples, everything()) 

  list(
    data = variant_data_output,
    last_updated = format_ISO8601(now(), usetz = TRUE)
  ) %>% write_json(
    output_data_file, 
    pretty = TRUE,
    auto_unbox = TRUE
  )

  # Save a chart
  variant_chart <- variant_data %>% 
    filter(!str_detect(variant_group, "other")) %>% 
    ggplot(aes(
      x = week, 
      y = percent_normalized, 
      group = variant_group, 
      fill = variant_group
    )) + 
    geom_col() + 
    scale_fill_manual(values = brewer.pal(9, "Purples")[1:9]) + 
    theme_minimal() +
    scale_y_continuous(labels = percent) +
    labs(
      title = "COVID-19 Variant Prevalence, Canada",
      x = "", y = "", 
      fill = "Variant",
      caption = paste0(
        "Source: Public Health Agency of Canada\nLast updated: ",
        format(now(), "%B %d, %Y at %I:%M %p %Z")
    ))

  variant_chart %>% 
    ggsave("covid-variants/charts/covid-19-variants-canada.png", ., device = "png", width = 8, height = 5)
 }
