{-# LANGUAGE CPP
           , GADTs
           , KindSignatures
           , DataKinds
           , ScopedTypeVariables
           , PatternGuards
           , Rank2Types
           , TypeOperators
           , FlexibleContexts
           , UndecidableInstances
           #-}
module Language.Hakaru.Pretty.SExpression where

#if __GLASGOW_HASKELL__ < 710
import Data.Foldable (foldMap)
import Control.Applicative ((<$>))
#endif

import System.IO (stderr)
import Data.Ratio
import Data.Text (Text)
import Data.Sequence (Seq)

import Data.Text as Text
import Data.Number.Nat (fromNat)
import Data.Number.Natural (fromNatural, fromNonNegativeRational)
import Data.Ratio
import Data.Sequence (Seq)
import Data.Text as Text
import Data.Text.IO as IO
import Language.Hakaru.Command (parseAndInfer)
import Language.Hakaru.Syntax.IClasses (fmap11, foldMap11, jmEq1, TypeEq(..))
import Language.Hakaru.Types.Coercion
import Language.Hakaru.Types.DataKind
import Language.Hakaru.Types.HClasses
import Language.Hakaru.Types.Sing

import Language.Hakaru.Summary
import Language.Hakaru.Syntax.ABT
import Language.Hakaru.Syntax.AST
import Language.Hakaru.Syntax.AST.Transforms
import Language.Hakaru.Syntax.Datum
import Language.Hakaru.Syntax.Reducer
import Language.Hakaru.Syntax.TypeCheck
import Language.Hakaru.Syntax.TypeOf
import Language.Hakaru.Types.Coercion
import Language.Hakaru.Types.DataKind
import Language.Hakaru.Types.HClasses
import Language.Hakaru.Types.Sing
import Text.PrettyPrint (Doc, (<>), (<+>))
import Text.PrettyPrint as PP

pretty :: (ABT Term abt) => abt '[] a -> Doc
pretty a =
  PP.brackets (caseVarSyn a prettyVariable prettyTerm <+>
               PP.colon <+> prettyType (typeOf a))

prettyTerm :: (ABT Term abt) => Term abt a -> Doc
prettyTerm (o :$ es) = PP.parens $ prettySCons o es
prettyTerm (NaryOp_ op es) = PP.parens $ prettyNary op es
prettyTerm (Literal_ v) = prettyLiteral v
prettyTerm (Array_ e1 e2) =
  PP.parens $ (PP.text "array") <+>
  (caseBind e2 $ \x e2' ->
                   PP.parens (prettyVariable x <+> pretty e1) <+>
                   pretty e2')
prettyTerm (Case_ e1 bs) =
  PP.parens $ PP.text "match" <+> pretty e1 <+>
  Prelude.foldl (<+>) PP.empty (prettyBranch <$> bs)
prettyTerm (Bucket b e r) =
  PP.parens $ ( PP.text "bucket" <+> pretty b <+> pretty e <+> prettyReducer r)
prettyTerm (Reject_ _) = PP.parens $ PP.text "reject"
prettyTerm (Empty_ _) = PP.parens $ PP.text "empty"
prettyTerm (ArrayLiteral_ es) = PP.text "TODO:arrayliteral"
prettyTerm (Superpose_ pes) = PP.text "TODO:superpose"

prettyTerm (Datum_ d) = PP.text "TODO:datum"

prettyReducer :: (ABT Term abt) => Reducer abt xs a -> Doc
prettyReducer (Red_Fanout red_a red_b) =
  PP.parens (PP.text "r_fanout" <+> prettyReducer red_a <+> prettyReducer red_b)
prettyReducer (Red_Index i red_i red_a) =
  PP.parens (PP.text "r_index" <+> prettyViewABT i <+>
             prettyViewABT red_i <+> prettyReducer red_a)
prettyReducer (Red_Split i red_a red_b) =
  PP.parens (PP.text "r_split" <+> prettyViewABT i <+>
            prettyReducer red_a <+> prettyReducer red_b)
prettyReducer (Red_Nop) = PP.text "r_nop"
prettyReducer (Red_Add s a) =
  PP.parens (PP.text "r_add" <+> prettyViewABT a)

prettyBranch :: (ABT Term abt) => Branch a abt b -> Doc
prettyBranch (Branch pat e) =
  PP.parens $ prettyPattern pat <+> prettyViewABT e

prettyPattern :: Pattern xs a -> Doc
prettyPattern PWild = PP.text "*"
prettyPattern PVar = PP.text "var"
prettyPattern (PDatum hint c) =
  PP.parens $ PP.text "datum" <+> PP.text (unpack hint) <+> goCode c
goCode :: PDatumCode xss vars a -> Doc
goCode c = PP.parens $ case c of
  (PInr d) -> PP.text "pc_inr" <+> goCode d
  (PInl s) -> PP.text "pc_inl" <+> goStruct s
goStruct :: PDatumStruct xs vars a -> Doc
goStruct s = PP.parens $ case s of
  (PDone) -> PP.text "ps_done"
  (PEt f s) -> PP.text "ps_et" <+> goFun f <+> goStruct s
goFun :: PDatumFun x vars a -> Doc
goFun f = PP.parens $ case f of
  (PKonst p) -> PP.text "pf_konst" <+> prettyPattern p
  (PIdent p) -> PP.text "pf_ident" <+> prettyPattern p


prettyViewABT :: (ABT Term abt) => abt xs a -> Doc
prettyViewABT = prettyView . viewABT

prettyView :: (ABT Term abt) => View (Term abt) xs a -> Doc
prettyView (Bind x v) =
  PP.parens $ PP.text "bind" <+> prettyVariable x <+> prettyView v
prettyView (Var x) = prettyVariable x
prettyView (Syn t) = pretty (syn t)

prettyShow :: (Show a) => a -> Doc
prettyShow = PP.text . show

prettyLiteral :: Literal a -> Doc
prettyLiteral (LNat v) = prettyShow v
prettyLiteral (LInt i) = prettyShow i
prettyLiteral (LProb p) = prettyRatio . fromNonNegativeRational $ p
prettyLiteral (LReal p) = prettyShow p


prettyRatio :: (Show a, Integral a) => Ratio a -> Doc
prettyRatio r
  | d == 1 = prettyShow n
  | n < 0 = PP.parens $ PP.text "/" <+> PP.text "-" <> prettyShow  n <+> prettyShow d
  | otherwise = PP.parens $ prettyShow n <+> prettyShow d
    where
      d = denominator r
      n = numerator r

prettyVariable :: Variable (a :: Hakaru) -> Doc
prettyVariable x | Text.null (varHint x) = PP.text "_" <> (PP.int . fromNat .varID) x
                 | otherwise = (PP.text . Text.unpack . varHint) x

prettySCons :: (ABT Term abt) => SCon args a -> SArgs abt args -> Doc
prettySCons Lam_ (e1 :* End) = caseBind e1 $ \x e1' ->
  PP.text "fn" <+> prettyVariable x  <+> (prettyType $ typeOf e1')
  <+> pretty e1'
prettySCons (PrimOp_ o) es = prettyPrimOp o es
prettySCons (ArrayOp_ o) es = prettyArrayOp o es
prettySCons (CoerceTo_ o) (e1 :* End) = PP.text (pCoerce o) <+> pretty e1
prettySCons (Summate _ _) (e1 :* e2 :* e3 :* End) =
  caseBind e3 $ \x e3' -> PP.text "summate" <+>
                          PP.parens (prettyVariable x <+> pretty e1 <+> pretty e2) <+>
                          pretty e3'
prettySCons (Product _ _) (e1 :* e2 :* e3 :* End) =
  caseBind e3 $ \x e3' -> PP.text "product" <+>
                          PP.parens (prettyVariable x <+> pretty e1 <+> pretty e2) <+>
                          pretty e3'
prettySCons App_ (e1 :* e2 :* End) = PP.text "appTODO"
prettySCons Let_ (e1 :* e2 :* End) = caseBind e2 $ \x e2' ->
  PP.text "let" <+>
  PP.parens (prettyVariable x <+> (prettyType $ typeOf e1) <+> pretty e1)
  <+> pretty e2'
prettySCons (UnsafeFrom_ o) es = PP.text "UnsafeSConsTODO"
prettySCons (MeasureOp_ o) es = prettyMeasureOp o es
prettySCons Dirac es     = PP.text "DiracSConsTODO"
prettySCons MBind es     = PP.text "MBindSConsTODO"
prettySCons Plate es     = PP.text "PlateSConsTODO"
prettySCons Chain es     = PP.text "ChainSConsTODO"
prettySCons Integrate es = PP.text "IntegrateSConsTODO"
prettySCons (Transform_ t) _ = PP.text $
     Prelude.concat [ "SCons{", show t, "}: TODO" ]

prettyMeasureOp
    :: (ABT Term abt, typs ~ UnLCs args, args ~ LCs typs)
    => MeasureOp typs a -> SArgs abt args -> Doc
prettyMeasureOp Lebesgue    = \(e1 :* e2 :* End)          -> PP.text "lebesgue" <+> pretty e1 <+> pretty e2
prettyMeasureOp Counting    = \End           -> PP.text "counting"
prettyMeasureOp Categorical = \(e1 :* End)   -> PP.text "categorical" <+> pretty e1
prettyMeasureOp Uniform = \(e1 :* e2 :* End) -> PP.text "uniform"     <+> pretty e1 <+> pretty e2
prettyMeasureOp Normal  = \(e1 :* e2 :* End) -> PP.text "normal"      <+> pretty e1 <+> pretty e2
prettyMeasureOp Poisson = \(e1 :* End)       -> PP.text "poisson"     <+> pretty e1
prettyMeasureOp Gamma   = \(e1 :* e2 :* End) -> PP.text "gamma"       <+> pretty e1 <+> pretty e2
prettyMeasureOp Beta    = \(e1 :* e2 :* End) -> PP.text "beta"        <+> pretty e1 <+> pretty e2

pCoerce :: Coercion a b -> String
pCoerce (CCons (Signed HRing_Real) CNil)             = "prob2real"
pCoerce (CCons (Signed HRing_Int)  CNil)             = "nat2int"
pCoerce (CCons (Continuous HContinuous_Real) CNil)   = "int2real"
pCoerce (CCons (Continuous HContinuous_Prob) CNil)   = "nat2prob"
pCoerce (CCons (Continuous HContinuous_Prob)
         (CCons (Signed HRing_Real) CNil))           = "nat2real"
pCoerce (CCons (Signed HRing_Int)
         (CCons (Continuous HContinuous_Real) CNil)) = "nat2real"


prettyNary :: (ABT Term abt) => NaryOp a -> Seq (abt '[] a) -> Doc
prettyNary And       es      = PP.text "and" <+> foldMap pretty es
prettyNary Or        es      = PP.text "or" <+> foldMap pretty es
prettyNary Xor       es      = PP.text "xor" <+> foldMap pretty es
prettyNary (Sum  _)  es      = PP.text "+" <+> foldMap pretty es
prettyNary (Prod  _) es      = PP.text "*" <+> foldMap pretty es
prettyNary (Min  _)  es      = PP.text "min" <+> foldMap pretty es
prettyNary (Max  _)  es      = PP.text "max" <+> foldMap pretty es

prettyType :: Sing (a :: Hakaru) -> Doc
prettyType SNat         = PP.text "nat"
prettyType SInt         = PP.text "int"
prettyType SProb        = PP.text "prob"
prettyType SReal        = PP.text "real"
prettyType (SArray a)   = PP.parens $ PP.text "array" <+> prettyType a
prettyType (SMeasure a) = PP.parens $ PP.text "measure" <+> prettyType a
prettyType (SFun a b)   = PP.parens $ prettyType a <+> PP.text "->" <+> prettyType b
prettyType typ =
    case typ of
    SData (STyCon sym `STyApp` a `STyApp` b) _
      | Just Refl <- jmEq1 sym sSymbol_Pair
      -> PP.parens $ PP.text "pair" <+> prettyType a <+> prettyType b
      | Just Refl <- jmEq1 sym sSymbol_Either
      -> PP.parens $ PP.text "either" <+> prettyType a <+> prettyType b
    SData (STyCon sym `STyApp` a) _
      | Just Refl <- jmEq1 sym sSymbol_Maybe
      -> PP.parens $ PP.text "maybe" <+> prettyType a
    SData (STyCon sym) _
      | Just Refl <- jmEq1 sym sSymbol_Bool
      -> PP.text "bool"
      | Just Refl <- jmEq1 sym sSymbol_Unit
      -> PP.text "unit"
    _ -> PP.text (showsPrec 11 typ "")

prettyPrimOp
    :: (ABT Term abt, typs ~ UnLCs args, args ~ LCs typs)
    => PrimOp typs a -> SArgs abt args -> Doc
prettyPrimOp Not              (e1 :* End)       = PP.text "not" <+> pretty e1
prettyPrimOp Pi               End               = PP.text "pi"
prettyPrimOp Cos              (e1 :* End)       = PP.text "cos" <+> pretty e1
prettyPrimOp RealPow          (e1 :* e2 :* End) = PP.text "realpow" <+> pretty e1 <+> pretty e2
prettyPrimOp Exp              (e1 :* End)       = PP.text "exp"  <+> pretty e1
prettyPrimOp Log              (e1 :* End)       = PP.text "log"  <+> pretty e1
prettyPrimOp (Infinity  _)    End               = PP.text "infinity"
prettyPrimOp GammaFunc        (e1 :* End)       = PP.text "gamma" <+> pretty e1
prettyPrimOp BetaFunc         (e1 :* e2 :* End) = PP.text "beta" <+> pretty e1 <+> pretty e2
prettyPrimOp (Equal _)        (e1 :* e2 :* End) = PP.text "==" <+> pretty e1 <+> pretty e2
prettyPrimOp (Less _)         (e1 :* e2 :* End) = PP.text "<" <+> pretty e1 <+> pretty e2
prettyPrimOp (NatPow _)       (e1 :* e2 :* End) = PP.text "natpow" <+> pretty e1 <+> pretty e2
prettyPrimOp (Negate _)       (e1 :* End)       = PP.text "negate" <+> pretty e1
prettyPrimOp (Abs _)          (e1 :* End)       = PP.text "abs"  <+> pretty e1
prettyPrimOp (Recip   _)      (e1 :* End)       = PP.text "recip" <+> pretty e1
prettyPrimOp (NatRoot _)      (e1 :* e2 :* End) = PP.text "root" <+> pretty e1 <+> pretty e2

prettyArrayOp
    :: (ABT Term abt, typs ~ UnLCs args, args ~ LCs typs)
    => ArrayOp typs a -> SArgs abt args -> Doc
prettyArrayOp (Index _) (e1 :* e2 :* End) = PP.text "index" <+> pretty e1 <+> pretty e2
prettyArrayOp (Size  _) (e1 :* End)       = PP.text "size" <+> pretty e1

prettyFile' :: [Char] -> [Char] -> IO ()
prettyFile' fname outFname = do
  fileText <- IO.readFile fname
  prettyText <- runPretty' fileText
  IO.writeFile outFname (pack prettyText)
  print prettyText

runPretty' :: Text -> IO String
runPretty' prog =
    case parseAndInfer prog of
    Left  err              -> return "err"
    Right (TypedAST _ ast) -> do
      summarised <- summary . expandTransformations $ ast
      return . render . pretty $ summarised

fromAst :: Either Text (TypedAST (TrivialABT Term)) -> String
fromAst prog =
    case prog of
    Left  err              -> unpack err
    Right (TypedAST _ ast) -> render . pretty . expandTransformations $ ast
