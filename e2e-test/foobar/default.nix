{ mkDerivation, base, containers, lens, lib, validity }:
mkDerivation {
  pname = "foobar";
  version = "0.0.0";
  src = ./.;
  libraryHaskellDepends = [ base containers lens validity ];
  license = "unknown";
}
