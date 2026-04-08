# OpenBao (open-source Vault fork) backend for vars.
# Secrets are generated locally then stored in an OpenBao KV v2 mount.
# At boot, a systemd service fetches them into a tmpfs directory so that
# the rest of the system can read them as ordinary files.
#
# Usage:
#   1. Enable the backend and point it at your OpenBao instance.
#   2. Run `generate-vars` once (as root, or with VAULT_TOKEN set) to
#      generate secrets and push them into OpenBao.
#   3. On subsequent boots the `fetch-vars` service pulls them back down.
{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.vars.settings.openbao;

  varsLib = import ../lib.nix { inherit pkgs lib config; };

  # KV path for a file within the configured mount.
  kvPath = gen: file:
    "${cfg.prefix}/${if file.secret then "secret" else "public"}/${gen.name}/${file.name}";

  # Shell snippet that sets VAULT_ADDR and VAULT_TOKEN.
  authEnv = ''
    export VAULT_ADDR="''${VAULT_ADDR:-${cfg.address}}"
    export VAULT_TOKEN
    VAULT_TOKEN=$(< ${lib.escapeShellArg cfg.tokenFile})
  '';

  generate-vars = varsLib.mkGenerateVars {
    runtimeInputs = [ pkgs.openbao ];
    preamble = authEnv;
    checkFileExists = gen: file: ''
      bao kv get \
        -mount=${lib.escapeShellArg cfg.mount} \
        -field=content \
        ${lib.escapeShellArg (kvPath gen file)} > /dev/null 2>&1
    '';
    fetchDependency = dep: file: ''
      bao kv get \
        -mount=${lib.escapeShellArg cfg.mount} \
        -field=content \
        ${lib.escapeShellArg "${cfg.prefix}/${if file.secret then "secret" else "public"}/${dep}/${file.name}"} \
        | base64 -d > "$in"/${dep}/${file.name}
    '';
    uploadFile = gen: file: ''
      bao kv put \
        -mount=${lib.escapeShellArg cfg.mount} \
        ${lib.escapeShellArg (kvPath gen file)} \
        content="$(base64 < "$out"/${file.name})"
    '';
  };

  # Runs at boot: pulls all secrets from OpenBao and writes them to tmpDir.
  fetch-vars = pkgs.writeShellApplication {
    name = "fetch-vars";
    runtimeInputs = [
      pkgs.openbao
      pkgs.coreutils
    ];
    text = ''
      ${authEnv}

      ${lib.concatMapStringsSep "\n" (
        gen:
        lib.concatMapStringsSep "\n" (file:
          let
            dest = lib.escapeShellArg "${cfg.tmpDir}/${if file.secret then "secret" else "public"}/${gen.name}/${file.name}";
          in
          ''
            mkdir -p "$(dirname ${dest})"
            bao kv get \
              -mount=${lib.escapeShellArg cfg.mount} \
              -field=content \
              ${lib.escapeShellArg (kvPath gen file)} \
              | base64 -d > ${dest}
            chown ${file.owner}:${file.group} ${dest}
            chmod ${file.mode} ${dest}
          ''
        ) (lib.attrValues gen.files)
      ) varsLib.sortedGenerators}
    '';
  };
in
{
  options.vars.settings.openbao = {
    enable = lib.mkEnableOption "OpenBao vars backend";

    address = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:8200";
      description = "OpenBao server address (VAULT_ADDR compatible).";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      description = ''
        Path to a file containing the OpenBao token.
        The token must have read/write access to the configured KV mount.
        For the generate step the token needs write access; for the fetch
        service at boot it only needs read access, so you can use two
        different policies/tokens if desired.
      '';
    };

    mount = lib.mkOption {
      type = lib.types.str;
      default = "secret";
      description = "KV v2 mount point in OpenBao.";
    };

    prefix = lib.mkOption {
      type = lib.types.str;
      default = "vars";
      description = "Path prefix within the KV mount used for all vars entries.";
    };

    tmpDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/vars";
      description = ''
        Directory where fetched secrets are written at boot.
        This should be on a tmpfs so secrets are not persisted across reboots.
        Defaults to /run/vars which is already on tmpfs on NixOS.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    vars.settings.fileModule = file: {
      path = "${cfg.tmpDir}/${if file.config.secret then "secret" else "public"}/${file.config.generator}/${file.config.name}";
    };

    environment.systemPackages = [ generate-vars ];
    system.build.generate-vars = generate-vars;

    systemd.services.fetch-vars = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      before = [ "default.target" ];
      description = "Fetch secrets from OpenBao";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${fetch-vars}/bin/fetch-vars";
      };
    };
  };
}
