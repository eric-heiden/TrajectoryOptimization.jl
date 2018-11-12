# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
# FILE CONTENTS:
#     SUMMARY: Forward and Backward passes for iLQR algorithm
#
#     backwardpass!: iLQR backward pass
#     backwardpass_sqrt: iLQR backward pass with Cholesky Factorization of
#        Cost-to-Go
#     backwardpass_foh!: iLQR backward pass for first order hold on controls
#     chol_minus: Calculate sqrt(A-B)
#     forwardpass!: iLQR forward pass
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

"""
$(SIGNATURES)
Solve the dynamic programming problem, starting from the terminal time step
Computes the gain matrices K and d by applying the principle of optimality at
each time step, solving for the gradient (s) and Hessian (S) of the cost-to-go
function. Also returns parameters Δv for line search (see Synthesis and Stabilization of Complex Behaviors through
Online Trajectory Optimization)
"""
function backwardpass!(res::SolverVectorResults,solver::Solver)
    N = solver.N; n = solver.model.n; m = solver.model.m;
    Q = solver.obj.Q; Qf = solver.obj.Qf; xf = solver.obj.xf;
    R = getR(solver)
    dt = solver.dt

    # check if infeasible start solve
    if solver.model.m != length(res.U[1])
        m += n
    end

    # pull out values from results
    X = res.X; U = res.U; K = res.K; d = res.d; S = res.S; s = res.s

    # Boundary Conditions
    S[N] = Qf
    s[N] = Qf*(X[N] - xf)

    # Terminal constraints
    if res isa ConstrainedIterResults
        C = res.C; Iμ = res.Iμ; λ = res.λ
        CxN = res.Cx_N
        S[N] += CxN'*res.IμN*CxN
        s[N] += CxN'*res.IμN*res.CN + CxN'*res.λN
    end


    # Backward pass
    k = N-1
    Δv = [0. 0.] # Initialize expected change in cost-to-go
    while k >= 1
        # compute stage cost expansions
        lx = dt*Q*vec(X[k] - xf)
        lu = dt*R*vec(U[k])
        lxx = dt*Q
        luu = dt*R

        # Compute gradients of the dynamics
        fx, fu = res.fx[k], res.fu[k]

        # Gradients and Hessians of Taylor Series Expansion of Q
        Qx = lx + fx'*vec(s[k+1])
        Qu = lu + fu'*vec(s[k+1])
        Qxx = lxx + fx'*S[k+1]*fx
        Quu = luu + fu'*S[k+1]*fu
        Qux = fu'*S[k+1]*fx

        # Constraints
        if res isa ConstrainedIterResults
            Cx, Cu = res.Cx[k], res.Cu[k]
            Qx += Cx'*Iμ[k]*C[k] + Cx'*λ[k]
            Qu += Cu'*Iμ[k]*C[k] + Cu'*λ[k]
            Qxx += Cx'*Iμ[k]*Cx
            Quu += Cu'*Iμ[k]*Cu
            Qux += Cu'*Iμ[k]*Cx
        end

        # Regularization
        # Note: it is critical to have a separate, regularized Quu, Qux for the gains and unregularized versions for S,s to propagate backward
        if solver.opts.regularization_type == :state
            Quu_reg = Quu + res.ρ[1]*fu'*fu
            Qux_reg = Qux + res.ρ[1]*fu'*fx
        elseif solver.opts.regularization_type == :control
            Quu_reg = Quu + res.ρ[1]*I
            Qux_reg = Qux
        end

        # check that Quu_reg is positive definite
        if !isposdef(Hermitian(Array(Quu_reg)))  # need to wrap Array since isposdef doesn't work for static arrays
            @logmsg InnerLoop "Regularized"
            # if solver.opts.verbose
            #     println("regularized (normal bp)")
            #     println("-condition number: $(cond(Array(Quu_reg)))")
            #     println("Quu_reg: $Quu_reg")
            # end

            # increase regularization
            regularization_update!(res,solver,:increase)

            # reset backward pass
            k = N-1
            Δv = [0.0 0.0]
            continue
        end

        # Compute gains
        K[k] = -Quu_reg\Qux_reg
        d[k] = -Quu_reg\Qu

        # Calculate cost-to-go (using unregularized Quu and Qux)
        s[k] = vec(Qx) + K[k]'*Quu*vec(d[k]) + K[k]'*vec(Qu) + Qux'*vec(d[k])
        S[k] = Qxx + K[k]'*Quu*K[k] + K[k]'*Qux + Qux'*K[k]
        S[k] = 0.5*(S[k] + S[k]')

        # calculated change is cost-to-go over entire trajectory
        Δv += [vec(d[k])'*vec(Qu) 0.5*vec(d[k])'*Quu*vec(d[k])]

        k = k - 1;
    end

    # decrease regularization after successful backward pass
    regularization_update!(res,solver,:decrease)

    return Δv
end

function backwardpass_mintime!(res::SolverVectorResults,solver::Solver)
    n,m,N = get_sizes(solver)
    Q = solver.obj.Q; Qf = solver.obj.Qf; xf = solver.obj.xf; c = solver.obj.c;
    R = getR(solver)
    dt = solver.dt

    min_time = is_min_time(solver)
    m̄,mm = get_num_controls(solver)

    # pull out values from results
    X = res.X; U = res.U; K = res.K; d = res.d; S = res.S; s = res.s

    # Boundary Conditions
    S[N] = Qf
    s[N] = Qf*(X[N] - xf)

    # Initialize expected change in cost-to-go
    Δv = [0.0 0.0]

    # Terminal constraints
    if res isa ConstrainedIterResults
        C = res.C; Iμ = res.Iμ; λ = res.λ
        CxN = res.Cx_N
        S[N] += CxN'*res.IμN*CxN
        s[N] += CxN'*res.IμN*res.CN + CxN'*res.λN
    end


    # Backward pass
    k = N-1
    while k >= 1
        min_time ? dt = U[k][m̄]^2 : nothing

        lx = dt*Q*vec(X[k] - xf)
        lu = dt*R*vec(U[k])
        lxx = dt*Q
        luu = dt*R

        # Compute gradients of the dynamics
        fx, fu = res.fx[k], res.fu[k]

        # Gradients and Hessians of Taylor Series Expansion of Q
        Qx = lx + fx'*vec(s[k+1])
        Qu = lu + fu'*vec(s[k+1])
        Qxx = lxx + fx'*S[k+1]*fx

        Quu = luu + fu'*S[k+1]*fu
        Qux = fu'*S[k+1]*fx

        # Constraints
        if res isa ConstrainedIterResults
            Cx, Cu = res.Cx[k], res.Cu[k]
            Qx += Cx'*Iμ[k]*C[k] + Cx'*λ[k]
            Qu += Cu'*Iμ[k]*C[k] + Cu'*λ[k]
            Qxx += Cx'*Iμ[k]*Cx
            Quu += Cu'*Iμ[k]*Cu
            Qux += Cu'*Iμ[k]*Cx

            if min_time
                h = U[k][m̄]
                Qu[m̄] += 2*h*stage_cost(X[k],U[k],Q,R,xf,c)
                Qux[m̄,1:n] += vec(2h*(X[k]-xf)'Q)
                tmp = zero(Quu)
                tmp[:,m̄] = R*U[k]
                Quu += 2h*(tmp+tmp')
                Quu[m̄,m̄] += 2*stage_cost(X[k],U[k],Q,R,xf,c)

                if k > 1
                    Qu[m̄] += - C[k-1][end]*Iμ[k-1][end,end] - λ[k-1][end]
                    Quu[m̄,m̄] += Iμ[k-1][end,end]
                end

            end

        end

        # Note: it is critical to have a separate, regularized Quu, Qux for the gains and unregularized versions for S,s to propagate backward
        if solver.opts.regularization_type == :state
            Quu_reg = Quu + fu'*(res.ρ[1]*I)*fu
            Qux_reg = Qux + fu'*(res.ρ[1]*I)*fx
        elseif solver.opts.regularization_type == :control
            Quu_reg = Quu + res.ρ[1]*I
            Qux_reg = Qux
        end

        # Regularization
        if rank(Quu_reg) != mm  # need to wrap Array since isposdef doesn't work for static arrays
            if solver.opts.verbose # TODO: switch to logger
                println("regularized (normal bp)")
                println("-condition number: $(cond(Array(Quu_reg)))")
                println("Quu_reg: $(eigvals(Quu_reg))")
                @show Quu_reg
            end

            # increase regularization
            regularization_update!(res,solver,:increase)

            # reset backward pass
            k = N-1
            Δv = [0.0 0.0]
            continue
        end

        # Compute gains
        K[k] = -Quu_reg\Qux_reg
        d[k] = -Quu_reg\Qu

        # Calculate cost-to-go (using unregularized Quu and Qux)
        s[k] = vec(Qx) + K[k]'*Quu*vec(d[k]) + K[k]'*vec(Qu) + Qux'*vec(d[k])
        S[k] = Qxx + K[k]'*Quu*K[k] + K[k]'*Qux + Qux'*K[k]
        S[k] = 0.5*(S[k] + S[k]')

        # calculated change is cost-to-go over entire trajectory
        Δv += [vec(d[k])'*vec(Qu) 0.5*vec(d[k])'*Quu*vec(d[k])]

        k = k - 1;
    end

    # decrease regularization after backward pass
    regularization_update!(res,solver,:decrease)

    return Δv
end

"""
$(SIGNATURES)
Perform a backwards pass with Cholesky Factorizations of the Cost-to-Go to
avoid ill-conditioning.
"""
function backwardpass_sqrt!(res::SolverVectorResults,solver::Solver)
    N = solver.N
    n = solver.model.n
    m = solver.model.m

    if solver.model.m != length(res.U[1])
        m += n
    end

    Q = solver.obj.Q
    R = solver.obj.R
    xf = solver.obj.xf
    Qf = solver.obj.Qf
    dt = solver.dt

    Uq = cholesky(Q).U
    Ur = cholesky(R).U

    # pull out values from results
    X = res.X; U = res.U; K = res.K; d = res.d; Su = res.S; s = res.s

    # Terminal Cost-to-go
    if isa(solver.obj, ConstrainedObjective)
        Cx = res.Cx_N
        Su[N] = cholesky(Qf + Cx'*res.IμN*Cx).U
        s[N] = Qf*(X[N] - xf) + Cx'*res.IμN*res.CN + Cx'*res.λN
    else
        Su[N] = cholesky(Qf).U
        s[N] = Qf*(X[N] - xf)
    end

    # Initialization of expected change in cost-to-go
    Δv = [0. 0.]

    k = N-1

    # Backward pass
    while k >= 1
        lx = dt*Q*(X[k] - xf)
        lu = dt*R*(U[k])
        lxx = dt*Q
        luu = dt*R

        fx, fu = res.fx[k], res.fu[k]

        Qx = lx + fx'*s[k+1]
        Qu = lu + fu'*s[k+1]

        Wxx = chol_plus(Su[k+1]*fx, cholesky(lxx).U)
        Wuu = chol_plus(Su[k+1]*fu, cholesky(luu).U)

        Qxu = (fx'*Su[k+1]')*(Su[k+1]*fu)

        # Constraints
        if isa(solver.obj, ConstrainedObjective)
            Iμ = res.Iμ; C = res.C; λ = res.λ;
            Cx, Cu = res.Cx[k], res.Cu[k]
            Iμ2 = sqrt.(Iμ[k])
            Qx += (Cx'*Iμ[k]*C[k] + Cx'*λ[k])
            Qu += (Cu'*Iμ[k]*C[k] + Cu'*λ[k])
            Qxu += Cx'*Iμ[k]*Cu

            Wxx = chol_plus(Wxx.R, Iμ2*Cx)
            Wuu = chol_plus(Wuu.R, Iμ2*Cu)
        end

        K[k] = -Wuu.R\(Array(Wuu.R')\Array(Qxu'))
        d[k] = -Wuu.R\(Wuu.R'\Qu)

        s[k] = Qx - Qxu*(Wuu.R\(Wuu.R'\Qu))

        try  # Regularization
            Su[k] = chol_minus(Wxx.R,(Array(Wuu.R'))\Array(Qxu'))
        catch ex
            error("sqrt bp not implemented")
        end

        # Expected change in cost-to-go
        Δv += [vec(Qu)'*vec(d[k]) 0.5*vec(d[k])'*Wuu.R'*Wuu.R*vec(d[k])]

        k = k - 1;
    end

    return Δv
end

function backwardpass_foh!(res::SolverVectorResults,solver::Solver)
    n, m, N = get_sizes(solver)

    # Check for infeasible start
    if solver.model.m != length(res.U[1])
        m += n
    end

    dt = solver.dt

    Q = solver.obj.Q
    R = getR(solver)
    Qf = solver.obj.Qf
    xf = solver.obj.xf

    K = res.K
    b = res.b
    d = res.d

    X = res.X
    U = res.U

    # Boundary conditions
    S = zeros(n+m,n+m)
    s = zeros(n+m)
    S[1:n,1:n] = Qf
    s[1:n] = Qf*(X[N]-xf)

    # Terminal constraints
    if res isa ConstrainedIterResults
        C = res.C; Iμ = res.Iμ; λ = res.λ
        CxN = res.Cx_N
        S[1:n,1:n] += CxN'*res.IμN*CxN
        s[1:n] += CxN'*res.IμN*res.CN + CxN'*res.λN
    end

    # create a copy of BC in case of regularization
    # SN = copy(S)
    # sN = copy(s)

    # Backward pass
    k = N-1
    Δv = [0. 0.] # Initialization of expected change in cost-to-go
    while k >= 1
        ## Calculate the L(x,u,y,v) second order expansion
        # Unpack Jacobians, ̇x
        Ac1, Bc1 = res.Ac[k], res.Bc[k][:,1:m]
        Ac2, Bc2 = res.Ac[k+1], res.Bc[k+1][:,1:m]
        Ad, Bd, Cd = res.fx[k], res.fu[k], res.fv[k]

        xm = res.xmid[k]
        um = (U[k] + U[k+1])/2.

        # Expansion of stage cost L(x,u,y,v) -> dL(dx,du,dy,dv)
        Lx = dt/6*Q*(X[k] - xf) + 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(xm - xf)
        Lu = dt/6*R*U[k] + 4*dt/6*((dt/8*Bc1)'*Q*(xm - xf) + 0.5*R*um)
        Ly = dt/6*Q*(X[k+1] - xf) + 4*dt/6*(I/2 - dt/8*Ac2)'*Q*(xm - xf)
        Lv = dt/6*R*U[k+1] + 4*dt/6*((-dt/8*Bc2)'*Q*(xm - xf) + 0.5*R*um)

        Lxx = dt/6*Q + 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(I/2 + dt/8*Ac1)
        Luu = dt/6*R + 4*dt/6*((dt/8*Bc1)'*Q*(dt/8*Bc1) + 0.5*R*0.5)
        Lyy = dt/6*Q + 4*dt/6*(I/2 - dt/8*Ac2)'*Q*(I/2 - dt/8*Ac2)
        Lvv = dt/6*R + 4*dt/6*((-dt/8*Bc2)'*Q*(-dt/8*Bc2) + 0.5*R*0.5)

        Lxu = 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(dt/8*Bc1)
        Lxy = 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(I/2 - dt/8*Ac2)
        Lxv = 4*dt/6*(I/2 + dt/8*Ac1)'*Q*(-dt/8*Bc2)
        Luy = 4*dt/6*(dt/8*Bc1)'*Q*(I/2 - dt/8*Ac2)
        Luv = 4*dt/6*((dt/8*Bc1)'*Q*(-dt/8*Bc2) + 0.5*R*0.5)
        Lyv = 4*dt/6*(I/2 - dt/8*Ac2)'*Q*(-dt/8*Bc2)

        # Constraints
        if res isa ConstrainedIterResults
            Cy, Cv = res.Cx[k+1], res.Cu[k+1]
            Ly += Cy'*Iμ[k+1]*C[k+1] + Cy'*λ[k+1]
            Lv += Cv'*Iμ[k+1]*C[k+1] + Cv'*λ[k+1]
            Lyy += Cy'*Iμ[k+1]*Cy
            Lvv += Cv'*Iμ[k+1]*Cv
            Lyv += Cy'*Iμ[k+1]*Cv
        end

        # Unpack cost-to-go P
        Sy = s[1:n]
        Sv = s[n+1:n+m]
        Syy = S[1:n,1:n]
        Svv = S[n+1:n+m,n+1:n+m]
        Syv = S[1:n,n+1:n+m]

        # Substitute in discrete dynamics (second order approximation)
        Qx = vec(Lx) + Ad'*vec(Ly) + Ad'*vec(Sy)
        Qu = vec(Lu) + Bd'*vec(Ly) + Bd'*vec(Sy)
        Qv = vec(Lv) + Cd'*vec(Ly) + Cd'*vec(Sy) + Sv

        Qxx = Lxx + Lxy*Ad + Ad'*Lxy' + Ad'*Lyy*Ad + Ad'*Syy*Ad
        Quu = Luu + Luy*Bd + Bd'*Luy' + Bd'*Lyy*Bd + Bd'*Syy*Bd
        Qvv = Lvv + Lyv'*Cd + Cd'*Lyv + Cd'*Lyy*Cd + Cd'*Syy*Cd + Cd'*Syv + Syv'*Cd + Svv
        Qxu = Lxu + Lxy*Bd + Ad'*Luy' + Ad'*Lyy*Bd + Ad'*Syy*Bd
        Qxv = Lxv + Lxy*Cd + Ad'*Lyv + Ad'*Lyy*Cd + Ad'*Syy*Cd + Ad'*Syv
        Quv = Luv + Luy*Cd + Bd'*Lyv + Bd'*Lyy*Cd + Bd'*Syy*Cd + Bd'*Syv

        # Regularization
        #TODO double check state regularization
        # if solver.opts.regularization_type == :state
        #     Qvv_reg = Qvv + Cd'*(res.ρ[1]*I)*Cd
        #     Qxv_reg = Qxv + Ad'*(res.ρ[1]*I)*Cd
        #     Quv_reg = Quv + Bd'*(res.ρ[1]*I)*Cd
        # elseif solver.opts.regularization_type == :control
            Qvv_reg = Qvv + res.ρ[1]*I
            Qxv_reg = Qxv
            Quv_reg = Quv
        # end

        if !isposdef(Hermitian(Array(Qvv_reg)))
            if solver.opts.verbose  # TODO move to logger
                println("regularized (foh bp)\n not implemented properly")
                println("-condition number: $(cond(Array(Qvv_reg)))")
                println("Qvv_reg: $Qvv_reg")
                println("iteration: $k")
            end

            regularization_update!(res,solver,:increase)

            # Reset BCs
            S = zeros(n+m,n+m)
            s = zeros(n+m)
            S[1:n,1:n] = Qf
            s[1:n] = Qf*(X[N]-xf)

            # Terminal constraints
            if res isa ConstrainedIterResults
                C = res.C; Iμ = res.Iμ; λ = res.λ
                CxN = res.Cx_N
                S[1:n,1:n] += CxN'*res.IμN*CxN
                s[1:n] += CxN'*res.IμN*res.CN + CxN'*res.λN
            end
            # S = SN
            # s = sN
            ############
            k = N-1
            Δv = [0. 0.]
            continue
        end

        # calculate gains
        K[k+1] = -Qvv_reg\Qxv_reg'
        b[k+1] = -Qvv_reg\Quv_reg'
        d[k+1] = -Qvv_reg\vec(Qv)

        # calculate optimized values
        Qx_ = vec(Qx) + K[k+1]'*vec(Qv) + Qxv*vec(d[k+1]) + K[k+1]'Qvv*d[k+1]
        Qu_ = vec(Qu) + b[k+1]'*vec(Qv) + Quv*vec(d[k+1]) + b[k+1]'*Qvv*d[k+1]
        Qxx_ = Qxx + Qxv*K[k+1] + K[k+1]'*Qxv' + K[k+1]'*Qvv*K[k+1]
        Quu_ = Quu + Quv*b[k+1] + b[k+1]'*Quv' + b[k+1]'*Qvv*b[k+1]
        Qxu_ = Qxu + K[k+1]'*Quv' + Qxv*b[k+1] + K[k+1]'*Qvv*b[k+1]

        # cache (approximate) cost-to-go at timestep k
        s[1:n] = Qx_
        s[n+1:n+m] = Qu_
        S[1:n,1:n] = Qxx_
        S[n+1:n+m,n+1:n+m] = Quu_
        S[1:n,n+1:n+m] = Qxu_
        S[n+1:n+m,1:n] = Qxu_'

        # line search terms
        Δv += [vec(Qv)'*vec(d[k+1]) 0.5*vec(d[k+1])'*Qvv*vec(d[k+1])]

        # at last time step, optimize over final control
        if k == 1
            if res isa ConstrainedIterResults
                Cx, Cu = res.Cx[k], res.Cu[k]
                Qx_ += Cx'*Iμ[k]*C[k] + Cx'*λ[k]
                Qu_ += Cu'*Iμ[k]*C[k] + Cu'*λ[k]
                Qxx_ += Cx'*Iμ[k]*Cx
                Quu_ += Cu'*Iμ[k]*Cu
                Qxu_ += Cx'*Iμ[k]*Cu
            end

            # regularize Quu_
            Quu__reg = Quu_ + res.ρ[1]*I

            if !isposdef(Array(Hermitian(Quu__reg)))
                if solver.opts.verbose  # TODO: Move to logger
                    println("regularized (foh bp)")
                    println("part 2")
                    println("-condition number: $(cond(Array(Quu__reg)))")
                    println("Quu__reg: $Quu__reg")
                end

                regularization_update!(res,solver,:increase)

                ## Reset BCs ##
                S = zeros(n+m,n+m)
                s = zeros(n+m)
                S[1:n,1:n] = Qf
                s[1:n] = Qf*(X[N]-xf)

                # Terminal constraints
                if res isa ConstrainedIterResults
                    C = res.C; Iμ = res.Iμ; λ = res.λ
                    CxN = res.Cx_N
                    S[1:n,1:n] += CxN'*res.IμN*CxN
                    s[1:n] += CxN'*res.IμN*res.CN + CxN'*res.λN
                end
                # S = SN
                # s = sN
                ################
                k = N-1
                Δv = [0. 0.]
                continue
            end

            K[1] = -Quu__reg\Qxu_'
            b[1] = zeros(m,m)
            d[1] = -Quu__reg\vec(Qu_)

            res.s[1] = vec(Qx_) + K[1]'*Quu_*vec(d[1]) + K[1]'*vec(Qu_) + Qxu_*vec(d[1]) # calculate for gradient check in solve

            Δv += [vec(Qu_)'*vec(d[1]) 0.5*vec(d[1])'*Quu_*vec(d[1])]

        end

        k = k - 1;
    end

    # if successful backward pass, reduce regularization
    regularization_update!(res,solver,:decrease)
    return Δv
end

function _backwardpass_foh_mintime!(results::SolverVectorResults,solver::Solver)
    # Problem dimensions
    n,m,N = get_sizes(solver)
    m̄,mm = get_num_controls(solver)

    # Objective parameters
    W = solver.obj.Q; R = solver.obj.R; Wf = solver.obj.Qf; xf = solver.obj.xf
    dt = solver.dt
    is_min_time(solver) ? R_minimum_time = solver.opts.R_minimum_time : nothing
    solver.opts.infeasible ? R_infeasible = solver.opts.R_infeasible*Matrix(I,n,n) : nothing
    # Pull out results
    X = results.X; U = results.U; K = results.K; b = results.b; d = results.d; s = results.s; # S = results.S

    # Boundary conditions
    S = zeros(n+mm,n+mm)
    s = zeros(n+mm)
    S[1:n,1:n] = Wf
    s[1:n] = Wf*(X[N]-xf)

    # Terminal constraints
    if results isa ConstrainedIterResults
        C = results.C; Iμ = results.Iμ; λ = results.λ
        CxN = results.Cx_N
        S[1:n,1:n] += CxN'*results.IμN*CxN
        s[1:n] += CxN'*results.IμN*results.CN + CxN'*results.λN

        # Include the the k = N expansions here for a cleaner backward pass
        Cx, Cu = results.Cx[N], results.Cu[N]
        s[1:n] += Cx'*Iμ[N]*C[N] + Cx'*λ[N]
        s[n+1:n+mm] += Cu'*Iμ[N]*C[N] + Cu'*λ[N]
        S[1:n,1:n] += Cx'*Iμ[N]*Cx
        S[n+1:n+mm,n+1:n+mm] += Cu'*Iμ[N]*Cu
        S[1:n,n+1:n+mm] += Cx'*Iμ[N]*Cu
        S[n+1:n+mm,1:n] += Cu'*Iμ[N]*Cx
    end

    # Create a copy of boundary conditions in case of regularization
    SN = copy(S)
    sN = copy(s)

    # Backward pass
    k = N-1
    Δv = [0. 0.] # Initialization of expected change in cost-to-go
    while k >= 1
        # Check for minimum time solve
        is_min_time(solver) ? dt = U[k][m̄]^2 : nothing

        # Unpack results
        fcx, fcu = results.Ac[k], results.Bc[k][:,1:m]
        fcy, fcv = results.Ac[k+1], results.Bc[k+1][:,1:m]
        fdx, fdu, fdv = results.fx[k], results.fu[k], results.fv[k]

        x = results.X[k]
        y = results.X[k+1]
        u = results.U[k]
        v = results.U[k+1]
        xm = results.xmid[k]
        um = 0.5*u + 0.5*v
        dx = results.xdot[k]
        dy = results.xdot[k+1]

        ## L(x,u,y,v) = L(x,u) + L(xm,um) + L(y,v) = L1 + L2 + L3
        # ℓ(x,u) expansion
        ℓ1 = ℓ(x,u[1:m],W,R,xf)
        ℓ1x = W*(x - xf)
        ℓ1u = R*u[1:m]

        ℓ1xx = W
        ℓ1uu = R

        # ℓ(xm,um) expansion
        ℓ2 = ℓ(xm,um[1:m],W,R,xf)
        ℓ2x = (I/2 + dt/8*fcx)'*W*(xm - xf)
        ℓ2u = ((dt/8*fcu[:,1:m])'*W*(xm - xf) + 0.5*R*um[1:m])
        ℓ2y = (I/2 - dt/8*fcy)'*W*(xm - xf)
        ℓ2v = ((-dt/8*fcv[:,1:m])'*W*(xm - xf) + 0.5*R*um[1:m])

        ℓ2xx = (I/2.0 + dt/8.0*fcx)'*W*(I/2.0 + dt/8.0*fcx)
        ℓ2uu = ((dt/8*fcu[:,1:m])'*W*(dt/8*fcu[:,1:m]) + 0.5*R*0.5)
        ℓ2yy = (I/2 - dt/8*fcy)'*W*(I/2 - dt/8*fcy)
        ℓ2vv = ((-dt/8*fcv[:,1:m])'*W*(-dt/8*fcv[:,1:m]) + 0.5*R*0.5)

        ℓ2xu = (I/2 + dt/8*fcx)'*W*(dt/8*fcu[:,1:m])
        ℓ2xy = (I/2 + dt/8*fcx)'*W*(I/2 - dt/8*fcy)
        ℓ2xv = (I/2 + dt/8*fcx)'*W*(-dt/8*fcv[:,1:m])
        ℓ2uy = (dt/8*fcu[:,1:m])'*W*(I/2 - dt/8*fcy)
        ℓ2uv = ((dt/8*fcu[:,1:m])'*W*(-dt/8*fcv[:,1:m]) + 0.5*R*0.5)
        ℓ2yv = (I/2 - dt/8*fcy)'*W*(-dt/8*fcv[:,1:m])

        # ℓ(y,v) expansion
        ℓ3 = ℓ(y,v[1:m],W,R,xf)

        ℓ3y = W*(y - xf)
        ℓ3v = R*v[1:m]

        ℓ3yy = W
        ℓ3vv = R

        # Assemble δL expansion
        if is_min_time(solver)
            h = u[m̄]

            # Additional expansion terms
            xmh = 2/8*h*(dx - dy)
            xmu = (h^2)/8*fcu[:,1:m]
            xmy = 0.5*Matrix(I,n,n) - (h^2)/8*fcy
            xmv = -(h^2)/8*fcv[:,1:m]
            ℓ2h = xmh'*W*(xm-xf)
            L2h = 4/6*(2*h*ℓ2 + (h^2)*ℓ2h)
            ℓ2hh = 2/8*((dx - dy)'*W*(xm - xf) + h*(dx - dy)'*W*xmh)
            L2hh = 4/6*(2*h*ℓ2h + 2*ℓ2 + (h^2)*ℓ2hh + 2*h*ℓ2h)
            L2xh = 4/6*(2*h*ℓ2x + (h^2)*(0.5*Matrix(I,n,n) + (h^2)/8*fcx)'*W*xmh + 2/8*h*fcx'*W*(xm - xf))
            L2uh = 4/6*(2*h*ℓ2u + (h^2)*((h^2)/8*fcu[:,1:m])'*W*xmh + 2/8*h*fcu[:,1:m]'*W*(xm - xf))
            L2hu = 4/6*(2*h*ℓ2u + 2/8*(h^3)*(fcu[:,1:m]'*W*(xm - xf) + xmu'*W*(dx - dy)))
            L2hy = 4/6*(2*h*ℓ2y + 2/8*(h^3)*(-fcy'*W*(xm - xf) + xmy'*W*(dx - dy)))
            L2hv = 4/6*(2*h*ℓ2v + 2/8*(h^3)*(-fcv[:,1:m]'*W*(xm - xf) + xmv'*W*(dx - dy)))

            # Assemble expansion
            Lx = (h^2)/6*ℓ1x + 4/6*(h^2)*ℓ2x
            Lu = [(h^2)/6*ℓ1u + 4/6*(h^2)*ℓ2u; (2/6*h*ℓ1 + L2h + 2/6*ℓ3 + 2*R_minimum_time*h)]
            Ly = 4/6*(h^2)*ℓ2y + (h^2)/6*ℓ3y
            Lv = [4/6*(h^2)*ℓ2v + (h^2)/6*ℓ3v; 0]

            Lxx = (h^2)/6*ℓ1xx + 4/6*(h^2)*ℓ2xx
            Luu = [((h^2)/6*ℓ1uu + 4/6*(h^2)*ℓ2uu) (2/6*h*ℓ1u + L2uh); (2/6*h*ℓ1u + L2hu)' (2/6*ℓ1 + L2hh + 2/6*ℓ3 + 2*R_minimum_time)]
            Lyy =  4/6*(h^2)*ℓ2yy + (h^2)/6*ℓ3yy
            Lvv = [(4/6*(h^2)*ℓ2vv + (h^2)/6*ℓ3vv) zeros(m); zeros(m)' 0]

            Lxu = [4/6*(h^2)*ℓ2xu (2/6*h*ℓ1x + L2xh)]
            Lxy = 4/6*(h^2)*ℓ2xy
            Lxv = [4/6*(h^2)*ℓ2xv zeros(n)]
            Luy = [4/6*(h^2)*ℓ2uy; (L2hy + 2*h/6*ℓ3y)']
            Luv = [4/6*(h^2)*ℓ2uv zeros(m); (L2hv + 2*h/6*ℓ3v)' 0]
            Lyv = [4/6*(h^2)*ℓ2yv zeros(n)]
        else
            Lx = dt/6*ℓ1x + 4*dt/6*ℓ2x
            Lu = dt/6*ℓ1u + 4*dt/6*ℓ2u
            Ly = 4*dt/6*ℓ2y + dt/6*ℓ3y
            Lv = 4*dt/6*ℓ2v + dt/6*ℓ3v
            Lxx = dt/6*ℓ1xx + 4*dt/6*ℓ2xx
            Luu = dt/6*ℓ1uu + 4*dt/6*ℓ2uu
            Lyy = 4*dt/6*ℓ2yy + dt/6*ℓ3yy
            Lvv = 4*dt/6*ℓ2vv + dt/6*ℓ3vv

            Lxu = 4*dt/6*ℓ2xu
            Lxy = 4*dt/6*ℓ2xy
            Lxv = 4*dt/6*ℓ2xv
            Luy = 4*dt/6*ℓ2uy
            Luv = 4*dt/6*ℓ2uv
            Lyv = 4*dt/6*ℓ2yv
        end

        if solver.opts.infeasible
            Lu = [Lu; R_infeasible*u[m̄+1:m̄+n]]
            Lv = [Lv; zeros(n)]

            Luu = [Luu zeros(m̄,n); zeros(n,m̄) R_infeasible]
            Lvv = [Lvv zeros(m̄,n); zeros(n,m̄) zeros(n,n)]

            Lxu = [Lxu zeros(n,n)]
            Lxv = [Lxv zeros(n,n)]
            Luy = [Luy; zeros(n,n)']
            Luv = [Luv zeros(m̄,n); zeros(n,m̄) zeros(n,n)]
            Lyv = [Lyv zeros(n,n)]
        end

        # Constraints
        if results isa ConstrainedIterResults
            Cx, Cu = results.Cx[k], results.Cu[k]
            Lx += Cx'*Iμ[k]*C[k] + Cx'*λ[k]
            Lu += Cu'*Iμ[k]*C[k] + Cu'*λ[k]
            Lxx += Cx'*Iμ[k]*Cx
            Luu += Cu'*Iμ[k]*Cu
            Lxu += Cx'*Iμ[k]*Cu

            if is_min_time(solver)
                p,pI,pE = get_num_constraints(solver)
                #TODO Simplify
                if k < N-1
                    Cv = zeros(p,mm)
                    Cv[p,m̄] = -1
                    Lv += Cv'*Iμ[k]*C[k] + Cv'*λ[k]
                    Lvv += Cv'*Iμ[k]*Cv
                    Lxv += Cx'*Iμ[k]*Cv
                    Luv += Cu'*Iμ[k]*Cv
                end
            end
        end

        # Unpack cost-to-go P
        Sy = s[1:n]
        Sv = s[n+1:n+mm]
        Syy = S[1:n,1:n]
        Svv = S[n+1:n+mm,n+1:n+mm]
        Syv = S[1:n,n+1:n+mm]

        # Substitute in discrete dynamics (second order approximation)
        Qx = vec(Lx) + fdx'*vec(Ly) + fdx'*vec(Sy)
        Qu = vec(Lu) + fdu'*vec(Ly) + fdu'*vec(Sy)
        Qv = vec(Lv) + fdv'*vec(Ly) + fdv'*vec(Sy) + Sv

        Qxx = Lxx + Lxy*fdx + fdx'*Lxy' + fdx'*Lyy*fdx + fdx'*Syy*fdx
        Quu = Luu + Luy*fdu + fdu'*Luy' + fdu'*Lyy*fdu + fdu'*Syy*fdu
        Qvv = Lvv + Lyv'*fdv + fdv'*Lyv + fdv'*Lyy*fdv + fdv'*Syy*fdv + fdv'*Syv + Syv'*fdv + Svv
        Qxu = Lxu + Lxy*fdu + fdx'*Luy' + fdx'*Lyy*fdu + fdx'*Syy*fdu
        Qxv = Lxv + Lxy*fdv + fdx'*Lyv + fdx'*Lyy*fdv + fdx'*Syy*fdv + fdx'*Syv
        Quv = Luv + Luy*fdv + fdu'*Lyv + fdu'*Lyy*fdv + fdu'*Syy*fdv + fdu'*Syv

        # Regularization
        Qvv_reg = Qvv + results.ρ[1]*I
        Qxv_reg = Qxv
        Quv_reg = Quv

        # @info "Qvv condition: $(cond(Qvv_reg))"

        if !isposdef(Hermitian(Array(Qvv_reg)))

            regularization_update!(results,solver,:increase)

            # Reset BCs
            S = copy(SN)
            s = copy(sN)
            ############
            k = N-1
            Δv = [0. 0.]
            continue
        end

        # calculate gains
        K[k+1] = -Qvv_reg\Qxv_reg'
        b[k+1] = -Qvv_reg\Quv_reg'
        d[k+1] = -Qvv_reg\vec(Qv)

        # calculate optimized values
        Q̄x = vec(Qx) + K[k+1]'*vec(Qv) + Qxv*vec(d[k+1]) + K[k+1]'Qvv*d[k+1]
        Q̄u = vec(Qu) + b[k+1]'*vec(Qv) + Quv*vec(d[k+1]) + b[k+1]'*Qvv*d[k+1]
        Q̄xx = Qxx + Qxv*K[k+1] + K[k+1]'*Qxv' + K[k+1]'*Qvv*K[k+1]
        Q̄uu = Quu + Quv*b[k+1] + b[k+1]'*Quv' + b[k+1]'*Qvv*b[k+1]
        Q̄xu = Qxu + K[k+1]'*Quv' + Qxv*b[k+1] + K[k+1]'*Qvv*b[k+1]

        # cache (approximate) cost-to-go at timestep k
        s[1:n] = Q̄x
        s[n+1:n+mm] = Q̄u
        S[1:n,1:n] = Q̄xx
        S[n+1:n+mm,n+1:n+mm] = Q̄uu
        S[1:n,n+1:n+mm] = Q̄xu
        S[n+1:n+mm,1:n] = Q̄xu'

        # line search terms
        Δv += [vec(Qv)'*vec(d[k+1]) 0.5*vec(d[k+1])'*Qvv*vec(d[k+1])]

        # at last time step, optimize over final control
        if k == 1
            # regularize Quu_
            Q̄uu_reg = Q̄uu + results.ρ[1]*I
            # @info "Q̄uu_reg condition: $(cond(Q̄uu_reg))"

            if !isposdef(Array(Hermitian(Q̄uu_reg)))
                # @logmsg InnerLoop "Regularized"
                regularization_update!(results,solver,:increase)

                ## Reset BCs ##
                S = copy(SN)
                s = copy(sN)
                ################
                k = N-1
                Δv = [0. 0.]
                continue
            end

            K[1] = -Q̄uu_reg\Q̄xu'
            b[1] = zeros(mm,mm)
            d[1] = -Q̄uu_reg\vec(Q̄u)

            results.s[1] = vec(Q̄x) + K[1]'*Q̄uu*vec(d[1]) + K[1]'*vec(Q̄u) + Q̄xu*vec(d[1]) # calculate for gradient check in solve

            Δv += [vec(Q̄u)'*vec(d[1]) 0.5*vec(d[1])'*Q̄uu*vec(d[1])]
        end

        k = k - 1;
    end

    # if successful backward pass, reduce regularization
    regularization_update!(results,solver,:decrease)
    return Δv
end

"""
$(SIGNATURES)
Perform the operation sqrt(A-B), where A and B are Symmetric Matrices
"""
function chol_minus(A,B::Matrix)
    AmB = Cholesky(A,:U,0)
    for i = 1:size(B,1)
        lowrankdowndate!(AmB,B[i,:])
    end
    U = AmB.U
end

function chol_plus(A,B)
    n1,m = size(A)
    n2 = size(B,1)
    P = zeros(n1+n2,m)
    P[1:n1,:] = A
    P[n1+1:end,:] = B
    qr(P)
end

"""
$(SIGNATURES)
Propagate dynamics with a line search (in-place)
"""
function forwardpass!(res::SolverIterResults, solver::Solver, Δv::Array{Float64,2})
    # status = :progress_made

    # Pull out values from results
    X = res.X
    U = res.U
    # K = res.K
    # d = res.d
    X_ = res.X_
    U_ = res.U_

    # Compute original cost
    update_constraints!(res,solver,X,U)

    # Ju_prev = _cost(solver, res, X, U)   # Unconstrained cost
    # Jc_prev = cost_constraints(solver, res)  # constraint cost
    # J_prev = Ju_prev + Jc_prev

    J_prev = cost(solver, res, X, U)


    J = Inf
    alpha = 1.0
    iter = 0
    z = -1.
    expected = 0.

    logger = current_logger()
    # print_header(logger,InnerIters) #TODO: fix, this errored out
    @logmsg InnerIters :iter value=0
    @logmsg InnerIters :cost value=J_prev
    # print_row(logger,InnerIters) #TODO: fix, same issue
    while z ≤ solver.opts.z_min || z > solver.opts.z_max

        # Check that maximum number of line search decrements has not occured
        if iter > solver.opts.iterations_linesearch
            # Ju = _cost(solver, res, X_, U_)   # Unconstrained cost
            # Jc = cost_constraints(solver, res)  # constraint cost

            # set trajectories to original trajectory
            X_ .= deepcopy(X)
            U_ .= deepcopy(U)

            # # Examine components
            # zu = (Ju_prev - Ju)
            # zc = (Jc_prev - Jc)
            #
            # status = :no_progress_made
            # if zu > 0
            #     status = :uncon_progress_made
            # end
            # if zc > 0
            #     status = :constraint_progress_made
            # end

            if solver.control_integration == :foh
                calculate_derivatives!(res, solver, X_, U_)
                calculate_midpoints!(res, solver, X_, U_)
            end

            update_constraints!(res,solver,X_,U_)
            J = copy(J_prev)
            z = 0.
            alpha = 0.0
            expected = 0.

            @logmsg InnerLoop "Max iterations (forward pass) -No improvement made"
            regularization_update!(res,solver,:increase) # increase regularization
            res.ρ[1] += 1.0
            break
        end

        # Otherwise, rollout a new trajectory for current alpha
        flag = rollout!(res,solver,alpha)

        # Check if rollout completed
        if ~flag
            # Reduce step size if rollout returns non-finite values (NaN or Inf)
            @logmsg InnerIters "Non-finite values in rollout"
            iter += 1
            alpha /= 2.0
            continue
        end

        # Calcuate cost
        update_constraints!(res,solver,X_,U_)

        # Ju = _cost(solver, res, X_, U_)   # Unconstrained cost
        # Jc = cost_constraints(solver, res)  # constraint cost
        # J = Ju + Jc
        J = cost(solver, res, X_, U_)   # Unconstrained cost

        expected = -alpha*(Δv[1] + alpha*Δv[2])
        if expected > 0
            z  = (J_prev - J)/expected
        else
            @logmsg InnerIters "Non-positive expected decrease"
            z = -1
        end

        iter += 1
        alpha /= 2.0

        # Log messages
        @logmsg InnerIters :iter value=iter
        @logmsg InnerIters :α value=2*alpha
        @logmsg InnerIters :cost value=J
        @logmsg InnerIters :z value=z
        # print_row(logger,InnerIters)

    end  # forward pass loop

    if res isa ConstrainedIterResults
        # @logmsg :scost value=cost(solver,res,res.X,res.U,true)
        @logmsg InnerLoop :c_max value=max_violation(res)
    end
    @logmsg InnerLoop :cost value=J
    @logmsg InnerLoop :dJ value=J_prev-J
    @logmsg InnerLoop :expected value=expected
    @logmsg InnerLoop :z value=z
    @logmsg InnerLoop :α value=2*alpha
    @logmsg InnerLoop :ρ value=res.ρ[1]

    return J
end
