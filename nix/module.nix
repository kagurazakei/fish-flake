{ self }: {
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.rum.programs.fish;
in {
  options.rum.programs.fish = {
    enable = lib.mkEnableOption "Enable Fish shell and configuration";

    defaultShell = lib.mkEnableOption "Set Fish as the default shell";

    mainUser = lib.mkOption {
      type = lib.types.str;
      default = "antonio";
      description = "Username to set Fish shell for";
    };

    wrapperPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
      description = "Extra packages wrapped in Fish shell env";
    };

    plugins = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "List of fisher plugins to install";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [
      fish fzf starship eza bat fd zoxide atuin g-ls
    ] ++ cfg.wrapperPackages;

    # Symlink fish config (except completions-extra)
    hj.files = {
      ".config/fish/functions".source = "${self}/fish-config/functions";
      ".config/fish/completions".source = "${self}/fish-config/completions";
      ".config/fish/conf.d".source = "${self}/fish-config/conf.d";
      ".config/fish/themes".source = "${self}/fish-config/themes";
      ".config/fish/abbreviations.fish".source = "${self}/fish-config/abbreviations.fish";
      ".config/fish/aliases.fish".source = "${self}/fish-config/aliases.fish";
      ".config/fish/fish_plugins".source = "${self}/fish-config/fish_plugins";
      ".config/fish/user_variables.fish".source = "${self}/fish-config/user_variables.fish";
      ".config/fish/config.fish".source = "${self}/fish-config/config.fish";
    };

    # Ensure completions-extra exists for user-managed completions
    system.activationScripts.ensureFishWritableCompletions = lib.stringAfter [ "users" ] ''
      mkdir -p /home/${cfg.mainUser}/.config/fish/completions-extra
      chown ${cfg.mainUser}:${cfg.mainUser} /home/${cfg.mainUser}/.config/fish/completions-extra
      chmod 755 /home/${cfg.mainUser}/.config/fish/completions-extra
    '';

    # Set default shell
    system.activationScripts.setFishShell = lib.mkIf cfg.defaultShell ''
      if [ "$(getent passwd ${cfg.mainUser} | cut -d: -f7)" != "${pkgs.fish}/bin/fish" ]; then
        echo "Setting fish as default shell for ${cfg.mainUser}"
        chsh -s ${pkgs.fish}/bin/fish ${cfg.mainUser}
      fi
    '';

    # Install fisher plugins
    system.activationScripts.installFisher = lib.mkIf (cfg.plugins != []) ''
      echo "Installing fisher plugins for fish..."
      export HOME=/home/${cfg.mainUser}
      sudo -u ${cfg.mainUser} fish -c 'fisher install ${lib.concatStringsSep " " cfg.plugins}'
    '';
  };
}


