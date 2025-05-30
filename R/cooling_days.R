################################################################################
#' Calculate "cooling degree day" binary indicator per for point or polygon
#' spatial units.
#' @param years integer. Year or years.
#' @param tmax_path chr(1). Directory with maximum temperature netCDF files.
#' @param vp_path chr(1). Directory with vapor pressure netCDF files.
#' @param threshold integer(1). Heat index temperature threshold. Default is
#' 65.
#' @param locs sf(1). Extraction locations as an `sf` object. Can be points
#' or polygons. Polygons will be used to calculate weighted mean.
#' @param locs_id chr(1). Column with unique identifier for each location
#' (e.g. "GEOID" or "GEOID20").
#' @param summarize logical(1). Summarize values according to location? (e.g.
#' total CDD per location).
#' @importFrom terra rast values longnames units varnames lapp nlyr crs time
#' @importFrom exactextractr exact_extract
#' @importFrom sf st_transform
#' @export
cooling_degree_days <- function(
  years,
  tmax_path,
  vp_path,
  threshold = 65,
  locs,
  locs_id,
  summarize = FALSE
) {
  # Check inputs.
  stopifnot(!is.null(years))
  stopifnot(!is.null(tmax_path))
  stopifnot(!is.null(vp_path))
  stopifnot(!is.null(locs))
  stopifnot(!is.null(locs_id))
  stopifnot(is.numeric(years))

  # Set empty data.frame for storing output.
  df_hi <- data.frame()

  # Iterate for each year.
  for (y in seq_along(years)) {
    # Index to year of interest.
    int_year <- years[y]

    # List all dates in year[y] (flexible to accomodate leap years).
    dates <- seq(
      lubridate::ymd(paste0(int_year, "-01-01")),
      lubridate::ymd(paste0(int_year, "-12-31")),
      by = "1 day"
    )

    # Define start/end of cooling period (May 01 to September 31).
    chr_start_cool <- paste0(int_year, "-05-01")
    chr_end_cool <- paste0(int_year, "-09-30")

    # Index value for May 01.
    int_start_cool_index <- grep(chr_start_cool, dates)
    # Index value for September 30.
    int_end_cool_index <- grep(chr_end_cool, dates)

    # Import `tmax` data from file.
    chr_tmax_path <- list.files(
      tmax_path,
      pattern = paste0(int_year),
      full.names = TRUE
    )
    stopifnot(length(chr_tmax_path) == 1)
    rast_tmax <- terra::rast(chr_tmax_path)

    # Subset to May 01 to September 31.
    rast_tmax_cooling <- rast_tmax[[int_start_cool_index:int_end_cool_index]]

    # Calculate saturated vapor pressure from `tmax` and store as `terra::rast`.
    rast_satvp <- rast_tmax_cooling
    terra::values(rast_satvp) <- GetSatVP(terra::values(rast_tmax_cooling))
    terra::varnames(rast_satvp) <- "satVP"
    terra::longnames(rast_satvp) <- "Saturated Vapor Pressure"
    terra::units(rast_satvp) <- "kPa"
    names(rast_satvp) <- gsub("tmax", "satVP", names(rast_satvp))

    # Convert `tmax` data to Fahrenheit.
    rast_tmax_cooling_f <- C_to_F(rast_tmax_cooling)

    # Import `vp` data from file.
    chr_vp_path <- list.files(
      vp_path,
      pattern = paste0(int_year),
      full.names = TRUE
    )
    stopifnot(length(chr_vp_path) == 1)
    rast_vp <- terra::rast(chr_vp_path)

    # Subset to May 01 to September 30.
    rast_vp_cooling <- rast_vp[[int_start_cool_index:int_end_cool_index]]

    # Calculate relative humidity from `satVP` and `vp`.
    rast_rh <- (rast_vp_cooling / rast_satvp) * 100
    terra::varnames(rast_rh) <- "rh"
    terra::longnames(rast_rh) <- "relative humidity"
    terra::units(rast_rh) <- "percent (%)"
    names(rast_rh) <- gsub("vp", "rh", names(rast_rh))

    # Calculate heat index by combining tmax_f[n] with rh[n].
    rast_hi <- terra::rast()
    for (n in seq_len(terra::nlyr(rast_tmax_cooling_f))) {
      rast_tmax_rh <- c(rast_tmax_cooling_f[[n]], rast_rh[[n]])
      rast_hi_lapp <- terra::lapp(rast_tmax_rh, GetHeatIndex)
      rast_hi <- c(rast_hi, rast_hi_lapp)
    }
    terra::time(rast_hi) <- terra::time(rast_tmax_cooling_f)
    names(rast_hi) <- gsub("tmax", "hi", names(rast_tmax_cooling_f))
    terra::varnames(rast_hi) <- "heat index"
    terra::longnames(rast_hi) <- "heat index"

    # Extract cooling degree day indicator for locations.
    for (h in seq_len(terra::nlyr(rast_hi))) {
      if ("POLYGON" %in% as.character(unique(sf::st_geometry_type(locs)))) {
        locs_p <- sf::st_transform(locs, terra::crs(rast_hi))
        num_hi <- exactextractr::exact_extract(
          rast_hi[[h]],
          locs_p,
          weights = "area",
          fun = "mean",
          progress = FALSE
        )
      } else {
        locs_p <- terra::project(locs, terra::crs(rast_hi))
        num_hi <- terra::extract(
          rast_hi[[h]],
          locs_p,
          method = "simple",
          ID = FALSE,
          bind = FALSE,
          na.rm = TRUE
        )
      }

      # Merge with location ID and time values.
      df_hi_h <- data.frame(
        id = locs[[locs_id]],
        time = terra::time(rast_hi[[h]]),
        hi = num_hi
      )
      names(df_hi_h) <- c(locs_id, "time", "HeatIndex")

      # Merge with other years' data.
      df_hi <- rbind(df_hi, df_hi_h)
    }
  }

  # Calculate degrees above threshold and cooling degree day binary values.
  df_hi$AboveThreshold <- CalcTempAboveThresh(
    df_hi$HeatIndex,
    threshold = threshold
  )
  df_hi$CDD <- ifelse(df_hi$AboveThreshold > 0, 1, 0)

  if (summarize) {
    # Calculate total degrees above threshold for each location.
    df_at <- aggregate(AboveThreshold ~ get(locs_id), data = df_hi, FUN = sum)
    # Calculate number of days above threshold for each location.
    df_cdd <- aggregate(CDD ~ get(locs_id), data = df_hi, FUN = sum)
    df_summarize <- merge(df_at, df_cdd, by = "get(locs_id)")
    names(df_summarize) <- c(locs_id, "CDD", "CDD_binary")
    return(df_summarize)
  } else {
    return(df_hi)
  }
}

################################################################################
#' Calculate saturated vapor pressure.
GetSatVP <- function(t) {
  ifelse(
    t > 0,
    exp(34.494 - (4924.99 / (t + 237.1))) / (t + 105)^1.57,
    exp(43.494 - (6545.8 / (t + 278))) / (t + 868)^2
  )
}

################################################################################
#' Convert Celcius to farenheit.
C_to_F <- function(T.celsius, round = 2) {
  T.fahrenheit <- (9 / 5) * T.celsius + 32
  T.fahrenheit <- round(T.fahrenheit, digits = round)

  return(T.fahrenheit)
}

################################################################################
#' Calculate heat index based on temperature and relative humidity.
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
#' Calculate heat index above threshold.
CalcTempAboveThresh <- function(temperature, threshold = 65) {
  pmax(temperature, threshold) - threshold
}
