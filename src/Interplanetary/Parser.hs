{-# language PackageImports #-}
{-# language ConstraintKinds #-}
{-# language DataKinds #-}
{-# language GeneralizedNewtypeDeriving #-}
{-# language FlexibleInstances #-}
{-# language StandaloneDeriving #-}
{-# language TupleSections #-}
-- A simple Core Frank parser based on the frankjnr implementation
module Interplanetary.Parser where

import Control.Applicative
import Control.Lens (unsnoc)
import Data.Functor (($>))

import Text.Trifecta
import "indentation-trifecta" Text.Trifecta.Indentation

import Data.Char

import Text.Parser.Token as Tok
import Text.Parser.Token.Style
import qualified Text.Parser.Token.Highlight as Hi
import qualified Data.HashSet as HashSet
import Bound

import Interplanetary.Syntax
import Interplanetary.Util

type Tm' = Tm String String
type Construction = Tm'
type Use = Tm'
type Cont' = Continuation String String
type Value' = Value String String

newtype CoreParser t m a =
  CoreParser { runCoreParser :: IndentationParserT t m a }
  deriving (Functor, Alternative, Applicative, Monad, Parsing
           , IndentationParsing)

deriving instance (DeltaParsing m) => (CharParsing (CoreParser Char m))
deriving instance (DeltaParsing m) => (CharParsing (CoreParser Token m))
deriving instance (DeltaParsing m) => (TokenParsing (CoreParser Char m))

instance DeltaParsing m => TokenParsing (CoreParser Token m) where
  someSpace = CoreParser $ buildSomeSpaceParser someSpace haskellCommentStyle
  nesting = CoreParser . nesting . runCoreParser
  semi = CoreParser $ runCoreParser semi
  highlight h = CoreParser . highlight h . runCoreParser
  token p = (CoreParser $ token (runCoreParser p)) <* whiteSpace

type MonadicParsing m = (TokenParsing m, IndentationParsing m, Monad m)

frankensteinStyle :: MonadicParsing m => IdentifierStyle m
frankensteinStyle = IdentifierStyle {
    _styleName = "Frankenstein"
  , _styleStart = satisfy (\c -> isAlpha c || c == '_')
  , _styleLetter = satisfy (\c -> isAlphaNum c || c == '_' || c == '\'')
  , _styleReserved = HashSet.fromList
    [ "data"
    , "interface"
    , "let"
    , "letrec"
    , "in"
    , "forall"
    , "case"
    , "handle"
    , "of"
    , "with"
    ]
  , _styleHighlight = Hi.Identifier
  , _styleReservedHighlight = Hi.ReservedIdentifier }

arr, bar, assign, bang :: MonadicParsing m => m String
arr = symbol "->"
bar = symbol "|"
assign = symbol "="
bang = symbol "!"

reserved :: MonadicParsing m => String -> m ()
reserved = Tok.reserve frankensteinStyle

identifier :: MonadicParsing m => m String
identifier = Tok.ident frankensteinStyle
  <?> "identifier"

parseUid :: MonadicParsing m => m UId
parseUid = mkUid <$> natural
  <?> "uid"

parseValTy :: MonadicParsing m => m (ValTy String)
parseValTy = try parseDataTy <|> parseValTy'
  <?> "Val Ty"

parseValTy' :: MonadicParsing m => m (ValTy String)
parseValTy' = parens parseValTy
          <|> SuspendedTy <$> braces parseCompTy
          <|> VariableTy <$> identifier
          <?> "Val Ty (not data)"

parseTyArg :: MonadicParsing m => m (TyArg String)
parseTyArg = TyArgVal <$> parseValTy'
         <|> TyArgAbility <$> brackets (convAbility =<< parseAbilityBody)
         <?> "Ty Arg"

parseConstructors :: MonadicParsing m => m (Vector (ConstructorDecl String))
parseConstructors = sepBy parseConstructor bar <?> "Constructors"

parseConstructor :: MonadicParsing m => m (ConstructorDecl String)
parseConstructor = ConstructorDecl <$> many parseValTy' <?> "Constructor"

-- Parse a potential datatype. Note it may actually be a type variable.
parseDataTy :: MonadicParsing m => m (ValTy String)
parseDataTy = DataTy
  <$> parseUid
  <*> localIndentation Gt (many parseTyArg)
  <?> "Data Ty"

parseTyVar :: MonadicParsing m => m (String, Kind)
parseTyVar = (,EffTy) <$> brackets parseEffectVar
         <|> (,ValTy) <$> identifier
         <?> "Ty Var"

parseEffectVar :: MonadicParsing m => m String
parseEffectVar = do
  mx <- optional identifier
  return $ case mx of
    Nothing -> "0"
    Just x -> x

-- 0 | 0|Interfaces | E|Interfaces | Interfaces
-- TODO: change to comma?
-- TODO: allow explicit e? `[e]`
parseAbilityBody :: MonadicParsing m => m (Ability String)
parseAbilityBody =
  let closedAb = do
        _ <- symbol "0"
        instances <- option [] (bar *> parseInterfaceInstances)
        return $ Ability ClosedAbility (uIdMapFromList instances)
      varAb = do
        e <- option "e" (try $ identifier <* bar)
        instances <- parseInterfaceInstances
        return $ Ability OpenAbility (uIdMapFromList instances)
  in try closedAb <|> varAb <?> "Ability Body"

parseAbility :: MonadicParsing m => m (Ability String)
parseAbility = do
  mxs <- optional $ brackets parseAbilityBody
  return $ maybe emptyAbility id mxs

convAbility :: MonadicParsing m => Ability String -> m (Ability Int)
convAbility ab = case closed ab of
  Nothing -> empty
  Just ab' -> pure ab'

parsePeg :: MonadicParsing m => m (Peg String)
parsePeg = Peg <$> (convAbility =<< parseAbility) <*> parseValTy <?> "Peg"

parseCompTy :: MonadicParsing m => m (CompTy String)
parseCompTy = CompTy
  <$> many (try (parseValTy <* arr))
  <*> parsePeg
  <?> "Comp Ty"

parseInterfaceInstance :: MonadicParsing m => m (UId, [TyArg String])
parseInterfaceInstance = (,) <$> parseUid <*> many parseTyArg
  <?> "Interface Instance"

parseInterfaceInstances :: MonadicParsing m => m [(UId, [TyArg String])]
parseInterfaceInstances = sepBy parseInterfaceInstance comma
  <?> "Interface Instances"

parseDataDecl :: MonadicParsing m => m (DataTypeInterface String)
parseDataDecl = do
  reserved "data"
  tyArgs <- many parseTyVar
  _ <- assign
  ctrs <- localIndentation Gt parseConstructors
  return $ DataTypeInterface tyArgs ctrs

-- only value arguments and result type
parseCommandType :: MonadicParsing m => m (Vector (ValTy String), ValTy String)
parseCommandType = do
  vs <- sepBy1 parseValTy arr
  maybe empty pure (unsnoc vs)
  -- maybe empty pure . unsnoc =<< sepBy1 parseValTy arr

parseCommandDecl :: MonadicParsing m => m (CommandDeclaration String)
parseCommandDecl = uncurry CommandDeclaration <$> parseCommandType
  <?> "Command Decl"

parseInterface :: MonadicParsing m => m (EffectInterface String)
parseInterface = do
  reserved "interface"
  tyVars <- many parseTyVar
  _ <- assign
  -- inBoundTys
  xs <- localIndentation Gt $ sepBy1 parseCommandDecl bar
  return (EffectInterface tyVars xs)

parseApplication :: MonadicParsing m => m Use
parseApplication =
  let parser = do
        fun <- (Variable <$> identifier) -- TODO: not sure this line is right
        spine <- choice [some parseUseNoAp, bang $> []]
        pure $ Cut (Application spine) fun
  in parser <?> "Application"

parseValue :: MonadicParsing m => m Value'
parseValue = choice
  -- [ parseDataConstructor
  -- parseCommand
  [ parseLambda
  ]

parseConstruction :: MonadicParsing m => m Construction
parseConstruction = choice
  [ parseLet
  -- , parseLetRec
  , parseUse
  ] <?> "Construction"

-- To avoid recurring back into an ap:
-- good: f f f -> f [f, f]
-- bad: f f f -> (f (f f))
parseUseNoAp :: MonadicParsing m => m Use
parseUseNoAp = choice
  [ Variable <$> identifier
  ] <?> "Use (no ap)"

parseCase :: MonadicParsing m => m Tm'
parseCase = do
  _ <- reserved "case"
  m <- parseTm
  _ <- reserved "of"
  (uid, branches) <- localIndentation Gt $ do
    uid <- parseUid
    branches <- localIndentation Gt $ many $ absoluteIndentation $ do
      _ <- bar
      vars <- many identifier
      _ <- arr
      rhs <- parseTm
      pure (vars, rhs)
    pure (uid, branches)
  pure $ Cut (case_ uid branches) m

parseHandle :: MonadicParsing m => m Tm'
parseHandle = do
  _ <- reserved "handle"
  adj <- parseAdjustment
  peg <- parsePeg
  tm <- parseTm
  _ <- reserved "with"
  (handlers, fallthrough) <- localIndentation Gt $ do
    -- parse handlers
    -- TODO: many vs some?
    handlers <- many $ absoluteIndentation $ do
      uid <- parseUid
      _ <- colon

      rows <- localIndentation Gt $ many $ absoluteIndentation $ do
        _ <- bar
        vars <- many identifier
        _ <- arr
        kVar <- arr
        _ <- arr
        rhs <- parseTm
        pure $ (vars, kVar, rhs)

      pure (uid, rows)

    -- and fallthrough
    fallthrough <- localIndentation Eq $ do
      var <- identifier
      _ <- arr
      rhs <- parseTm
      pure (var, rhs)

    pure (uIdMapFromList handlers, fallthrough)

  let cont = handle adj peg handlers fallthrough
  pure (Cut cont tm)

parseTm :: MonadicParsing m => m Tm'
parseTm = (do
  tms <- some parseTmNoApp
  case tms of
    [] -> empty
    [tm] -> pure tm
    tm:spine -> pure (Cut (Application spine) tm)
  ) <?> "Tm"

parseTmNoApp :: MonadicParsing m => m Tm'
parseTmNoApp
  = parens parseTm
  <|> Value <$> parseValue
  <|> parseCase
  <|> parseHandle
  -- <|> parseLet
  <?> "Tm (no app)"

parseAdjustment :: MonadicParsing m => m (Adjustment String)
parseAdjustment = todo "parseAdjustment"

-- parseContinuation

parseUse :: MonadicParsing m => m Use
parseUse = choice [ try parseApplication, parseUseNoAp ]
  <?> "Use"

parseLambda :: MonadicParsing m => m Value'
parseLambda = lam
  <$> (symbol "\\" *> some identifier) <*> (arr *> parseConstruction)
  <?> "Lambda"

parsePolyty :: MonadicParsing m => m (Polytype String)
parsePolyty = do
  reserved "forall"
  args <- many parseTyVar
  _ <- dot
  result <- parseValTy
  pure (polytype args result)

parseLet :: MonadicParsing m => m Construction
parseLet =
  let parser = do
        reserved "let"
        name <- identifier
        _ <- colon
        ty <- parsePolyty
        _ <- assign
        rhs <- parseValue
        reserved "in"
        body <- parseConstruction
        let body' = abstract1 name body
        return $ Cut (Let ty body') (Value rhs)
  in parser <?> "Let"

-- reorgTuple :: (a, b, c) -> (a, (c, b))
-- reorgTuple (a, b, c) = (a, (c, b))

-- parseLetRec :: MonadicParsing m => m Construction
-- parseLetRec =
--   let parser = do
--         reserved "letrec"
--         definitions <- some $ (,,)
--           <$> identifier <* colon
--           <*> parsePolyty <* assign
--           <*> parseLambda
--         reserved "in"
--         body <- parseConstruction
--         let (names, binderVals) = unzip (reorgTuple <$> definitions)
--         return $ letrec names binderVals body
--   in parser <?> "Letrec"

parseDecl :: MonadicParsing m => m (Construction, ValTy String)
parseDecl =
  let parser = do
        -- name <- identifier
        _ <- colon
        ty <- parseValTy -- differs from source `parseSigType`
        construction <- localIndentation Gt $ do
          _ <- assign
          parseConstruction
        pure (construction, ty)
  in parser <?> "declaration"

evalCharIndentationParserT
  :: Monad m => CoreParser Char m a -> IndentationState -> m a
evalCharIndentationParserT = evalIndentationParserT . runCoreParser

evalTokenIndentationParserT
  :: Monad m => CoreParser Token m a -> IndentationState -> m a
evalTokenIndentationParserT = evalIndentationParserT . runCoreParser

runParse
  :: (t -> IndentationState -> Parser b) -> t -> String -> Either String b
runParse ev p input
 = let indA = ev p $ mkIndentationState 0 infIndentation True Ge
   in case parseString indA mempty input of
    Failure (ErrInfo errDoc _deltas) -> Left (show errDoc)
    Success t -> Right t

--runCharParse = runParse evalCharIndentationParserT
runTokenParse :: CoreParser Token Parser b -> String -> Either String b
runTokenParse p = runParse evalTokenIndentationParserT p
