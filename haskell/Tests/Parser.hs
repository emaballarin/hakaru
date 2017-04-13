{-# LANGUAGE CPP, OverloadedStrings, DataKinds #-}
{-# OPTIONS_GHC -Wall -fwarn-tabs -fno-warn-orphans #-}

module Tests.Parser where

import Prelude hiding (unlines)

import Language.Hakaru.Parser.Parser
import Language.Hakaru.Parser.AST

import Data.Text
import Test.HUnit
import Test.QuickCheck.Arbitrary
import Test.QuickCheck

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative   (Applicative(..), (<$>))
#endif

arbNat  :: Gen (Positive Integer)
arbNat  = arbitrary

arbProb :: Gen (Positive Rational)
arbProb = arbitrary

instance Arbitrary Text where
    arbitrary = pack <$> ("x" ++) . show <$> getPositive <$> arbNat
    shrink xs = pack <$> shrink (unpack xs)

instance Arbitrary Literal' where
    arbitrary = oneof
        [ Nat  <$> getPositive <$> arbNat
        , Int  <$> arbitrary
        , Prob <$> getPositive <$> arbProb
        , Real <$> arbitrary
        ]

instance Arbitrary TypeAST' where
    arbitrary = frequency
        [ (20, TypeVar <$> arbitrary)
        , ( 1, TypeApp <$> arbitrary <*> arbitrary)
        , ( 1, TypeFun <$> arbitrary <*> arbitrary)
        ]

instance Arbitrary NaryOp where
    arbitrary = elements
        [And, Or,  Xor, Iff, Min, Max, Sum, Prod]

instance Arbitrary a => Arbitrary (Pattern' a) where
    arbitrary = oneof
        [ PVar' <$> arbitrary
        , return PWild'
        , PData' <$> (DV <$> arbitrary <*> arbitrary)
        ]

instance Arbitrary a => Arbitrary (Branch' a) where
    arbitrary = Branch' <$> arbitrary <*> arbitrary

instance Arbitrary a => Arbitrary (AST' a) where
    arbitrary = frequency
        [ (10, Var <$> arbitrary)
        , ( 1, Lam <$> arbitrary <*> arbitrary <*> arbitrary)
        , ( 1, App <$> arbitrary <*> arbitrary)
        , ( 1, Let <$> arbitrary <*> arbitrary <*> arbitrary)
        , ( 1, If  <$> arbitrary <*> arbitrary <*> arbitrary)
        , ( 1, Ann <$> arbitrary <*> arbitrary)
        , ( 1, return Infinity')
        , ( 1, ULiteral <$> arbitrary)
        --, ( 1, NaryOp <$> arbitrary)
        , ( 1, return Empty)
        , ( 1, Case  <$> arbitrary <*> arbitrary)
        , ( 1, Dirac <$> arbitrary)
        , ( 1, Bind  <$> arbitrary <*> arbitrary <*> arbitrary)
        ]

testParse :: Text -> AST' Text -> Assertion
testParse s p =
    case parseHakaru s of
    Left  m  -> assertFailure (unpack s ++ "\n" ++ show m)
    Right p' -> assertEqual "" p p'

if1, if2, if3, if4, if5 :: Text

ifAST1, ifAST2 :: AST' Text

if1 = "if True: 1 else: 2"

if2 = unlines
    ["if True: 1 else:"
    ,"2"
    ] 

if3 = unlines
    ["if True:"
    ,"  1"
    ,"else:"
    ,"  2"
    ]

if4 = unlines
    ["if True:"
    ,"  1 else: 2"
    ]

if5 = unlines
    ["if True:"
    ,"   4"
    ,"else:"
    ,"   if False:"
    ,"      2"
    ,"   else:"
    ,"      3"
    ]

ifAST1 =
    If (Var "True")
    (ULiteral (Nat 1))
    (ULiteral (Nat 2))

ifAST2 =
    If (Var "True")
    (ULiteral (Nat 4))
    (If (Var "False")
        (ULiteral (Nat 2))
        (ULiteral (Nat 3)))

testIfs :: Test
testIfs = test
    [ testParse if1 ifAST1
    , testParse if2 ifAST1
    , testParse if3 ifAST1
    , testParse if4 ifAST1
    , testParse if5 ifAST2
    ]

lam1 :: Text
lam1 = "fn x nat: x+3"

lam1AST :: AST' Text
lam1AST = Lam "x" (TypeVar "nat")
          (NaryOp Sum [ Var "x"
                      , ULiteral (Nat 3)
                      ])

def1 :: Text
def1 = unlines
    ["def foo(x nat):"
    ,"    x + 3"
    ,"foo(5)"
    ]

def2 :: Text
def2 = unlines
    ["def foo(x nat): x + 3"
    ,"foo(5)"
    ]

def3 :: Text
def3 = unlines
    ["def foo(x real):"
    ,"    y <~ normal(x,1.0)"
    ,"    return (y + y. real)"
    ,"foo(-2.0)"
    ]

def4 :: Text
def4 = unlines
    ["def foo(x nat) nat:"
    ,"    x+3"
    ,"foo(5)"
    ]

def1AST :: AST' Text
def1AST =
    Let "foo" (Lam "x" (TypeVar "nat")
               (NaryOp Sum [Var "x", ULiteral (Nat 3)]))
    (App (Var "foo") (ULiteral (Nat 5)))

def2AST :: AST' Text
def2AST =
    Let "foo" (Lam "x" (TypeVar "real")
        (Bind "y" (App (App (Var "normal") (Var "x")) (ULiteral (Prob 1.0)))
        (Dirac (Ann (NaryOp Sum [Var "y", Var "y"])
                    (TypeVar "real")))))
    (App (Var "foo") (App (Var "negate") (ULiteral (Prob 2.0))))

def3AST :: AST' Text
def3AST =
    Let "foo" (Ann
        (Lam "x" (TypeVar "nat")
                 (NaryOp Sum [Var "x", ULiteral (Nat 3)]))
        (TypeFun (TypeVar "nat") (TypeVar "nat")))
    (App (Var "foo") (ULiteral (Nat 5)))

testLams :: Test
testLams = test
    [ testParse lam1 lam1AST
    , testParse def1 def1AST
    , testParse def2 def1AST
    , testParse def3 def2AST
    , testParse def4 def3AST
    ]

let1 :: Text
let1 = unlines
    ["x = 3"
    ,"y = 2"
    ,"x + y"
    ]

let1AST :: AST' Text
let1AST =
    Let "x" (ULiteral (Nat 3))
    (Let "y" (ULiteral (Nat 2))
    (NaryOp Sum [Var "x", Var "y"]))

testLets :: Test
testLets = test
    [ testParse let1 let1AST ]

bind1 :: Text
bind1 = unlines
    ["x <~ uniform(0,1)"
    ,"y <~ normal(x, 1)"
    ,"dirac(y)"
    ]

bind2 :: Text
bind2 = unlines
    ["x <~ uniform(0,1)"
    ,"y <~ normal(x, 1)"
    ,"return y"
    ]

bind1AST :: AST' Text
bind1AST =
    Bind "x" (App (App (Var "uniform")
                       (ULiteral (Nat 0)))
                       (ULiteral (Nat 1)))
    (Bind "y" (App (App (Var "normal")
                        (Var "x"))
                        (ULiteral (Nat 1)))
    (Dirac (Var "y")))

ret1 :: Text
ret1 =  "return return 3"

ret1AST :: AST' Text
ret1AST = Dirac (Dirac (ULiteral (Nat 3)))

testBinds :: Test
testBinds = test
   [ testParse bind1 bind1AST
   , testParse bind2 bind1AST
   , testParse ret1  ret1AST
   ]

match1 :: Text
match1 = unlines
    ["match e:"
    ,"  left(a): e1"
    ]

match1AST :: AST' Text
match1AST =
    Case (Var "e")
    [Branch' (PData' (DV "left" [PVar' "a"])) (Var "e1")]

-- The space between _ and : is important
match2 :: Text
match2 = unlines
    ["match e:"
    ,"  _: e"
    ]

match2AST :: AST' Text
match2AST =
    Case (Var "e")
    [Branch' PWild' (Var "e")]

match3 :: Text
match3 = unlines
    ["match e:"
    ,"  a: e"
    ]

match3AST :: AST' Text
match3AST =
    Case (Var "e")
    [Branch' (PVar' "a") (Var "e")]

match4 :: Text
match4 = unlines
    ["match e:"
    ,"  left(a):  e1"
    ,"  right(b): e2"
    ]

match4AST :: AST' Text
match4AST =
    Case (Var "e")
    [ Branch' (PData' (DV "left"  [PVar' "a"])) (Var "e1")
    , Branch' (PData' (DV "right" [PVar' "b"])) (Var "e2")
    ]

match5 :: Text
match5 = unlines
    ["match e:"
    ,"  left(a):"
    ,"   e1"
    ,"  right(b):"
    ,"   e2"
    ]

match5AST :: AST' Text
match5AST =
    Case (Var "e")
    [ Branch' (PData' (DV "left" [PVar' "a"])) (Var "e1")
    , Branch' (PData' (DV "right" [PVar' "b"])) (Var "e2")
    ]

match6 :: Text
match6 = unlines
    ["match (2,3). pair(nat,nat):"
    ,"   (a,b): a+b"
    ]

match6AST :: AST' Text
match6AST =
    Case (Ann
          (Pair
           (ULiteral (Nat 2))
           (ULiteral (Nat 3)))
     (TypeApp "pair" [TypeVar "nat",TypeVar "nat"]))
    [Branch' (PData' (DV "pair" [PVar' "a",PVar' "b"]))
     (NaryOp Sum [Var "a", Var "b"])]


match7 :: Text
match7 = unlines
    ["match (-2.0,1.0). pair(real,prob):"
    ,"   (a,b): normal(a,b)"
    ]

match7AST :: AST' Text
match7AST = Case (Ann
                  (Pair
                   (App (Var "negate") (ULiteral (Prob 2.0)))
                   (ULiteral (Prob 1.0)))
             (TypeApp "pair" [TypeVar "real",TypeVar "prob"]))
            [Branch' (PData' (DV "pair" [PVar' "a",PVar' "b"]))
             (App (App (Var "normal") (Var "a")) (Var "b"))]

testMatches :: Test
testMatches = test
    [ testParse match1 match1AST
    , testParse match2 match2AST
    , testParse match3 match3AST
    , testParse match4 match4AST
    , testParse match5 match5AST
    , testParse match6 match6AST
    , testParse match7 match7AST
    ]

ann1 :: Text
ann1 = "5. nat"

ann1AST :: AST' Text
ann1AST = Ann (ULiteral (Nat 5)) (TypeVar "nat")

ann2 :: Text
ann2 = "(2,3). pair(a,b)"

ann2AST :: AST' Text
ann2AST =
    Ann (Pair (ULiteral (Nat 2)) (ULiteral (Nat 3)))
        (TypeApp "pair" [TypeVar "a", TypeVar "b"])

ann3 :: Text
ann3 = "f. a -> measure(a)"

ann3AST :: AST' Text
ann3AST =
    Ann (Var "f") (TypeFun (TypeVar "a")
        (TypeApp "measure" [(TypeVar "a")]))

testAnn :: Test
testAnn = test
    [ testParse ann1 ann1AST
    , testParse ann2 ann2AST
    , testParse ann3 ann3AST
    ]

expect1 :: Text
expect1 = unlines
    ["expect x normal(0,1):"
    ,"   1"
    ]

expect1AST :: AST' Text
expect1AST = Expect "x" (App (App (Var "normal")
                              (ULiteral (Nat 0)))
                         (ULiteral (Nat 1)))
             (ULiteral (Nat 1))

expect2 :: Text
expect2 = unlines
    ["expect x normal(0,1):"
    ,"   unsafeProb(x*x)"
    ]

expect2AST :: AST' Text
expect2AST = Expect "x" (App (App (Var "normal")
                              (ULiteral (Nat 0)))
                         (ULiteral (Nat 1)))
             (App (Var "unsafeProb")
              (NaryOp Prod [Var "x", Var "x"]))

testExpect :: Test
testExpect = test
    [ testParse expect1 expect1AST
    , testParse expect2 expect2AST
    ]

array1 :: Text
array1 = unlines
   ["array x of 12:"
   ,"   x + 1"
   ]

array1AST :: AST' Text
array1AST = Array "x" (ULiteral (Nat 12))
            (NaryOp Sum [Var "x", ULiteral (Nat 1)])

array2 :: Text
array2 = "2 + x[3][4]"

array2AST :: AST' Text
array2AST = NaryOp Sum
            [ ULiteral (Nat 2)
            , Index (Index (Var "x")
                     (ULiteral (Nat 3)))
              (ULiteral (Nat 4))
            ]

array3 :: Text
array3 = "[4, 0, 9]"

array3AST :: AST' Text
array3AST = ArrayLiteral [ ULiteral (Nat 4)
                         , ULiteral (Nat 0)
                         , ULiteral (Nat 9)
                         ]
                                   
testArray :: Test
testArray = test
    [ testParse array1 array1AST
    , testParse array2 array2AST
    , testParse array3 array3AST
    ]

easyRoad1 :: Text
easyRoad1 = unlines
    ["noiseT <~ uniform(3, 8)"
    ,"noiseE <~ uniform(1, 4)"
    ,"x1 <~ normal( 0, noiseT)"
    ,"m1 <~ normal(x1, noiseE)"
    ,"x2 <~ normal(x1, noiseT)"
    ,"m2 <~ normal(x2, noiseE)"
    ,"return ((m1, m2), (noiseT, noiseE))"
    ]

-- works in lax mode
easyRoad2 :: Text
easyRoad2 = unlines
    ["noiseT_ <~ uniform(3, 8)"
    ,"noiseE_ <~ uniform(1, 4)"
    ,"noiseT = unsafeProb(noiseT_)"
    ,"noiseE = unsafeProb(noiseE_)"
    ,"x1 <~ normal(0,  noiseT)"
    ,"m1 <~ normal(x1, noiseE)"
    ,"x2 <~ normal(x1, noiseT)"
    ,"m2 <~ normal(x2, noiseE)"
    ,"return ((m1, m2), (noiseT, noiseE)). measure(pair(pair(real,real),pair(prob,prob)))"
    ]


easyRoadAST :: AST' Text
easyRoadAST =
    Bind "noiseT" (App (App (Var "uniform")
                            (ULiteral (Nat 3)))
                            (ULiteral (Nat 8)))
    (Bind "noiseE" (App (App (Var "uniform")
                             (ULiteral (Nat 1)))
                             (ULiteral (Nat 4)))
    (Bind "x1" (App (App (Var "normal")
                         (ULiteral (Nat 0)))
                         (Var "noiseT"))
    (Bind "m1" (App (App (Var "normal")
                         (Var "x1"))
                         (Var "noiseE"))
    (Bind "x2" (App (App (Var "normal")
                         (Var "x1"))
                         (Var "noiseT"))
    (Bind "m2" (App (App (Var "normal")
                         (Var "x2"))
                         (Var "noiseE"))
    (Dirac
        (Pair
         (Pair
          (Var "m1")
          (Var "m2"))
         (Pair
          (Var "noiseT")
          (Var "noiseE")))))))))

testRoadmap :: Test
testRoadmap = test
    [ testParse easyRoad1 easyRoadAST
    ]



allTests :: Test
allTests = test
    [ testIfs
    , testLams
    , testLets
    , testBinds
    , testMatches
    , testAnn
    , testExpect
    , testArray
    , testRoadmap
    ]


