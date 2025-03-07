using HDF5

export forward_model, forward_model_init
export pd_write_sim, pd_read_sim
export reset_qcdnum_evolfg_ϵ_values

qcdnum_evolfg_ϵ_values = Vector{Float64}()
splint_init_complete = false


function forward_model(pdf_params::Union{BernsteinPDFParams, BernsteinDirichletPDFParams}, qcdnum_params::QCDNUMParameters,
                       splint_params::SPLINTParameters, quark_coeffs::QuarkCoefficients)


    # Get input PDF function
    my_func = get_input_pdf_func(pdf_params)
    input_pdf = @cfunction($my_func, Float64, (Ref{Int32}, Ref{Float64}))

    # Evolve PDFs
    iq0 = QCDNUM.iqfrmq(qcdnum_params.q0)
    pdf_loc = 1
    ϵ = QCDNUM.evolfg(pdf_loc, input_pdf, input_pdf_map, iq0)

    # Debugging
    if ϵ > 0.05

        @warn "QCDNUM.evolfg(): Spline issues detected" eps pdf_params

    end
    push!(qcdnum_evolfg_ϵ_values, ϵ)

    # Read spline addresses
    iaF2up = Int64(QCDNUM.dsp_uread(splint_params.spline_addresses.F2up))
    iaF2dn = Int64(QCDNUM.dsp_uread(splint_params.spline_addresses.F2dn))
    iaF3up = Int64(QCDNUM.dsp_uread(splint_params.spline_addresses.F3up))
    iaF3dn = Int64(QCDNUM.dsp_uread(splint_params.spline_addresses.F3dn))
    iaFLup = Int64(QCDNUM.dsp_uread(splint_params.spline_addresses.FLup))
    iaFLdn = Int64(QCDNUM.dsp_uread(splint_params.spline_addresses.FLdn))
    iaF_eP = Int64(QCDNUM.dsp_uread(splint_params.spline_addresses.F_eP))
    iaF_eM = Int64(QCDNUM.dsp_uread(splint_params.spline_addresses.F_eM))

    # Splines for structure functions
    QCDNUM.ssp_s2f123(iaFLup, pdf_loc, quark_coeffs.proup, 1, 0.0)
    QCDNUM.ssp_s2f123(iaF2up, pdf_loc, quark_coeffs.proup, 2, 0.0)
    QCDNUM.ssp_s2f123(iaF3up, pdf_loc, quark_coeffs.valup, 3, 0.0)
    QCDNUM.ssp_s2f123(iaFLdn, pdf_loc, quark_coeffs.prodn, 1, 0.0)
    QCDNUM.ssp_s2f123(iaF2dn, pdf_loc, quark_coeffs.prodn, 2, 0.0)
    QCDNUM.ssp_s2f123(iaF3dn, 1, quark_coeffs.valdn, 3, 0.0)

    # Get input cross section function
    my_func = get_input_xsec_func()
    input_xsec = @cfunction($my_func, Float64, (Ref{Int32}, Ref{Int32}, Ref{UInt8}))

    # Make two cross section splines
    set_lepcharge(1)
    QCDNUM.ssp_s2fill(iaF_eP, input_xsec, splint_params.rscut)

    set_lepcharge(-1)
    QCDNUM.ssp_s2fill(iaF_eM, input_xsec, splint_params.rscut)

    # Integrate over cross section
    nbins = size(xbins_M_begin)[1]
    integ_xsec_ep = zeros(nbins)
    integ_xsec_em = zeros(nbins)

    for i in 1:nbins
        integ_xsec_ep[i] = QCDNUM.dsp_ints2(iaF_eP, xbins_M_begin[i], xbins_M_end[i],
            q2bins_M_begin[i], q2bins_M_end[i], 318.0, 4)
        integ_xsec_em[i] = QCDNUM.dsp_ints2(iaF_eM, xbins_M_begin[i], xbins_M_end[i],
            q2bins_M_begin[i], q2bins_M_end[i], 318.0, 4)
    end

    # Fold through response to get counts
    ePp = 0
    eMp = 1

    TM_eP = get_TM_elements(ePp)
    TM_eM = get_TM_elements(eMp)

    K_eP = get_K_elements(ePp)
    K_eM = get_K_elements(eMp)

    nbins_out = size(TM_eP)[2]

    counts_pred_ep = zeros(nbins_out)
    counts_pred_em = zeros(nbins_out)

    for j in 1:nbins_out

        for i in 1:nbins

            counts_pred_ep[j] += TM_eP[i, j] * (1.0 / K_eP[i]) * integ_xsec_ep[i]
            counts_pred_em[j] += TM_eM[i, j] * (1.0 / K_eM[i]) * integ_xsec_em[i]

        end

    end

    return counts_pred_ep, counts_pred_em

end

      
function pd_write_sim(file_name::String, pdf_params::Union{BernsteinPDFParams, BernsteinDirichletPDFParams}, sim_data::Dict{String, Any})

    h5open(file_name, "w") do fid

        # store sim_data
        sim_data_group = create_group(fid, "data")
        for (key, value) in sim_data
            sim_data_group[key] = value
        end

        # store pdf_params
        truth_group = create_group(fid, "truth")
        truth_group["U_list"] = pdf_params.U_list
        truth_group["D_list"] = pdf_params.D_list
        truth_group["λ_g1"] = pdf_params.λ_g1
        truth_group["λ_g2"] = pdf_params.λ_g2
        truth_group["K_g"] = pdf_params.K_g
        truth_group["λ_q"] = pdf_params.λ_q
        truth_group["K_q"] = pdf_params.K_q
        truth_group["seed"] = pdf_params.seed
        truth_group["weights"] = pdf_params.weights
        truth_group["θ"] = pdf_params.θ
        truth_group["param_type"] = pdf_params.param_type

    end

    return nothing
end
