################################################################################
# Copy 'Cooling Degree Day' (CDD) functions from chee/TEJM_Analysis.

################################################################################
# Function for converting celcius to farenheit
C_to_F <- function(T.celsius, round = 2) {
  T.fahrenheit <- (9 / 5) * T.celsius + 32
  T.fahrenheit <- round(T.fahrenheit, digits = round)

  return(T.fahrenheit)
}

################################################################################
# Setting the threshold for HICDD
CalcTempAboveThresh <- function(temperature, threshold = 65) {
  pmax(temperature, threshold) - threshold
}

################################################################################
GetCensusData <- function(geography) {
  census_data <- tidycensus::get_decennial(
    geography = geography,
    variables = c("Total_pop" = "P001001"),
    year = 2010,
    output = "wide",
    geometry = TRUE,
    state = 36
  ) %>%
    sf::st_transform(crs = sf::st_crs(4326)) %>%
    filter(!sf::st_is_empty(.))

  return(census_data)
}

################################################################################
# function to calculate saturated vapor pressure
GetSatVP <- function(t) {
  ifelse(
    t > 0,
    exp(34.494 - (4924.99 / (t + 237.1))) / (t + 105)^1.57,
    exp(43.494 - (6545.8 / (t + 278))) / (t + 868)^2
  )
}

################################################################################
# functions to calculate heat index
hi <- function(t) {
  -42.379 +
    2.04901523 * t +
    10.14333127 * rh -
    0.22475541 * t * rh -
    6.83783 * 10^-3 * t^2 -
    5.481717 * 10^-2 * rh^2 +
    1.22874 * 10^-3 * t^2 * rh +
    8.5282 * 10^-4 * t * rh^2 -
    1.99 * 10^-6 * t^2 * rh^2
}

GetHeatIndex <- function(t = NA, rh = NA) {
  ifelse(
    is.na(rh) | is.na(t) | is.nan(rh) | is.nan(t),
    NA,
    ifelse(
      t <= 40,
      t,
      ifelse(
        -10.3 + 1.1 * t + 0.047 * rh < 79,
        -10.3 + 1.1 * t + 0.047 * rh,
        ifelse(
          rh <= 13 & t >= 80 & t <= 112,
          -42.379 +
            2.04901523 * t +
            10.14333127 * rh -
            0.22475541 * t * rh -
            6.83783 * 10^-3 * t^2 -
            5.481717 * 10^-2 * rh^2 +
            1.22874 * 10^-3 * t^2 * rh +
            8.5282 * 10^-4 * t * rh^2 -
            1.99 * 10^-6 * t^2 * rh^2 -
            (13 - rh) / 4 * ((17 - abs(t - 95)) / 17)^0.5,
          ifelse(
            rh > 85 & t >= 80 & t <= 87,
            -42.379 +
              2.04901523 * t +
              10.14333127 * rh -
              0.22475541 * t * rh -
              6.83783 * 10^-3 * t^2 -
              5.481717 * 10^-2 * rh^2 +
              1.22874 * 10^-3 * t^2 * rh +
              8.5282 * 10^-4 * t * rh^2 -
              1.99 * 10^-6 * t^2 * rh^2 +
              0.02 * (rh - 85) * (87 - t),
            -42.379 +
              2.04901523 * t +
              10.14333127 * rh -
              0.22475541 * t * rh -
              6.83783 * 10^-3 * t^2 -
              5.481717 * 10^-2 * rh^2 +
              1.22874 * 10^-3 * t^2 * rh +
              8.5282 * 10^-4 * t * rh^2 -
              1.99 * 10^-6 * t^2 * rh^2
          )
        )
      )
    )
  )
}

################################################################################
# Function for Downloading Daymet Data
DownloadDaymetData <- function(years, location) {
  # Creating folders for the parameters we want, which are
  # maximum temperature and vapor pressure
  tmax_folder <- file.path(dir_daymet, "tmax")
  vp_folder <- file.path(dir_daymet, "vp")

  if (!dir.exists(tmax_folder)) dir.create(tmax_folder, recursive = TRUE)

  if (!dir.exists(vp_folder)) dir.create(vp_folder, recursive = TRUE)

  # Remove years that already exist in tmax_folder
  existing_tmax_files <- list.files(
    tmax_folder,
    pattern = ".nc$",
    full.names = TRUE
  )
  existing_tmax_years <- unique(sub(".nc$", "", basename(existing_tmax_files)))
  existing_tmax_years <- gsub("^.*?([0-9]{4}).*$", "\\1", existing_tmax_years)
  years <- setdiff(years, existing_tmax_years)

  # Remove years that already exist in vp_folder
  existing_vp_files <- list.files(
    vp_folder,
    pattern = ".nc$",
    full.names = TRUE
  )
  existing_vp_years <- unique(sub(".nc$", "", basename(existing_vp_files)))
  existing_vp_years <- gsub("^.*?([0-9]{4}).*$", "\\1", existing_vp_years)
  years <- setdiff(years, existing_vp_years)

  # Check if there are remaining years to download
  if (length(years) > 0) {
    # Download maximum temperature daymet data
    daymetr::download_daymet_ncss(
      location = location,
      start = years[1],
      end = years[length(years)],
      param = c("tmax"),
      path = tmax_folder
    )

    # Download vapor pressure daymet data
    daymetr::download_daymet_ncss(
      location = location,
      start = years[1],
      end = years[length(years)],
      param = c("vp"),
      path = vp_folder
    )
  } else {
    cat("Data already exists for the specified years and location.\n")
  }
}

################################################################################
# Calculate HICDD
GetHicddsPerYear_monthly <- function(year, census_data) {
  # defining the cooling season
  cooling_season_starts <- c("-05-01", "-06-01", "-07-01", "-08-01", "-09-01")
  cooling_season_ends <- c("-05-31", "-06-30", "-07-31", "-08-31", "-09-30")

  hicdds_year <- lapply(1:5, function(i) {
    year_start_date <- as.Date(paste0(year, "-01-01"))
    cooling_season_start_index <- as.numeric(
      as.Date(paste0(year, cooling_season_starts[i])) - year_start_date
    )
    cooling_season_ends_index <- as.numeric(
      as.Date(paste0(year, cooling_season_ends[i])) - year_start_date
    )
    days_in_season <- cooling_season_ends_index - cooling_season_start_index + 1

    # opening tmax data
    tmax_filepath <- list.files(
      file.path(dir_daymet, "tmax"),
      pattern = paste0(year),
      full.names = TRUE
    )
    tmax <- ncdf4::nc_open(tmax_filepath)
    tmax_array <- ncdf4::ncvar_get(tmax, "tmax")

    # fill missing values in with 0
    fillvalue <- ncdf4::ncatt_get(tmax, "tmax", "_FillValue")
    tmax_array[tmax_array == fillvalue$value] <- 0

    # extracting temperature data corresponding to cooling season
    tmax_array_cooling_season <- tmax_array[,,
      cooling_season_start_index:cooling_season_ends_index
    ]

    # calculating vapor pressure data corresponding to cooling season
    satVP_array_cooling_season <- GetSatVP(
      tmax_array_cooling_season[,, seq_along(1:days_in_season)]
    )

    # removing tmax_array from memory to save space
    rm(tmax_array)

    # opening vapor pressure data
    vp_filepath <- list.files(
      file.path(dir_daymet, "vp"),
      pattern = paste0(year),
      full.names = TRUE
    )
    vp <- ncdf4::nc_open(vp_filepath)
    long_vp <- ncdf4::ncvar_get(vp, "x")
    lat_vp <- ncdf4::ncvar_get(vp, "y")
    vp_array <- ncdf4::ncvar_get(vp, "vp")

    # fill missing values in with 0
    fillvalue <- ncdf4::ncatt_get(vp, "vp", "_FillValue")
    vp_array[vp_array == fillvalue$value] <- 0

    # extracting vapor pressure data corresponding to cooling season
    vp_array_cooling_season <- vp_array[,,
      cooling_season_start_index:cooling_season_ends_index
    ]

    # removing vp_array from memory to save space
    rm(vp_array)

    # converting temperature values from Celsius to Fahrenheit
    tmax_array_cooling_season_F <- C_to_F(
      tmax_array_cooling_season[,, seq_along(1:days_in_season)]
    )

    # calculating relative humidity
    relative_humidity <- lapply(
      1:days_in_season,
      function(j) {
        (vp_array_cooling_season[,, j] / satVP_array_cooling_season[,, j]) * 100
      }
    )

    # storing the relative humidity values in an array
    relative_humidity <- array(
      unlist(relative_humidity),
      dim = c(854, 811, days_in_season)
    )

    return(
      list(
        days_in_season = days_in_season,
        tmax_array_cooling_season_F = tmax_array_cooling_season_F,
        relative_humidity = relative_humidity
      )
    )

    # calculating heat index
    heat_index <- sapply(
      1:days_in_season,
      function(j) {
        GetHeatIndex(
          t = tmax_array_cooling_season_F[,, j],
          rh = relative_humidity[,, j]
        )
      }
    )

    # storing heat index values in an array
    heat_index <- array(unlist(heat_index), dim = c(854, 811, days_in_season))

    # calculating cooling degree days per day
    cdds_per_day <- lapply(
      1:days_in_season,
      function(j) CalcTempAboveThresh(heat_index[,, j])
    )

    #cdds_per_day

    # calculating cooling degree days for the season
    cdds_across_summer <- matrix(nrow = 854, ncol = 811)
    cdds_across_summer[is.na(cdds_across_summer)] <- 0
    for (i in 1:days_in_season) {
      step1 <- Reduce(
        `+`,
        lapply(list(cdds_per_day[[i]], cdds_across_summer), function(x) {
          x[is.na(x)] <- 0
          x
        })
      )
      cdds_across_summer <- step1
    }

    # converting cooling degree data for the season into a raster and set CRS
    raster_1year <- raster::raster(
      t(cdds_across_summer),
      xmn = min(long_vp),
      xmx = max(long_vp),
      ymn = min(lat_vp),
      ymx = max(lat_vp),
      crs = sp::CRS(
        paste0(
          "+proj=lcc +lat_1=25 +lat_2=60 +lat_0=42.5 +lon_0=-100 ",
          "+x_0=0 +y_0=0 +ellps=WGS84 +units=km +no_defs"
        )
      )
    )
    raster_1year_epsg4326 <- raster::projectRaster(
      from = raster_1year,
      crs = "+init=epsg:4326"
    )

    # finding the CDDs per census area per year using exact_extract function
    tract_mean_cdds_1year <- exactextractr::exact_extract(
      raster_1year_epsg4326,
      census_data,
      weights = "area",
      fun = "mean",
      append_cols = TRUE
    ) %>%
      dplyr::mutate(year = year)

    return(tract_mean_cdds_1year)
  })

  return(hicdds_year)
}

################################################################################
# Get HICDDS for Specified Years and Save as Data Frame
calculateHICDD <- function(years, census_data, observations = 1794) {
  month_var <- rep(5:9, each = observations)
  # get HICDDs for specified years
  hicdds <- lapply(years, function(i) {
    GetHicddsPerYear_monthly(year = i, census_data = census_data)
  })

  # create an empty data frame to store the HICDDS
  hicdds_collection <- data.frame()

  # add the HICDDs to the data frame
  for (i in 1:length(years)) {
    temp <- dplyr::bind_rows(hicdds[[i]]) %>% dplyr::mutate(month = month_var)
    hicdds_collection <- dplyr::bind_rows(hicdds_collection, temp)
  }

  return(hicdds_collection)
}
