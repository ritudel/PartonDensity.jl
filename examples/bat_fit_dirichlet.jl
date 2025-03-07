# # Fit with Dirichlet parametrisation
#
# In this example we show how to bring the PDF parametrisation and
# forward model together with `BAT.jl` to perform a fit of simulated data.
# This fit is a work in progress and just a starting point for verification
# of the method.

using BAT, DensityInterface
using PartonDensity
using QCDNUM
using Plots, Random, Distributions, ValueShapes, ParallelProcessingTools
using StatsBase, LinearAlgebra

gr(fmt=:png);

# ## Simulate some data

seed = 42
Random.seed!(seed) # for reproducibility

# We can start off by simulating some fake data for us to fit. This way,
# we know exactly what initial conditions we have specified and can check
# the validity of our inference, assuming the generative model is the one that is producing our data.
#
# This is a good first check to work with.
#
# ### Specify the input PDFs
#
# See the *Input PDF parametrisation and priors* example for more information on the
# definition of the input PDFs. Here, we use the Dirichlet parametrisation.

pdf_params = DirichletPDFParams(K_u=4.0, K_d=4.0, λ_g1=1.5, λ_g2=-0.4, K_g=6.0,
    λ_q=-0.25, K_q=5, weights=[30.0, 15.0, 12.0, 6.0, 3.6, 0.85, 0.85, 0.85, 0.85]);

@info "Valence λ:" pdf_params.λ_u pdf_params.λ_d

plot_input_pdfs(pdf_params)

# ### Go from PDFs to counts in ZEUS detector bins
#
# Given the input PDFs, we can then evolve, calculate the cross sections, and fold through
# the ZEUS transfer matrix to get counts in bins. Here, we make use of some simple helper
# functions to do so. For more details, see the *Forward model* example.

# first specify QCDNUM inputs
qcdnum_grid = QCDNUMGrid(x_min=[1.0e-3, 1.0e-1, 5.0e-1], x_weights=[1, 2, 2], nx=100,
    qq_bounds=[1.0e2, 3.0e4], qq_weights=[1.0, 1.0], nq=50, spline_interp=3)
qcdnum_params = QCDNUMParameters(order=2, α_S=0.118, q0=100.0, grid=qcdnum_grid,
    n_fixed_flav=5, iqc=1, iqb=1, iqt=1, weight_type=1);

# now SPLINT and quark coefficients
splint_params = SPLINTParameters();
quark_coeffs = QuarkCoefficients();

# initialise QCDNUM
forward_model_init(qcdnum_grid, qcdnum_params, splint_params)

# run forward model 
counts_pred_ep, counts_pred_em = forward_model(pdf_params, qcdnum_params,
    splint_params, quark_coeffs);

#
# take a poisson sample
nbins = size(counts_pred_ep)[1]
counts_obs_ep = zeros(UInt64, nbins)
counts_obs_em = zeros(UInt64, nbins)

for i in 1:nbins
    counts_obs_ep[i] = rand(Poisson(counts_pred_ep[i]))
    counts_obs_em[i] = rand(Poisson(counts_pred_em[i]))
end

#

plot(1:nbins, counts_pred_ep, label="Expected counts (eP)", color="blue")
plot!(1:nbins, counts_pred_em, label="Expected counts (eM)", color="red")
scatter!(1:nbins, counts_obs_ep, label="Detected counts (eP)", color="blue")
scatter!(1:nbins, counts_obs_em, label="Detected counts (eM)", color="red")
plot!(xlabel="Bin number")

# store
sim_data = Dict{String,Any}()
sim_data["nbins"] = nbins;
sim_data["counts_obs_ep"] = counts_obs_ep;
sim_data["counts_obs_em"] = counts_obs_em;

# write to file
pd_write_sim("output/simulation.h5", pdf_params, sim_data)

# ## Fit the simulated data
#
# Now we can try to fit this simulated data using `Bat.jl`.
# The first step is to define the prior and likelihood.
# For now, let's try relatively narrow priors centred on the true values.

prior = NamedTupleDist(
    θ=Dirichlet(pdf_params.weights),
    K_u=Uniform(3.0, 7.0),
    K_d=Uniform(3.0, 7.0),
    λ_g1=Uniform(1.0, 2.0),
    λ_g2=Uniform(-0.5, -0.1),
    K_g=Uniform(3.0, 7.0),
    λ_q=Uniform(-0.5, -0.1),
    K_q=Uniform(3.0, 7.0),
);

# The likelihood is similar to that used in the *input PDF parametrisation* example.
# We start by accessing the current parameter set of the sampler's iteration,
# then running the forward model to get the predicted counts and comparing to
# the observed counts using a simple Poisson likelihood.
#
# The `@critical` macro is used because `forward_model()` is currently not thread safe, so
# this protects it from being run in parallel.

likelihood = let d = sim_data

    counts_obs_ep = d["counts_obs_ep"]
    counts_obs_em = d["counts_obs_em"]
    nbins = d["nbins"]

    logfuncdensity(function (params)

        pdf_params = DirichletPDFParams(K_u=params.K_u, K_d=params.K_d, λ_g1=params.λ_g1, λ_g2=params.λ_g2,
            K_g=params.K_g, λ_q=params.λ_q, K_q=params.K_q, θ=params.θ)

        #Ensure u-valence weight > d-valence weight
        if params.θ[2] > params.θ[1]

            return -Inf

        end

        counts_pred_ep, counts_pred_em = @critical forward_model(pdf_params,
            qcdnum_params, splint_params, quark_coeffs)

        ll_value = 0.0
        for i in 1:nbins

            if counts_pred_ep[i] < 0
                @debug "counts_pred_ep[i] < 0, setting to 0" i counts_pred_ep[i]
                counts_pred_ep[i] = 0
            end

            if counts_pred_em[i] < 0
                @debug "counts_pred_em[i] < 0, setting to 0" i counts_pred_em[i]
                counts_pred_em[i] = 0
            end

            ll_value += logpdf(Poisson(counts_pred_ep[i]), counts_obs_ep[i])
            ll_value += logpdf(Poisson(counts_pred_em[i]), counts_obs_em[i])
        end

        return ll_value
    end)
end

# We can now run the MCMC sampler. We will start by using the
# Metropolis-Hastings algorithm as implemented in `BAT.jl`.
# To get reasonable results, we need to run the sampler for a
# long time (several hours). To save time in this demo, we will
# work with a ready-made results file. To actually run the sampler,
# simply uncomment the code below.

#posterior = PosteriorDensity(likelihood, prior);
#mcalg = MetropolisHastings(proposal=BAT.MvTDistProposal(10.0))
#convergence = BrooksGelmanConvergence(threshold=1.3);
#burnin = MCMCMultiCycleBurnin(max_ncycles=50);

#samples = bat_sample(posterior, MCMCSampling(mcalg=mcalg, nsteps=10^4, nchains=2)).result;
# Alternatively, we could also try a nested sampling approach
# here for comparison. This is easily done thanks to the
# interface of `BAT.jl`, you will just need to add the
# `NestedSamplers.jl` package.

#import NestedSamplers
#samples = bat_sample(posterior, EllipsoidalNestedSampling()).result

# If you run the sampler, be sure to save
# the results for further analysis

#import HDF5
#bat_write("output/results.h5", samples)

# ## Analysing the results
#
# First, let's load our simulation inputs and results

pdf_params, sim_data = pd_read_sim("output/demo_simulation_dirichlet.h5");
samples = bat_read("output/demo_results_dirichlet.h5").result;

# We can check some diagnostics using built in `BAT.jl`, such as the
# effective sample size shown below

bat_eff_sample_size(unshaped.(samples))[1]

# We see a value for each of our 15 total parameters. As the
# Metropolis-Hastings algorithm's default implementation
# isn't very efficient, we see that the effective sample size
# is only a small percentage of the input `nsteps`. We should try
# to improve this if possible, or use a much larger `nsteps` value.
#
# For demonstration purposes, we will continue to show how we can
# visualise the results in this case. For robust inference, we need
# to improve the sampling stage above.

# We can use `BAT.jl`'s built in plotting recipes to show the marginals,
# for example, consider `λ_u`, and compare to the known truth.

plot(
    samples, :(K_u),
    nbins=50,
    colors=[:skyblue4, :skyblue3, :skyblue1],
    alpha=0.7,
    marginalmode=false,
    legend=:topleft
)
vline!([pdf_params.K_u], color="black", label="truth", lw=3)

# If we want to compare the momentum weights, we no longer need to
# transform (compared to the valence parametrisation case) and can
# simply use the `BAT.jl` recipes as before.

plot(
    samples, (:(θ[1]), :(θ[2])),
    nbins=50,
    colors=[:skyblue4, :skyblue3, :skyblue1],
    alpha=0.7,
    marginalmode=false,
    legend=:topright
)

vline!([pdf_params.θ[1]], color="black", label="true θ[1]", lw=3)
hline!([pdf_params.θ[2]], color="black", label="true θ[2]", lw=3)

# Rather than making a large plot 15 different marginals,
# it can be more useful to visualise the posterior distribution
# in differently, such as the shape of the distributions
# we are trying to fit, or the *model space*. Helper functions
# exist for doing just this.

# Using BAT recipe
function wrap_xtotx(p::NamedTuple, x::Real)
    pdf_params = DirichletPDFParams(K_u=p.K_u, K_d=p.K_d, λ_g1=p.λ_g1,
        λ_g2=p.λ_g2, K_g=p.K_g, λ_q=p.λ_q, K_q=p.K_q, θ=p.θ)
    return log(xtotx(x, pdf_params))
end

x_grid = range(1e-3, stop=1, length=50)
plot(x_grid, wrap_xtotx, samples, colors=[:skyblue4, :skyblue3, :skyblue1],
    legend=:topright)
plot!(x_grid, [log(xtotx(x, pdf_params)) for x in x_grid], color="black", lw=3,
    label="Truth", linestyle=:dash)
plot!(ylabel="log(xtotx)")

# Using `PartonDensity.jl`
plot_model_space(pdf_params, samples, nsamples=500)

# Alternatively, we can also visualise the implications of the fit
# in the *data space*, as shown below. 

plot_data_space(pdf_params, sim_data, samples, qcdnum_grid, qcdnum_params,
    splint_params, quark_coeffs, nsamples=500)

# The first results seem promising, but these are really just first checks
# and more work will have to be done to verify the method.
