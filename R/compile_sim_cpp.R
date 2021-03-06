#' Compile ODE model to c++ function
#' @param code C++ code ODE system
#' @param dose_code C++ code per event ($PK)
#' @param size size of ODE system
#' @param p parameters (list)
#' @param cpp_show_code show output c++ function?
#' @param code_init code for initialization of state
#' @param declare_variables variable declaration
#' @param covariates covariates specification
#' @param obs observation specification
#' @param dose dose specification
#' @param state_init state init vector
#' @param verbose show more output
#' @export
compile_sim_cpp <- function(code, dose_code, size, p, cpp_show_code, code_init = NULL, state_init = NULL, declare_variables = NULL, covariates = NULL, obs = NULL, dose = NULL, verbose = FALSE) {
  folder <- c(system.file(package="PKPDsim"))
  ode_def <- code

  ## find newly declared variables and make sure they are defined as double
  ode_def <- paste0(gsub("[\n^]( *?)double ", "", ode_def))
  newpar <- gregexpr("[\n^](.*?)=", ode_def)
  par1 <- regmatches(ode_def, newpar)[[1]]
  def1 <- par1[-grep("dadt\\[", tolower(par1))]
  for (i in seq(def1)) {
    ode_def <- gsub(def1[i], paste0("\ndouble ", gsub("\n","",def1[i])), ode_def)
  }
  par1 <- gsub("[\n\\= ]", "", par1)
  par1 <- gsub("double ", "", par1)
  defined <- par1[-grep("dadt\\[", tolower(par1))]
  ode_def_cpp <- shift_state_indices(ode_def, -1)
  ode_def_cpp <- gsub("\\n *", "\\\n  ", ode_def_cpp)

  # add 'rate' for dose compartments to allow infusions, remove if already specified by user (previous versions req'd this)
  if(is.null(dose)) {
    dose <- list(cmt = 1)
  }
  line_end <- gregexpr(";", ode_def_cpp)[[1]]
  match_rate <- gregexpr(paste0("\\+(.)*rate"), tolower(ode_def_cpp))[[1]]
  if(match_rate[1] >= 0) {
    stop("Sorry, the manual specification of `rate` in the ODE definition is deprecated. Please use the `dose` argument in `new_ode_model()`, or the `cmt` argument in `new_regimen()` instead.")
  }
  lines <- strsplit(ode_def_cpp, ";")[[1]]
  new_ode <- c()
  j <- 0
  for(i in seq(lines)) {
    if(length(grep("dAdt", lines[i])) > 0) {
      lines[i] <- paste0(lines[i], " + rate[", j, "]")
      j <- j+1
    }
    if(nchar(lines[i]) > 0) {
      new_ode <- c(new_ode, lines[i])
    }
  }
  ode_def_cpp <- paste(new_ode, collapse=";")

  if(any(p %in% defined)) {
    p <- p[!p %in% defined]
  }
  p_def <- unique(p)
  if (!is.null(declare_variables)) {
    m <- p_def %in% declare_variables # remove covariates and other declared variables
    p_def <- p_def[!m]
  }
  p <- unique(c(p, "conc", "scale", declare_variables)) # add rate and conc as explicitly declared variables
  pars <- "\n"
  par_def <- ""
  for(i in seq(p)) { # parameters and auxiliary variables
    pars <- paste0(pars, "double ", p[i], ";\n")
  }
  pars <- paste0(pars, "double prv_dose, t_prv_dose = 0;\n")
  pars <- paste0(pars, paste0("double rate[] = { ", paste(rep(0, size), collapse=", "), " };\n"))
  for(i in seq(p_def)) { # actual parameters for model
    par_def <- paste0(par_def, '  ', p_def[i], ' = par["', p_def[i], '"];\n')
  }
  comp_def <- paste0("const int n_comp = ", size, ";\n",
                     "typedef boost::array < double , ", size, " > state_type; \n");
  cpp_code <- readLines(paste0(folder, "/cpp/sim.cpp"))
  idx <- grep("insert_parameter_definitions", cpp_code)
  cpp_code[idx] <- par_def
  idx2 <- grep("insert_state_init", cpp_code)
  cpp_code[idx2] <- paste("   ", code_init)
  cov_scale <- ""
  cov_names <- NULL
  if(!is.null(covariates)) {
    if(class(covariates) == "character") {
      cov_names <- covariates
    }
    if(class(covariates) == "list") {
      cov_names <- names(covariates)
    }
  }
  if(!is.null(cov_names) && length(cov_names) > 0) {
    cov_def <- "  // covariate definitions\n"
    cov_tmp <- "    // covariates during integration period\n"
    for(i in seq(cov_names)) {
      nam <- cov_names[i]
      ode_def_cpp <- paste0(
        paste0('  double ', nam, ' = ', nam, '_0 + gr_', nam, ' * (t - t_prv_', nam, ');\n'),
        ode_def_cpp)
      cov_def <- paste0(cov_def, paste0('  std::vector<double> cov_', nam, ' = design["cov_', nam,'"];\n'))
      cov_def <- paste0(cov_def, paste0('  std::vector<double> cov_t_', nam, ' = design["cov_t_', nam,'"];\n'))
      cov_def <- paste0(cov_def, paste0('  std::vector<double> gradients_', nam, ' = design["gradients_', nam,'"];\n'))
      cov_tmp <- paste0(cov_tmp, paste0('    ', nam, '_0 = cov_', nam,'[i];\n'))
      if(class(covariates) == "list" && tolower(covariates[[nam]]$implementation) != "locf") {
        cov_tmp <- paste0(cov_tmp, paste0('    gr_', nam, ' = gradients_',nam,'[i] ;\n'))
        cov_tmp <- paste0(cov_tmp, paste0('    t_prv_', nam, ' = cov_t_', nam, '[i] ;\n'))
      } else { ## if covariates specified as character vector, also assume non-timevarying
        cov_tmp <- paste0(cov_tmp, paste0('    gr_', nam, ' = 0 ;\n'))
        cov_tmp <- paste0(cov_tmp, paste0('    t_prv_', nam, ' = 0 ;\n'))
      }
      cov_tmp <- paste0(cov_tmp, paste0('    ', nam, ' = ', nam,'_0;\n'))
      cov_scale <- paste0(cov_scale, paste0('      ', nam, ' = ', nam, '_0 + gr_', nam, ' * (tmp.time[k] - t_prv_', nam), ');\n')
    }
    idx3 <- grep("insert covariate definitions", cpp_code)
    cpp_code[idx3] <- cov_def
    idx4 <- grep("insert covariates for integration period", cpp_code)
    cpp_code[idx4] <- cov_tmp
  }
  idx5 <- grep("insert scale definition for integration period", cpp_code)
  idx6 <- grep("observation compartment", cpp_code)
  idx7 <- grep("insert scale definition for observation", cpp_code)
  idx8 <- grep("insert time-dependent covariates scale", cpp_code)
  idx9 <- grep("insert custom dosing code", cpp_code)
  if(is.null(obs)) {
    cpp_code[idx5] <- "    double scale = 1;"
    cpp_code[idx6] <- "  int cmt = 0;"
    cpp_code[idx7] <- "  scale = 1;"
    cpp_code[idx8] <- paste0("    scale = ", obs$scale, ";")
  } else {
    cpp_code[idx5] <- paste0("    scale = ", obs$scale, ";")
    cpp_code[idx6] <- paste0("  int cmt = ", (obs$cmt-1), ";")
    cpp_code[idx7] <- paste0("      scale = ", obs$scale, ";")
    cpp_code[idx8] <- cov_scale
  }
  if(!is.null(dose_code)) {
    cpp_code[idx9] <- dose_code
  }
  sim_func <-
    paste0(paste0(readLines(paste0(folder, "/cpp/sim_header.cpp")), collapse = "\n"),
           pars,
           comp_def,
           "\nvoid ode ( const state_type &A , state_type &dAdt , double t ) {\n",
           ode_def_cpp,
           "\n}\n\n",
           paste0(cpp_code, collapse = "\n"))
  if(cpp_show_code) {
    cat(sim_func)
  }
  flg <- Sys.getenv("PKG_CXXFLAGS")
  if(length(grep("-w", flg)) == 0) {
    Sys.setenv("PKG_CXXFLAGS" = paste(flg, "-w"))
  }
  sourceCpp(code=sim_func, rebuild = TRUE, env = globalenv(), verbose = verbose, showOutput = verbose)
  Sys.setenv("PKG_CXXFLAGS" = flg)
  return(list(
    ode = ode_def_cpp
  ))
}
