{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Dekking.SourceAdapter (adaptLocatedHsModule, unitToString) where

import Control.Monad.Reader
import Control.Monad.Writer.Strict
import qualified Data.Set as S
import qualified Data.Text as T
import Dekking.Coverable
import GHC hiding (moduleName)
import GHC.Data.Bag
import GHC.Driver.Types as GHC
import GHC.Plugins as GHC

addExpression :: Coverable Expression -> AdaptM ()
addExpression e = tell (mempty {moduleCoverablesExpressions = S.singleton e})

type AdaptM = WriterT ModuleCoverables (ReaderT GHC.Module Hsc)

adapterImport :: LImportDecl GhcPs
adapterImport = noLoc (simpleImportDecl adapterModuleName)

adapterModuleName :: GHC.ModuleName
adapterModuleName = mkModuleName "Dekking.ValueLevelAdapter"

adaptLocatedHsModule :: Located HsModule -> AdaptM (Located HsModule)
adaptLocatedHsModule = liftL adaptHsModule

adaptHsModule :: HsModule -> AdaptM HsModule
adaptHsModule m = do
  moduule <- ask
  liftIO $ putStrLn $ "Adapting module: " ++ moduleNameString (moduleName moduule)
  decls' <- mapM adaptLDecl (hsmodDecls m)
  pure (m {hsmodDecls = decls', hsmodImports = adapterImport : hsmodImports m})

adaptLDecl :: Located (HsDecl GhcPs) -> AdaptM (Located (HsDecl GhcPs))
adaptLDecl = liftL $ \case
  ValD x bind -> ValD x <$> adaptBind bind
  -- TODO
  d -> pure d

adaptLBind :: LHsBind GhcPs -> AdaptM (LHsBind GhcPs)
adaptLBind = liftL adaptBind

adaptBind :: HsBind GhcPs -> AdaptM (HsBind GhcPs)
adaptBind = \case
  FunBind x name matchGroup ticks -> FunBind x name <$> adaptMatchGroup matchGroup <*> pure ticks
  -- TODO
  b -> pure b

adaptMatchGroup :: MatchGroup GhcPs (LHsExpr GhcPs) -> AdaptM (MatchGroup GhcPs (LHsExpr GhcPs))
adaptMatchGroup = \case
  MG x as origin -> MG x <$> liftL (mapM adaptLMatch) as <*> pure origin

adaptLMatch :: LMatch GhcPs (LHsExpr GhcPs) -> AdaptM (LMatch GhcPs (LHsExpr GhcPs))
adaptLMatch = liftL adaptMatch

adaptMatch :: Match GhcPs (LHsExpr GhcPs) -> AdaptM (Match GhcPs (LHsExpr GhcPs))
adaptMatch = \case
  Match x ctx pats body -> Match x ctx pats <$> adaptGRHSs body

adaptGRHSs :: GRHSs GhcPs (LHsExpr GhcPs) -> AdaptM (GRHSs GhcPs (LHsExpr GhcPs))
adaptGRHSs = \case
  GRHSs x rhs localBinds -> GRHSs x <$> mapM adaptLGRHS rhs <*> adaptLocalBinds localBinds

adaptLGRHS ::
  LGRHS GhcPs (LHsExpr GhcPs) ->
  AdaptM (LGRHS GhcPs (LHsExpr GhcPs))
adaptLGRHS = liftL adaptGRHS

adaptGRHS :: GRHS GhcPs (LHsExpr GhcPs) -> AdaptM (GRHS GhcPs (LHsExpr GhcPs))
adaptGRHS = \case
  GRHS x guards body -> GRHS x guards <$> adaptLExpr body

adaptLocalBinds :: LHsLocalBinds GhcPs -> AdaptM (LHsLocalBinds GhcPs)
adaptLocalBinds = liftL $ \case
  HsValBinds x valBinds -> HsValBinds x <$> adaptValBinds valBinds
  lbs -> pure lbs

adaptValBinds :: HsValBinds GhcPs -> AdaptM (HsValBinds GhcPs)
adaptValBinds = \case
  ValBinds x binds sigs -> ValBinds x <$> mapBagM adaptLBind binds <*> pure sigs
  XValBindsLR (NValBinds binds sigs) ->
    XValBindsLR
      <$> ( NValBinds
              <$> mapM
                ( \(f, s) ->
                    (,) f <$> mapBagM adaptLBind s
                )
                binds
              <*> pure sigs
          )

--   -- TODO
--   HsValBinds x ->
--   lbs -> pure lbs

adaptLExpr :: LHsExpr GhcPs -> AdaptM (LHsExpr GhcPs)
adaptLExpr (L sp e) = fmap (L sp) $ do
  let applyAdapter mName = case spanLocation sp of
        Just loc -> do
          addExpression
            Coverable
              { coverableValue = Expression {expressionIdentifier = mName},
                coverableLocation = loc
              }
          applyAdapterExpr loc e
        Nothing -> pure e

  -- We cannot use uniplate's method of transforming the code, because it would
  -- replace the middle part of infix operations by an expression that contains
  -- multiple pieces, and GHC (correctly) assumes that that is not possible.
  -- So we have to use the manual traversal.
  case e of
    HsVar _ (L _ rdr) -> applyAdapter $ Just $ occNameString $ rdrNameOcc rdr
    HsUnboundVar x on -> pure $ HsUnboundVar x on
    HsConLikeOut x cl -> pure $ HsConLikeOut x cl
    HsRecFld x afo -> pure $ HsRecFld x afo
    HsOverLabel x mid fs -> pure $ HsOverLabel x mid fs
    HsIPVar x iv -> pure $ HsIPVar x iv
    HsOverLit {} -> applyAdapter Nothing
    HsLit {} -> applyAdapter Nothing
    HsLam x mg -> HsLam x <$> adaptMatchGroup mg
    HsLamCase x mg -> HsLamCase x <$> adaptMatchGroup mg
    HsApp x left right -> HsApp x <$> adaptLExpr left <*> adaptLExpr right
    -- TODO: Things inside a visible type application might be covered more
    -- granularly but this is quite good in the meantime.
    HsAppType {} -> applyAdapter Nothing
    OpApp x left middle right ->
      OpApp x
        <$> adaptLExpr left
        -- We cannot transform the middle part of an infix operator expression
        -- because then it would consist of more than one part.
        -- This would break GHC's assumption that infix operator expressions
        -- only consist of one part, and would cause transformations of an
        -- expression like
        -- print $ succ $ 5
        -- which is
        -- print $ (succ $ 5)
        -- to result in this expression:
        -- ((f ($))
        --  ((f (($))
        --   (f print)
        --   (f succ)))
        --  (f 5))
        -- instead of this expression:
        -- ((f ($))
        --  (f print)
        --  ((f ($))
        --   (f succ)
        --   (f 5)))
        -- , which fails to parse
        <*> pure middle
        <*> adaptLExpr right
    NegApp x body se -> NegApp x <$> adaptLExpr body <*> pure se
    HsPar x le -> HsPar x <$> adaptLExpr le
    ExplicitTuple x args boxity -> ExplicitTuple x <$> mapM adaptLTupArg args <*> pure boxity
    ExplicitSum x ct a body -> ExplicitSum x ct a <$> adaptLExpr body
    HsCase x body mg -> HsCase x <$> adaptLExpr body <*> adaptMatchGroup mg
    HsIf x condE ifE elseE -> HsIf x <$> adaptLExpr condE <*> adaptLExpr ifE <*> adaptLExpr elseE
    HsLet x lbs body -> HsLet x <$> adaptLocalBinds lbs <*> adaptLExpr body
    HsDo x ctx stmts -> HsDo x ctx <$> liftL (mapM adaptExprLStmt) stmts
    ExplicitList x m bodies -> ExplicitList x m <$> mapM adaptLExpr bodies
    RecordCon x name binds -> RecordCon x name <$> adaptRecordBinds binds
    RecordUpd x left updates -> RecordUpd x <$> adaptLExpr left <*> mapM (liftL adaptRecordField) updates
    -- TODO
    _ -> pure e

adaptLTupArg :: LHsTupArg GhcPs -> AdaptM (LHsTupArg GhcPs)
adaptLTupArg = liftL $ \case
  Present x body -> Present x <$> adaptLExpr body
  Missing x -> pure $ Missing x

adaptRecordBinds :: HsRecordBinds GhcPs -> AdaptM (HsRecordBinds GhcPs)
adaptRecordBinds = \case
  HsRecFields fields md -> HsRecFields <$> mapM (liftL adaptHsRecField') fields <*> pure md

adaptRecordField :: HsRecUpdField GhcPs -> AdaptM (HsRecUpdField GhcPs)
adaptRecordField = adaptHsRecField'

adaptHsRecField' :: HsRecField' id (LHsExpr GhcPs) -> AdaptM (HsRecField' id (LHsExpr GhcPs))
adaptHsRecField' = \case
  HsRecField i e b -> HsRecField i <$> adaptLExpr e <*> pure b

adaptExprLStmt ::
  ExprLStmt GhcPs ->
  AdaptM (ExprLStmt GhcPs)
adaptExprLStmt = liftL $ \case
  LastStmt x e mb se -> LastStmt x <$> adaptLExpr e <*> pure mb <*> pure se
  BindStmt x p e -> BindStmt x p <$> adaptLExpr e
  BodyStmt x e se1 se2 -> BodyStmt x <$> adaptLExpr e <*> pure se1 <*> pure se2
  LetStmt x lbs -> LetStmt x <$> adaptLocalBinds lbs
  s -> pure s -- TODO

applyAdapterExpr :: Location -> HsExpr GhcPs -> AdaptM (HsExpr GhcPs)
applyAdapterExpr loc e = do
  moduule <- ask
  let strToLog = mkStringToLog moduule loc
  pure $
    HsPar NoExtField $
      noLoc $
        HsApp
          NoExtField
          ( noLoc
              ( HsApp
                  NoExtField
                  (noLoc (HsVar NoExtField (noLoc (Qual adapterModuleName (mkVarOcc "adaptValue")))))
                  (noLoc (HsLit NoExtField (HsString NoSourceText (mkFastString strToLog))))
              )
          )
          (noLoc e)

spanLocation :: SrcSpan -> Maybe Location
spanLocation sp = case sp of
  RealSrcSpan s _ ->
    Just
      Location
        { locationLine = fromIntegral (srcSpanStartLine s),
          locationColumnStart = fromIntegral (srcSpanStartCol s),
          locationColumnEnd = fromIntegral (srcSpanEndCol s)
        }
  UnhelpfulSpan _ -> Nothing

mkStringToLog :: GHC.Module -> Location -> String
mkStringToLog moduule loc =
  unwords
    [ unitToString (moduleUnit moduule),
      moduleNameString (moduleName moduule),
      locationString loc
    ]

-- We drop the hash because it differs in a cabal build versus a nix build.
unitToString :: GHC.Unit -> String
unitToString u =
  case reverse . T.splitOn "-" . T.pack $ unitString u of
    [] -> "-"
    -- If there's only one component, it's probably the "main" package, and we
    -- still want to see this instead of drop it
    [x] -> T.unpack x
    -- If there is more than one component, the last component is the hash, so
    -- we drop it.
    (_ : rest) -> T.unpack $ T.intercalate "-" $ reverse rest
