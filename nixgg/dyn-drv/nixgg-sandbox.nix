# Run a nixgg-style build inside a Nix sandbox and expose its final
# output as a dynamic derivation.
#
# Shape of the chain:
#
#   nixggBuild — outer derivation. Compiles hello.c → hello.o →
#                hello via nixgg shims. Instantiates the final link
#                thunk into a .drv file inside the sandbox. Submits
#                that .drv as its `out`.
#
#   binary     — consumer. `builtins.outputOf nixggBuild.outPath "out"`
#                gives a placeholder for whatever the inner .drv will
#                produce. Nix resolves the chain: build nixggBuild →
#                read the .drv → build the inner → return `hello`.
#
# Key mechanism: `nix-instantiate <thunk.nix>` inside the sandbox
# turns the thunk's `srcTree = /tmp/.../foo` path literal into a
# store-path reference in the resulting .drv. The absolute paths
# in the thunk file don't need to survive the sandbox — the .drv
# does.
{
  pkgs ? import <nixpkgs> { },
  patchedNix,
  nixgg,       # store path containing bin/nixgg + shims/
  nixHelpers,  # store path with builder.nix, linker.nix, etc.
}:
let
  cfg = import ./config.nix { inherit pkgs; };

  # The single source file. builtins.path adds it to the store, so
  # `$src` is available inside the sandbox at a stable location.
  helloSrc = builtins.path {
    name = "hello-src";
    path = ./.;
    filter = path: type: baseNameOf path == "hello.cc";
  };

  # Outer derivation: sandbox running nixgg over hello.cc.
  #
  # outputHashMode="text" + name ending in .drv tells Nix "my output
  # is a derivation file, not a build artifact." That's what makes
  # this a *dynamic* derivation from the consumer's point of view.
  nixggBuild = derivation {
    name = "hello.drv";
    system = builtins.currentSystem;

    __contentAddressed = true;
    outputHashMode = "text";
    outputHashAlgo = "sha256";

    builder = cfg.shell;
    # Real toolchain must come from the same store paths nixHelpers
    # baked in — don't use cfg.path (which uses <nixpkgs>).
    PATH = builtins.concatStringsSep ":" [
      "${nixgg}/bin"
      "${nixgg}/shims"
      "${patchedNix}/bin"
      "${builtins.storePath /nix/store/adcz0m6qq2flmshdf0zz2xwjr5zbq1gr-gcc-wrapper-15.3.0}/bin"
      "${builtins.storePath /nix/store/mp8s10fwm685azvvv1qq7zyf7iajjlj8-coreutils-9.11}/bin"
      "${builtins.storePath /nix/store/dddwfz7nph37q3cjky9lhpy9kb90rrrx-bash-interactive-5.3p15}/bin"
    ];

    # Env vars the shim reads (mirrors what `nixgg env` prints).
    # Must be the SAME store paths nixHelpers references, so the
    # child derivations' string interpolations match sandbox mounts.
    NIXGG_COMPILER_ROOT = "${builtins.storePath /nix/store/adcz0m6qq2flmshdf0zz2xwjr5zbq1gr-gcc-wrapper-15.3.0}";
    NIXGG_BASH_ROOT = "${builtins.storePath /nix/store/dddwfz7nph37q3cjky9lhpy9kb90rrrx-bash-interactive-5.3p15}";
    NIXGG_COREUTILS_ROOT = "${builtins.storePath /nix/store/mp8s10fwm685azvvv1qq7zyf7iajjlj8-coreutils-9.11}";
    NIXGG_GNUMAKE_ROOT = "${builtins.storePath /nix/store/66x1qiph890315003f27a15xsqax6lwf-gnumake-4.4.1}";
    NIXGG_NIX = "${patchedNix}/bin/nix";
    NIXGG_NIX_HELPERS = "${nixHelpers}";
    NIXGG_REAL_CC = "${builtins.storePath /nix/store/adcz0m6qq2flmshdf0zz2xwjr5zbq1gr-gcc-wrapper-15.3.0}/bin/g++";
    # Inside the sandbox, the daemon socket points at the outer nix's
    # store. Setting NIXGG_STORE to "auto" tells nixgg to use whatever
    # NIX_REMOTE / NIX_CONFIG dictates (which the sandbox controls).
    NIXGG_STORE = "auto";

    src = helloSrc;

    # Pull toolchain paths into the sandbox by referencing them from
    # a string-valued env var. Nix tracks string-context, so these
    # store paths become sandbox inputs. Without this the inner
    # nix-instantiate can't see gcc/coreutils/bash to resolve the
    # thunks it walks.
    #
    # This must include every store path baked into nixHelpers's
    # pure-store-path.nix — otherwise linker.nix / builder.nix
    # reference paths that aren't mounted.
    TOOLCHAIN_STORE_PATHS = builtins.concatStringsSep " " [
      "${builtins.storePath /nix/store/adcz0m6qq2flmshdf0zz2xwjr5zbq1gr-gcc-wrapper-15.3.0}"
      "${builtins.storePath /nix/store/dddwfz7nph37q3cjky9lhpy9kb90rrrx-bash-interactive-5.3p15}"
      "${builtins.storePath /nix/store/mp8s10fwm685azvvv1qq7zyf7iajjlj8-coreutils-9.11}"
      "${builtins.storePath /nix/store/66x1qiph890315003f27a15xsqax6lwf-gnumake-4.4.1}"
      "${nixgg}"
      "${nixHelpers}"
      "${patchedNix}"
    ];

    args = [
      "-c"
      ''
        set -euo pipefail
        export CC=cc CXX=c++
        export NIXGG_ROOT="${nixgg}"


        # The inner nix-instantiate needs ca-derivations for the CA
        # thunks and dynamic-derivations for emit-as-drv. Also crucial:
        # disable substituters and signature checking. The sandbox has
        # no network and no /nix/var/nix db; every path a thunk
        # references is already mounted by our TOOLCHAIN_STORE_PATHS
        # trick, so we don't want nix trying to download or verify
        # anything.
        export NIX_CONFIG='
          extra-experimental-features = nix-command ca-derivations dynamic-derivations
          substituters =
          require-sigs = false
          trusted-substituters =
        '

        # NIXGG_AUTOFORCE off: we don't want the shim to call nix
        # build itself. We handle instantiate+submit at the end.

        # Sandbox tmp is writable; use it as the project root.
        mkdir -p work
        cp $src/hello.cc work/hello.cc
        cd work

        # Compile + link. Shims fire, write thunks under .nixgg/thunks/.
        c++ -O2 -c hello.cc -o hello.o
        c++ hello.o -o hello

        # `hello` is now a symlink to a link-thunk .nix file.
        linkThunk="$(readlink -f hello)"
        echo "link thunk: $linkThunk" >&2

        # Instantiate (no --realize). Just evaluates the .nix
        # expression, walks sibling imports, and writes .drv files
        # into the store via the RPC. Doesn't build anything.
        #
        # --store points inside the sandbox's /nix/store view; we
        # can't use /nix/var/nix (there's no db). The RPC daemon
        # accepts `nix store add` here, which is what
        # `derivationStrict` uses under the hood to register drvs.
        drvPath=$(nix-instantiate --store daemon --impure "$linkThunk")
        echo "instantiated: $drvPath" >&2

        # Submit the emitted .drv as our output. Nix will resolve
        # (build) it when the consumer's `outputOf` reference is
        # dereferenced.
        nix store submit-output "$drvPath" out
      ''
    ];
  };
in
{
  inherit nixggBuild;

  # Consumer: outputOf resolves the chain at build time.
  binary = builtins.outputOf nixggBuild.outPath "out";
}
