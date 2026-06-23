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
        # Anicat is a Tauri (Rust) + React (Node) desktop app with a small
        # Python scraper sidecar. This flake provides only a dev shell — the
        # app is built with `npm run tauri build`, not Nix.
        devShells.default = pkgs.mkShell {
          packages =
            with pkgs;
            [
              # Frontend
              nodejs_22

              # Rust / Tauri backend
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
                # Tauri v2 system dependencies on Linux
                webkitgtk_4_1
                gtk3
                libsoup_3
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
