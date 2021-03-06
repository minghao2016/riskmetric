#' If not NULL else
#'
#' @param lhs Left-hand side
#' @param rhs Right-hand side
#'
#' A shorthand for a common comparison
#'
#' @name if_not_null_else
`%||%` <- function(lhs, rhs) if (is.null(lhs)) rhs else lhs



#' Accessor for tools namespace
#'
#' used internally for
#'   - tools:::.news_reader_default
.tools <- memoise::memoise(function() {
  getNamespace("tools")
})



#' check if a url originates from a list of repo urls
#'
#' @param url a url which may stem from one of the provided base urls
#' @param urls vector of base urls
#'
#' @return logical vector indicating which base urls have a sub url of
#'   \code{url}
#'
is_url_subpath_of <- function(url, urls) {
  grepl(paste0("(", paste0(gsub("/$", "", urls), collapse = "|"), ")"), url)
}



#' Evaluate an expression after first removing a range of S3 classes
#'
#' @param x a structured S3-classed object
#' @param .class the class to unclass the object to
#' @param expr an expression to evaluate, avoiding parent classs dispatch
#' @param envir an environment in which the expression is to be evaluated
#'
#' @return the result of \code{expr}
#'
with_unclassed_to <- function(x, .class = 1:length(class(x)), expr,
    envir = parent.frame()) {

  x_expr <- substitute(x)
  orig_class <- class(x)
  if (is.character(.class)) .class = 1:which(class(x) == .class)

  eval(bquote(class(.(x_expr)) <- class(.(x_expr))[-.(.class)]), envir = envir)
  out <- eval(expr, envir = envir)
  eval(bquote(class(.(x_expr)) <- .(orig_class)), envir = envir)
  out
}



#' Capture side effects issued by an evaluated expression
#'
#' All messaging condition side effects are captured in the order that they
#' are issued.
#'
#' @param expr an expression to evaluate, capturing output events as they
#'   are issued
#' @param env the environment in which \code{expr} should be evaluated,
#'   defaulting to the calling environment.
#' @param quoted whether \code{expr} is a quoted object and should be evaluated
#'   as is, or whether the expression should be captured from the function call.
#'   Defaults to \code{FALSE}, capturing the passed expression.
#' @inheritParams base::sink
#'
#' @examples
#' fn <- function() {
#'   print(paste(letters[1:3], collapse = ", "))
#'   warning("easy as")
#'   message(paste(1:3, collapse = ", "))
#'   message("simple as")
#'   warning("do re mi")
#'   return(3L)
#' }
#'
#' console_output <- riskmetric:::capture_expr_output(fn())
#'
#' console_output
#' # > fn()
#' # [1] "a, b, c"
#' # Warning in fn(): easy as
#' # 1, 2, 3
#' # simple as
#' # Warning in fn(): do re mi
#' # [1] 3
#'
#' @importFrom utils head tail
#'
capture_expr_output <- function(expr, split = FALSE, env = parent.frame(),
    quoted = FALSE) {

  expr_quote <- substitute(expr)
  log_file <- tempfile("riskmetric_sink_", fileext = ".txt")
  log_file_con <- file(log_file, "wb")
  on.exit(try(close(log_file_con), silent = TRUE))

  cnds_seek <- numeric()
  cnds_err_traceback <- NULL
  cnds <- list() # messages + warnings + misc conditions

  append_cnd <- function(cnd, envir) {
    cnd_seek <- seek(log_file_con)
    assign("cnds_seek", append(cnds_seek, cnd_seek), envir = envir)
    assign("cnds", append(cnds, list(cnd)), envir = envir)
  }

  n_calls <- length(sys.calls())
  fn_env <- environment()
  sink(log_file_con, split = split)
  res <- withVisible(try(withCallingHandlers(
    if (!quoted) eval(expr_quote, env) else eval(expr, env),
    condition = function(cnd) {
      append_cnd(cnd, fn_env)
      if (inherits(cnd, "message") || inherits(cnd, "warning")) {
        invokeRestart(computeRestarts()[[1]])
      } else if (inherits(cnd, "error")) {
        # trim call stack back to just the scope of the evaluated expression
        syscalls <- utils::head(utils::tail(sys.calls(), -(9L + n_calls)), -2L)
        assign("cnds_err_traceback", syscalls, envir = fn_env)
      }
    }), silent = TRUE))

  # read as raw so that we can keep carriage return and console-overwrites
  sink(NULL)
  close(log_file_con)
  log_text <- rawToChar(readBin(log_file, "raw", file.size(log_file)))
  log_text_line_nchars <- nchar(strsplit(gsub("\r", "\n", log_text), "\n")[[1]])

  # NOTE: Windows might use two newline characters "\r\n"?
  log_newlines <- cumsum(log_text_line_nchars + 1L)

  # rejoin into singular string to split at newlines, as well as any condition
  # emission points
  log_cuts <- sort(unique(c(log_newlines, cnds_seek)))
  log_cuts <- log_cuts[log_cuts < nchar(log_text)]
  log_text <- substring(log_text, c(1, log_cuts + 1L), c(log_cuts, nchar(log_text)))
  log_chars <- cumsum(nchar(log_text))

  # find where to insert emitted conditions among output
  cnd_i <- findInterval(cnds_seek, log_chars)
  cnds_new_index <- cnd_i + seq_along(cnd_i)

  # inject conditions throughout console output as they were emitted
  outputs <- rep(list(NULL), length(log_text) + length(cnds_new_index))
  if (length(cnds_new_index) > 0L) {
    outputs[cnds_new_index] <- cnds
    outputs[-cnds_new_index] <- log_text
  } else {
    outputs <- log_text
  }

  any_output_error <- any(vapply(outputs, inherits, logical(1L), "error"))

  structure(
    if (!quoted) expr_quote else expr,
    value = res$value,
    visible = res$visible,
    traceback = cnds_err_traceback,
    output = outputs[nzchar(outputs)],
    class = c("expr_output", "expression"))
}



#' Handle pretty printing of expression output
#'
#' @param x expr_output to print
#' @param cr a \code{logical} indicating whether carriage returns should be
#'   printed, possibly overwriting characters in the output.
#' @param ... additional arguments unused
#' @param sleep an \code{numeric} indicating a time to sleep between printing
#'   each line to console. This can be helpful if the original output overwrites
#'   valuable information in the log that is eventually overwritten and you
#'   would like to watch it play out as it was formatted.
#'
#' @export
#'
#'
print.expr_output <- function(x, cr = TRUE, ..., sleep = 0) {
  x_call <- as.call(as.list(x))

  if (x_call[[1]] == "{") {
    x_call_str <- vapply(
      x_call[-1],
      function(xi) paste0(capture.output(xi), collapse = "\n"),
      character(1L))
  } else {
    x_call_str <- capture.output(x_call)
  }

  x_call_str[1] <- paste(">", x_call_str[1])
  x_call_str[-1] <- paste("+", x_call_str[-1])
  str_call <- paste(x_call_str, collapse = "\n")

  str_traceback <- paste(
    sprintf(
      "%s  %s",
      "#",
      capture.output(traceback(attr(x, "traceback")))),
    collapse = "\n")

  cat(str_call, "\n", sep = "")
  for (i in attr(x, "output")) {
    if (inherits(i, "message")) {
      message(i$message, appendLF = FALSE)
    } else if (inherits(i, "warning")) {
      message(gsub("^simple", "", .makeMessage(i)), appendLF = FALSE)
    } else if (inherits(i, "error")) {
      message(sprintf("Error%s: %s\n",
        if (!is.null(i$call)) sprintf(" in %s ", format(i$call)) else "",
        i$message), appendLF = FALSE)
    } else if (inherits(i, "condition")) {
      message(.makeMessage(i))
    } else if (cr) {
      cat(i)
    } else if (nzchar(gsub("\r", "", i))) {
      cat(gsub("\r", "\n", i))
    }
    if (sleep > 0L) Sys.sleep(sleep)
  }
  if (!is.null(attr(x, "traceback"))) cat(str_traceback, "\n", sep = "")
  else if (attr(x, "visible")) print(attr(x, "value"))
}




#' Suppress messages and warnings based on one or more regex matches
#'
#' @param expr An expression to evaluate
#' @param ... Named parameters, where the name indicates the class of conditions
#'   to capture and the value is a vector of regular expressions that, when
#'   matched against the respective condition message, should suppress that
#'   condition.
#' @param .opts A named list of arguments to pass to \code{grepl}
#'
#' @examples
#' riskmetric:::suppressMatchingConditions({
#'     print(paste(letters[1:3], collapse = ", "))
#'     warning(structure(
#'       list(message = "easy as", call = NULL),
#'       class = c("custom_warning", "warning", "condition")))
#'     message(paste(1:3, collapse = ", "))
#'     message("simple as")
#'     warning("do re mi")
#'   },
#'   message = "\\d",
#'   custom_warning = "as$",
#'   warning = "\\w{2}\\s")
#'
suppressMatchingConditions <- function(expr, ..., .opts = list()) {
  optioned_grepl <- function(pattern, x)
    do.call(grepl, append(list(pattern = pattern, x = x), .opts))

  generate_cond_handler <- function(cond_regexes) {
    function(cond) {
      if (any(sapply(cond_regexes, optioned_grepl, conditionMessage(cond))))
        invokeRestart(computeRestarts()[[1]])
    }
  }

  do.call(withCallingHandlers, append(list(
    substitute(expr)),
    lapply(list(...), generate_cond_handler)))
}
