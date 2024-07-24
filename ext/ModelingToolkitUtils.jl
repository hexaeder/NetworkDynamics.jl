"""
    eq_type(eq::Equation)

Checks the type of the equation. Returns:
- `(:explicit_diffeq, lhs_variable)` for explicit differential equations
- `(:implicit_diffeq, lhs_variable)` for implicit differential equations
- `(:explicit_algebraic, lhs_variable)` for explicit algebraic equations
- `(:implicit_algebraic, lhs_variable)` for implicit algebraic equations

"""
function eq_type(eq::Equation)
    if istree(eq.lhs) && operation(eq.lhs) isa Differential
        vars = get_variables(eq.lhs)
        @argcheck length(vars) == 1 "Diff. eq $eq has more than one variable in lhs!"
        return (:explicit_diffeq, vars[1])
    elseif eq.lhs isa Symbolic
        vars = get_variables(eq.lhs)
        @argcheck length(vars) == 1 "Algebraic eq $eq has more than one variable in lhs!"
        diffs = _collect_differentials(eq.rhs)
        if diffs != Set{Symbolic}()
            if operation(first(diffs.dict)[1]) isa Differential
                return (:implicit_diffeq, vars[1])
            else
                throw(ArgumentError("Unknown equation type $eq"))
            end
        end
        if vars[1] ∈ Set(get_variables(eq.rhs))
            return (:implicit_algebraic, vars[1])
        else
            return (:explicit_algebraic, vars[1])
        end
    elseif isequal(eq.lhs, 0)
        return (:implicit_algebraic, nothing)
    else
        throw(ArgumentError("Unknown equation type $eq"))
    end
end

"""
    lhs_var(eq::Equation)

Returns the variable on the lhs of the equation for equations.
"""
lhs_var(eq::Equation) = eq_type(eq)[2]

function rhs_differentials(eqs::Vector{Equation})
    diffs = Set{Symbolic}()
    for eq in eqs
        _collect_differentials!(diffs, eq.rhs)
    end
    return diffs
end

_collect_differentials(ex) = _collect_differentials!(Set{Symbolic}(), ex)

function _collect_differentials!(found, ex)
    if istree(ex)
        if operation(ex) isa Differential
            push!(found, ex)
        else
            for arg in arguments(ex)
                _collect_differentials!(found, arg)
            end
        end
    end
    return found
end

function _resolve_var(sys, var)
    ns = string(getname(sys))
    varname = string(getname(var))
    varname_nons = Symbol(replace(varname, r"^"*ns*"₊" => ""))
    unwrap(getproperty(sys, varname_nons; namespace=false))
end

function reorder_by_states(eqs::AbstractVector{Equation}, states)
    @assert length(eqs) == length(states) "Numbers of eqs should be equal to states! ($(length(eqs)) equations for $(length(states)) states = $states)"
    # for each state, collect the eq_idx which corresponds some states (implicit
    # algebraic) don't have special equations attached to them those are the "unused_idx"
    eq_idx::Vector{Union{Int, Nothing}} = [findfirst(x->isequal(s, lhs_var(x)), eqs) for s in states]
    unused_idx = reverse(setdiff(1:length(eqs), eq_idx))
    for i in 1:length(eq_idx)
        if eq_idx[i] === nothing
            eq_idx[i] = pop!(unused_idx)
        end
    end
    @assert sort(unique(eq_idx)) == 1:length(eqs) "eq_idx should contain all idx!"
    return eqs[eq_idx]
end

function generate_massmatrix(eqs::AbstractVector{Equation})
    V = map(eqs) do eq
        type = eq_type(eq)[1]
        if type === :explicit_diffeq
            1
        elseif type === :implicit_algebraic
            0
        else
            error("Cant build mass matrix entry for $(eq) of type $type")
        end
    end
    M = Diagonal(V)
    return M==I ? I : M
end
