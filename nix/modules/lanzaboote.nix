{ lib, config, options, pkgs, ... }:
let
  cfg = config.boot.lanzaboote;

  sbctlWithPki = pkgs.sbctl.override {
    databasePath = "/tmp/pki";
  };

  loaderSettingsFormat = pkgs.formats.keyValue {
    mkKeyValue = k: v: if v == null then "" else
    lib.generators.mkKeyValueDefault { } " " k v;
  };

  loaderConfigFile = loaderSettingsFormat.generate "loader.conf" cfg.settings;

  configurationLimit = if cfg.configurationLimit == null then 0 else cfg.configurationLimit;
in
{
  options.boot.lanzaboote = {
    enable = lib.mkEnableOption "Enable the LANZABOOTE";

    enrollKeys = lib.mkEnableOption "Do not use this option. Only for used for integration tests! Automatic enrollment of the keys using sbctl";

    configurationLimit = lib.mkOption {
      default = config.boot.loader.systemd-boot.configurationLimit;
      defaultText = "config.boot.loader.systemd-boot.configurationLimit";
      example = 120;
      type = lib.types.nullOr lib.types.int;
      description = ''
        Maximum number of latest generations in the boot menu.
        Useful to prevent boot partition running out of disk space.

        `null` means no limit i.e. all generations
        that were not garbage collected yet.
      '';
    };

    pkiBundle = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      description = "PKI bundle containing db, PK, KEK";
    };

    publicKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.pkiBundle}/keys/db/db.pem";
      defaultText = "\${cfg.pkiBundle}/keys/db/db.pem";
      description = "Public key to sign your boot files";
    };

    privateKeyFile = lib.mkOption {
      type = lib.types.path;
      default = "${cfg.pkiBundle}/keys/db/db.key";
      defaultText = "\${cfg.pkiBundle}/keys/db/db.key";
      description = "Private key to sign your boot files";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.lzbt;
      defaultText = "pkgs.lzbt";
      description = "Lanzaboote tool (lzbt) package";
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = loaderSettingsFormat.type;
      };

      apply = lib.recursiveUpdate options.boot.lanzaboote.settings.default;

      default = {
        timeout = config.boot.loader.timeout;
        console-mode = config.boot.loader.systemd-boot.consoleMode;
        editor = config.boot.loader.systemd-boot.editor;
        default = "nixos-*";
      };

      defaultText = ''
        {
          timeout = config.boot.loader.timeout;
          console-mode = config.boot.loader.systemd-boot.consoleMode;
          editor = config.boot.loader.systemd-boot.editor;
          default = "nixos-*";
        }
      '';

      example = lib.literalExpression ''
        {
          editor = null; # null value removes line from the loader.conf
          beep = true;
          default = "@saved";
          timeout = 10;
        }
      '';

      description = ''
        Configuration for the `systemd-boot`

        See `loader.conf(5)` for supported values.
      '';
    };

    sortKey = lib.mkOption {
      default = "lanza";
      type = lib.types.str;
      description = ''
        The sort key used for the NixOS bootloader entries. This key determines
        sorting relative to non-NixOS entries. See also
        https://uapi-group.org/specifications/specs/boot_loader_specification/#sorting
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    boot.bootspec = {
      enable = true;
      extensions."org.nix-community.lanzaboote" = {
        sort_key = config.boot.lanzaboote.sortKey;
      };
    };
    boot.loader.supportsInitrdSecrets = true;
    boot.loader.external = {
      enable = true;
      installHook = pkgs.writeShellScript "bootinstall" ''
        ${lib.optionalString cfg.enrollKeys ''
          ${lib.getExe' pkgs.coreutils "mkdir"} -p /tmp/pki
          ${lib.getExe' pkgs.coreutils "cp"} -r ${cfg.pkiBundle}/* /tmp/pki
          ${lib.getExe sbctlWithPki} enroll-keys --yes-this-might-brick-my-machine
        ''}

        prof_dir="/nix/var/nix/profiles" profiles=""

        # Add all default system profiles, if any
        if [ "$(${lib.getExe pkgs.findutils} "$prof_dir" -type l -name 'system-*-link' \
                | ${lib.getExe' pkgs.coreutils "wc"} -l)" -gt 0 ]; then
          profiles+="$prof_dir/system-*-link "
        fi

        # Add all extra system profiles, if any
        if [ -d "$prof_dir/system-profiles" ] &&
            [ "$(${lib.getExe pkgs.findutils} \
                   "$prof_dir/system-profiles" -type l -name '*-*-link' \
                 | ${lib.getExe' pkgs.coreutils "wc"} -l)" -gt 0 ]; then
          profiles+="$prof_dir/system-profiles/*-*-link"
        fi

        # Display a clear error message if no usable profile can be found
        if [ "$profiles" = "" ]; then
          ${lib.getExe' pkgs.coreutils "printf"} "%s %s %s\n" \
            "Failed to find usable system profiles. Please make sure that" \
            "system profiles are present under $prof_dir/system-*-link and/or" \
            "$prof_dir/system-profiles/<profile-name>-*-link." 1>&2
          exit 1
        fi

        # Use the system from the kernel's hostPlatform because this should
        # always, even in the cross compilation case, be the right system.
        ${lib.getExe cfg.package} install \
          --system ${config.boot.kernelPackages.stdenv.hostPlatform.system} \
          --systemd ${config.systemd.package} \
          --systemd-boot-loader-config ${loaderConfigFile} \
          --public-key ${cfg.publicKeyFile} \
          --private-key ${cfg.privateKeyFile} \
          --configuration-limit ${toString configurationLimit} \
          ${config.boot.loader.efi.efiSysMountPoint} \
          $profiles
      '';
    };

    systemd.services.fwupd = lib.mkIf config.services.fwupd.enable {
      # Tell fwupd to load its efi files from /run
      environment.FWUPD_EFIAPPDIR = "/run/fwupd-efi";
    };

    systemd.services.fwupd-efi = lib.mkIf config.services.fwupd.enable {
      description = "Sign fwupd EFI app";
      # Exist with the lifetime of the fwupd service
      wantedBy = [ "fwupd.service" ];
      partOf = [ "fwupd.service" ];
      before = [ "fwupd.service" ];
      # Create runtime directory for signed efi app
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "fwupd-efi";
      };
      # Place the fwupd efi files in /run and sign them
      script = ''
        ln -sf ${config.services.fwupd.package.fwupd-efi}/libexec/fwupd/efi/fwupd*.efi /run/fwupd-efi/
        ${lib.getExe' pkgs.sbsigntool "sbsign"} --key '${cfg.privateKeyFile}' --cert '${cfg.publicKeyFile}' /run/fwupd-efi/fwupd*.efi
      '';
    };

    services.fwupd.uefiCapsuleSettings = lib.mkIf config.services.fwupd.enable {
      DisableShimForSecureBoot = true;
    };
  };
}
