# Shared helpers for vars backends.
#
# The generate-vars logic (checking state, running prompts, executing generator
# scripts) is identical across backends -- only how files are stored and
# retrieved differs.  This module extracts the common parts so each backend
# only needs to supply a few storage-specific shell snippets.
{
  pkgs,
  lib,
  config,
}:
let
  sortedGenerators =
    (lib.toposort (a: b: builtins.elem a.name b.dependencies) (lib.attrValues config.vars.generators))
    .result;

  promptCmd = {
    hidden = "read -sr prompt_value";
    line = "read -r prompt_value";
    multiline = ''
      echo 'press control-d to finish'
      prompt_value=$(cat)
    '';
  };
in
{
  inherit sortedGenerators;

  /**
    Build a `generate-vars` script parameterised by backend-specific hooks.

    mkGenerateVars :: { ... } -> package

    # Inputs

    `name`

    : Name for the resulting script (default: `"generate-vars"`)

    `runtimeInputs`

    : Extra packages to add to the wrapper's PATH

    `preamble`

    : Shell code run once at the top (e.g. auth setup)

    `checkFileExists`

    : `gen -> file -> string` -- shell snippet that sets exit code 0 when
      the file already exists in the backend store

    `fetchDependency`

    : `dep -> file -> string` -- shell snippet that fetches a dependency
      file into `"$in"/<dep>/<file.name>`

    `uploadFile`

    : `gen -> file -> string` -- shell snippet run after generation to
      persist `"$out"/<file.name>` to the backend store
  */
  mkGenerateVars =
    {
      name ? "generate-vars",
      runtimeInputs ? [ ],
      preamble ? "",
      checkFileExists,
      fetchDependency,
      uploadFile,
    }:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [ pkgs.coreutils ] ++ runtimeInputs;
      text = ''
        ${preamble}

        ${lib.concatMapStringsSep "\n" (
          gen:
          let
            templates = lib.filter (file: file.template != null) (lib.attrValues gen.files);
          in
          ''
            all_files_missing=true
            all_files_present=true
            echo "Checking vars for ${gen.name}..."
            ${lib.concatMapStringsSep "\n" (file: ''
              if ${checkFileExists gen file}; then
                all_files_missing=false
              else
                all_files_present=false
              fi
            '') (lib.attrValues gen.files)}

            out=$(mktemp -d)
            trap 'rm -rf $out' EXIT
            export out
            mkdir -p "$out"

            if [ "$all_files_missing" = false ] && [ "$all_files_present" = false ]; then
              echo "Inconsistent state for generator: ${gen.name}"
              exit 1
            fi
            if [ "$all_files_present" = true ]; then
              echo "All secrets for ${gen.name} are present"
            elif [ "$all_files_missing" = true ]; then
              prompts=$(mktemp -d)
              trap 'rm -rf $prompts' EXIT
              export prompts
              mkdir -p "$prompts"
              ${lib.concatMapStringsSep "\n" (prompt: ''
                echo ${lib.escapeShellArg prompt.description}
                ${promptCmd.${prompt.type}}
                echo -n "$prompt_value" > "$prompts"/${prompt.name}
              '') (lib.attrValues gen.prompts)}
              echo "Generating vars for ${gen.name}"
            fi

            # dependencies
            in=$(mktemp -d)
            export in
            trap 'rm -rf $in' EXIT
            mkdir -p "$in"
            ${lib.concatMapStringsSep "\n" (dep: ''
              mkdir -p "$in"/${dep}
              ${lib.concatMapStringsSep "\n" (
                file: fetchDependency dep file
              ) (lib.attrValues config.vars.generators.${dep}.files)}
            '') gen.dependencies}

            # templates
            templates=$(mktemp -d)
            trap 'rm -rf $templates' EXIT
            export templates
            mkdir -p "$templates"
            ${lib.concatMapStringsSep "\n" (file: ''
              cp ${lib.escapeShellArg (toString file.template)} "$templates"/${file.name}
            '') templates}

            # generate if all files are missing or we have templates to re-render
            # shellcheck disable=SC2078
            if [ "$all_files_missing" = true ] || [ "${lib.concatMapStringsSep "" (file: file.name) templates}" ]; then
              (
                unset PATH
                ${lib.optionalString (gen.runtimeInputs != [ ]) ''
                  PATH=${lib.makeBinPath gen.runtimeInputs}
                  export PATH
                ''}
                ${gen.script}
              )

              ${lib.concatMapStringsSep "\n" (file: ''
                if ! test -e "$out"/${file.name}; then
                  echo 'generator ${gen.name} failed to generate ${file.name}'
                  exit 1
                fi
              '') (lib.attrValues gen.files)}

              ${lib.concatMapStringsSep "\n" (file: uploadFile gen file) (lib.attrValues gen.files)}
            fi

            rm -rf "$out"
          ''
        ) sortedGenerators}
      '';
    };
}
