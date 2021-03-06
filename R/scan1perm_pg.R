# scan1 permutations by LMM (with a kinship matrix)
scan1perm_pg <-
    function(genoprobs, pheno, kinship, addcovar=NULL, Xcovar=NULL, intcovar=NULL,
             weights=NULL, reml=TRUE, n_perm=1, perm_strata=NULL, cores=1, ind2keep, ...)
{
    # deal with the dot args
    dotargs <- list(...)
    tol <- grab_dots(dotargs, "tol", 1e-12)
    stopifnot(tol > 0)
    intcovar_method <- grab_dots(dotargs, "intcovar_method", "lowmem",
                                 c("highmem", "lowmem"))
    quiet <- grab_dots(dotargs, "quiet", TRUE)
    check_boundary <- grab_dots(dotargs, "check_boundary", TRUE)
    check_extra_dots(dotargs, c("tol", "intcovar_method", "quiet", "max_batch",
                                "check_boundary"))

    # set up parallel analysis
    cores <- setup_cluster(cores)
    if(!quiet && n_cores(cores)>1) {
        message(" - Using ", n_cores(cores), " cores")
        quiet <- TRUE # make the rest quiet
    }

    # max batch size
    max_batch <- grab_dots(dotargs, "max_batch",
                           min(1000, ceiling(n_perm*length(genoprobs)*ncol(pheno)/n_cores(cores))))

    # generate permutations
    perms <- gen_strat_perm(n_perm, ind2keep, perm_strata)

    # batch permutations
    phe_batches <- batch_cols(pheno[ind2keep,,drop=FALSE], max_batch)

    # drop cols in genotype probs that are all 0 (just looking at the X chromosome)
    genoprob_Xcol2drop <- genoprobs_col2drop(genoprobs)
    is_x_chr <- attr(genoprobs, "is_x_chr")
    if(is.null(is_x_chr)) is_x_chr <- rep(FALSE, length(genoprobs))

    ## decompose kinship matrices (multiplied by weights)
    # look for the unique groups of individuals omitted
    #   (we subset and then decompose the kinship matrix separately for each)
    index_batches <- index_batches_by_omits(phe_batches)
    # unique indexes
    uindex_batches <- unique(index_batches)
    decomp_func <- function(i) {
        these2keep <- ind2keep # individuals 2 keep for this batch
        omit <- phe_batches[[uindex_batches[i]]]$omit
        if(length(omit) > 0) these2keep <- ind2keep[-omit]

        k <- subset_kinship(kinship, ind=these2keep)
        wts <- weights[these2keep]
        k <- weight_kinship(k, wts)

        decomp_kinship(k, cores=1)
    }
    kinship_list <- cluster_lapply(cores, seq_along(uindex_batches), decomp_func)

    ## null results
    null_by_batch_func <- function(i) {
        omit <- phe_batches[[i]]$omit
        phecol <- phe_batches[[i]]$cols
        these2keep <- ind2keep # individuals 2 keep for this batch
        if(length(omit) > 0) these2keep <- ind2keep[-omit]
        if(length(these2keep)<=2) return(NULL) # not enough individuals

        ac <- addcovar; if(!is.null(ac)) ac <- ac[these2keep,,drop=FALSE]
        Xc <- Xcovar;   if(!is.null(Xc)) Xc <- Xc[these2keep,,drop=FALSE]
        wts <- weights; if(!is.null(wts)) wts <- wts[these2keep]
        ph <- pheno[these2keep, phecol, drop=FALSE]

        k <- kinship_list[[ index_batches[i] ]]

        # multiply stuff by weights (kinship is already done)
        ac <- weight_matrix(ac, wts)
        Xc <- weight_matrix(Xc, wts)
        ph <- weight_matrix(ph, wts)

        result <- calc_hsq_clean(Ke=k, pheno=ph, addcovar=ac, Xcovar=Xc,
                                 is_x_chr=is_x_chr, reml=reml, weights=wts,
                                 cores=1, check_boundary=check_boundary, tol=tol)

        # expand hsq and loglik to one row per chromosome
        n_chr <- length(is_x_chr)
        if(nrow(result$hsq) != n_chr) {
            if(nrow(result$hsq)==1) {
                for(i in seq_along(result))
                    result[[i]] <- matrix(rep(result[[i]], n_chr), byrow=TRUE, nrow=n_chr)
            }
            else if(nrow(result$hsq)==2) {
                for(i in seq_along(result)) {
                    tmp <- result[[i]]
                    result[[i]] <- matrix(nrow=n_chr, ncol=ncol(tmp))
                    for(j in seq_along(is_x_chr)) {
                        if(is_x_chr[j])
                            result[[i]][j,] <- tmp[2,]
                        else
                            result[[i]][j,] <- tmp[1,]
                    }
                }
            }
        }

        result
    }
    nullresult <- cluster_lapply(cores, seq_along(phe_batches), null_by_batch_func)

    # batches for analysis, to allow parallel analysis
    run_batches <- data.frame(chr=rep(seq_len(length(genoprobs)), length(phe_batches)*n_perm),
                              phe_batch=rep(seq_along(phe_batches), each=length(genoprobs)*n_perm),
                              perm_batch=rep(rep(seq_len(n_perm), each=length(genoprobs), length(phe_batches))))

    run_indexes <- seq_len(length(genoprobs)*length(phe_batches)*n_perm)

    # the function that does the work
    by_group_func <- function(i) {
        # deal with batch information, including individuals to drop due to missing phenotypes
        chr <- run_batches$chr[i]
        chrnam <- names(genoprobs)[chr]
        phebatchnum <- run_batches$phe_batch[i]
        phebatch <- phe_batches[[phebatchnum]]
        permbatch <- run_batches$perm_batch[i]
        phecol <- phebatch$cols
        omit <- phebatch$omit
        these2keep <- ind2keep # individuals 2 keep for this batch
        if(length(omit) > 0) these2keep <- ind2keep[-omit]
        if(length(these2keep)<=2) return(NULL) # not enough individuals

        # apply permutation to the probs
        #     (I initially thought we'd need to apply these just to the rownames, but
        #     actually we've already aligned probs and pheno and so forth
        #     via ind2keep/these2keep, so now we need to just permute the rows)
        #
        # (also need some contortions here to keep the sizes the same)
        pr <- genoprobs[[chr]][ind2keep,,,drop=FALSE]
        pr <- pr[perms[,permbatch],,,drop=FALSE]
        rownames(pr) <- ind2keep
        pr <- pr[these2keep,,,drop=FALSE]

        # subset the genotype probabilities: drop cols with all 0s, plus the first column
        Xcol2drop <- genoprob_Xcol2drop[[chrnam]]
        if(length(Xcol2drop) > 0) {
            pr <- pr[,-Xcol2drop,,drop=FALSE]
        }
        pr <- pr[,-1,,drop=FALSE]

        # subset the rest
        ac <- addcovar; if(!is.null(ac)) ac <- ac[these2keep,,drop=FALSE]
        ic <- intcovar; if(!is.null(ic)) ic <- ic[these2keep,,drop=FALSE]
        wts <- weights; if(!is.null(wts)) wts <- wts[these2keep]
        ph <- pheno[these2keep, phecol, drop=FALSE]

        # grab decomposed kinship matrix for this chromosome
        Ke <- subset_kinship(kinship_list[[index_batches[phebatchnum]]], chr=chrnam)

        # multiply stuff by weights
        ac <- weight_matrix(ac, wts)
        ic <- weight_matrix(ic, wts)
        ph <- weight_matrix(ph, wts)

        # weight the probabilities
        pr <- weight_array(pr, wts)

        # hsq, null_loglik for this batch and chr
        hsq <- nullresult[[phebatchnum]]$hsq[chr,]
        null_loglik <- nullresult[[phebatchnum]]$loglik[chr,]

        # scan this chromosome and calculate maximum LOD for each phenotype
        scan1perm_pg_onechr(pr, Ke, ph, ac, ic, wts, hsq, null_loglik, reml,
                            intcovar_method, tol)

    }

    # calculations in parallel
    list_result <- cluster_lapply(cores, run_indexes, by_group_func)

    # check for problems (if clusters run out of memory, they'll return NULL)
    result_is_null <- vapply(list_result, is.null, TRUE)
    if(any(result_is_null))
        stop("cluster problem: returned ", sum(result_is_null), " NULLs.")

    # reorganize results
    result <- array(dim=c(length(genoprobs), n_perm, ncol(pheno)))

    for(i in run_indexes) {
        chr <- run_batches$chr[i]
        phebatch <- phe_batches[[run_batches$phe_batch[i]]]
        permbatch <- run_batches$perm_batch[i]

        result[chr, permbatch, phebatch$cols] <- list_result[[i]]
    }

    result <- apply(result, c(2,3), max)
    colnames(result) <- colnames(pheno)

    class(result) <- c("scan1perm", "matrix")
    result
}


# identify groups of equivalent batches, by individuals omitted
index_batches_by_omits <-
    function(phe_batches)
{
    omits <- vapply(phe_batches, function(a) paste(a$omit, collapse="|"), "")

    match(omits, omits)
}


# perform an LMM scan for a single chromosome, and returns the maximum LOD for each phenotype
# genoprobs is an array for a single chromosome
# Ke is the decomposed kinship matrix
scan1perm_pg_onechr <-
    function(genoprobs, Ke, pheno, addcovar, intcovar, weights,
             hsq, null_loglik, reml, intcovar_method, tol)
{
    Kevec <- Ke$vectors
    Keval <- Ke$values

    maxlod <- rep(NA, ncol(pheno))

    intercept <- weights; if(is_null_weights(weights)) intercept <- rep(1,nrow(pheno))
    ac <- cbind(intercept, addcovar)
    ic <- intcovar

    for(phecol in seq_len(ncol(pheno))) {
        y <- pheno[,phecol,drop=FALSE]

        w <- 1/(hsq[phecol]*Keval + (1-hsq[phecol]))
        w <- sqrt(w)

        if(is.null(ic))
            loglik <- scan_pg_onechr(genoprobs, y, ac, Kevec, w, tol)
        else if(intcovar_method=="highmem")
            loglik <- scan_pg_onechr_intcovar_highmem(genoprobs, y, ac, ic, Kevec, w, tol)
        else
            loglik <- scan_pg_onechr_intcovar_lowmem(genoprobs, y, ac, ic, Kevec, w, tol)

        maxlod[phecol] <- (max(loglik) - null_loglik[phecol])/log(10)
    }
    names(maxlod) <- colnames(pheno)

    maxlod
}
