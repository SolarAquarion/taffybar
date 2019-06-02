let config = {
  packageOverrides = pkgs: rec {
      haskellPackages = pkgs.haskellPackages.override {
        overrides = self: super: rec {
          taffybar = pkgs.haskell.lib.overrideCabal (super.taffybar.overrideAttrs (oldAttrs: rec {
            src = ./.;
          })) (oldDerivation: {
            libraryHaskellDepends = oldDerivation.libraryHaskellDepends ++ [ self.broadcast-chan ];
          });
          broadcast-chan = pkgs.haskell.lib.overrideCabal super.broadcast-chan (_: {
            version = "0.2.0.2";
            sha256 = "12ax37y9i3cs8wifz01lpq0awm9c235l5xkybf13ywvyk5svb0jv";
            revision = null;
            editedCabalFile = null;
            broken = false;
          });
        };
      };
    };
  };
  pkgs = import <nixpkgs> { inherit config; };
in pkgs.haskellPackages.taffybar
