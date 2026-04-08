# On-machine vars backend.
# Generates secrets and stores them directly on the local filesystem.
# Run `generate-vars` after updating the system to create the required values.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.vars.settings.on-machine;

  varsLib = import ../lib.nix { inherit pkgs lib config; };

  filePath =
    file:
    "${cfg.fileLocation}/${if file.secret then "secret" else "public"}/${file.generator}/${file.name}";

  generate-vars = varsLib.mkGenerateVars {
    preamble = ''
      OUT_DIR=''${OUT_DIR:-${cfg.fileLocation}}
    '';
    checkFileExists = _gen: file: ''
      test -e "$OUT_DIR"/${if file.secret then "secret" else "public"}/${file.generator}/${file.name}
    '';
    fetchDependency = dep: file: ''
      cp "$OUT_DIR"/${if file.secret then "secret" else "public"}/${dep}/${file.name} "$in"/${dep}/${file.name}
    '';
    uploadFile = _gen: file: ''
      OUT_FILE="$OUT_DIR"/${if file.secret then "secret" else "public"}/${file.generator}/${file.name}
      mkdir -p "$(dirname "$OUT_FILE")"
      mv "$out"/${file.name} "$OUT_FILE"
      chown ${file.owner}:${file.group} "$OUT_FILE"
      chmod ${file.mode} "$OUT_FILE"
    '';
  };
in
{
  options.vars.settings.on-machine = {
    enable = lib.mkEnableOption "Enable on-machine vars backend";
    fileLocation = lib.mkOption {
      type = lib.types.str;
      default = "/etc/vars";
    };
  };

  config = lib.mkIf cfg.enable {
    vars.settings.fileModule = file: {
      path = filePath file.config;
    };

    environment.systemPackages = [ generate-vars ];
    system.build.generate-vars = generate-vars;

    systemd.services.generate-vars = {
      wantedBy = [ "multi-user.target" ];
      after = [ "default.target" ];
      description = "generate needed secrets";
      serviceConfig.ExecStart = "${generate-vars}/bin/generate-vars";
    };
  };
}
