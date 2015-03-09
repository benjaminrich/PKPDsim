#' Simulate ODE
#'
#' Simulates a specified ODE system and regimen
#' @param ode function describing the ODE system
#' @param parameters
#' @param omega vector describing the lower-diagonal of the between-subject variability matrix
#' @param omega_type exponential or normal
#' @param n_ind number of individuals to simulate
#' @param regimen a regimen object created using the regimen() function
#' @param A_init vector with the initial state of the ODE system
#' @param step_size the step size between the observations (NOT the step size of the differential equation solver)
#' @param tmax maximum simulation time, if not specified will pick the end of the regimen as maximum
#' @param output vector specifying which compartment numbers to output
#' @return a list containing calculated VPC information, and a ggplot2 object
#' @export
#' @seealso \link{sim_ode_shiny}
#' @examples
#'
#'library(PKPDsim)
#'p <- list(CL = 38.48,
#'          V  = 7.4,
#'          Q2 = 7.844,
#'          V2 = 5.19,
#'          Q3 = 9.324,
#'          V3 = 111)
#'
#'r1 <- new_regimen(amt = 100,
#'              times = c(0, 24, 36),
#'              type = "infusion")
#'
#'dat <- sim_ode (ode = pk_3cmt_iv,
#'                par = p,
#'                regimen = r1)
#'
#'ggplot(dat, aes(x=t, y=y)) +
#'  geom_line() +
#'  scale_y_log10() +
#'  facet_wrap(~comp)
#'
#'# repeat with IIV:
#'omega <- c(0.3,       # IIV CL
#'           0.1, 0.3)  # IIV V
#'
#'dat <- sim_ode (ode = pk_3cmt_iv,
#'                par = p,
#'                omega = omega,
#'                n_ind = 20,
#'                regimen = r1)
#'
#'ggplot(dat, aes(x=t, y=y, colour=factor(id), group=id)) +
#'  geom_line() +
#'  scale_y_log10() +
#'  facet_wrap(~comp)

sim_ode <- function (ode = function() {},
                     parameters = list(),
                     omega = NULL,
                     omega_type = "exponential",
                     n_ind = 1,
                     regimen = NULL,
                     A_init = NULL,
                     step_size = .25,
                     tmax = NULL,
                     output_cmt = NULL) {
  num_int_wrapper <- function (times, A_init, des, p_ind) {
    des_out <- deSolve::lsoda(A_init, times, des, p_ind)
    dat_ind <- c()
    for (j in 1:length(A_init)) {
      dat_ind <- rbind (dat_ind, cbind(t=des_out[,1], comp=j, y=des_out[,(j+1)]))
    }
    return(data.frame(dat_ind))
  }
  get_size_ode <- function(ode, p) {
    p$rate <- 1
    dum <- ode(1, rep(1, 1000), p)
    length(dum[[1]])
  }
  trans.lower <- function(x,y) { ifelse(y<x, x*(x-1)/2 + y, y*(y-1)/2 + x) }
  full.mat <- function(p) { outer(1:p,1:p, trans.lower) }
  if (!is.null(omega)) {
    omega_mat <- matrix (omega[full.mat(2)], nrow=2, byrow=T)
    require(MASS)
    etas   <- mvrnorm(n = n_ind, mu=rep(0, 2), Sigma=omega_mat)
    if(n_ind == 1) {
      etas <- t(matrix(etas))
    }
  }
  if(is.null(regimen)) {
    regimen <- new_regimen()
  }
  comb <- list()
  if (is.null(A_init)) {
    A_init <- rep(0, get_size_ode(ode, parameters))
  }
  p <- parameters
  if(class(regimen) != "regimen") {
    stop("Please create a regimen using the new_regimen() function!")
  }
  if(regimen$type == "infusion") {
    p$t_inf <- regimen$t_inf
    p$dose_type <- "infusion"
    design <- data.frame(rbind(cbind(t=regimen$dose_times, dose = regimen$dose_amts), cbind(t=regimen$dose_times + regimen$t_inf, dose=0))) %>%
      dplyr::arrange(t)
  } else {
    p$dose_type <- "bolus"
    design <- data.frame(rbind(cbind(t=regimen$dose_times, dose = regimen$dose_amts)))
  }
  if (is.null(tmax)) {
    tmax <- tail(design$t,1) + max(diff(regimen$dose_times))
  }
  design <- rbind(design %>%
                    dplyr::filter(t < tmax), tail(design,1))
  design[length(design[,1]), c("t", "dose")] <- c(tmax,0)
  times <- seq(from=0, to=tail(design$t,1), by=step_size)
  for (i in 1:n_ind) {
    p_i <- p
    if (!is.null(omega)) {
      if (omega_type=="exponential") {
        p_i[1:nrow(omega_mat)] <- relist(unlist(as.relistable(p_i[1:nrow(omega_mat)])) * exp(etas[i,]))
      } else {
        p_i[1:nrow(omega_mat)] <- relist(unlist(as.relistable(p_i[1:nrow(omega_mat)])) + etas[i,])
      }
    }
    for (k in 1:(length(design$t)-1)) {
      if (k > 1) {
        A_upd <- dat[dat$t==tail(time_window,1),]$y
      } else {
        A_upd <- A_init
      }
      p_i$rate <- 0
      if(p_i$dose_type != "infusion") {
        A_upd[regimen$cmt] <- A_upd[regimen$cmt] + regimen$dose_amts[k]
      } else {
        if(design$dose[k] > 0) {
          p_i$rate <- design$dose[k] / p_i$t_inf
        }
      }
      time_window <- times[(times >= design$t[k]) & (times <= design$t[k+1])]
      dat <- num_int_wrapper (time_window, A_upd, ode, p_i)
      comb <- rbind(comb, cbind(id = i, dat))
    }
  }
  # Add concentration to dataset:
  if(!is.null(attr(ode, "obs"))) {
    comb <- rbind (comb, comb %>% dplyr::filter(comp == attr(ode, "obs")[["cmt"]]) %>% dplyr::mutate(comp = "obs", y = y/p[[attr(ode, "obs")[["scale"]]]]) )
  }
  if(!is.null(output_cmt)) {
    comb <- comb %>% dplyr::filter(comp %in% output_cmt)
  }
  return(data.frame(comb))
}