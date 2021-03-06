# required packages                                                                                  
library(tidyverse)
library(shiny)                                                                                    
library(shinythemes)                                                                                 
library(RColorBrewer)                                                                                
library(leaflet)                                                                                 
library(plotly)

# Load Data ---------------------------------------------------------------

# Get what is in the 'Data' directory
city_list <- list.files(path = "Data/") %>% 
    grep(pattern = "*\\.csv$", value = TRUE) %>% 
    gsub(pattern = "*\\.csv$", replacement = "")

# Combine all data frames into a list
cities <- list.files(path = "Data", pattern = "\\.csv$", full.names = TRUE) %>% 
    lapply(FUN = read.csv, stringsAsFactors = FALSE)
# Assign names
names(cities) <- toupper(city_list)


# Helper Function ---------------------------------------------------------

# Set main color for room type
room_cols <- brewer.pal(3, "Set1")

# For Leaflet's markers color
pal <- colorFactor(room_cols, domain = cities[[1]]$room_type %>% unique())

# Modify ggplot theme
old <- theme_set(theme_light() + 
                     theme(legend.position = "none", 
                           axis.title = element_text(family = "Menlo", colour = "navyblue"),
                           axis.text = element_text(family = "Menlo")
                           ))

# UI ----------------------------------------------------------------------

ui <- fillPage(
    
    # Custom CSS goes here
    tags$head(
        tags$style(HTML("
                body {
                    overflow: auto;
                }
                .leaflet-control.legend {
                    font-family: 'Futura', mono, sans;
                    width: 12em;
                    margin-right: 20px;
                }
            "))
    ),
    
    # Theme selection
    theme = shinythemes::shinytheme("yeti"),
    
    fluidPage(
        # Upper half
        leafletOutput("map", height = 400, width = "100%"),
        hr(),
        uiOutput("h4"),
        fluidRow(
                # Lower half
                column(width = 2,
                             selectInput("city", label = "Select A City", choices = c("", toupper(city_list))),
                             selectInput("area", label = "Filter By Area", character(0)),
                             verbatimTextOutput("roomInBounds")),
                column(width = 10,
                          column(6, plotlyOutput("price")),
                          column(6, plotlyOutput("host"))
                )
            ),
        hr(),
        span(icon("github"), a("Source Code", href = "https://github.com/tmasjc/Airbnb_Market_Data"))
        )
)


# Server ------------------------------------------------------------------

server <- function(input, output, session){
    
    # Select a city from a list of cities
    selected_city <- reactive({
        req(input$city)
        cities[[input$city]]
    })
    
    # Text for the main header
    output$h4 <- renderUI({
        text <- ifelse(isTruthy(input$city), input$city, "Select A City To Get Started.")
        h4(paste("Hello,", text), style = "text-align: center;")
    })
    
    # Geography concentration goes here
    output$map <- renderLeaflet({
        
        # Create a base map
        selected_city() %>% 
            leaflet() %>% 
            addProviderTiles(providers$CartoDB.Positron) %>% 
            # customise viewport to fit
            fitBounds(lng1 = ~min(longitude), 
                      lat1 = ~min(latitude), 
                      lng2 = ~max(longitude), 
                      lat2 = ~max(latitude)) %>% 
            addLegend("bottomleft", pal = pal, values = ~ room_type, title = "Room Type") %>% 
            # For resetting zoom
            addEasyButton(
                easyButton("fa-arrows-alt", title = "Reset Zoom", 
                           onClick = JS("function(btn, map){ map.setZoom(11); }"))
            )
    })
    
    # Sublevel of city
    area <- reactive({ 
        # some cities have a larger subcity cluster called neightbourhood_group
        if(sum(is.na(selected_city()[["neighbourhood_group"]] > 100))){
            unique(selected_city()[["neighbourhood"]])
        }else{
            unique(selected_city()[["neighbourhood_group"]])
        }
    })
    
    # Generate neighbourhood selection based on selected area (dynamic UI)
    observe({
        updateSelectInput(session, "area", choices = c("", area()))
    })
    
    # A subset of city data frame based on selected area
    area_df <- reactive({
        req(input$area)
        # depends on data available
        selected_city() %>% filter(neighbourhood == input$area |
                                       neighbourhood_group == input$area)
        
    })
    
    # Prepare neighbourhood bounding lng and lat for Leaflet proxy
    bounds <- reactive({
        list(
            lng = range(area_df()$longitude),
            lat = range(area_df()$latitude)
        )
    })
    
    # Update data points within current bounding box
    bounded_area <- reactive({
        
        req(input$map_bounds, cancelOutput = TRUE)
        
        # Get map boundary from Leaflet
        bounds <- input$map_bounds
        latRng <- range(bounds$north, bounds$south)
        lngRng <- range(bounds$east, bounds$west)
        
        # Filter area given boundary
        subset(area_df(), 
               latitude >= latRng[1] & 
                   latitude <= latRng[2] & 
                   longitude >= lngRng[1] & 
                   longitude <= lngRng[2])
        
    })
    
    # Leaflet proxy to modify map aspect (add markers here)
    observeEvent(input$area, {
        leafletProxy("map", data = area_df()) %>% 
            clearMarkers() %>% 
            addCircleMarkers(lng = ~longitude, 
                             lat = ~latitude, 
                             color = ~pal(room_type), 
                             radius = 5, 
                             stroke = FALSE, 
                             fillOpacity = 0.5) %>% 
            # Fit bounding box based on neighbourhood
            fitBounds(lng1 = bounds()$lng[1], 
                      lng2 = bounds()$lng[2], 
                      lat1 = bounds()$lat[1], 
                      lat2 = bounds()$lat[2])
    })
    
    # Calculate total of respective room type (within bounding box)
    output$roomInBounds <- renderPrint({
        # Total count by room type
        df <- bounded_area() %>% group_by(room_type) %>% summarise(n = n()) %>% as.data.frame(row.names = NULL)
        colnames(df) <- c("Room Type", "Quantity")
        df
            
    })
    
    
    # Data points for price density and listings per host analysis
    rv <- reactive({
        
        # ** Require this to trigger first selected city  **
        input$map_bounds
        
        # If subcity (area) is not selected, fall back to city data frame
        if(!input$area == ""){
            bounded_area()
        }else{
            selected_city()
        }
        
    })
    
    # Slow down reactive expression to prevent invalidation when switching city
    rv_d <- rv %>% debounce(750)
    
    # Price distribution goes here
    output$price <- renderPlotly({
        
        # Prevent invalidation when switching from area to area (further investigation required)
        withProgress(message = "Rendering...", value = 0.5, {
            p <- rv_d() %>% 
                # filter right tail outlier using Tukey's IQR method
                filter(price < (1.5 * IQR(price) + quantile(price, .75))) %>% 
                ggplot(aes(price, fill = room_type, col = room_type, text = "")) +
                geom_density(alpha = 0.6) + 
                scale_color_manual(values = room_cols) +
                scale_fill_manual(values = room_cols) +
                labs(x = "Price", y = "Kernel Density Estimation")
            
            setProgress(1)

        })
        
        ggplotly(p, tooltip = c("text"))
        
    })
    
    # Listings per host goes here
    output$host <- renderPlotly({
        
        withProgress(message = "Rendering...", value = 0,5, {
            p <- rv_d() %>% 
                group_by(host_id, host_name) %>% 
                summarise(n = n_distinct(id)) %>% 
                # Do a count on n (how many hosts own 3, 4..n houses?)
                ungroup() %>% count(n) %>% 
                filter(n > 1) %>% 
                ggplot(aes(n, nn, text = paste("# Listings:", n, "\n# Hosts:", nn))) + 
                # geom_hline(aes(yintercept = 0), lty = 3) +
                geom_bar(stat = 'identity', width = 0.1, fill = "skyblue", alpha = 0.6) + 
                geom_point(size = 3, col = "royalblue") +
                scale_x_continuous(breaks = scales::pretty_breaks(n = 5)) +
                scale_y_continuous(breaks = scales::pretty_breaks(n = 10)) +
                coord_flip() + 
                labs(x = "# Listings", y = "# Hosts with y listings")    
            
            setProgress(1)
            
        })
        
        ggplotly(p, tooltip = c("text"))

    })
    
}

# run App
shinyApp(ui = ui, server = server)





