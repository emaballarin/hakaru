{-# LANGUAGE CPP, OverloadedStrings, DataKinds, GADTs #-}

module Main where

import           Language.Hakaru.Pretty.Concrete  
import           Language.Hakaru.Syntax.AST.Transforms
import           Language.Hakaru.Syntax.TypeCheck
import           Language.Hakaru.Command (parseAndInfer, readFromFile, Term)

import           Language.Hakaru.Simplify

#if __GLASGOW_HASKELL__ < 710
import           Control.Applicative   (Applicative(..), (<$>))
#endif

import           Data.Monoid
import           Data.Text
import qualified Data.Text.IO as IO
import           System.IO (stderr)

import qualified Options.Applicative as O

data Options = Options
  { debug     :: Bool
  , timelimit :: Int
  , program   :: String }

options :: O.Parser Options
options = Options
  <$> O.switch
      ( O.long "debug" <>
        O.help "Prints output that is sent to Maple" )
  <*> O.option O.auto
      ( O.long "timelimit" <>
        O.help "Set simplify to timeout in N seconds" <>
        O.showDefault <>
        O.value 90 <>
        O.metavar "N")
  <*> O.strArgument
      ( O.metavar "PROGRAM" <> 
        O.help "Program to be simplified" )

parseOpts :: IO Options
parseOpts = O.execParser $ O.info (O.helper <*> options)
      (O.fullDesc <> O.progDesc "Simplify a hakaru program")

et :: Term a -> Term a
et = expandTransformations

main :: IO ()
main = do
  args <- parseOpts
  case args of
   Options debug_ timelimit file -> do
    prog <- readFromFile file
    runSimplify prog debug_ timelimit

runSimplify :: Text -> Bool -> Int -> IO ()
runSimplify prog debug_ timelimit =
    case parseAndInfer prog of
    Left  err              -> IO.hPutStrLn stderr err
    Right (TypedAST _ ast) -> do ast' <- simplifyDebug debug_ timelimit (et ast)
                                 print (pretty ast')

