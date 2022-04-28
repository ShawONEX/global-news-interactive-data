library(dplyr)
library(tidyr)
library(vroom)
library(stringr)
library(janitor)
library(jsonlite)
library(tidygraph)
library(ggraph)
library(purrr)
library(lubridate)

source("consumer-price-index/scripts/cpi_categories.R")

temp <- tempfile(fileext = "zip")
download.file("https://www150.statcan.gc.ca/n1/tbl/csv/18100004-eng.zip", temp)

cpi <- unz(temp, "18100004.csv") %>%
  vroom %>%
  clean_names

metadata <- unz(temp, "18100004_MetaData.csv") %>%
  vroom(skip = 7) %>%
  clean_names %>%
  filter(dimension_id == 2, !is.na(member_id)) %>%
  mutate(member_name = str_remove(member_name, " \\(.+\\)") %>% str_squish) %>%
  select(member_name, member_id, parent_member_id)

unlink(temp)

metadata <- left_join(
  metadata, metadata,
  by = c("parent_member_id" = "member_id")
) %>%
  transmute(to = `member_name.x`, from = `member_name.y`) %>%
  filter(!is.na(from), from != "All-items")

metadata_graph <- as_tbl_graph(metadata)

root <- metadata_graph %>%
  activate(nodes) %>%
  mutate(
    leaf = node_is_leaf(),
    node = map_bfs(node_is_root(), .f = function(node, ...) { node }),
    root = map_bfs(node_is_root(), .f = function(path, ...) { path$node[1] })
  ) %>%
  as_tibble

node_parents <- root %>%
  left_join(root %>% select(node, name), by = c("root" = "node")) %>%
  transmute(product = name.x, category = name.y)

cpi_joined <- cpi %>% 
  select(ref_date, geo, products_and_product_groups, value) %>%
  mutate(latest_date = max(paste0(ref_date, "-01"))) %>%
  filter(interval(paste0(ref_date, "-01"), latest_date) / years(1) <= 10) %>%
  pivot_wider(names_from = "ref_date", values_from = "value") %>%
  mutate(product = str_remove(products_and_product_groups, " \\(.+\\)") %>% str_squish) %>%
  left_join(node_parents) %>% 
  select(geo, product, category, everything()) %>% 
  select(-products_and_product_groups, -latest_date) 

cpi_subset <- cpi_joined %>%
  filter(
    product %in% cpi_list | product %in% category_list,
    geo %in% geo_list,
    !is.na(`2022-01`)
  ) %>%
  mutate(is_category = product %in% category_list) %>%
  select(product, category, geo, is_category, everything()) %>%
  mutate(
    product = case_when(
      product == "All-items" ~ "All items",
      product == "Fresh or frozen poultry" ~ "Poultry",
      product == "Fresh or frozen pork" ~ "Pork",
      product == "Fresh or frozen beef" ~ "Beef",
      product == "Dairy products and eggs" ~ "Dairy and eggs",
      product == "Fresh fruit" ~ "Fruit",
      product == "Vegetables and vegetable preparations" ~ "Vegetables",
      product == "Fish, seafood and other marine products" ~ "Seafood",
      product == "Food purchased from restaurants" ~ "Restaurant food",
      product == "Fuel oil and other fuels" ~ "Fuel oil",
      product == "Internet access services" ~ "Internet access",
      product == "Passenger vehicle insurance premiums" ~ "Car insurance premiums",
      product == "Rental of passenger vehicles" ~ "Car rentals",
      product == "Passenger vehicle parts, maintenance and repairs" ~ "Car parts, maintenance and repairs",
      product == "Purchase of passenger vehicles" ~ "Car purchases",
      product == "Non-prescribed medicines" ~ "Over-the-counter medicines",
      product == "Household cleaning products" ~ "Cleaning products",
      product == "Home entertainment equipment, parts and services" ~ "Home entertainment",
      product == "Digital computing equipment and devices" ~ "Computing equipment and devices",
      product == "Clothing accessories, watches and jewellery" ~ "Accessories, watches and jewellery",
      product == "Books and reading material" ~ "Books",
      product == "Household operations, furnishings and equipment" ~ "Household",
      product == "Alcoholic beverages, tobacco products and recreational cannabis" ~ "Alcohol, tobacco and cannabis",
      product == "Eye care services" ~ "Eye care",
      product == "Dental care services" ~ "Dental care",
      TRUE ~ product
    ),
    category = case_when(
      category == "Household operations, furnishings and equipment" ~ "Household",
      category == "Alcoholic beverages, tobacco products and recreational cannabis" ~ "Alcohol, tobacco and cannabis",
      TRUE ~ category
    )
  )

list(
  data = cpi_subset,
  last_updated = format_ISO8601(now(), usetz = TRUE)
) %>%
  write_json(
    "consumer-price-index/data/consumer-price-index.json",
    na = "null",
    pretty = TRUE,
    auto_unbox = TRUE
  )
