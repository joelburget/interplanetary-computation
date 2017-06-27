{-# language QuasiQuotes #-}
module Planetary.Library.Management where

decls = forceDeclarations [text|
data ExprF Expr =
  | <nat <foreignTm>>
  | <str <foreignTm>>
  | <addExpr Expr Expr>
  | <catExpr Expr Expr>

semantics = letrec
  eval : forall. {<Expr <Expr>> -> <Syntax <Syntax>>}
       = \expr -> case expr of
         Expr:
           | <nat n> -> <foreignTm n>
           | <str str> -> <foreignTm str>
           | <addExpr l r> -> <cut <apply <vector l r>> <value <foreignTm add>>
           | <catExpr l r> -> <cut <apply <vector l r>> <value <foreignTm cat>>
|]

-- TODO:
-- * define foreignTm, cut, apply, etc
-- * sub in add, cat

predefined :: UIdMap Text Cid
predefined = uIdMapFromList
  [ ("add", _)
  , ("cat", _)
  ]

resolved :: ResolvedDecls
Right resolved = nameResolution decls predefined