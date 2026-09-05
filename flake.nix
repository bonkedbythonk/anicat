{
  description = "Anicat development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        # Anicat is a Swift package (AnicatApple/) over a Rust core (core/)
        # exposed through UniFFI. This flake provides only a dev shell for
        # the Rust side; the app itself is built with `swift build` on a Mac,
        # not Nix.
        devShells.default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              # Rust core
              rustc
              cargo
              pkg-config

              # Python scraper sidecar (scraper/ has its own uv project)
              uv

              # Media player
              mpv
            ]
            ++ lib.optionals stdenv.isLinux (
              with pkgs;
              [
                openssl
              ]
            )
            ++ lib.optionals stdenv.isDarwin (
              with pkgs;
              [
                libiconv
              ]
            );
        };
      }
    );
}
