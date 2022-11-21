{-# LANGUAGE RecordWildCards #-}

module Dekking.Report (reportMain) where

import Control.Monad
import Data.List
import Dekking.Coverable
import Dekking.Coverage
import Dekking.OptParse
import Path
import Path.IO
import Text.Show.Pretty

reportMain :: IO ()
reportMain = do
  Settings {..} <- getSettings

  coverablesFiles <-
    filter
      (maybe False (isSuffixOf "coverable") . fileExtension)
      . concat
      <$> mapM (fmap snd . listDirRecur) settingCoverablesDirs

  let coverageFiles = settingCoverageFiles

  coverables <- fmap mconcat $
    forM coverablesFiles $ \coverablesFile -> do
      print coverablesFile
      coverables <- readCoverableFile coverablesFile
      pPrint coverables
      pure coverables

  coverage <- fmap mconcat $
    forM coverageFiles $ \coverageFile -> do
      print coverageFile
      coverage <- readCoverageFile coverageFile
      pPrint coverage
      pure coverage

  pPrint coverables
  pPrint coverage
  pPrint (computeCoverageReport coverables coverage)

computeCoverageReport :: Coverables -> [TopLevelBinding] -> CoverageReport
computeCoverageReport Coverables {..} topLevelCoverage =
  CoverageReport
    { coverageReportTopLevelBindings = computeCoverage coverableTopLevelBindings topLevelCoverage
    }

data CoverageReport = CoverageReport {coverageReportTopLevelBindings :: Coverage String}
  deriving (Show, Eq)

data Coverage a = Coverage
  { coverageCovered :: [a],
    coverageUncovered :: [a]
  }
  deriving (Show, Eq)

computeCoverage :: Eq a => [a] -> [a] -> Coverage a
computeCoverage coverables covereds =
  Coverage
    { coverageCovered = coverables `intersect` covereds,
      coverageUncovered = coverables \\ covereds
    }
