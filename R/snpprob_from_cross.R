# snpprob_from_cross: genoprob_to_snpprob where snpinfo is a cross2 object
# ...construct snpinfo for all markers with no missing founder genotypes
# ...apply genoprob_to_snpprob with that

snpprob_from_cross <-
    function(genoprobs, cross)
{
    if(!("founder_geno" %in% names(cross)))
        stop("cross doesn't contain founder_geno")

    ### calculate snp info from cross
    # drop markers that are missing any founder genotypes
    cross <- drop_markers(cross, unlist(lapply(cross$founder_geno, function(a) colnames(a)[colSums(a==0)>0])))

    # subset to common chr
    chr_pr <- names(genoprobs)
    chr_cross <- chr_names(cross)
    chr <- chr_pr[chr_pr %in% chr_cross]
    cross <- cross[,chr]
    genoprobs <- genoprobs[,chr]

    # get physical map, if available; otherwise genetic map
    map <- cross$pmap
    if(is.null(map)) map <- cross$gmap

    sdp <- calc_sdp(t(do.call("cbind", cross$founder_geno)))

    snpinfo <- data.frame(chr=rep(chr_names(cross), n_mar(cross)),
                          pos=unlist(map),
                          sdp=sdp,
                          snp=names(sdp))

    mar2keep <- NULL
    for(i in seq_along(genoprobs)) {
        mar <- colnames(cross$geno[[i]])
        mar <- mar[mar %in% dimnames(genoprobs)[[3]][[i]]]
        if(length(mar) == 0) {
            stop("No overlap between genoprobs and markers on chr ", names(genoprobs)[i])
        }
        map[[i]] <- map[[i]][mar]

        if("fst_genoprob" %in% class(genoprobs)) {
            mar2keep <- c(mar2keep, mar)
        } else {
            genoprobs[[i]] <- genoprobs[[i]][,,mar,drop=FALSE]
        }
    }
    if("fst_genoprob" %in% class(genoprobs)) {
        genoprobs <- subset(genoprobs, mar=mar2keep)
    }

    snpinfo <- index_snps(map, snpinfo)

    genoprob_to_snpprob(genoprobs, snpinfo)
}
