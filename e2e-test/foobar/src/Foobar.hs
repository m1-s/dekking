{-# LANGUAGE DeriveGeneric #-}

module Foobar where

import Control.Lens
import Data.Sequence
import Data.Validity
import GHC.Generics (Generic)

data Example = Example
  { exampleString :: String,
    exampleInt :: Int
  }
  deriving (Show, Eq, Generic)

instance Validity Example

printExample :: Example -> IO ()
printExample = print

myLensFunction = fromList [1, 2, 3, 4] ^? ix 2
