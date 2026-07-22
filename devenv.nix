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
      pkg-config
      openssl
      cargo
      rustc
      beam28Packages.elixir-ls
    ]
    ++ lib.optionals stdenv.isLinux [
      inotify-tools
    ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.pnpm.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  processes.sigma = {
    exec = "mix sigma.run";
  };

  enterShell = ''
    hello
  '';
}
