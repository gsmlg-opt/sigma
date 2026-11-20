{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: let
  pkgs-stable = import inputs.nixpkgs-stable {system = pkgs.stdenv.system;};
in {
  env.GREET = "Sigma";
  env.MIX_TAILWIND_PATH = "${pkgs-stable.tailwindcss_4}/bin/tailwindcss";
  env.MIX_BUN_PATH = "${pkgs-stable.bun}/bin/bun";
  env.NODE_PATH = "${config.git.root}/deps";

  packages = with pkgs-stable;
    [
      git
      figlet
      lolcat
      watchman
      tailwindcss_4
      deno
      pkg-config
      openssl
      cargo
      rustc
      stdenv.cc
      pkgs.beam28Packages.elixir-ls
    ]
    ++ lib.optionals stdenv.isLinux [
      bubblewrap
      inotify-tools
    ];

  languages.elixir.enable = true;
  # BEAM comes from devenv-nixpkgs (rolling): DuskMoon's precompiled NIFs
  # (duskmoon_vize >= 10.0.9) need glibc >= 2.43; release-26.05 has 2.42.
  languages.elixir.package = pkgs.beam28Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.pnpm.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  processes.sigma = {
    exec = "exec mix sigma.run";
    after = ["sigma:mix-tools"];
  };

  # devenv keeps MIX_HOME per project ($DEVENV_STATE/mix), so install Hex and
  # Rebar there non-interactively before Mix starts the server.
  tasks."sigma:mix-tools".exec = ''
    mix local.hex --force --if-missing
    mix local.rebar --force --if-missing
  '';

  enterShell = ''
    hello
  '';
}
