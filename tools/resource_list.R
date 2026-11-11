# Writes the resource lists on the home page from resources.csv:
# one section per `section`, one bullet per row.

format_extra <- function(label, urls) {
  if (is.na(label) || is.na(urls)) {
    return("")
  }
  url_list <- strsplit(urls, " ", fixed = TRUE)[[1]]
  links <- paste0("<", url_list, ">", collapse = ", ")
  paste0("\n  - ", label, ": ", links)
}

format_resource <- function(resource) {
  if (!is.na(resource$citekey)) {
    return(paste0("- @", resource$citekey))
  }
  link <- paste0("<", resource$url, ">")
  if (!is.na(resource$title)) {
    link <- paste0("[", resource$title, "](", resource$url, ")")
  }
  blurb <- ""
  if (!is.na(resource$description)) {
    blurb <- paste0(": ", resource$description)
  }
  extra <- format_extra(resource$extra_label, resource$extra_urls)
  paste0("- ", link, blurb, extra)
}

format_subgroup <- function(resources) {
  rows <- split(resources, seq_len(nrow(resources)))
  bullets <- vapply(rows, format_resource, character(1))
  heading <- character(0)
  if (!is.na(resources$subgroup[1])) {
    heading <- paste0(resources$subgroup[1], ":\n")
  }
  c(heading, bullets, "")
}

format_section <- function(resources) {
  subgroup <- resources$subgroup
  subgroup[is.na(subgroup)] <- ""
  groups <- split(resources, factor(subgroup, levels = unique(subgroup)))
  lines <- lapply(groups, format_subgroup)
  c(paste0("## ", resources$section[1], "\n"), unlist(lines))
}

write_resource_lists <- function(path = "resources.csv") {
  resources <- utils::read.csv(path, na.strings = "", encoding = "UTF-8")
  section <- factor(resources$section, levels = unique(resources$section))
  sections <- split(resources, section)
  lines <- lapply(sections, format_section)
  cat(unlist(lines), sep = "\n")
}
