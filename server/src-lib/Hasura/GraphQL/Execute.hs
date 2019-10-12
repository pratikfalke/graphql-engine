{-# LANGUAGE DataKinds       #-}
{-# LANGUAGE RecordWildCards #-}

module Hasura.GraphQL.Execute
  ( GQExecPlanPartial(..)
  , GQFieldPartialPlan(..)
  , GQRemoteRelPlan(..)
  , GQFieldResolvedPlan(..)
  , GQExecPlan

  , getExecPlanPartial

  , ExecOp(..)
  , getResolvedExecPlan
  , execRemoteGQ
  , getSubsOp

  , EP.PlanCache
  , EP.initPlanCache
  , EP.clearPlanCache
  , EP.dumpPlanCache

  , ExecutionCtx(..)

  , mkQuery
  ) where

import           Control.Exception                      (try)
import           Control.Lens
import           Data.Has
import           Data.Time

import qualified Data.Aeson                             as J
import qualified Data.CaseInsensitive                   as CI
import qualified Data.HashMap.Strict                    as Map
import qualified Data.HashMap.Strict.InsOrd             as OMap
import qualified Data.Sequence                          as Seq
import qualified Data.String.Conversions                as CS
import qualified Data.Text                              as T
import qualified Language.GraphQL.Draft.Syntax          as G
import qualified Network.HTTP.Client                    as HTTP
import qualified Network.HTTP.Types                     as N
import qualified Network.Wreq                           as Wreq


import           Hasura.EncJSON
import           Hasura.GraphQL.Context
import           Hasura.GraphQL.Resolve.Context
import           Hasura.GraphQL.Schema
import           Hasura.GraphQL.Transport.HTTP.Protocol
import           Hasura.GraphQL.Validate.Types
import           Hasura.HTTP
import           Hasura.Prelude
import           Hasura.RQL.DDL.Headers
import           Hasura.RQL.Types
import           Hasura.Server.Context
import           Hasura.Server.Utils                    (RequestId,
                                                         filterRequestHeaders)
import           Hasura.SQL.Time
import           Hasura.SQL.Value

import qualified Hasura.GraphQL.Execute.LiveQuery       as EL
import qualified Hasura.GraphQL.Execute.Plan            as EP
import qualified Hasura.GraphQL.Execute.Query           as EQ
import           Hasura.GraphQL.Execute.RemoteJoins
import qualified Hasura.GraphQL.Resolve                 as GR
import qualified Hasura.GraphQL.Validate                as VQ
import qualified Hasura.Logging                         as L

-- | Execution context
data ExecutionCtx
  = ExecutionCtx
  { _ecxLogger          :: !L.Logger
  , _ecxSqlGenCtx       :: !SQLGenCtx
  , _ecxPgExecCtx       :: !PGExecCtx
  , _ecxPlanCache       :: !EP.PlanCache
  , _ecxSchemaCache     :: !SchemaCache
  , _ecxSchemaCacheVer  :: !SchemaCacheVer
  , _ecxHttpManager     :: !HTTP.Manager
  , _ecxEnableAllowList :: !Bool
  }

data GQFieldPartialPlan
  = GQFieldPartialHasura !(GCtx, VQ.Field)
  | GQFieldPartialRemote !RemoteSchemaInfo !VQ.Field

data GQFieldResolvedPlan
  = GQFieldResolvedHasura !ExecOp
  | GQFieldResolvedRemote !RemoteSchemaInfo !G.OperationType !VQ.Field

data GQExecPlanPartial
  = GQExecPlanPartial
  { execOpType     :: G.OperationType
  , execFieldPlans :: Seq.Seq GQFieldPartialPlan
  }

data GQRemoteRelPlan (p :: RRF_P)
  = GQRemoteRelPlan
  { rrpRemoteRelField   :: RemoteRelBranch p
  , rrpRemoteSchemaInfo :: RemoteSchemaInfo
  }

deriving instance Show (GQRemoteRelPlan 'RRF_Tree)
deriving instance Show (GQRemoteRelPlan 'RRF_Splice)

type GQExecPlan = ([GQRemoteRelPlan 'RRF_Tree], GQFieldResolvedPlan)

-- | Split the 'rrSelSet' from the 'RemoteRelBranch'
mkQuery :: GQRemoteRelPlan 'RRF_Tree -> JoinArguments -> (GQRemoteRelPlan 'RRF_Splice, [VQ.Field])
mkQuery GQRemoteRelPlan{..} JoinArguments{..} =
  let RemoteRelBranch{..} = rrpRemoteRelField
      indexedRows = enumerateRowAliases $ toList joinArguments
      batchFields =
        flip map indexedRows $ \(alias, varArgs) ->
           fieldCallsToField
             rrArguments
             varArgs
             rrSelSet
             alias
             (rtrRemoteFields rrRemoteRelationship)
   in (GQRemoteRelPlan (rrFieldToSplice rrpRemoteRelField) rrpRemoteSchemaInfo, batchFields)

getExecPlanPartial
  :: (MonadError QErr m)
  => UserInfo
  -> SchemaCache
  -> Bool
  -> GQLReqParsed
  -> m GQExecPlanPartial
getExecPlanPartial userInfo sc enableAL req
  -- check if query is in allowlist
 = do
  when enableAL checkQueryInAllowlist
  (gCtx, _) <- flip runStateT sc $ getGCtx role gCtxRoleMap
  queryParts <- flip runReaderT gCtx $ VQ.getQueryParts req
  let remoteSchemas = scRemoteSchemas sc
  rootSelSet <- runReaderT (VQ.validateGQ queryParts) gCtx
  runReaderT (generatePlan rootSelSet) (gCtx, remoteSchemas)
  where
    generatePlan ::
         (MonadError QErr m, MonadReader (GCtx, RemoteSchemaMap) m)
      => VQ.RootSelSet
      -> m GQExecPlanPartial
    generatePlan =
      \case
        VQ.RQuery selSet ->
          (GQExecPlanPartial G.OperationTypeQuery) <$>
          (mapM generateFieldPlan selSet)
        VQ.RMutation selSet ->
          (GQExecPlanPartial G.OperationTypeMutation) <$>
          (mapM generateFieldPlan selSet)
        VQ.RSubscription field ->
          (GQExecPlanPartial G.OperationTypeSubscription) <$>
          (fmap Seq.singleton $ generateFieldPlan field)
    generateFieldPlan ::
         (MonadError QErr m, MonadReader (GCtx, RemoteSchemaMap) m)
      => VQ.Field
      -> m GQFieldPartialPlan
    generateFieldPlan field =
      case VQ._fSource field of
        TLHasuraType -> do
          (gCtx, _) <- ask
          pure $ GQFieldPartialHasura (gCtx, field)
        TLRemoteType rsName -> do
          (_, rsMap) <- ask
          rsCtx <-
            onNothing (Map.lookup rsName rsMap) $
            throw500 "remote schema not found"
          pure $ GQFieldPartialRemote (rscInfo rsCtx) field
        TLRemoteRelType {} -> throw500 "remote relationship cannot be top level field"
    role = userRole userInfo
    gCtxRoleMap = scGCtxMap sc
    checkQueryInAllowlist
     =
      when (role /= adminRole) $ do
        let notInAllowlist =
              not $ VQ.isQueryInAllowlist (_grQuery req) (scAllowlist sc)
        when notInAllowlist $ modifyQErr modErr $ throwVE "query is not allowed"
    modErr e =
      let msg = "query is not in any of the allowlists"
       in e {qeInternal = Just $ J.object ["message" J..= J.String msg]}


-- An execution operation, in case of queries and mutations it is just a
-- transaction to be executed
data ExecOp
  = ExOpQuery !LazyRespTx !(Maybe EQ.GeneratedSqlMap)
  | ExOpMutation !LazyRespTx
  | ExOpSubs !EL.LiveQueryPlan
  deriving Show

getResolvedExecPlan
  :: (MonadError QErr m, MonadIO m)
  => PGExecCtx
  -> EP.PlanCache
  -> UserInfo
  -> SQLGenCtx
  -> Bool
  -> SchemaCache
  -> SchemaCacheVer
  -> GQLReqUnparsed
  -> m (Seq.Seq GQExecPlan)
getResolvedExecPlan pgExecCtx planCache userInfo sqlGenCtx enableAL sc scVer reqUnparsed = do
  planM <-
    liftIO $ EP.getPlan scVer (userRole userInfo) opNameM queryStr planCache
  let usrVars = userVars userInfo
  case planM of
    Just plan ->
      case plan of
        EP.RPQuery queryPlan -> do
          (tx, genSql) <- EQ.queryOpFromPlan usrVars queryVars queryPlan
          let queryOp = ExOpQuery tx (Just genSql)
          pure $ pure $ plainPlan $ GQFieldResolvedHasura queryOp
        EP.RPSubs subsPlan -> do
          subOp <-
            ExOpSubs <$>
            EL.reuseLiveQueryPlan pgExecCtx usrVars queryVars subsPlan
          pure $ pure $ plainPlan $ GQFieldResolvedHasura subOp
    Nothing -> noExistingPlan
  where
    GQLReq opNameM queryStr queryVars = reqUnparsed
    addPlanToCache plan =
      -- liftIO $
      EP.addPlan scVer (userRole userInfo) opNameM queryStr plan planCache
    noExistingPlan = do
      req <- toParsed reqUnparsed
      (GQExecPlanPartial opType fieldPlans) <-
        getExecPlanPartial userInfo sc enableAL req
      case opType of
        G.OperationTypeQuery ->
          forM fieldPlans $ \case
            GQFieldPartialHasura (gCtx, field) -> do
              let (newHasuraField, remoteRelFields) = rebuildFieldStrippingRemoteRels field
              (queryTx, plan, genSql) <-
                getQueryOp gCtx sqlGenCtx userInfo (Seq.singleton newHasuraField)
              -- traverse_ (addPlanToCache . EP.RPQuery) plan
              (, GQFieldResolvedHasura $ ExOpQuery queryTx (Just genSql)) <$>
                mkRemoteRelPlans remoteRelFields
            GQFieldPartialRemote rsInfo field ->
              return . plainPlan $ GQFieldResolvedRemote rsInfo G.OperationTypeQuery field
        G.OperationTypeMutation ->
          forM fieldPlans $ \case
            GQFieldPartialHasura (gCtx, field) -> do
              mutationTx <-
                getMutOp gCtx sqlGenCtx userInfo (Seq.singleton field)
              (return . plainPlan . GQFieldResolvedHasura) $ ExOpMutation mutationTx
            GQFieldPartialRemote rsInfo field ->
              return . plainPlan $
              GQFieldResolvedRemote rsInfo G.OperationTypeMutation field
        G.OperationTypeSubscription ->
          forM fieldPlans $ \case
            GQFieldPartialHasura (gCtx, field) -> do
              (lqOp, plan) <- getSubsOp pgExecCtx gCtx sqlGenCtx userInfo field
              -- traverse_ (addPlanToCache . EP.RPSubs) plan
              (return . plainPlan . GQFieldResolvedHasura) $ ExOpSubs lqOp
            GQFieldPartialRemote rsInfo field ->
              return . plainPlan $
              GQFieldResolvedRemote rsInfo G.OperationTypeSubscription field

    plainPlan = ([],)
    mkRemoteRelPlans :: MonadError QErr m => [RemoteRelBranch 'RRF_Tree] -> m [GQRemoteRelPlan 'RRF_Tree]
    mkRemoteRelPlans = traverse (\remoteRelField -> GQRemoteRelPlan remoteRelField <$> getRsi remoteRelField)
      where
        getRsi remoteRel =
          case Map.lookup
                 (rtrRemoteSchema
                    (rrRemoteRelationship remoteRel))
                 (scRemoteSchemas sc) of
            Just remoteSchemaCtx -> pure $ rscInfo remoteSchemaCtx
            Nothing -> throw500 "could not find remote schema info"

-- Monad for resolving a hasura query/mutation
type E m =
  ReaderT ( UserInfo
          , QueryCtxMap
          , MutationCtxMap
          , TypeMap
          , FieldMap
          , OrdByCtx
          , InsCtxMap
          , SQLGenCtx
          ) (ExceptT QErr m)

runE
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> E m a
  -> m a
runE ctx sqlGenCtx userInfo action = do
  res <- runExceptT $ runReaderT action
    (userInfo, queryCtxMap, mutationCtxMap, typeMap, fldMap, ordByCtx, insCtxMap, sqlGenCtx)
  either throwError return res
  where
    queryCtxMap = _gQueryCtxMap ctx
    mutationCtxMap = _gMutationCtxMap ctx
    typeMap = _gTypes ctx
    fldMap = _gFields ctx
    ordByCtx = _gOrdByCtx ctx
    insCtxMap = _gInsCtxMap ctx

getQueryOp
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.SelSet
  -> m (LazyRespTx, Maybe EQ.ReusableQueryPlan, EQ.GeneratedSqlMap)
getQueryOp gCtx sqlGenCtx userInfo fields =
  runE gCtx sqlGenCtx userInfo $ EQ.convertQuerySelSet fields

mutationRootName :: Text
mutationRootName = "mutation_root"

resolveMutSelSet
  :: ( MonadError QErr m
     , MonadReader r m
     , Has UserInfo r
     , Has MutationCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has InsCtxMap r
     )
  => VQ.SelSet
  -> m LazyRespTx
resolveMutSelSet fields = do
  aliasedTxs <- forM (toList fields) $ \fld -> do
    fldRespTx <- case VQ._fName fld of
      "__typename" -> return $ return $ encJFromJValue mutationRootName
      _            -> fmap liftTx . evalResolveT $ GR.mutFldToTx fld
    return (G.unName $ G.unAlias $ VQ._fAlias fld, fldRespTx)

  -- combines all transactions into a single transaction
  return $ toSingleTx aliasedTxs
  where
    -- A list of aliased transactions for eg
    -- [("f1", Tx r1), ("f2", Tx r2)]
    -- are converted into a single transaction as follows
    -- Tx {"f1": r1, "f2": r2}
    toSingleTx :: [(Text, LazyRespTx)] -> LazyRespTx
    toSingleTx aliasedTxs =
      fmap encJFromAssocList $
        forM aliasedTxs sequence

getMutOp
  :: (MonadError QErr m)
  => GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.SelSet
  -> m LazyRespTx
getMutOp ctx sqlGenCtx userInfo selSet =
  runE ctx sqlGenCtx userInfo $ resolveMutSelSet selSet

getSubsOpM
  :: ( MonadError QErr m
     , MonadReader r m
     , Has QueryCtxMap r
     , Has FieldMap r
     , Has OrdByCtx r
     , Has SQLGenCtx r
     , Has UserInfo r
     , MonadIO m
     )
  => PGExecCtx
  -> VQ.Field
  -> m (EL.LiveQueryPlan, Maybe EL.ReusableLiveQueryPlan)
getSubsOpM pgExecCtx fld =
  case VQ._fName fld of
    "__typename" ->
      throwVE "you cannot create a subscription on '__typename' field"
    _            -> do
      (astUnresolved, varTypes) <- runResolveT $ GR.queryFldToPGAST fld
      EL.buildLiveQueryPlan pgExecCtx (VQ._fAlias fld) astUnresolved varTypes

getSubsOp
  :: ( MonadError QErr m
     , MonadIO m
     )
  => PGExecCtx
  -> GCtx
  -> SQLGenCtx
  -> UserInfo
  -> VQ.Field
  -> m (EL.LiveQueryPlan, Maybe EL.ReusableLiveQueryPlan)
getSubsOp pgExecCtx gCtx sqlGenCtx userInfo fld =
  runE gCtx sqlGenCtx userInfo $ getSubsOpM pgExecCtx fld

execRemoteGQ
  :: ( MonadIO m
     , MonadError QErr m
     , MonadReader ExecutionCtx m
     )
  => RequestId
  -> UserInfo
  -> [N.Header]
  -> RemoteSchemaInfo
  -> G.OperationType
  -> VQ.SelSet
  -> m (HttpResponse EncJSON)
execRemoteGQ reqId userInfo reqHdrs rsi opType selSet = do
  execCtx <- ask
  let _logger  = _ecxLogger execCtx
      manager = _ecxHttpManager execCtx
  when (opType == G.OperationTypeSubscription) $
    throw400 NotSupported "subscription to remote server is not supported"
  hdrs <- getHeadersFromConf hdrConf
  gqlReq <- fieldsToRequest opType (toList selSet)
  let body = encJToLBS (encJFromJValue gqlReq)
  let confHdrs   = map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) hdrs
      clientHdrs = bool [] filteredHeaders fwdClientHdrs
      -- filter out duplicate headers
      -- priority: conf headers > resolved userinfo vars > client headers
      hdrMaps    = [ Map.fromList confHdrs
                   , Map.fromList userInfoToHdrs
                   , Map.fromList clientHdrs
                   ]
      headers  = Map.toList $ foldr Map.union Map.empty hdrMaps
      finalHeaders = addDefaultHeaders headers
  initReqE <- liftIO $ try $ HTTP.parseRequest (show url)
  initReq <- either httpThrow pure initReqE
  let req = initReq
           { HTTP.method = "POST"
           , HTTP.requestHeaders = finalHeaders
           , HTTP.requestBody = HTTP.RequestBodyLBS body
           , HTTP.responseTimeout = HTTP.responseTimeoutMicro (timeout * 1000000)
           }
  -- liftIO $ logGraphqlQuery logger $ QueryLog q Nothing reqId
  res  <- liftIO $ try $ HTTP.httpLbs req manager
  resp <- either httpThrow return res
  let cookieHdrs = getCookieHdr (resp ^.. Wreq.responseHeader "Set-Cookie")
      respHdrs  = Just $ mkRespHeaders cookieHdrs
  return $ HttpResponse (encJFromLBS $ resp ^. Wreq.responseBody) respHdrs
  where
    RemoteSchemaInfo url hdrConf fwdClientHdrs timeout = rsi
    httpThrow :: (MonadError QErr m) => HTTP.HttpException -> m a
    httpThrow = \case
      HTTP.HttpExceptionRequest _req content -> throw500 $ T.pack . show $ content
      HTTP.InvalidUrlException _url reason -> throw500 $ T.pack . show $ reason

    userInfoToHdrs = map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) $
                     userInfoToList userInfo
    filteredHeaders = filterUserVars $ filterRequestHeaders reqHdrs
    filterUserVars hdrs =
      let txHdrs = map (\(n, v) -> (bsToTxt $ CI.original n, bsToTxt v)) hdrs
      in map (\(k, v) -> (CI.mk $ CS.cs k, CS.cs v)) $
         filter (not . isUserVar . fst) txHdrs

    getCookieHdr = fmap (\h -> ("Set-Cookie", h))

    mkRespHeaders hdrs =
      map (\(k, v) -> Header (bsToTxt $ CI.original k, bsToTxt v)) hdrs


fieldsToRequest
  :: (MonadIO m, MonadError QErr m)
  => G.OperationType
  -> [VQ.Field]
  -> m GQLReqParsed
fieldsToRequest opType fields = do
  case traverse fieldToField fields of
    Right gfields ->
      pure
        (GQLReq
           { _grOperationName = Nothing
           , _grQuery =
               GQLExecDoc
                 [ G.ExecutableDefinitionOperation
                     (G.OperationDefinitionTyped
                       (emptyOperationDefinition {
                         G._todSelectionSet = (map G.SelectionField gfields)
                         } )
                       )
                 ]
           , _grVariables = Nothing -- TODO: Put variables in here?
           })
    Left err -> throw500 ("While converting remote field: " <> err)
    where
      emptyOperationDefinition =
        G.TypedOperationDefinition {
          G._todType = opType
        , G._todName = Nothing
        , G._todVariableDefinitions = []
        , G._todDirectives = []
        , G._todSelectionSet = [] }


fieldToField :: VQ.Field -> Either Text G.Field
fieldToField VQ.Field{..} = do
  _fArguments <- traverse makeArgument (Map.toList _fArguments)
  _fSelectionSet <- fmap G.SelectionField . toList <$>
    traverse fieldToField _fSelSet
  _fDirectives <- pure []
  _fAlias      <- pure (Just _fAlias)
  pure $
    G.Field{..}

makeArgument :: (G.Name, AnnInpVal) -> Either Text G.Argument
makeArgument (_aName, annInpVal) =
  do _aValue <- annInpValToValue annInpVal
     pure $ G.Argument {..}

annInpValToValue :: AnnInpVal -> Either Text G.Value
annInpValToValue = annGValueToValue . _aivValue

annGValueToValue :: AnnGValue -> Either Text G.Value
annGValueToValue = fromMaybe (pure G.VNull) .
  \case
    AGScalar _ty mv ->
      pgcolvalueToGValue <$> mv
    AGEnum _ _enumVal ->
      pure (Left "enum not supported")
    AGObject _ mobj ->
      flip fmap mobj $ \obj -> do
        fields <-
          traverse
            (\(_ofName, av) -> do
               _ofValue <- annInpValToValue av
               pure (G.ObjectFieldG {..}))
            (OMap.toList obj)
        pure (G.VObject (G.ObjectValueG fields))
    AGArray _ mvs ->
      fmap (G.VList . G.ListValueG) . traverse annInpValToValue <$> mvs

pgcolvalueToGValue :: PGScalarValue -> Either Text G.Value
pgcolvalueToGValue colVal = case colVal of
  PGValInteger i  -> pure $ G.VInt $ fromIntegral i
  PGValSmallInt i -> pure $ G.VInt $ fromIntegral i
  PGValBigInt i   -> pure $ G.VInt $ fromIntegral i
  PGValFloat f    -> pure $ G.VFloat $ realToFrac f
  PGValDouble d   -> pure $ G.VFloat $ realToFrac d
  -- TODO: Scientific is a danger zone; use its safe conv function.
  PGValNumeric sc -> pure $ G.VFloat $ realToFrac sc
  PGValBoolean b  -> pure $ G.VBoolean b
  PGValChar t     -> pure $ G.VString (G.StringValue (T.singleton t))
  PGValVarchar t  -> pure $ G.VString (G.StringValue t)
  PGValText t     -> pure $ G.VString (G.StringValue t)
  PGValDate d     -> pure $ G.VString $ G.StringValue $ T.pack $ showGregorian d
  PGValTimeStampTZ u -> pure $
    G.VString $ G.StringValue $   T.pack $ formatTime defaultTimeLocale "%FT%T%QZ" u
  PGValTimeTZ (ZonedTimeOfDay tod tz) -> pure $
    G.VString $ G.StringValue $   T.pack (show tod ++ timeZoneOffsetString tz)
  PGNull _ -> pure G.VNull
  PGValJSON {}    -> Left "PGValJSON: cannot convert"
  PGValJSONB {}  -> Left "PGValJSONB: cannot convert"
  PGValGeo {}    -> Left "PGValGeo: cannot convert"
  PGValRaster {} -> Left "PGValRaster: cannot convert"
  PGValUnknown t -> pure $ G.VString $ G.StringValue t
