#ifndef CROSS_F2_H
#define CROSS_F2_H

class F2 : public Cross
{
 public:
    F2(){
        type = "f2";
        phase_known_type = "f2pk";
    };
    ~F2(){};

    bool check_geno(int gen, bool is_observed_value,
                bool is_X_chr, bool is_female, IntegerVector cross_info);

    double init(int true_gen,
                bool is_X_chr, bool is_female, IntegerVector cross_info);
    double emit(int obs_gen, int true_gen, double error_prob,
                bool is_X_chr, bool is_female, IntegerVector cross_info);
    double step(int gen_left, int gen_right, double rec_frac,
                bool is_X_chr, bool is_female, IntegerVector cross_info);

    IntegerVector geno_index(bool is_X_chr, bool is_female, IntegerVector cross_info);

    int n_geno(bool is_X_chr);

};

#endif // CROSS_F2_H
