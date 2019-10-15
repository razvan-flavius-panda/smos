{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeOperators #-}

module Smos.Sync.Client.Sync where

import Data.Aeson as JSON
import Data.Aeson.Encode.Pretty as JSON
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LB
import Data.Hashable
import Data.Map (Map)
import qualified Data.Map as M
import qualified Data.Text as T
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Validity.UUID ()
import Text.Show.Pretty

import Control.Monad
import Control.Monad.Logger
import Control.Monad.Reader

import System.Exit
import System.FileLock

import Servant.Client

import Path
import Path.IO

import qualified Data.Mergeful as Mergeful
import qualified Data.Mergeful.Timed as Mergeful

import Network.HTTP.Client as HTTP
import Network.HTTP.Client.TLS as HTTP

import Database.Persist.Sqlite as DB

import Smos.Client

import Smos.Sync.Client.Contents
import Smos.Sync.Client.ContentsMap (ContentsMap(..))
import Smos.Sync.Client.DB
import Smos.Sync.Client.Env
import Smos.Sync.Client.OptParse
import Smos.Sync.Client.OptParse.Types
import Smos.Sync.Client.Query
import Smos.Sync.Client.Session

syncSmosSyncClient :: Settings -> SyncSettings -> IO ()
syncSmosSyncClient Settings {..} SyncSettings {..} =
  withFileLock (fromAbsFile syncSetMetadataDB) Exclusive $ \_ ->
    runStderrLoggingT $
    filterLogger (\_ ll -> ll >= setLogLevel) $
    DB.withSqlitePool (T.pack $ fromAbsFile syncSetMetadataDB) 1 $ \pool -> do
      logDebugN "CLIENT START"
      man <- liftIO $ HTTP.newManager HTTP.tlsManagerSettings
      let cenv = mkClientEnv man setServerUrl
      let env = SyncClientEnv {syncClientEnvServantClientEnv = cenv, syncClientEnvConnection = pool}
      flip runReaderT env $
        withToken setSessionPath $ \token -> do
          void $ runDB $ runMigrationSilent migrateAll
          mUUID <- liftIO $ readServerUUID syncSetUUIDFile
          logDebugData "READ STORED UUID" mUUID
          files <- liftIO $ readFilteredSyncFiles syncSetIgnoreFiles syncSetContentsDir
          logDebugData "READ FILE CONTENTS" files
          clientStore <-
            case mUUID of
              Nothing
             -- Never synced yet
             --
             -- That means we need to run an initial sync first.
               -> do
                initialStore <- runInitialSync token
                liftIO $ writeServerUUID syncSetUUIDFile (clientStoreServerUUID initialStore)
                pure $ consolidateInitialStoreWithFiles initialStore files
              Just uuid
             -- We have synced before.
               -> do
                meta <- runDB readClientMetadata
                logDebugData "CLIENT META MAP BEFORE SYNC" meta
                let store = consolidateMetaMapWithFiles meta files
                pure $ ClientStore {clientStoreServerUUID = uuid, clientStoreItems = store}
          logDebugData "CLIENT STORE BEFORE SYNC" clientStore
          newClientStore <- runSync token clientStore
          logDebugData "CLIENT STORE AFTER SYNC" newClientStore
          saveClientStore syncSetIgnoreFiles syncSetContentsDir newClientStore
          logDebugN "CLIENT END"

runInitialSync :: Token -> C ClientStore
runInitialSync token = do
  logDebugN "INITIAL SYNC START"
  let clientStore = Mergeful.initialClientStore :: Mergeful.ClientStore FileUUID SyncFile
  let req = Mergeful.makeSyncRequest clientStore
  logDebugData "INITIAL SYNC REQUEST" req
  logInfoJsonData "INITIAL SYNC REQUEST (JSON)" req
  resp@SyncResponse {..} <- runClientOrDie $ clientPostSync token req
  logDebugData "INITIAL SYNC RESPONSE" resp
  logInfoJsonData "INITIAL SYNC RESPONSE (JSON)" resp
  let items = Mergeful.mergeSyncResponseFromServer Mergeful.initialClientStore syncResponseItems
  let newClientStore =
        ClientStore {clientStoreServerUUID = syncResponseServerId, clientStoreItems = items}
  logDebugData "INITIAL CLIENT STORE" newClientStore
  logDebugN "INITIAL SYNC END"
  pure newClientStore

runSync :: Token -> ClientStore -> C ClientStore
runSync token clientStore = do
  logDebugN "SYNC START"
  let items = clientStoreItems clientStore
  let req = Mergeful.makeSyncRequest items
  logDebugData "SYNC REQUEST" req
  logInfoJsonData "SYNC REQUEST (JSON)" req
  resp@SyncResponse {..} <- runClientOrDie $ clientPostSync token req
  logDebugData "SYNC RESPONSE" resp
  logInfoJsonData "SYNC RESPONSE (JSON)" resp
  liftIO $
    unless (syncResponseServerId == clientStoreServerUUID clientStore) $
    die $
    unlines
      [ "The server was reset since the last time it was synced with, refusing to sync."
      , "If you want to sync anyway, remove the client metadata file and sync again."
      , "Note that you can lose data by doing this, so make a backup first."
      ]
  let newClientStore =
        clientStore
          { clientStoreServerUUID = syncResponseServerId
          , clientStoreItems = Mergeful.mergeSyncResponseFromServer items syncResponseItems
          }
  logDebugN "SYNC END"
  pure newClientStore

logInfoJsonData :: ToJSON a => Text -> a -> C ()
logInfoJsonData name a =
  logInfoN $ T.unwords [name <> ":", TE.decodeUtf8 $ LB.toStrict $ encodePretty a]

logDebugData :: Show a => Text -> a -> C ()
logDebugData name a = logDebugN $ T.unwords [name <> ":", T.pack $ ppShow a]

readServerUUID :: Path Abs File -> IO (Maybe ServerUUID)
readServerUUID p = do
  mContents <- forgivingAbsence $ LB.readFile $ toFilePath p
  forM mContents $ \contents ->
    case JSON.eitherDecode contents of
      Left err -> die err
      Right store -> pure store

writeServerUUID :: Path Abs File -> ServerUUID -> IO ()
writeServerUUID p u = do
  ensureDir (parent p)
  LB.writeFile (fromAbsFile p) $ JSON.encodePretty u

consolidateInitialStoreWithFiles :: ClientStore -> ContentsMap -> ClientStore
consolidateInitialStoreWithFiles cs contentsMap =
  let Mergeful.ClientStore {..} = clientStoreItems cs
   in if not
           (null clientStoreAddedItems &&
            null clientStoreDeletedItems && null clientStoreSyncedButChangedItems)
        then error "should not happen: initial"
        else cs
               { clientStoreItems =
                   consolidateInitialSyncedItemsWithFiles clientStoreSyncedItems contentsMap
               }

consolidateInitialSyncedItemsWithFiles ::
     Map FileUUID (Mergeful.Timed SyncFile) -> ContentsMap -> Mergeful.ClientStore FileUUID SyncFile
consolidateInitialSyncedItemsWithFiles syncedItems =
  M.foldlWithKey go (Mergeful.initialClientStore {Mergeful.clientStoreSyncedItems = syncedItems}) .
  contentsMapFiles
  where
    alreadySyncedMap = makeAlreadySyncedMap syncedItems
    go ::
         Mergeful.ClientStore FileUUID SyncFile
      -> Path Rel File
      -> ByteString
      -> Mergeful.ClientStore FileUUID SyncFile
    go s rf contents =
      let sf = SyncFile {syncFileContents = contents, syncFilePath = rf}
       in case M.lookup rf alreadySyncedMap of
            Nothing
          -- Not in the initial sync, that means it was added
             -> Mergeful.addItemToClientStore sf s
            Just (i, contents') ->
              if contents == contents'
                -- We the same file locally, do nothing.
                then s
                -- We have a different file locally, so we'll mark this as 'synced but changed'.
                else Mergeful.changeItemInClientStore i sf s

makeAlreadySyncedMap :: Map i (Mergeful.Timed SyncFile) -> Map (Path Rel File) (i, ByteString)
makeAlreadySyncedMap m = M.fromList $ map go $ M.toList m
  where
    go (i, Mergeful.Timed SyncFile {..} _) = (syncFilePath, (i, syncFileContents))

consolidateMetaMapWithFiles ::
     Map (Path Rel File) SyncFileMeta -> ContentsMap -> Mergeful.ClientStore FileUUID SyncFile
consolidateMetaMapWithFiles clientMetaDataMap contentsMap
      -- The existing files need to be checked for deletions and changes.
 =
  let go1 ::
           Mergeful.ClientStore FileUUID SyncFile
        -> Path Rel File
        -> SyncFileMeta
        -> Mergeful.ClientStore FileUUID SyncFile
      go1 s rf sfm@SyncFileMeta {..} =
        case M.lookup rf $ contentsMapFiles contentsMap of
          Nothing
               -- The file is not there, that means that it must have been deleted.
               -- so we will mark it as such
           ->
            s
              { Mergeful.clientStoreDeletedItems =
                  M.insert syncFileMetaUUID syncFileMetaTime $ Mergeful.clientStoreDeletedItems s
              }
          Just contents
               -- The file is there, so we need to check if it has changed.
           ->
            if isUnchanged sfm contents
                   -- If it hasn't changed, it's still synced.
              then s
                     { Mergeful.clientStoreSyncedItems =
                         M.insert
                           syncFileMetaUUID
                           (Mergeful.Timed
                              { Mergeful.timedValue =
                                  SyncFile {syncFilePath = rf, syncFileContents = contents}
                              , timedTime = syncFileMetaTime
                              })
                           (Mergeful.clientStoreSyncedItems s)
                     }
                   -- If it has changed, mark it as such
              else s
                     { Mergeful.clientStoreSyncedButChangedItems =
                         M.insert
                           syncFileMetaUUID
                           (Mergeful.Timed
                              { Mergeful.timedValue =
                                  SyncFile {syncFilePath = rf, syncFileContents = contents}
                              , timedTime = syncFileMetaTime
                              })
                           (Mergeful.clientStoreSyncedButChangedItems s)
                     }
      syncedChangedAndDeleted = M.foldlWithKey go1 Mergeful.initialClientStore clientMetaDataMap
      go2 ::
           Mergeful.ClientStore FileUUID SyncFile
        -> Path Rel File
        -> ByteString
        -> Mergeful.ClientStore FileUUID SyncFile
      go2 s rf contents =
        let sf = SyncFile {syncFilePath = rf, syncFileContents = contents}
         in Mergeful.addItemToClientStore sf s
   in M.foldlWithKey
        go2
        syncedChangedAndDeleted
        (contentsMapFiles contentsMap `M.difference` clientMetaDataMap)

-- We will trust hashing. (TODO do we need to fix that?)
isUnchanged :: SyncFileMeta -> ByteString -> Bool
isUnchanged SyncFileMeta {..} contents = hash contents == syncFileMetaHash

-- TODO this could be probably optimised using the sync response
saveClientStore :: IgnoreFiles -> Path Abs Dir -> ClientStore -> C ()
saveClientStore igf dir store = do
  runDB $ writeClientMetadata $ makeClientMetaData igf store
  liftIO $ saveSyncFiles igf dir $ clientStoreItems store

-- | We only check the synced items, because it should be the case that
-- they're the only ones that are not empty.
makeClientMetaData :: IgnoreFiles -> ClientStore -> Map (Path Rel File) SyncFileMeta
makeClientMetaData igf ClientStore {..} =
  let Mergeful.ClientStore {..} = clientStoreItems
   in if not
           (null clientStoreAddedItems &&
            null clientStoreDeletedItems && null clientStoreSyncedButChangedItems)
        then error "Should not happen: make meta"
        else let go ::
                      Map (Path Rel File) SyncFileMeta
                   -> FileUUID
                   -> Mergeful.Timed SyncFile
                   -> Map (Path Rel File) SyncFileMeta
                 go m u Mergeful.Timed {..} =
                   let SyncFile {..} = timedValue
                       goOn =
                         M.insert
                           syncFilePath
                           SyncFileMeta
                             { syncFileMetaUUID = u
                             , syncFileMetaTime = timedTime
                             , syncFileMetaHash = hash syncFileContents
                             }
                           m
                    in case igf of
                         IgnoreNothing -> goOn
                         IgnoreHiddenFiles ->
                           if isHidden syncFilePath
                             then m
                             else goOn
              in M.foldlWithKey go M.empty clientStoreSyncedItems

saveSyncFiles :: IgnoreFiles -> Path Abs Dir -> Mergeful.ClientStore FileUUID SyncFile -> IO ()
saveSyncFiles igf dir store = saveContentsMap igf dir $ makeContentsMap store
