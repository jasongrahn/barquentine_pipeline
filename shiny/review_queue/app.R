# global.R is auto-sourced by runApp(dir) but not runApp(file).
# This guard makes both invocation styles work and recovers from stale session state.
if (!exists("PROJECT_ROOT")) {
  .wd <- normalizePath(getwd())
  PROJECT_ROOT <- if (dir.exists(file.path(.wd, "R")) && dir.exists(file.path(.wd, "shiny"))) .wd else normalizePath(file.path(.wd, "../.."))
  setwd(PROJECT_ROOT)
  source("shiny/review_queue/global.R")
}

ui <- fluidPage(
  useShinyjs(),
  tags$head(tags$style(HTML("
    body { font-size: 14px; }
    .sidebar-panel { padding-top: 8px; }
    .action-bar .btn { margin-right: 6px; margin-bottom: 6px; }
    .verdict-approved  { color: #28a745; font-weight: bold; }
    .verdict-flagged   { color: #fd7e14; font-weight: bold; }
    .verdict-rejected  { color: #dc3545; font-weight: bold; }
    .verdict-escalated { color: #6f42c1; font-weight: bold; }
    details > summary { list-style: none; }
    details > summary::-webkit-details-marker { display: none; }
    mark { background: #fff3cd; padding: 0 1px; border-radius: 2px; }
    .confidence-bar {
      height: 6px; border-radius: 3px; background: #e9ecef; margin-top: 4px;
    }
    .conf-approved { color: #28a745; font-weight: bold; }
    .conf-warn     { color: #fd7e14; font-weight: bold; }
    .conf-danger   { color: #dc3545; font-weight: bold; }
  "))),

  titlePanel("Barquentine \u2014 Entity Review Queue"),

  sidebarLayout(
    sidebarPanel(
      width = 3,
      class = "sidebar-panel",

      fluidRow(
        column(6, actionButton("refresh_btn", "Refresh", class = "btn-sm btn-outline-secondary",
                               icon = icon("sync"), width = "100%")),
        column(6, tags$div(style = "padding-top:4px;",
                           textOutput("progress_text")))
      ),
      tags$div(id = "progress_bar_container",
        style = "height:6px;background:#e9ecef;border-radius:3px;margin:6px 0 10px;",
        tags$div(id = "progress_bar_fill",
                 style = "height:6px;background:#28a745;border-radius:3px;width:0%;")
      ),
      textInput("search_box", label = NULL, placeholder = "\U1F50D Search entities\u2026",
                width = "100%"),
      hr(style = "margin:6px 0;"),
      uiOutput("sidebar_content"),
      hr(style = "margin:8px 0;"),
      uiOutput("action_log_ui")
    ),

    mainPanel(
      width = 9,
      uiOutput("entity_panel")
    )
  )
)

source(file.path(PROJECT_ROOT, "shiny/review_queue/R/server.R"))

shinyApp(ui, server)
