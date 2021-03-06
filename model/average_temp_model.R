# This file computes the leaf energy balance using average leaf temperature and related meteorological data
# from the submitted manuscript "Spatiotemporal dynamics of leaf transpiration quantified with time-series thermal imaging"
# code written by Gerald Page and Jean Lienard

require(Hmisc)

# this functions return the squared error in  prediction
compute_error = function(SR01Up=0, IR01UpCo=0, IR01DnCo=0, LTemp=0, ATemp=0, Larea=0, Lwidth=0, nrep=10, gha_method = 'dry_leaves', doplot=F)
{
  pb <- txtProgressBar(style = 3)

  ## constants--------------------------------------------
  cp = 29.3  # heat capacity of air (J mol-1 C-1)
  eL = 0.98 # leaf emissivity
  c_pw = 4182 # specific heat capacity of water at constant pressure (J kg-1 K-1)
  bz = 5.6703 * 10^(-8) # Stefan-Boltzmann Constant
  Gam = 2.265e6 # latent heat of vaporization of water (J kg-1)
  Absorptivity = 0.70
  Atmospheric_view_factor = 0.8
  Ground_view_factor = 1 - Atmospheric_view_factor
  
  correction_missing_photos = read.table(text='0
                                         4
                                         0
                                         0
                                         3
                                         1
                                         0
                                         0
                                         2
                                         0
                                         0
                                         1
                                         0
                                         0
                                         1
                                         0
                                         1
                                         1
                                         3
                                         1
                                         0
                                         1')
  
  # leave_dir = 'leaves_wdry/'
  my_files <- list.files('./data/leaves_wdry/', pattern = "\\.csv$")
  my_files <- my_files[order(nchar(my_files), my_files)]
  setwd('./data/leaves_wdry/')
  leaves <- lapply(my_files, read.csv)
  
  
  # compute Rabs:
  setwd('../met/')
  for (i in 1:length(leaves)) {
    m = read.csv(paste0('l', i, '.csv'), header = T)
    # formula: Rabs = incident shortwave*absorptivity + (eL*(atmospheric view factor*atmospheric longwave + ground view factor*ground longwave))
    leaves[[i]]$Rabs[] = (m$SR01Up + SR01Up) * Absorptivity + eL * (Atmospheric_view_factor * (m$IR01UpCo + IR01UpCo) + Ground_view_factor * (m$IR01DnCo + IR01DnCo))
    leaves[[i]]$wind.int = m$wind.int
  }
  
  # read leaf area and change in mass data
  setwd("../leaf_params/")
  larea <- read.csv("single_leaf_areas_R.csv", header=T) # leaf area - scans analysed in Matlab 2016b
  water <- read.csv("single_leaf_water_R.csv", header=T) # leaf mass before and after TIR image capture
  larea <- larea[order(larea$Leaf),]
  leaf_params.df <- data.frame(larea$Leaf, larea$Area_m + Larea, water$InitialKG, water$FinalKG)
  names(leaf_params.df) <- c("Leaf", "Area_m", "InitKG", "FinalKG")
  leaf_params.df$SWM_A <- leaf_params.df$InitKG/leaf_params.df$Area_m
  leaf_params.df$FWM_A <- leaf_params.df$FinalKG/leaf_params.df$Area_m
  leaf_params.df$mass_loss_g <- (leaf_params.df$InitKG - leaf_params.df$FinalKG) * 1000
  av_lwma <- mean(leaf_params.df$SWM_A) # average starting leaf water mass per area, for dry reference leaf heat capacity estimation
  
  # initialize the bootstrap variables
  med_res = NULL
  min_res = NULL
  max_res = NULL
  med_E = NULL
  min_E = NULL
  max_E = NULL
  med_gHa = NULL
  min_gHa = NULL
  max_gHa = NULL
  min_SHF = NULL
  med_SHF = NULL
  max_SHF = NULL
  sd_res = NULL
  
  for (l_i in 1:length(my_files)) {
    
    # update the progress bar:
    setTxtProgressBar(pb, l_i/length(my_files))
    
    # data specific to this leaf:
    d = leaves[[l_i]]
    leaf_area = leaf_params.df$Area_m[l_i]
    starting_water_mass = leaf_params.df$SWM_A[l_i]
    L_l = sqrt(leaf_params.df$Area_m[l_i]) # leaf length
    
    # put a few additional columns in the dataframe
    d$E = NA
    d$S = NA
    d$Loe = NA
    d$gr = NA
    d$Real_LTemp = d$LTemp + LTemp
    d$Real_DLTemp = d$DLTemp + LTemp
    d$AirT = d$AirT + ATemp
    d$missing = is.na(d$LTemp)
    ran = 2:nrow(d)
    d$gHa_recomputed = NULL
    
    # compute radiative conductance term
    d$gr = (4*bz*((d$AirT + 273.15)^3))/cp # radiative conductance
    
    # initialize the bootstrap variables
    results = matrix(NA, nrow=nrep, ncol=1)
    detailed = matrix(NA, nrow=nrep, ncol=nrow(d))
    detailed_gHa = matrix(NA, nrow=nrep, ncol=nrow(d))
    SHF = matrix(NA, nrow=nrep, ncol=nrow(d))
    
    
    for (bt in 1:nrep)
    {
      # re-initialize the starting water mass:
      d$water_mass = starting_water_mass
      
      # randomly generate a new temperature trace
      if (nrep == 1) {
        # only one trial => no noise
        measurement_error = 0
        dref_measurement_error = 0
      } else {
        measurement_error = rnorm(sum(!d$missing), 0, sqrt(d$LTemp[1]*0.01)) # variance of 1% of measurement
        dref_measurement_error = rnorm(sum(!d$missing), 0, sqrt(d$DLTemp[1]*0.01))
      }
      d$LTemp = spline(d$Seconds[!d$missing], measurement_error + d$Real_LTemp[!d$missing], xout = d$Seconds)$y
      d$DLTemp = spline(d$Seconds[!d$missing], dref_measurement_error + d$Real_DLTemp[!d$missing], xout = d$Seconds)$y
      
      
      # computes the corresponding Lwatts:
      d$Lwatts = 5.6697 * 10^(-8) * (d$LTemp + 273.15)^4 #
      
      # the Loe term (long-wave emission)
      d$Loe = (eL*bz*((d$AirT+ 273.15)^4)) + (cp*d$gr*(d$LTemp - d$AirT))
      
      if (gha_method == 'dry_leaves') {
        # Recomputing gHa from dry leaves
        # cat('DL')
        # d$gHa_recomputed = (d$Rabs - ((eL*bz*((d$AirT + 273.15)^4)) + (cp*d$gr*(d$DLTemp - d$AirT)))) / (cp*(d$DLTemp - d$AirT))
        d$gHa_recomputed[2:max(ran)] = (d$Rabs[2:max(ran)] - (c_pw*av_lwma*(d$DLTemp[2:max(ran)] - d$DLTemp[1:max(ran)-1])) - ((eL*bz*((d$AirT[2:max(ran)]+ 273.15)^4)) + (cp*d$gr[2:max(ran)]*(d$DLTemp[2:max(ran)] - d$AirT[2:max(ran)])))) / (cp*(d$DLTemp[2:max(ran)] - d$AirT[2:max(ran)]))
        d$gHa_recomputed[1] = d$gHa_recomputed[2]
        d$Sensible_Heat_Flux = cp * d$gHa_recomputed * (d$LTemp - d$AirT)
        gHa = d$gHa_recomputed
      } else if (gha_method == 'Schymanski13') {
        # cat('SCHYMANSKI')
        N_pr = 0.71 # dimensionless Prandtl number
        d$T_b = (d$AirT + d$LTemp + 273.15*2) / 2 # corrected to K
        d$v_a = (9*(10^-8) * d$T_b) - 1.13*(10^-5) # corrected - previously calculating dynamic visc. of water
        d$N_rel = d$wind.int * L_l / d$v_a
        N_rec1 = 3000 # cricitical reynolds number, set as per Schymanski et al. 2013
        d$N_rec = (d$N_rel + N_rec1 - abs(N_rec1 - d$N_rel) ) / 2 # substituting this term for Nrec in the calculation of C_l, following Schymanski et al. 2013
        d$C_l = 0.037 * d$N_rec^(4/5) - 0.664 * d$N_rec^(1/2)
        d$N_nul = (0.037 * d$N_rel^(4/5) - d$C_l) * N_pr^(1/3)
        d$k_a = 6.84 * 10^(-5) * d$T_b + 5.62 * 10^(-3)
        d$h_c = d$k_a * d$N_nul / L_l
        d$Sensible_Heat_Flux = 2 * d$h_c * (d$LTemp - d$AirT)
        gHa = d$h_c
      } else if (gha_method == 'simple') {
        # cat('SIMPLE')
        d$gHa = 1.4 * (0.135 * sqrt(d$wind.int/(0.72 * L_l)))
        d$Sensible_Heat_Flux = cp * d$gHa * (d$LTemp - d$AirT)
        gHa = d$gHa
      } else {
        stop('Undefined method')
      }

      # evapotranspiration, WITHOUT water loss:
      # d$E[ran] =  cp*1.4*d$gHa[ran] * (d$AirT[ran] - d$LTemp[ran]) + d$Rabs[ran] -eL * d$Lwatts[ran] - (d$LTemp[ran] - d$LTemp[ran-1]) * d$water_mass[ran]*c_pw
      
      # evapotranspiration, WITH water loss:
      for (i in ran) {
        # normal formula:
        # d$E[i] =  (cp*1.4*d$gHa[i] * (d$LTemp[i] - d$AirT[i])) + d$Rabs[i] - d$Loe[i] - ((d$LTemp[i] - d$LTemp[i-1])* d$water_mass[i]*c_pw)
        # using H computed with the dry leaves:
        d$E[i] = - d$Sensible_Heat_Flux[i] + d$Rabs[i] - d$Loe[i] - ((d$LTemp[i] - d$LTemp[i-1])* d$water_mass[i]*c_pw)
        if (i < nrow(d))
          d$water_mass[i+1] = d$water_mass[i] - d$E[i] / Gam / 1e3
      }
      
      # store the data to compute confidence interval
      results[bt,1] = sum(d$E[c(rep(2,(15)*unlist(correction_missing_photos)[l_i]),2:length(d$E))], na.rm=T) # we duplicate the first value 15 times for each missing picture
      detailed[bt, ] = d$E
      detailed_gHa[bt,] = gHa
      SHF[bt,] = d$Sensible_Heat_Flux
    }
   
    results[,1] = results[,1] / 44000 * leaf_area  * 18.01528 # converts from watts to water content
    
    med_res = c(med_res, median(results[,1], na.rm=T) )
    min_res = c(min_res, quantile(results[,1], probs = 0.025, na.rm=T) )
    max_res = c(max_res, quantile(results[,1], probs = 0.975, na.rm=T) )
    
    med_E = c(med_E, mean(apply(detailed,1,median, na.rm = T)))
    max_E = c(max_E, mean(apply(detailed,1,max, na.rm = T)))
    min_E = c(min_E, mean(apply(detailed,1,min, na.rm = T)))
    
    med_gHa = c(med_gHa, mean(apply(detailed_gHa,1,median, na.rm = T)))
    max_gHa = c(max_gHa, mean(apply(detailed_gHa,1,max, na.rm = T)))
    min_gHa = c(min_gHa, mean(apply(detailed_gHa,1,min, na.rm = T)))
    
    min_SHF = c(min_SHF, mean(apply(SHF,1,min, na.rm = T)))
    med_SHF = c(med_SHF, mean(apply(SHF,1,median, na.rm = T)))
    max_SHF = c(max_SHF, mean(apply(SHF,1,max, na.rm = T)))
    
    sd_res = c(sd_res, sd(results[,1], na.rm = T))
  }

  computed_water_loss = med_res
  if (doplot) {
    par(mfrow=c(1,1), mai=rep(0.8,4))
    if (nrep == 1) {
      plot(leaf_params.df$mass_loss_g, computed_water_loss, pch=20, asp=1, las=1, xlab='Measured Water Loss', ylab='Computed Water Loss (with 95% CI)', xlim=c(0,0.6), ylim=c(0,0.6))
      # R-squared?
      # summary(lm(leaf_params.df$mass_loss_g ~ computed_water_loss))$r.squared
    } else {
      errbar(leaf_params.df$mass_loss_g, computed_water_loss, min_res, max_res, pch='.', asp=1, las=1, xlab='Measured Water Loss', ylab='Computed Water Loss (with 95% CI)', xlim=c(0,0.6), ylim=c(0,0.6))
    }
    abline(0,1)
  }
  
  
  return(list(err_s=sqrt(mean((leaf_params.df$mass_loss_g - computed_water_loss)^2)), 
              mean_loss = mean(computed_water_loss),
              computed_water_loss=computed_water_loss,
              min_res=min_res,
              max_res=max_res,
              mass_loss_g = leaf_params.df$mass_loss_g,
              med_E = med_E,
              max_E = max_E,
              min_E = min_E,
              med_gHa = med_gHa,
              max_gHa = max_gHa,
              min_gHa = min_gHa,
              min_SHF = min_SHF,
              med_SHF = med_SHF,
              max_SHF = max_SHF,
              sd_res = sd_res))
  close(pb)
}


# use function
preds_dry_leaves = compute_error(nrep=1000, gha_method = 'dry_leaves')
preds_shymanski = compute_error(nrep=1000, gha_method = 'Schymanski13')
preds_simple = compute_error(nrep=1000, gha_method = 'simple')



