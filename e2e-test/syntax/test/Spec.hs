import qualified Lens
import qualified OverloadedStrings
import qualified Paren
import qualified Record
import qualified ServantExample
import qualified TopLevel
import qualified TypeApplications

main :: IO ()
main = do
  Lens.main
  OverloadedStrings.main
  Paren.main
  Record.main
  ServantExample.main
  TopLevel.main
  TypeApplications.main
