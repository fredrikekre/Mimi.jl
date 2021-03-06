# For generating symbols that work as dataframe column names; symbols
# generated by gensym() don't work for this.
global _rvnum = 0

function _make_rvname(name)
    global _rvnum += 1
    return Symbol("$(name)!$(_rvnum)")
end

function _make_dims(args)
    dims = Vector{Any}()
    for arg in args
        # println("Arg: $arg")

        if @capture(arg, i_Int)  # scalar (must be integer)
            # println("arg is Int")
            dim = i

        elseif @capture(arg, first_Int:last_)   # last can be an int or 'end', which is converted to 0
            # println("arg is range")
            last = last == :end ? 0 : last
            dim = :($first:$last)

        elseif @capture(arg, first_Int:step_:last_)
            # println("arg is step range")
            last = last == :end ? 0 : last
            dim = :($first:$step:$last)

        elseif @capture(arg, s_Symbol)
            if arg == :(:)
                # println("arg is Colon")
                dim = Colon()
            else
                # println("arg is Symbol")
                dim = :($(QuoteNode(s)))
            end

        elseif @capture(arg, s_String)
            dim = s

        elseif isa(arg, Expr) && arg.head == :tuple  # tuple of Strings/Symbols (@capture didn't work...)
            argtype = typeof(arg.args[1])            # ensure all are same type as first element
            if ! isempty(filter(s -> typeof(s) != argtype, arg.args))
                error("A parameter dimension tuple must all String or all Symbol (got $arg)")
            end
            dim = :(convert(Vector{$argtype}, $(arg.args)))

        else
            error("Unrecognized stochastic parameter specification: $arg")
        end
        push!(dims, dim)
    end
    # println("dims = $dims")
    return dims
end

macro defmcs(expr)
    let # to make vars local to each macro invocation
        local _rvs        = []
        local _corrs      = []
        local _transforms = []
        local _saves      = []

        # distilled into a function since it's called from two branches below
        function saverv(rvname, distname, distargs)
            expr = :(RandomVariable($(QuoteNode(rvname)), $distname($(distargs...))))
            push!(_rvs, esc(expr))
        end

        @capture(expr, elements__)
        for elt in elements
            # Meta.show_sexpr(elt)
            # println("")
            # e.g.,  rv(name1) = Normal(10, 3)
            if @capture(elt, rv(rvname_) = distname_(distargs__))
                saverv(rvname, distname, distargs)

            elseif @capture(elt, save(vars__))
                for var in vars
                    # println("var: $var")
                    if @capture(var, comp_.datum_)
                        expr = :($(QuoteNode(comp)), $(QuoteNode(datum)))
                        push!(_saves, esc(expr))
                    else
                        error("Save arg spec must be of the form comp_name.datum_name; got ($var)")
                    end
                end

            # handle vector of distributions
            elseif @capture(elt, extvar_ = [items__])
                for pair in items
                    if (@capture(pair, [dims__] => distname_(distargs__)) ||
                        @capture(pair,     dim_ => distname_(distargs__)))

                        dims = _make_dims(dims === nothing ? [dim] : dims)

                        rvname = _make_rvname(extvar)
                        saverv(rvname, distname, distargs)

                        expr = :(TransformSpec($(QuoteNode(extvar)), :(=), $(QuoteNode(rvname)), [$(dims...)]))
                        push!(_transforms, esc(expr))
                    end
                end

            # e.g., name1:name2 = 0.7
            elseif @capture(elt, name1_:name2_ = value_)
                expr = :(CorrelationSpec($(QuoteNode(name1)), $(QuoteNode(name2)), $value))
                push!(_corrs, esc(expr))

            # e.g., ext_var5[2010:2050, :] *= name2
            # A bug in Macrotools prevents this shorter expression from working:
            # elseif @capture(elt, ((extvar_  = rvname_Symbol) | 
            #                       (extvar_ += rvname_Symbol) |
            #                       (extvar_ *= rvname_Symbol) |
            #                       (extvar_  = distname_(distargs__)) | 
            #                       (extvar_ += distname_(distargs__)) |
            #                       (extvar_ *= distname_(distargs__))))
            elseif (@capture(elt, extvar_  = rvname_Symbol) ||
                    @capture(elt, extvar_ += rvname_Symbol) ||
                    @capture(elt, extvar_ *= rvname_Symbol) ||
                    @capture(elt, extvar_  = distname_(distargs__)) ||
                    @capture(elt, extvar_ += distname_(distargs__)) ||
                    @capture(elt, extvar_ *= distname_(distargs__)))

                # For "anonymous" RVs, e.g., ext_var2[2010:2100, :] *= Uniform(0.8, 1.2), we
                # gensym a name based on the external var name and process it as a named RV.
                if rvname === nothing
                    param_name = @capture(extvar, name_[args__]) ? name : extvar
                    rvname = _make_rvname(param_name)
                    saverv(rvname, distname, distargs)
                end

                op = elt.head
                if @capture(extvar, name_[args__])
                    # println("Ref:  $name, $args")        
                    # Meta.show_sexpr(extvar)
                    # println("")

                    # if extvar.head == :ref, extvar.args must be one of:
                    # - a scalar value, e.g., name[2050] => (:ref, :name, 2050)
                    #   convert to tuple of dimension specifiers (:name, 2050)
                    # - a slice expression, e.g., name[2010:2050] => (:ref, :name, (:(:), 2010, 2050))
                    #   convert to (:name, 2010:2050) [convert it to actual UnitRange instance]
                    # - a tuple of symbols, e.g., name[(US, CHI)] => (:ref, :name, (:tuple, :US, :CHI))
                    #   convert to (:name, (:US, :CHI))
                    # - combinations of these, e.g., name[2010:2050, (US, CHI)] => (:ref, :name, (:(:), 2010, 2050), (:tuple, :US, :CHI))
                    #   convert to (:name, 2010:2050, (:US, :CHI))

                    dims = _make_dims(args)
                    expr = :(TransformSpec($(QuoteNode(name)), $(QuoteNode(op)), $(QuoteNode(rvname)), [$(dims...)]))
                else
                    expr = :(TransformSpec($(QuoteNode(extvar)), $(QuoteNode(op)), $(QuoteNode(rvname))))
                end
                push!(_transforms, esc(expr))
            else
                error("Unrecognized expression '$elt' in @defmcs")
            end
        end
        return :(MonteCarloSimulation([$(_rvs...)], 
                                      [$(_transforms...)], 
                                      CorrelationSpec[$(_corrs...)], 
                                      Tuple{Symbol, Symbol}[$(_saves...)]))
    end
end