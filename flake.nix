{
  description = "Serialization of cryptographic data types";
  inputs.haskellNix.url = "github:input-output-hk/haskell.nix";
  inputs.nixpkgs.follows = "haskellNix/nixpkgs-unstable";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  outputs = { self, nixpkgs, flake-utils, haskellNix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "x86_64-darwin" "aarch64-darwin" ] (system:
    let
      compiler-nix-name = "ghc928";
      overlays = [haskellNix.overlay (final: prev: {
        cryptostore-crypton =
          final.haskell-nix.cabalProject' {
            src = ./.;
            inherit compiler-nix-name;
            
            shell.tools = {
              cabal = {};
              ghcid = {};
              haskell-language-server = {};
            };
            shell.buildInputs = [ ];
          };
      })];
      pkgs = import nixpkgs { inherit system overlays; };
      flake = pkgs.cryptostore-crypton.flake { } ;
    in flake
    );
}
