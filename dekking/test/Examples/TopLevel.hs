{-# OPTIONS_GHC -fplugin=Dekking -w #-}

module Examples.TopLevel where

covered :: IO ()
covered = pure ()

coveredWithArg :: Int -> IO ()
coveredWithArg _ = pure ()

uncovered :: IO ()
uncovered = pure ()

uncoveredWithArg :: Int -> IO ()
uncoveredWithArg _ = pure ()
