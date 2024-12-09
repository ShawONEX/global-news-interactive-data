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


cpi_list <- c(
  "Meat",
  "Fish, seafood and other marine products",
  "Dairy products and eggs",
  "Fresh fruit",
  "Bakery products",
  "Vegetables and vegetable preparations",
  "Coffee",
  "Food purchased from restaurants",
  "Rent",
  "Owned accommodation",
  "Electricity",
  "Water",
  "Natural gas",
  "Fuel oil and other fuels",
  "Internet access services",
  "Telephone services",
  "Pet food and supplies",
  "Furniture",
  "Household appliances",
  "Financial services",
  "Child care services",
  "Household cleaning products",
  "Sporting and exercise equipment",
  "Clothing",
  "Footwear",
  "Clothing accessories, watches and jewellery",
  "Public transportation",
  "Rental of passenger vehicles",
  "Purchase of passenger vehicles",
  "Gasoline",
  "Passenger vehicle parts, maintenance and repairs",
  "Passenger vehicle insurance premiums",
  "Air transportation",
  "Eye care services",
  "Dental care services",
  "Prescribed medicines",
  "Non-prescribed medicines",
  "Home entertainment equipment, parts and services",
  "Travel services",
  "Toiletry items and cosmetics",
  "Digital computing equipment and devices",
  "Toys, games and hobby supplies",
  "Toiletry items and cosmetics",
  "Books and reading material",
  "Tuition fees",
  "Recreational cannabis",
  "Alcoholic beverages",
  "Cigarettes"
)

category_list <- c(
  "All-items",
  "Recreation, education and reading",
  "Alcoholic beverages, tobacco products and recreational cannabis",
  "Food",
  "Shelter",
  "Household operations, furnishings and equipment",
  "Clothing and footwear",
  "Transportation",
  "Health and personal care"
)

geo_list <- c(
  "Canada",
  "Alberta",
  "British Columbia",
  "Manitoba",
  "New Brunswick",
  "Newfoundland and Labrador",
  "Nova Scotia",
  "Ontario",
  "Prince Edward Island",
  "Quebec",
  "Saskatchewan"
)


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

# number of components in the created graph
number_of_components = metadata_graph %>% to_components() %>% length()
# a table to contain the nodes and their main root
node_parents <- tibble()
for (i in 1:number_of_components){
  # iterate over each component of the graph
  component <- metadata_graph %>% filter(group_components()==i)
  # identify the root node in each component
  root<- component %>% activate(nodes) %>%
    filter(centrality_degree(mode = "in") == 0) %>%
    pull(name) %>%
    first()
  # create a column called category that shows the root for each node in the component
  temp_table<- metadata_graph %>% filter(group_components()==i) %>% 
    activate(nodes) %>% 
    as_tibble %>% 
    mutate(category = if_else(name == root, NA, root))
  
  # stack all the nodes and parents
  node_parents <- bind_rows(node_parents, temp_table)

}

node_parents<- node_parents %>% rename(product=name)

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
      product == "Child care services" ~ "Child care",
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
    "./consumer-price-index/data/consumer-price-index.json",
    na = "null",
    pretty = TRUE,
    auto_unbox = TRUE
  )
