# personal fish flake
{
  description = "Minimal Fish shell flake";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: {
    nixosModules.myfish = import ./nix/module.nix { inherit self; };

    packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        default = pkgs.buildEnv {
          name = "my-fish-env";
          paths = with pkgs; [ fish starship fzf eza bat fd zoxide atuin lsd ];
        };
      }
    );
  };
}
