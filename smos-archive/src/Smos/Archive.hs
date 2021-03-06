{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Archive
  ( smosArchive,

    -- ** Helper functions
    isDone,
    prepareToArchive,
  )
where

import Control.Monad.Reader
import Data.Maybe
import Data.Time
import Data.Tree
import Path
import Path.IO
import Smos.Archive.OptParse
import Smos.Archive.OptParse.Types
import Smos.Archive.Prompt
import Smos.Data
import Smos.Report.Config
import System.Exit

smosArchive :: IO ()
smosArchive = do
  Settings {..} <- getSettings
  runReaderT (archive setFile) setReportSettings

type Q a = ReaderT SmosReportConfig IO a

archive :: Path Abs File -> Q ()
archive from = do
  to <- determineToFile from
  liftIO $ do
    checkFromFile from
    moveToArchive from to

determineToFile :: Path Abs File -> Q (Path Abs File)
determineToFile file = do
  getWorkflowDir <- asks resolveReportWorkflowDir
  workflowDir <- liftIO getWorkflowDir
  case stripProperPrefix workflowDir file of
    Nothing ->
      liftIO
        $ die
        $ unlines
          [ "The smos file",
            fromAbsFile file,
            "is not in the smos workflow directory",
            fromAbsDir workflowDir
          ]
    Just rf -> do
      getArchiveDir <- asks resolveReportArchiveDir
      archiveDir <- liftIO getArchiveDir
      let ext = fileExtension rf
      withoutExt <- setFileExtension "" rf
      today <- liftIO $ utctDay <$> getCurrentTime
      let newRelFile = fromRelFile withoutExt ++ "_" ++ formatTime defaultTimeLocale "%F" today
      arf' <- parseRelFile newRelFile
      arf'' <- setFileExtension ext arf'
      pure $ archiveDir </> arf''

checkFromFile :: Path Abs File -> IO ()
checkFromFile from = do
  mErrOrSF <- readSmosFile from
  case mErrOrSF of
    Nothing -> die $ unwords ["File does not exist:", fromAbsFile from]
    Just (Left err) ->
      die $
        unlines
          [unwords ["The file to archive doesn't look like a smos file:", fromAbsFile from], err]
    Just (Right sf) -> do
      let allDone = all (maybe True isDone . entryState) (concatMap flatten (smosFileForest sf))
      if allDone
        then pure ()
        else do
          res <-
            promptYesNo No $
              unlines
                [ unwords ["Not all entries in", fromAbsFile from, "are done."],
                  "Are you sure that you want to archive it?",
                  "All remaining non-done entries will be set to CANCELLED."
                ]
          case res of
            Yes -> pure ()
            No -> die "Not archiving."

isDone :: TodoState -> Bool
isDone "DONE" = True
isDone "CANCELLED" = True
isDone "FAILED" = True
isDone _ = False

moveToArchive :: Path Abs File -> Path Abs File -> IO ()
moveToArchive from to = do
  ensureDir $ parent to
  mErrOrSmosFile <- readSmosFile from
  case mErrOrSmosFile of
    Nothing -> die $ unwords ["The file to archive does not exist:", fromAbsFile from]
    Just (Left err) -> die $ unlines ["The file to archive doesn't look like a smos file:", err]
    Just (Right sf) -> do
      e2 <- doesFileExist to
      if e2
        then die $ unwords ["Proposed archive file", fromAbsFile to, "already exists."]
        else do
          now <- liftIO getCurrentTime
          let archivedSmosFile = prepareToArchive now sf
          writeSmosFile to archivedSmosFile
          removeFile from

prepareToArchive :: UTCTime -> SmosFile -> SmosFile
prepareToArchive now = smosFileClockOutEverywhere now . setAllUndoneToCancelled now

setAllUndoneToCancelled :: UTCTime -> SmosFile -> SmosFile
setAllUndoneToCancelled now (SmosFile f) = SmosFile $ map (fmap go) f
  where
    go :: Entry -> Entry
    go e =
      case entryState e of
        Nothing -> e
        Just ts ->
          if isDone ts
            then e
            else fromMaybe e $ entrySetState now (Just "CANCELLED") e
