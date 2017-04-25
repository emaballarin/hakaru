{-# LANGUAGE CPP
           , GADTs
           , DataKinds
           , TypeFamilies
           , FlexibleContexts
           , UndecidableInstances
           , LambdaCase
           , OverloadedStrings
           , Rank2Types
           #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs -fsimpl-tick-factor=1000 #-}
module Language.Hakaru.Runtime.Prelude where

#if __GLASGOW_HASKELL__ < 710
import           Data.Functor                    ((<$>))
import           Control.Applicative             (Applicative(..))
#endif
import           Data.Foldable                   as F
import qualified System.Random.MWC               as MWC
import qualified System.Random.MWC.Distributions as MWCD
import           Data.Number.Natural
import           Data.STRef
import qualified Data.Vector                     as V
import qualified Data.Vector.Unboxed             as U
import qualified Data.Vector.Generic             as G
import           Control.Monad
import           Control.Monad.ST
import           Prelude                         hiding (product, init)

type family MinBoxVec (v1 :: * -> *) (v2 :: * -> *) :: * -> *
type instance MinBoxVec V.Vector v        = V.Vector
type instance MinBoxVec v        V.Vector = V.Vector
type instance MinBoxVec U.Vector U.Vector = U.Vector

type family MayBoxVec a :: * -> *
type instance MayBoxVec ()           = U.Vector
type instance MayBoxVec Int          = U.Vector
type instance MayBoxVec Double       = U.Vector
type instance MayBoxVec Bool         = U.Vector
type instance MayBoxVec (U.Vector a) = V.Vector
type instance MayBoxVec (V.Vector a) = V.Vector
type instance MayBoxVec (a,b)        = MinBoxVec (MayBoxVec a) (MayBoxVec b)

lam :: (a -> b) -> a -> b
lam = id
{-# INLINE lam #-}

app :: (a -> b) -> a -> b
app f x = f x
{-# INLINE app #-}

let_ :: a -> (a -> b) -> b
let_ x f = let x1 = x in f x1
{-# INLINE let_ #-}

ann_ :: a -> b -> b
ann_ _ a = a
{-# INLINE ann_ #-}

newtype Measure a = Measure { unMeasure :: MWC.GenIO -> IO (Maybe a) }

instance Functor Measure where
    fmap  = liftM
    {-# INLINE fmap #-}

instance Applicative Measure where
    pure x = Measure $ \_ -> return (Just x)
    {-# INLINE pure #-}
    (<*>)  = ap
    {-# INLINE (<*>) #-}

instance Monad Measure where
    return  = pure
    {-# INLINE return #-}
    m >>= f = Measure $ \g -> do
                          Just x <- unMeasure m g
                          unMeasure (f x) g
    {-# INLINE (>>=) #-}

makeMeasure :: (MWC.GenIO -> IO a) -> Measure a
makeMeasure f = Measure $ \g -> Just <$> f g
{-# INLINE makeMeasure #-}

uniform :: Double -> Double -> Measure Double
uniform lo hi = makeMeasure $ MWC.uniformR (lo, hi)
{-# INLINE uniform #-}

normal :: Double -> Double -> Measure Double
normal mu sd = makeMeasure $ MWCD.normal mu sd
{-# INLINE normal #-}

beta :: Double -> Double -> Measure Double
beta a b = makeMeasure $ MWCD.beta a b
{-# INLINE beta #-}

gamma :: Double -> Double -> Measure Double
gamma a b = makeMeasure $ MWCD.gamma a b
{-# INLINE gamma #-}

categorical :: MayBoxVec Double Double -> Measure Int
categorical a = makeMeasure (\g -> fromIntegral <$> MWCD.categorical a g)
{-# INLINE categorical #-}

plate :: (G.Vector (MayBoxVec a) a) =>
         Int -> (Int -> Measure a) -> Measure (MayBoxVec a a)
plate n f = G.generateM (fromIntegral n) $ \x ->
             f (fromIntegral x)
{-# INLINE plate #-}

bucket :: Int -> Int -> (forall s. Reducer () s a) -> a
bucket b e r = runST
             $ case r of Reducer{init=initR,accum=accumR,done=doneR} -> do
                          s' <- initR ()
                          F.mapM_ (\i -> accumR () i s') [b .. e - 1]
                          doneR s'
{-# INLINE bucket #-}

data Reducer xs s a =
    forall cell.
    Reducer { init  :: xs -> ST s cell
            , accum :: xs -> Int -> cell -> ST s ()
            , done  :: cell -> ST s a
            }

r_fanout :: Reducer xs s a
         -> Reducer xs s b
         -> Reducer xs s (a,b)
r_fanout Reducer{init=initA,accum=accumA,done=doneA}
         Reducer{init=initB,accum=accumB,done=doneB} = Reducer
   { init  = \xs       -> liftM2 (,) (initA xs) (initB xs)
   , accum = \bs i (s1, s2) ->
             accumA bs i s1 >> accumB bs i s2
   , done  = \(s1, s2) -> liftM2 (,) (doneA s1) (doneB s2)
   }
{-# INLINE r_fanout #-}

r_index :: (G.Vector (MayBoxVec a) a)
        => (xs -> Int)
        -> ((Int, xs) -> Int)
        -> Reducer (Int, xs) s a
        -> Reducer xs s (MayBoxVec a a)
r_index n f Reducer{init=initR,accum=accumR,done=doneR} = Reducer
   { init  = \xs -> V.generateM (n xs) (\b -> initR (b, xs))
   , accum = \bs i v ->
             let ov = f (i, bs) in
             accumR (ov,bs) i (v V.! ov)
   , done  = \v -> fmap G.convert (V.mapM doneR v)
   }
{-# INLINE r_index #-}

r_split :: ((Int, xs) -> Bool)
        -> Reducer xs s a
        -> Reducer xs s b
        -> Reducer xs s (a,b)
r_split b Reducer{init=initA,accum=accumA,done=doneA}
          Reducer{init=initB,accum=accumB,done=doneB} = Reducer
   { init  = \xs -> liftM2 (,) (initA xs) (initB xs)
   , accum = \bs i (s1, s2) ->
             if (b (i,bs)) then accumA bs i s1 else accumB bs i s2
   , done  = \(s1, s2) -> liftM2 (,) (doneA s1) (doneB s2)
   }
{-# INLINE r_split #-}

r_add :: Num a => ((Int, xs) -> a) -> Reducer xs s a
r_add e = Reducer
   { init  = \_ -> newSTRef 0
   , accum = \bs i s ->
             modifySTRef' s (+ (e (i,bs)))
   , done  = readSTRef
   }
{-# INLINE r_add #-}

r_nop :: Reducer xs s ()
r_nop = Reducer
   { init  = \_ -> return ()
   , accum = \_ _ _ -> return ()
   , done  = \_ -> return ()
   }
{-# INLINE r_nop #-}

pair :: a -> b -> (a, b)
pair = (,)
{-# INLINE pair #-}

true, false :: Bool
true  = True
false = False

nothing :: Maybe a
nothing = Nothing

just :: a -> Maybe a
just = Just

left :: a -> Either a b
left = Left

right :: b -> Either a b
right = Right

unit :: ()
unit = ()

data Pattern = PVar | PWild
newtype Branch a b =
    Branch { extract :: a -> Maybe b }

ptrue, pfalse :: a -> Branch Bool a
ptrue  b = Branch { extract = extractBool True  b }
pfalse b = Branch { extract = extractBool False b }
{-# INLINE ptrue  #-}
{-# INLINE pfalse #-}

extractBool :: Bool -> a -> Bool -> Maybe a
extractBool b a p | p == b     = Just a
                  | otherwise  = Nothing
{-# INLINE extractBool #-}


pnothing :: b -> Branch (Maybe a) b
pnothing b = Branch { extract = \ma -> case ma of
                                         Nothing -> Just b
                                         Just _  -> Nothing }

pjust :: Pattern -> (a -> b) -> Branch (Maybe a) b
pjust PVar c = Branch { extract = \ma -> case ma of
                                           Nothing -> Nothing
                                           Just x  -> Just (c x) }
pjust _ _ = error "TODO: Runtime.Prelude{pjust}"

pleft :: Pattern -> (a -> c) -> Branch (Either a b) c
pleft PVar f = Branch { extract = \ma -> case ma of
                                           Right _ -> Nothing
                                           Left x -> Just (f x) }
pleft _ _ = error "TODO: Runtime.Prelude{pLeft}"

pright :: Pattern -> (b -> c) -> Branch (Either a b) c
pright PVar f = Branch { extract = \ma -> case ma of
                                            Left _ -> Nothing
                                            Right x -> Just (f x) }
pright _ _ = error "TODO: Runtime.Prelude{pRight}"


ppair :: Pattern -> Pattern -> (x -> y -> b) -> Branch (x,y) b
ppair PVar  PVar c = Branch { extract = (\(x,y) -> Just (c x y)) }
ppair _     _    _ = error "ppair: TODO"

uncase_ :: Maybe a -> a
uncase_ (Just a) = a
uncase_ Nothing  = error "case_: unable to match any branches"
{-# INLINE uncase_ #-}

case_ :: a -> [Branch a b] -> b
case_ e [c1]     = uncase_ (extract c1 e)
case_ e [c1, c2] = uncase_ (extract c1 e `mplus` extract c2 e)
case_ e bs_      = go bs_
  where go []     = error "case_: unable to match any branches"
        go (b:bs) = case extract b e of
                      Just b' -> b'
                      Nothing -> go bs
{-# INLINE case_ #-}

branch :: (c -> Branch a b) -> c -> Branch a b
branch pat body = pat body
{-# INLINE branch #-}

dirac :: a -> Measure a
dirac = return
{-# INLINE dirac #-}

pose :: Double -> Measure a -> Measure a
pose _ a = a
{-# INLINE pose #-}

superpose :: [(Double, Measure a)]
          -> Measure a
superpose pms = do
  i <- makeMeasure $ MWCD.categorical (U.fromList $ map fst pms)
  snd (pms !! i)
{-# INLINE superpose #-}

reject :: Measure a
reject = Measure $ \_ -> return Nothing

nat_ :: Int -> Int
nat_ = id

int_ :: Int -> Int
int_ = id

unsafeNat :: Int -> Int
unsafeNat = id

nat2prob :: Int -> Double
nat2prob = fromIntegral

fromInt  :: Int -> Double
fromInt  = fromIntegral

nat2int  :: Int -> Int
nat2int  = id

nat2real :: Int -> Double
nat2real = fromIntegral

fromProb :: Double -> Double
fromProb = id

unsafeProb :: Double -> Double
unsafeProb = id

real_ :: Rational -> Double
real_ = fromRational

prob_ :: NonNegativeRational -> Double
prob_ = fromRational . fromNonNegativeRational

infinity :: Double
infinity = 1/0

abs_ :: Num a => a -> a
abs_ = abs

thRootOf :: Int -> Double -> Double
thRootOf a b = b ** (recip $ fromIntegral a)
{-# INLINE thRootOf #-}

array
    :: (G.Vector (MayBoxVec a) a)
    => Int
    -> (Int -> a)
    -> MayBoxVec a a
array n f = G.generate (fromIntegral n) (f . fromIntegral)
{-# INLINE array #-}

arrayLit :: (G.Vector (MayBoxVec a) a) => [a] -> MayBoxVec a a
arrayLit = G.fromList
{-# INLINE arrayLit #-}

(!) :: (G.Vector (MayBoxVec a) a) => MayBoxVec a a -> Int -> a
a ! b = a G.! (fromIntegral b)
{-# INLINE (!) #-}

size :: (G.Vector (MayBoxVec a) a) => MayBoxVec a a -> Int
size v = fromIntegral (G.length v)
{-# INLINE size #-}

reduce
    :: (G.Vector (MayBoxVec a) a)
    => (a -> a -> a)
    -> a
    -> MayBoxVec a a
    -> a
reduce f n v = G.foldr f n v
{-# INLINE reduce #-}

product
    :: Num a
    => Int
    -> Int
    -> (Int -> a)
    -> a
product a b f = F.foldl' (\x y -> x * f y) 1 [a .. b-1]
{-# INLINE product #-}

summate
    :: Num a
    => Int
    -> Int
    -> (Int -> a)
    -> a
summate a b f = F.foldl' (\x y -> x + f y) 0 [a .. b-1]
{-# INLINE summate #-}

run :: Show a
    => MWC.GenIO
    -> Measure a
    -> IO ()
run g k = unMeasure k g >>= \case
           Just a  -> print a
           Nothing -> return ()

iterateM_
    :: Monad m
    => (a -> m a)
    -> a
    -> m b
iterateM_ f = g
    where g x = f x >>= g

withPrint :: Show a => (a -> IO b) -> a -> IO b
withPrint f x = print x >> f x
