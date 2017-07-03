{-# language DataKinds #-}
{-# language OverloadedStrings #-}
{-# language QuasiQuotes #-}
{-# language TypeApplications #-}
module Planetary.Core.Eval.Test (unitTests, runEvalTests, stepTest) where

import Prelude hiding (not)
import NeatInterpolation
import Network.IPLD as IPLD
import Test.Tasty
import Test.Tasty.HUnit

import Planetary.Core
import Planetary.Support.Ids
import Planetary.Support.NameResolution (resolveTm)
import Planetary.Support.Parser (forceTm)
import Planetary.Library.HaskellForeign (mkForeignTm, mkForeign)

stepTest
  :: String
  -> EvalEnv
  -> Int
  -> TmI
  -> Either Err TmI
  -> TestTree
stepTest name env steps tm expected =
  let applications = iterate (step =<<) (pure tm)
      actual = applications !! steps

  in testCase name $ do
    result <- runEvalM env [] actual

    fst result @?= expected

runTest
  :: String
  -> EvalEnv
  -> TmI
  -> Either Err TmI
  -> TestTree
runTest name env tm expected = testCase name $ do
  result <- run env [] tm
  fst result @?= expected

bool :: Int -> Tm Cid
bool i = DataTm boolId i []

unitTests :: TestTree
unitTests  =
  let emptyEnv :: EvalEnv
      emptyEnv = EvalEnv mempty mempty

      -- true, false :: forall a b. Tm Cid a b
      false = bool 0
      true = bool 1

      not = Case boolId
        [ ([], true)
        , ([], false)
        ]
      -- boolOfInt = Case boolId
      --   [ ([], one)
      --   , ([], zero)
      --   ]

  in testGroup "evaluation"
       [ testGroup "functions"
         [ let x = BV 0
               -- tm = forceTm "(\y -> y) x"
               lam = Lam ["X"] x
               tm = Cut (Application [x]) (Value lam)
           in stepTest "application 1" emptyEnv 1 tm (Right x)
         ]
       , testGroup "case"
           [ stepTest "case False of { False -> True; True -> False }"
               emptyEnv 1
             -- [tmExp|
             --   case false of
             --     boolId:
             --       | -> one
             --       | -> zero
             -- |]
             -- [ ("false", false)
             -- , ("bool", bool)
             -- , ("one", one)
             -- , ("zero", zero)
             -- ]
             (Cut not false)
             (Right true)
           , stepTest "case True of { False -> True; True -> False }"
               emptyEnv 1
             (Cut not true)
             (Right false)

         , stepTest "not false" emptyEnv 1
           (Cut not false)
           (Right true)
           ]
       , let ty :: Polytype Cid
             ty = Polytype [] (DataTy boolId [])
             -- TODO: remove shadowing
             Just tm = closeVar ("x", 0) $ let_ "x" ty false (FV"x")
         in stepTest "let x = false in x" emptyEnv 1 tm (Right false)

       , let handler = forceTm [text|
               handle x : [e , <Abort>]HaskellInt with
                 Abort:
                   | <aborting -> k> -> one
                 | v -> two
             |]

             zero = mkForeignTm @Int intId [] 0
             one  = mkForeignTm @Int intId [] 1
             two  = mkForeignTm @Int intId [] 2

             Right handler' = resolveTm mempty handler
             handler'' = substitute "one" one $
               substitute "two" two
                 handler'

             handleVal = substitute "x" zero handler''
         in testGroup "handle"
              [ runTest "handle val" emptyEnv handleVal (Right two)
              ]

       , let
             ty = Polytype [] (DataTy boolId [])
             -- Just tm = cast [tmExp|
             --   let x: forall. bool = false in
             --     let y: forall. bool = not x in
             --       not y
             -- |]
             Just tm = closeVar ("x", 0) $
                  let_ "x" ty false $
                    let_ "y" ty (Cut not (FV"x")) $
                      Cut not (FV"y")
         in stepTest "let x = false in let y = not x in not y"
              emptyEnv 3 tm (Right false)

       -- , let
       --   in stepTest ""
       ]

runEvalTests :: IO ()
runEvalTests = defaultMain unitTests
