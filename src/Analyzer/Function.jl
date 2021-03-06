module Function
using  ...PatternStructure.Trees
using  ...PatternStructure.Checks
using  ...PatternStructure.Special
using  ...PatternStructure.SlurpTypes
using  ...Analyzer.SlurpOptimizations
using  ...Helper
export analyze

#-----------------------------------------------------------------------------------
# Analysis state
#-----------------------------------------------------------------------------------

struct AnalysisState
  tree    :: PatternTree
  literal :: Bool
  mod     :: Module
  consts  :: Set{Symbol}
end
const newstate = AnalysisState
AnalysisState(state, tree::PatternTree) = newstate(tree, state.literal, state.mod, state.consts)
AnalysisState(state, literal::Bool)     = newstate(state.tree, literal, state.mod, state.consts)


#-----------------------------------------------------------------------------------
# analyze function: transform expressions into patterns
#-----------------------------------------------------------------------------------

function analyze(ex, mod=current_module())
  root   = PatternRoot()
  consts = Set{Symbol}()
  analyze!(ex, newstate(root, false, mod, consts))
  addbindings!(root)

  return root
end

#-----------------------------------------------------------------------------------
# analyze!: constructs patterns from expression and inserts them in a pattern tree
#-----------------------------------------------------------------------------------

function analyze!(ex::Symbol, state)
  is_binding_name(ex) && !state.literal ?
     newleaf!(newbinding(ex), state.tree) :
     newleaf!(equalsto(ex),   state.tree)
  #--
end

function analyze!(ex::Expr, state)
  is_special_expr(ex) && (return analyze_special!(ex, state))
  ex.head == :line && (return analyze!(LineNumberNode(0), state))

  step = getstep(ex.head)
  head = ex.head in [:kw, :(=)] ? :assign : ex.head
  node = newnode!(ExprHead(head), step, state.tree)
  args = step(ex)

  analyze_args!(args, node, state)
end

function analyze!(ex::QuoteNode, state)
  step = QuoteStep()
  node = newnode!(ExprHead(:quote), step, state.tree)
  analyze!(ex.value, newstate(state, node))
end

function analyze!(ex::LineNumberNode, state)
  analyze_special!(:(:P{$Helper.is_line_number}), state)
end

function analyze!(ex, state)
  newleaf!(equalsto(ex), state.tree)
end

#-----------------------------------------------------------------------------------
# analyze_args!: creates patterns from a vector of expressions
#-----------------------------------------------------------------------------------

function analyze_args!(args, node, state)
  nstate = newstate(state, node)
  for i in eachindex(args)
    analyze!(args[i], nstate)
    union!(node.bindings, bindings(node.children[i]))
  end
  optimize_slurps!(node, state)
end

#-----------------------------------------------------------------------------------
# analyze_special: patterns of the form :X{ys...} have special meaning
#-----------------------------------------------------------------------------------

function analyze_special!(ex, state)
  @assert length(ex.args) > 1 "Special syntax with no arguments is not supported."

  head = special_name(ex.args[1])
  args = ex.args[2:end]

  if head in [:?, :*]
    slurptype = head == :? ? GenericLazySlurp() : GenericGreedySlurp()

    node = newnode!(slurptype, SlurpStep(), state.tree)
    analyze_args!(args, node, state)

  elseif head == :binding
    @assert length(args) == 1    "the :binding pattern only accepts one argument"
    @assert isa(args[1], Symbol) "the :binding pattern only accepts a Symbol argument"
    newleaf!(newbinding(args[1]),  state.tree)

  elseif head == :autobinding
    @assert state.literal "Invalid :autobinding pattern. Only use it inside a :literal pattern."
    @assert length(args) == 1 "the :autobinding pattern only accepts one argument."
    analyze!(args[1], newstate(state, false))

  elseif head == :literal
    @assert !state.literal "Invalid :literal pattern. Don't use it inside another :literal pattern."
    @assert length(args) == 1 "the :literal pattern only accepts one argument."
    analyze!(args[1], newstate(state, true))

  elseif head == :predicate
    args = assertation_args(args)
    pred = eval(state.mod, args[2])
    gate = PatternGate(PredicateCheck(pred), depth(state.tree))
    insert!(state.tree, gate)
    analyze!(args[1], newstate(state, gate))

  elseif head == :type
    args = assertation_args(args)
    typ  = eval(state.mod, args[2])
    gate = PatternGate(TypeCheck{typ}(), depth(state.tree))
    insert!(state.tree, gate)
    analyze!(args[1], newstate(state, gate))

  elseif head == :equals
    args = assertation_args(args)
    val  = eval(state.mod, args[2])
    gate = PatternGate(EqualityCheck(val), depth(state.tree))
    insert!(state.tree, gate)
    analyze!(args[1], newstate(state, gate))

  elseif head == :iterable
    node = newnode!(ExprHead(:iterable), IterStep(), state.tree)
    analyze_args!(args, node, state)

  elseif head == :raw
    analyze!(Expr(QuoteStep()(args[1])[1], args[2:end]...), state)

  end
end

#-----------------------------------------------------------------------------------
# Find and add bindings
#-----------------------------------------------------------------------------------

function addbindings!(tree::PatternGate)
  addbindings!(tree.child)
  union!(tree.bindings, bindings(tree.child))
end

function addbindings!(tree::PatternNode)
  for child in tree.children
    addbindings!(child)
    union!(tree.bindings, bindings(child))
  end
end

function addbindings!(tree::PatternRoot)
  addbindings!(tree.child)
end

function addbindings!(tree::PatternLeaf)
end

#-----------------------------------------------------------------------------------
# Utility functions
#-----------------------------------------------------------------------------------

function getstep(head)
  head == :quote ? QuoteStep() :
  head == :block ? BlockStep() :
                  ArgsStep()
end

function is_macro_name(x::Symbol)
  string(x)[1] == '@'
end

function newbinding(ex)
  name = is_macro_name(ex) ? Symbol(string(ex)[2:end]) : ex
  Binding(name)
end

equalsto(x) = EqualityCheck(x)

assertation_args(args) =
  length(args) == 1 ? [gensym("x"), args[1]] : args

#-----------------------------------------------------------------------------------

end
