{-# LANGUAGE DataKinds        #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs            #-}
{-# LANGUAGE KindSignatures   #-}
{-# LANGUAGE RankNTypes       #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
module Tests.ASTTransforms (allTests) where

import           Control.Monad
import qualified Data.Number.LogFloat             as LF
import qualified Data.Vector                      as V
import           GHC.Word                         (Word32)
import           Language.Hakaru.Sample           (runEvaluate)
import           Language.Hakaru.Syntax.ABT
import           Language.Hakaru.Syntax.ANF       (normalize)
import           Language.Hakaru.Syntax.CSE       (cse)
import           Language.Hakaru.Syntax.Prune     (prune)
import           Language.Hakaru.Syntax.Hoist     (hoist)
import           Language.Hakaru.Syntax.Uniquify  (uniquify)
import           Language.Hakaru.Syntax.Unroll    (unroll)
import           Language.Hakaru.Syntax.AST
import           Language.Hakaru.Syntax.AST.Eq    (alphaEq)
import           Language.Hakaru.Syntax.Datum
import           Language.Hakaru.Syntax.DatumCase
import           Language.Hakaru.Syntax.IClasses
import           Language.Hakaru.Syntax.Prelude
import           Language.Hakaru.Syntax.Value
import           Language.Hakaru.Syntax.Variable
import           Language.Hakaru.Types.Coercion
import           Language.Hakaru.Types.DataKind
import           Language.Hakaru.Types.HClasses
import           Language.Hakaru.Types.Sing
import           Prelude                          hiding (product, (*), (+),
                                                   (-), (==))

import qualified System.Random.MWC                as MWC
import           Test.HUnit
import           Tests.Disintegrate               hiding (allTests)
import           Tests.TestTools

checkMeasure :: String
             -> Value ('HMeasure a)
             -> Value ('HMeasure a)
             -> Assertion
checkMeasure p (VMeasure m1) (VMeasure m2) = do
  -- Generate 2 copies of the same random seed so that sampling the random seeds
  -- always produce the same trace of results.
  g1 <- MWC.createSystemRandom
  s  <- MWC.save g1
  g2 <- MWC.restore s
  forM_ [1 :: Int .. 10000] $ \_ -> do
      p1 <- LF.logFloat `fmap` MWC.uniform g1
      p2 <- LF.logFloat `fmap` MWC.uniform g2
      Just (v1, w1) <- m1 (VProb p1) g1
      Just (v2, w2) <- m2 (VProb p2) g2
      assertEqual p v1 v2
      assertEqual p w1 w2

allTests :: Test
allTests = test [ TestLabel "ANF" anfTests ]

opts :: (ABT Term abt) => abt '[] a -> abt '[] a
opts = uniquify . prune . cse . hoist . uniquify . normalize

optsUnroll :: (ABT Term abt) => abt '[] a -> abt '[] a
optsUnroll = uniquify . prune . cse . normalize . unroll

anfTests :: Test
anfTests = test [ "example1" ~: testNormalizer "example1" example1 example1'
                , "example2" ~: testNormalizer "example2" example2 example2'
                , "example3" ~: testNormalizer "example3" example3 example3'

                -- Test some deterministic results
                , "runExample1" ~: testPreservesResult "example1" example1 normalize
                , "runExample2" ~: testPreservesResult "example2" example2 normalize
                , "runExample3" ~: testPreservesResult "example3" example3 normalize

                -- Test some programs which produce measures, these are
                -- statistical tests
                , "norm1a"        ~: testPreservesMeasure "norm1a" norm1a normalize
                , "norm1b"        ~: testPreservesMeasure "norm1b" norm1b normalize
                , "norm1c"        ~: testPreservesMeasure "norm1c" norm1c normalize
                , "easyRoad"      ~: testPreservesMeasure "easyRoad" easyRoad normalize
                , "helloWorld100" ~: testPreservesMeasure "helloWorld100" helloWorld100 normalize

                -- Test some deterministic results
                , "runExample1CSE" ~: testPreservesResult "example1" example1 opts
                , "runExample2CSE" ~: testPreservesResult "example2" example2 opts
                , "runExample3CSE" ~: testPreservesResult "example3" example3 opts

                , "cse1" ~: testCSE "cse1" example1CSE example1CSE'
                , "cse2" ~: testCSE "cse2" example2CSE example2CSE'
                , "cse3" ~: testCSE "cse3" example3CSE example3CSE
                , "cse4" ~: testCSE "cse4" (normalize example3CSE) example2CSE'

                -- Test some programs which produce measures, these are
                -- statistical tests
                , "norm1a all"        ~: testPreservesMeasure "norm1a" norm1a opts
                , "norm1b all"        ~: testPreservesMeasure "norm1b" norm1b opts
                , "norm1c all"        ~: testPreservesMeasure "norm1c" norm1c opts
                , "easyRoad all"      ~: testPreservesMeasure "easyRoad" easyRoad opts
                , "helloWorld100 all" ~: testPreservesMeasure "helloWorld100" helloWorld100 opts

                , "example1Hoist" ~: testPreservesResult "result" example1Hoist opts
                , "example1Hoist" ~: testTransform "transform" example1Hoist example1Hoist' opts

                , "unroll" ~: testTransform "unroll" example1Unroll example1Unroll' optsUnroll
                ]


example1 :: TrivialABT Term '[] 'HReal
example1 = if_ (real_ 1 == real_ 2)
               (real_ 2 + real_ 3)
               (real_ 3 + real_ 4)

example1' :: TrivialABT Term '[] 'HReal
example1' = let_ (real_ 1 == real_ 2) $ \v ->
            if_ v (real_ 2 + real_ 3)
                  (real_ 3 + real_ 4)

example2 :: TrivialABT Term '[] 'HNat
example2 = let_ (nat_ 1) $ \ a -> triv ((summate a (a + (nat_ 10)) (\i -> i)) +
                                        (product a (a + (nat_ 10)) (\i -> i)))

example2' :: TrivialABT Term '[] 'HNat
example2' = let_ (nat_ 1) $ \ x4 ->
            let_ (x4 + nat_ 10) $ \ x3 ->
            let_ (summate x4 x3 (\ x0 -> x0)) $ \ x2 ->
            let_ (x4 + nat_ 10) $ \ x1 ->
            let_ (product x4 x1 (\ x0 -> x0)) $ \ x0 ->
            x2 + x0

example3 :: TrivialABT Term '[] 'HReal
example3 = triv (real_ 1 * (real_ 2 + real_ 3) * (real_ 4 + (real_ 5 + (real_ 6 * real_ 7))))


example3' :: TrivialABT Term '[] 'HReal
example3' = let_ (real_ 2 + real_ 3) $ \ x2 ->
            let_ (real_ 6 * real_ 7) $ \ x1 ->
            let_ (real_ 4 + real_ 5 + x1) $ \ x0 ->
            real_ 1 * x2 * x0

testNormalizer :: (ABT Term abt) => String -> abt '[] a -> abt '[] a -> Assertion
testNormalizer name a b = testTransform name a b normalize

testTransform
  :: (ABT Term abt)
  => String
  -> abt '[] a
  -> abt '[] a
  -> (abt '[] a -> abt '[] a)
  -> Assertion
testTransform name a b opt = assertBool name (alphaEq (opt a) b)

testCSE :: (ABT Term abt) => String -> abt '[] a -> abt '[] a -> Assertion
testCSE name a b = assertBool name (alphaEq (cse a) b)

testPreservesResult
  :: forall (a :: Hakaru) abt . (ABT Term abt)
  => String
  -> abt '[] a
  -> (abt '[] a -> abt '[] a)
  -> Assertion
testPreservesResult name ast opt = assertEqual name result1 result2
  where result1 = runEvaluate ast
        result2 = runEvaluate (opt ast)

testPreservesMeasure
  :: forall (a :: Hakaru) abt . (ABT Term abt)
  => String
  -> abt '[] ('HMeasure a)
  -> (abt '[] ('HMeasure a) -> abt '[] ('HMeasure a))
  -> Assertion
testPreservesMeasure name ast opt = checkMeasure name result1 result2
  where result1 = runEvaluate ast
        result2 = runEvaluate (opt ast)

example1CSE :: TrivialABT Term '[] 'HReal
example1CSE = let_ (real_ 1 + real_ 2) $ \x ->
              let_ (real_ 1 + real_ 2) $ \y ->
              x + y

example1CSE' :: TrivialABT Term '[] 'HReal
example1CSE' = let_ (real_ 1 + real_ 2) $ \x ->
               x + x

example2CSE :: TrivialABT Term '[] 'HReal
example2CSE = let_ (summate (nat_ 0) (nat_ 1) $ \x -> real_ 1) $ \x ->
              let_ (summate (nat_ 0) (nat_ 1) $ \x -> real_ 1) $ \y ->
              x + y

example2CSE' :: TrivialABT Term '[] 'HReal
example2CSE' = let_ (summate (nat_ 0) (nat_ 1) $ \x -> real_ 1) $ \x ->
               x + x

example3CSE :: TrivialABT Term '[] 'HReal
example3CSE = (summate (nat_ 0) (nat_ 1) $ \x -> real_ 1)
            + (summate (nat_ 0) (nat_ 1) $ \x -> real_ 1)


example1Unroll :: TrivialABT Term '[] 'HInt
example1Unroll = (summate (int_ 0) (int_ 100) $ \x -> x + (int_ 1 * int_ 42))

example1Unroll' :: TrivialABT Term '[] 'HInt
example1Unroll' = let_ (int_ 0 == int_ 100) $ \cond ->
                  if_ cond (int_ 0)
                      (let_ (int_ 1 * int_ 42) $ \tmp ->
                       let_ (int_ 0 + tmp)     $ \first ->
                       let_ (int_ 0 + int_ 1)  $ \start ->
                       let_ (summate start (int_ 100) $ (+ tmp)) $ \total ->
                       first + total)

example1Hoist :: TrivialABT Term '[] 'HInt
example1Hoist = summate (int_ 0) (int_ 1) $ \_ ->
                summate (int_ 1) (int_ 2) id

example1Hoist' :: TrivialABT Term '[] 'HInt
example1Hoist' = let_ (summate (int_ 1) (int_ 2) id) $ \x ->
                 summate (int_ 0) (int_ 1) (const x)

