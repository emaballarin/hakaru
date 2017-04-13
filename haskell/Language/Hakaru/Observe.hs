{-# LANGUAGE DataKinds
           , GADTs
           , FlexibleContexts
           , KindSignatures
           , PolyKinds
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                    2016.04.21
-- |
-- Module      :  Language.Hakaru.Observe
-- Copyright   :  Copyright (c) 2016 the Hakaru team
-- License     :  BSD3
-- Maintainer  :  ppaml@indiana.edu
-- Stability   :  experimental
-- Portability :  GHC-only
--
-- A simpler version of the work done in 'Language.Hakaru.Disintegrate'
--
-- In principle, this module's functionality is entirely subsumed
-- by the work done in Language.Hakaru.Disintegrate, so we can hope
-- to define observe in terms of disintegrate. This is still useful
-- as a guide to those that want something more in line with what other
-- probabilisitc programming systems support.
----------------------------------------------------------------
module Language.Hakaru.Observe where

import           Language.Hakaru.Syntax.AST
import           Language.Hakaru.Syntax.ABT
import           Language.Hakaru.Types.DataKind
import           Language.Hakaru.Types.Sing
import qualified Language.Hakaru.Syntax.Prelude as P
import           Language.Hakaru.Syntax.TypeOf

observe
    :: (ABT Term abt)
    => abt '[] ('HMeasure a)
    -> abt '[] a 
    -> abt '[] ('HMeasure a)
observe m a = observeAST (LC_ m) (LC_ a)


-- TODO: move this to ABT.hs
freshenVarRe
    :: ABT syn abt => Variable (a :: k) -> abt '[] (b :: k) -> Variable a
freshenVarRe x m = x {varID = nextFree m `max` nextBind m}


observeAST
    :: (ABT Term abt)
    => LC_ abt ('HMeasure a)
    -> LC_ abt a
    -> abt '[] ('HMeasure a)
observeAST (LC_ m) (LC_ a) =
    caseVarSyn m observeVar $ \ast ->
        case ast of
        -- TODO: Add a name supply
        Let_ :$ e1 :* e2 :* End ->
            caseBind e2 $ \x e2' ->
            let x'   = freshenVarRe x m
                e2'' = rename x x' e2'
            in syn (Let_ :$ e1 :* bind x' (observe e2'' a) :* End)
        --Dirac :$ e :* End -> P.if_ (e P.== a) (P.dirac a) P.reject
        -- TODO: Add a name supply
        MBind :$ e1 :* e2 :* End ->
            caseBind e2 $ \x e2' ->
            let x'   = freshenVarRe x m
                e2'' = rename x x' e2'
            in syn (MBind :$ e1 :* bind x' (observe e2'' a) :* End)
        Plate :$ e1 :* e2 :* End ->
            caseBind e2 $ \x e2' ->
            let a' = syn (ArrayOp_ (Index (sUnMeasure $ typeOf e2'))
                        :$ a
                        :* var x :* End)
            in syn (Plate :$ e1 :* bind x (observe e2' a') :* End)
        MeasureOp_ op :$ es -> observeMeasureOp op es a
        _ -> error "observe can only be applied to measure primitives"

-- This function can't inspect a variable due to
-- calls to subst that happens in Let_ and Bind_
observeVar :: Variable a -> r
observeVar = error "observe can only be applied measure primitives"

observeMeasureOp
    :: (ABT Term abt, typs ~ UnLCs args, args ~ LCs typs)
    => MeasureOp typs a
    -> SArgs abt args
    -> abt '[] a
    -> abt '[] ('HMeasure a)
observeMeasureOp Normal = \(mu :* sd :* End) a ->
    P.withWeight (P.densityNormal mu sd a) (P.dirac a)
observeMeasureOp Uniform = \(lo :* hi :* End) a ->
    P.if_ (lo P.<= a P.&& a P.<= hi)
        (P.withWeight (P.unsafeProb $ P.recip $ hi P.- lo) (P.dirac a))
        (P.reject (SMeasure SReal))
observeMeasureOp _ = error "TODO{Observe:observeMeasureOp}"
