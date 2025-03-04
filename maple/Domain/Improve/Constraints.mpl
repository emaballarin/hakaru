# Note this is valid only because this file is technically a top-level file,
# i.e. it isn't included anywhere with `$include'
with(Domain_Type):

local Simplify_DConstrain := (can_simp, do_simp) -> module()
    uses Domain;

    export ModuleApply := proc(vs0 :: DomBound, sh :: DomShape, $)
        local vs := vs0, ctx;
        if _Env_HakaruSolve=false then
           return sh end if;
        vs  := Domain:-Bound:-varsOf(vs,"set");
        ctx := Domain:-Bound:-toConstraints(vs0, 'bound_types');
        subsindets(sh, DomConstrain
                  ,x->do_simpl_constraints(vs0, vs, ctx, x));
    end proc;

    local do_simpl_constraints := proc(vs0, vars, ctx_vs, x, $)
        local ctx1, ctx, ss, td, rest, d, in_vs;
        ss, ctx := selectremove(q->depends(q,indets(vars,Name)), x);
        td, rest := selectremove(can_simp(vs0), ss);
        ctx1 := { op(ctx), op(ctx_vs), op(rest) };
        d := map(x->do_simp(vs0,ctx1,x), td);
        DConstrain(op(d), op(ctx), op(rest));
    end proc;
end module;

Domain_try_improve_exp := module()
  uses Utilities;

  export SimplName  := "Try improve exp";
  export SimplOrder := 6 - 2/10;

  local can := proc(vs)
    c -> c::relation and (not(lhs(c) :: Name) and not(rhs(c) :: Name) and has(c,{ln,exp}));
  end proc;

  local `try` := proc(dbnd, ctx1, q0, $)
    local vars, vars_q, q := q0;
    vars := Domain:-Bound:-varsOf(dbnd,"set");
    vars_q := indets(q, name) intersect vars;
    if nops(vars_q)=0 then return q end if;

    vars_q := op(1,vars_q);
    try_improve_exp(q, vars_q, ctx1);
  end proc;

  export ModuleApply := Simplify_DConstrain(can, `try`);
end module;

constraints_about_vars := module()
  uses Utilities;
  export SimplName  := "Make constraints abouts vars";
  export SimplOrder := 6;

  local can_make_about := proc(vs)
    local vars := Domain:-Bound:-varsOf(vs,"set");
    c -> c::relation and (not(lhs(c) in vars) and not(rhs(c) in vars));
  end proc;
  local try_make_about := proc(dbnd, ctx1_, q0, $)
      local vars_q, vars, q_s, q_r
          , q := q0
          , ctx1 := ctx1_ ;
      vars := Domain:-Bound:-varsOf(dbnd,"set");
      vars_q := indets(q, name) intersect vars;
      if nops(vars_q)=0 then return q end if;

      vars_q := op(1,vars_q);
      q := try_improve_exp(q, vars_q, ctx1);
      q_r := `if`(has(q,{ln,exp}),q0,q);

      q, ctx1 := map(KB:-chill, [q,ctx1])[];
      # Unevaluated for debugging
      q_s := 'solve({q},[op(vars_q)], 'useassumptions'=true) assuming (op(ctx1))';
      q_s := eval(q_s);
      q, ctx1 := map(KB:-warm, [q,ctx1])[];
      if q_s::list and not has(q_s, signum) then
        if nops(q_s)=0 then return q_r end if;
        q_s := map(s->remove(c->c in ctx1 or `and`(c::relation,lhs(c)::name,lhs(c)=rhs(c)), s), q_s);
        q_s := remove(x->x=[],q_s);
        if nops(q_s)=0 then return q_r end if;
        userinfo(3, 'constraints_about_vars'
                ,printf("Found a solution to %a (with solve):\n\t%a\n", q0, op(1,q_s)));
        op(op(1,q_s)); # pick the first solution arbitrarily!
      else
        q_r
      end if;
  end proc;

  export ModuleApply := Simplify_DConstrain(can_make_about, try_make_about);
end module;


clamp_extraneous_constraints := module()
  uses Utilities;
  export SimplName  := "clamp_extraneous_constraints";
  export SimplOrder := 6 - 1/10;

  local can := proc(vs)
    local vars := Domain:-Bound:-varsOf(vs,"set");
    c-> c::relation and
        (ormap(s->s(c)::Name and not(c in vars),[lhs,rhs]) and has(c, vars));
  end proc;

  local `try` := proc(dbnd, ctx1, q0, $)
    local bnd, b_ty, b_rel, b_var, b_bnd, b_bnd_vs, vars, extremum, q := q0;
    if has(q, {ln,exp}) then
      vars := Domain:-Bound:-varsOf(dbnd, "set");
      bnd := classify_relation(q0, x -> type(x, Name) and not (x in vars));
      if bnd=FAIL then return q0 end if;
      b_ty, b_rel, b_var, b_bnd := op(bnd):
      b_bnd_vs := indets(b_bnd, satisfies(x -> x in vars));
      if b_bnd_vs <> {} then
        b_ty := `if`(b_ty=B_LO, 'minimize', 'maximize');
        extremum := b_ty(b_bnd, op(b_bnd_vs)) assuming(op(ctx1));
        if not (ext :: SymbolicInfinity or has(extremum, {maximize,minimize})) then
          q := q, b_rel(b_var,extremum);
        end if;
      end if;
    end if;
    q
  end proc;
  export ModuleApply := Simplify_DConstrain(can, `try`);
end module;

# Pushes constraints down, or pulls them up, when there are such constraints.
local do_ctx_dir := dir -> proc(vs :: DomBound, sh :: DomShape, $)
    local ctx := Domain:-Bound:-toConstraints(vs, 'no_infinity');
    ctx := remove(x->x::`::`,ctx);
    if ctx <> {} then
        dir(ctx)(sh);
    else
        sh;
    end if;
end proc;

push_ctx_down := module()
  uses Domain;
  export ModuleApply := do_ctx_dir(ctx->sh->subsindets(sh, DomConstrain, x->if nops(x)<>0 then DConstrain(op(x), op(ctx)) else DConstrain() end if));
  export SimplName  := "Push context down";
  export SimplOrder := 1;
end module;

pull_ctx_out := module()
  export ModuleApply :=
    do_ctx_dir(ctx->sh->subsindets(sh, DomConstrain
              ,x->remove(c->c in ctx or (is(c) assuming op(ctx)), x)));
  export SimplName  := "Pull context out";
  export SimplOrder := 20;
end module;

# Turns constraints(relations) into bounds
classify_DConstrains := module()
  uses Domain, Utilities;

  export SimplName  := "Classify constraints";
  export SimplOrder := 8;

  export ModuleApply := proc(dbnds::DomBound,dsh::DomShape,$)
    subsindets(dsh, DomConstrain, x->classify_Rels([op(x)], dbnds));
  end proc;

  # Split relations into those we can incorporate
  # into bounds and others; this process also includes
  # some intermediate computations about the new bound:
  #  [ DInto(var), orig, upd_bound, bound_kind, numVars ]
  #    var         :=   variable to be modified
  #    orig        :=   the original relation
  #    upd_bound   :=   how to modify (a function)
  #    bound_kind  :=   {LO/HI}
  #    numVars     :=   how many variables are mentioned by the bound
  local classify_Rel := proc(r0,dbnd,$)
    local ret, vars, mk_k, bnd_k, i, var_k, q, cl, lhs_r, rhs_r, r := r0;
    ret := [ DConstrain, r0 ];
    vars := Domain:-Bound:-varsOf(dbnd,"set");

    # extract a representation of the relation, and check that it is a bound
    cl := classify_relation(r, vars);
    if cl=FAIL or not (op(1,cl) in {B_LO,B_HI}) then return ret; end if;
    bnd_k,mk_k,lhs_r,rhs_r := op(cl);

    i := Domain:-Bound:-varIx_mb(dbnd, lhs_r);
    if i >= 0 then
      var_k := op([1,i,3], dbnd);
      q := Domain:-ExtBound[var_k]:-RecogBound(mk_k,rhs_r);
      if q <> NULL then
        ret := [ DInto(lhs_r), r0, q, bnd_k, countVs(vars minus {lhs_r},r0) ];
      end if;
    end if;
    ret;
  end proc;

  # Classifies a set of relations as potential bounds. The process
  # is as follows:
  #  - Classify each relation individually (see classify_Rel)
  #  - "Categorize" by the classification
  #  - Split relations which will be DConstrains, and those where we found
  #      more than one LO/HI bound or more than 2 bounds total.
  #  - Sort the relations which are to become bounds by the number of variables
  #      mentioned in the bound
  #  - Rebuild the continuations producing each new bound (see make_DInto)
  #  - Rebuild the leftover relations as a DConstrain.
  #  - Squash together ("foldr (.) id fs z") the continuations and leftover relations.
  local classify_Rels := proc(rs0,dbnd,$)
    local cs1, cs2, cs, rs := rs0;
    rs := map(r->classify_Rel(r,dbnd), rs);
    rs := [ListTools[Categorize]( ((a,b) -> op(1,a)=op(1,b) ), rs )];
    cs1, rs := selectremove(x->op([1,1],x)=DConstrain, rs);
    rs, cs2 := selectremove(x->nops(x)=1 or (nops(x)=2 and op([1,4],x)<>op([2,4],x)), rs);
    rs := sort(rs, key=solOrder);
    rs := map(r->make_DInto(r,dbnd),rs);
    cs := DConstrain(map(c->map(q->op(2,q),c)[], [op(cs1),op(cs2)])[]);
    foldr((f,g)->f@g,x->x,op(rs))(cs);
  end proc;

  # Rebuild a classified (by classify_Rel) relation; this
  # takes a list of such classifications, all of whose variable should
  # be identical, and for which the different bound kinds are all distinct.
  # None of this is checked!
  # (since there are 2 bound kinds, this list is at most length 2)
  local make_DInto := proc(r::list([specfunc(DInto),anything,anything,identical(B_LO,B_HI),nonnegint]), dbnd, $)
    local var_nm, var_ty;
    var_nm := op([1,1,1], r);
    var_ty := Domain:-Bound:-get(dbnd, var_nm)[1];
    var_ty := foldr( ((q,x)->op(3,q)(x)), var_ty, op(r) );
    (ctx -> DInto(var_nm, var_ty, ctx))
  end proc;
  local flip_rel := table([`=`=`=`,`<>`=`<>`,`<=`=`>=`,`<`=`>`,`>=`=`<=`,`>`=`<`]);
  local countVs := ((vs,c)-> nops(indets(c, DomBoundVar) intersect {op(vs)} ));
  local solOrder := (x->`+`(map(z->op(5,z),x)[]));
end module;

# todo; this should actually solve for a variable, then substitute
# that variable in. In most cases, it would probably be enough to
# leave that as it is; it would simplify later.
singular_pts := module()
  uses Domain, Domain_Type, Hakaru;

  export SimplName  := "Single_pts";
  export SimplOrder := 7;

  export ModuleApply := proc(bnds :: DomBound, sh :: DomShape, $)
    local kb, kb_rn, ns, sh1; sh1 := sh;
    kb, kb_rn := Domain:-Bound:-toKB(bnds)[];
    sh1 := subs(kb_rn, sh1);
    ns := op(1,bnds);
    ns := select(b->op(3,b) in {`Int`,`Ints`}, ns);
    ns := map(curry(op,1), ns);

    sh1 := Partition:-Simpl:-singular_pts(sh1, kb, _name_cands=ns);
    eval(sh1, [DSum=DSum,DConstrain=DConstrain]);
  end proc;
end module;
