{
  description = "The purely functional package manager";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  inputs.nixpkgs-regression.url = "github:NixOS/nixpkgs/215d4d0fd80ca5163643b03a33fde804a29cc1e2";
  inputs.nixpkgs-23-11.url = "github:NixOS/nixpkgs/a62e6edd6d5e1fa0329b8653c801147986f8d446";
  inputs.flake-compat = {
    url = "github:edolstra/flake-compat";
    flake = false;
  };

  # dev tooling
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.git-hooks-nix.url = "github:cachix/git-hooks.nix";
  # work around https://github.com/NixOS/nix/issues/7730
  inputs.flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  inputs.git-hooks-nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.git-hooks-nix.inputs.nixpkgs-stable.follows = "nixpkgs";
  # work around 7730 and https://github.com/NixOS/nix/issues/7807
  inputs.git-hooks-nix.inputs.flake-compat.follows = "";
  inputs.git-hooks-nix.inputs.gitignore.follows = "";

  outputs =
    inputs@{
      self,
      nixpkgs,
      nixpkgs-regression,
      ...
    }:

    let
      inherit (nixpkgs) lib;

      officialRelease = false;

      linux32BitSystems = [ "i686-linux" ];
      linux64BitSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      linuxSystems = linux32BitSystems ++ linux64BitSystems;
      darwinSystems = [
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      systems = linuxSystems ++ darwinSystems;

      crossSystems = [
        "armv6l-unknown-linux-gnueabihf"
        "armv7l-unknown-linux-gnueabihf"
        "riscv64-unknown-linux-gnu"
        # Disabled because of https://github.com/NixOS/nixpkgs/issues/344423
        # "x86_64-unknown-netbsd"
        "x86_64-unknown-freebsd"
        "x86_64-w64-mingw32"
      ];

      stdenvs = [
        "ccacheStdenv"
        "clangStdenv"
        "gccStdenv"
        "libcxxStdenv"
        "stdenv"
      ];

      /**
        `flatMapAttrs attrs f` applies `f` to each attribute in `attrs` and
        merges the results into a single attribute set.

        This can be nested to form a build matrix where all the attributes
        generated by the innermost `f` are returned as is.
        (Provided that the names are unique.)

        See https://nixos.org/manual/nixpkgs/stable/index.html#function-library-lib.attrsets.concatMapAttrs
      */
      flatMapAttrs = attrs: f: lib.concatMapAttrs f attrs;

      forAllSystems = lib.genAttrs systems;

      forAllCrossSystems = lib.genAttrs crossSystems;

      forAllStdenvs = lib.genAttrs stdenvs;

      # We don't apply flake-parts to the whole flake so that non-development attributes
      # load without fetching any development inputs.
      devFlake = inputs.flake-parts.lib.mkFlake { inherit inputs; } {
        imports = [ ./maintainers/flake-module.nix ];
        systems = lib.subtractLists crossSystems systems;
        perSystem =
          { system, ... }:
          {
            _module.args.pkgs = nixpkgsFor.${system}.native;
          };
      };

      # Memoize nixpkgs for different platforms for efficiency.
      nixpkgsFor = forAllSystems (
        system:
        let
          make-pkgs =
            crossSystem:
            forAllStdenvs (
              stdenv:
              import nixpkgs {
                localSystem = {
                  inherit system;
                };
                crossSystem =
                  if crossSystem == null then
                    null
                  else
                    {
                      config = crossSystem;
                    }
                    // lib.optionalAttrs (crossSystem == "x86_64-unknown-freebsd13") {
                      useLLVM = true;
                    };
                overlays = [
                  (overlayFor (pkgs: pkgs.${stdenv}))
                ];
              }
            );
        in
        rec {
          nativeForStdenv = make-pkgs null;
          crossForStdenv = forAllCrossSystems make-pkgs;
          # Alias for convenience
          native = nativeForStdenv.stdenv;
          cross = forAllCrossSystems (crossSystem: crossForStdenv.${crossSystem}.stdenv);
        }
      );

      /**
        Produce the `nixComponents` and `nixDependencies` package sets (scopes) for
        a given `pkgs` and `getStdenv`.
      */
      packageSetsFor =
        let
          /**
            Removes a prefix from the attribute names of a set of splices.
            This is a completely uninteresting and exists for compatibility only.

            Example:
            ```nix
            renameSplicesFrom "pkgs" { pkgsBuildBuild = ...; ... }
            => { buildBuild = ...; ... }
            ```
          */
          renameSplicesFrom = prefix: x: {
            buildBuild = x."${prefix}BuildBuild";
            buildHost = x."${prefix}BuildHost";
            buildTarget = x."${prefix}BuildTarget";
            hostHost = x."${prefix}HostHost";
            hostTarget = x."${prefix}HostTarget";
            targetTarget = x."${prefix}TargetTarget";
          };

          /**
            Adds a prefix to the attribute names of a set of splices.
            This is a completely uninteresting and exists for compatibility only.

            Example:
            ```nix
            renameSplicesTo "self" { buildBuild = ...; ... }
            => { selfBuildBuild = ...; ... }
            ```
          */
          renameSplicesTo = prefix: x: {
            "${prefix}BuildBuild" = x.buildBuild;
            "${prefix}BuildHost" = x.buildHost;
            "${prefix}BuildTarget" = x.buildTarget;
            "${prefix}HostHost" = x.hostHost;
            "${prefix}HostTarget" = x.hostTarget;
            "${prefix}TargetTarget" = x.targetTarget;
          };

          /**
            Takes a function `f` and returns a function that applies `f` pointwise to each splice.

            Example:
            ```nix
            mapSplices (x: x * 10) { buildBuild = 1; buildHost = 2; ... }
            => { buildBuild = 10; buildHost = 20; ... }
            ```
          */
          mapSplices =
            f:
            {
              buildBuild,
              buildHost,
              buildTarget,
              hostHost,
              hostTarget,
              targetTarget,
            }:
            {
              buildBuild = f buildBuild;
              buildHost = f buildHost;
              buildTarget = f buildTarget;
              hostHost = f hostHost;
              hostTarget = f hostTarget;
              targetTarget = f targetTarget;
            };

        in
        args@{
          pkgs,
          getStdenv ? pkgs: pkgs.stdenv,
        }:
        let
          nixComponentsSplices = mapSplices (
            pkgs': (packageSetsFor (args // { pkgs = pkgs'; })).nixComponents
          ) (renameSplicesFrom "pkgs" pkgs);
          nixDependenciesSplices = mapSplices (
            pkgs': (packageSetsFor (args // { pkgs = pkgs'; })).nixDependencies
          ) (renameSplicesFrom "pkgs" pkgs);

          # A new scope, so that we can use `callPackage` to inject our own interdependencies
          # without "polluting" the top level "`pkgs`" attrset.
          # This also has the benefit of providing us with a distinct set of packages
          # we can iterate over.
          nixComponents =
            lib.makeScopeWithSplicing'
              {
                inherit (pkgs) splicePackages;
                inherit (nixDependencies) newScope;
              }
              {
                otherSplices = renameSplicesTo "self" nixComponentsSplices;
                f = import ./packaging/components.nix {
                  inherit (pkgs) lib;
                  inherit officialRelease;
                  inherit pkgs;
                  src = self;
                  maintainers = [ ];
                };
              };

          # The dependencies are in their own scope, so that they don't have to be
          # in Nixpkgs top level `pkgs` or `nixComponents2`.
          nixDependencies =
            lib.makeScopeWithSplicing'
              {
                inherit (pkgs) splicePackages;
                inherit (pkgs) newScope; # layered directly on pkgs, unlike nixComponents2 above
              }
              {
                otherSplices = renameSplicesTo "self" nixDependenciesSplices;
                f = import ./packaging/dependencies.nix {
                  inherit inputs pkgs;
                  stdenv = getStdenv pkgs;
                };
              };

          # If the package set is largely empty, we should(?) return empty sets
          # This is what most package sets in Nixpkgs do. Otherwise, we get
          # an error message that indicates that some stdenv attribute is missing,
          # and indeed it will be missing, as seemingly `pkgsTargetTarget` is
          # very incomplete.
          fixup = lib.mapAttrs (k: v: if !(pkgs ? nix) then { } else v);
        in
        fixup {
          inherit nixDependencies;
          inherit nixComponents;
        };

      overlayFor =
        getStdenv: final: prev:
        let
          packageSets = packageSetsFor {
            inherit getStdenv;
            pkgs = final;
          };
        in
        {
          nixStable = prev.nix;

          # The `2` suffix is here because otherwise it interferes with `nixVersions.latest`, which is used in daemon compat tests.
          nixComponents2 = packageSets.nixComponents;

          # The dependencies are in their own scope, so that they don't have to be
          # in Nixpkgs top level `pkgs` or `nixComponents2`.
          # The `2` suffix is here because otherwise it interferes with `nixVersions.latest`, which is used in daemon compat tests.
          nixDependencies2 = packageSets.nixDependencies;

          nix = final.nixComponents2.nix-cli;
        };

    in
    {
      overlays.internal = overlayFor (p: p.stdenv);

      /**
        A Nixpkgs overlay that sets `nix` to something like `packages.<system>.nix-everything`,
        except dependencies aren't taken from (flake) `nix.inputs.nixpkgs`, but from the Nixpkgs packages
        where the overlay is used.
      */
      overlays.default =
        final: prev:
        let
          packageSets = packageSetsFor { pkgs = final; };
        in
        {
          nix = packageSets.nixComponents.nix-everything;
        };

      hydraJobs = import ./packaging/hydra.nix {
        inherit
          inputs
          forAllCrossSystems
          forAllSystems
          lib
          linux64BitSystems
          nixpkgsFor
          self
          officialRelease
          ;
      };

      checks = forAllSystems (
        system:
        {
          installerScriptForGHA = self.hydraJobs.installerScriptForGHA.${system};
          installTests = self.hydraJobs.installTests.${system};
          nixpkgsLibTests = self.hydraJobs.tests.nixpkgsLibTests.${system};
          rl-next =
            let
              pkgs = nixpkgsFor.${system}.native;
            in
            pkgs.buildPackages.runCommand "test-rl-next-release-notes" { } ''
              LANG=C.UTF-8 ${pkgs.changelog-d}/bin/changelog-d ${./doc/manual/rl-next} >$out
            '';
          repl-completion = nixpkgsFor.${system}.native.callPackage ./tests/repl-completion.nix { };

          /**
            Checks for our packaging expressions.
            This shouldn't build anything significant; just check that things
            (including derivations) are _set up_ correctly.
          */
          packaging-overriding =
            let
              pkgs = nixpkgsFor.${system}.native;
              nix = self.packages.${system}.nix;
            in
            assert (nix.appendPatches [ pkgs.emptyFile ]).libs.nix-util.src.patches == [ pkgs.emptyFile ];
            if pkgs.stdenv.buildPlatform.isDarwin then
              lib.warn "packaging-overriding check currently disabled because of a permissions issue on macOS" pkgs.emptyFile
            else
              # If this fails, something might be wrong with how we've wired the scope,
              # or something could be broken in Nixpkgs.
              pkgs.testers.testEqualContents {
                assertion = "trivial patch does not change source contents";
                expected = "${./.}";
                actual =
                  # Same for all components; nix-util is an arbitrary pick
                  (nix.appendPatches [ pkgs.emptyFile ]).libs.nix-util.src;
              };
        }
        // (lib.optionalAttrs (builtins.elem system linux64BitSystems)) {
          dockerImage = self.hydraJobs.dockerImage.${system};
        }
        // (lib.optionalAttrs (!(builtins.elem system linux32BitSystems))) {
          # Some perl dependencies are broken on i686-linux.
          # Since the support is only best-effort there, disable the perl
          # bindings
          perlBindings = self.hydraJobs.perlBindings.${system};
        }
        # Add "passthru" tests
        //
          flatMapAttrs
            (
              {
                # Run all tests with UBSAN enabled. Running both with ubsan and
                # without doesn't seem to have much immediate benefit for doubling
                # the GHA CI workaround.
                #
                # TODO: Work toward enabling "address,undefined" if it seems feasible.
                # This would maybe require dropping Boost coroutines and ignoring intentional
                # memory leaks with detect_leaks=0.
                "" = rec {
                  nixpkgs = nixpkgsFor.${system}.native;
                  nixComponents = nixpkgs.nixComponents2.overrideScope (
                    nixCompFinal: nixCompPrev: {
                      mesonComponentOverrides = _finalAttrs: prevAttrs: {
                        mesonFlags =
                          (prevAttrs.mesonFlags or [ ])
                          # TODO: Macos builds instrumented with ubsan take very long
                          # to run functional tests.
                          ++ lib.optionals (!nixpkgs.stdenv.hostPlatform.isDarwin) [
                            (lib.mesonOption "b_sanitize" "undefined")
                          ];
                      };
                    }
                  );
                };
              }
              // lib.optionalAttrs (!nixpkgsFor.${system}.native.stdenv.hostPlatform.isDarwin) {
                # TODO: enable static builds for darwin, blocked on:
                #       https://github.com/NixOS/nixpkgs/issues/320448
                # TODO: disabled to speed up GHA CI.
                # "static-" = {
                #   nixpkgs = nixpkgsFor.${system}.native.pkgsStatic;
                # };
              }
            )
            (
              nixpkgsPrefix:
              {
                nixpkgs,
                nixComponents ? nixpkgs.nixComponents2,
              }:
              flatMapAttrs nixComponents (
                pkgName: pkg:
                flatMapAttrs pkg.tests or { } (
                  testName: test: {
                    "${nixpkgsPrefix}${pkgName}-${testName}" = test;
                  }
                )
              )
              // lib.optionalAttrs (nixpkgs.stdenv.hostPlatform == nixpkgs.stdenv.buildPlatform) {
                "${nixpkgsPrefix}nix-functional-tests" = nixComponents.nix-functional-tests;
              }
            )
        // devFlake.checks.${system} or { }
      );

      packages = forAllSystems (
        system:
        {
          # Here we put attributes that map 1:1 into packages.<system>, ie
          # for which we don't apply the full build matrix such as cross or static.
          inherit (nixpkgsFor.${system}.native)
            changelog-d
            ;
          default = self.packages.${system}.nix;
          installerScriptForGHA = self.hydraJobs.installerScriptForGHA.${system};
          binaryTarball = self.hydraJobs.binaryTarball.${system};
          # TODO probably should be `nix-cli`
          nix = self.packages.${system}.nix-everything;
          nix-manual = nixpkgsFor.${system}.native.nixComponents2.nix-manual;
          nix-internal-api-docs = nixpkgsFor.${system}.native.nixComponents2.nix-internal-api-docs;
          nix-external-api-docs = nixpkgsFor.${system}.native.nixComponents2.nix-external-api-docs;
        }
        # We need to flatten recursive attribute sets of derivations to pass `flake check`.
        //
          flatMapAttrs
            {
              # Components we'll iterate over in the upcoming lambda
              "nix-util" = { };
              "nix-util-c" = { };
              "nix-util-test-support" = { };
              "nix-util-tests" = { };

              "nix-store" = { };
              "nix-store-c" = { };
              "nix-store-test-support" = { };
              "nix-store-tests" = { };

              "nix-fetchers" = { };
              "nix-fetchers-c" = { };
              "nix-fetchers-tests" = { };

              "nix-expr" = { };
              "nix-expr-c" = { };
              "nix-expr-test-support" = { };
              "nix-expr-tests" = { };

              "nix-flake" = { };
              "nix-flake-c" = { };
              "nix-flake-tests" = { };

              "nix-main" = { };
              "nix-main-c" = { };

              "nix-cmd" = { };

              "nix-cli" = { };

              "nix-everything" = { };

              "nix-functional-tests" = {
                supportsCross = false;
              };

              "nix-perl-bindings" = {
                supportsCross = false;
              };
            }
            (
              pkgName:
              {
                supportsCross ? true,
              }:
              {
                # These attributes go right into `packages.<system>`.
                "${pkgName}" = nixpkgsFor.${system}.native.nixComponents2.${pkgName};
                "${pkgName}-static" = nixpkgsFor.${system}.native.pkgsStatic.nixComponents2.${pkgName};
                "${pkgName}-llvm" = nixpkgsFor.${system}.native.pkgsLLVM.nixComponents2.${pkgName};
              }
              // lib.optionalAttrs supportsCross (
                flatMapAttrs (lib.genAttrs crossSystems (_: { })) (
                  crossSystem:
                  { }:
                  {
                    # These attributes go right into `packages.<system>`.
                    "${pkgName}-${crossSystem}" = nixpkgsFor.${system}.cross.${crossSystem}.nixComponents2.${pkgName};
                  }
                )
              )
              // flatMapAttrs (lib.genAttrs stdenvs (_: { })) (
                stdenvName:
                { }:
                {
                  # These attributes go right into `packages.<system>`.
                  "${pkgName}-${stdenvName}" =
                    nixpkgsFor.${system}.nativeForStdenv.${stdenvName}.nixComponents2.${pkgName};
                }
              )
            )
        // lib.optionalAttrs (builtins.elem system linux64BitSystems) {
          dockerImage =
            let
              pkgs = nixpkgsFor.${system}.native;
              image = pkgs.callPackage ./docker.nix {
                tag = pkgs.nix.version;
              };
            in
            pkgs.runCommand "docker-image-tarball-${pkgs.nix.version}"
              { meta.description = "Docker image with Nix for ${system}"; }
              ''
                mkdir -p $out/nix-support
                image=$out/image.tar.gz
                ln -s ${image} $image
                echo "file binary-dist $image" >> $out/nix-support/hydra-build-products
              '';
        }
      );

      devShells =
        let
          makeShell = import ./packaging/dev-shell.nix { inherit lib devFlake; };
          prefixAttrs = prefix: lib.concatMapAttrs (k: v: { "${prefix}-${k}" = v; });
        in
        forAllSystems (
          system:
          prefixAttrs "native" (
            forAllStdenvs (
              stdenvName:
              makeShell {
                pkgs = nixpkgsFor.${system}.nativeForStdenv.${stdenvName};
              }
            )
          )
          // lib.optionalAttrs (!nixpkgsFor.${system}.native.stdenv.isDarwin) (
            prefixAttrs "static" (
              forAllStdenvs (
                stdenvName:
                makeShell {
                  pkgs = nixpkgsFor.${system}.nativeForStdenv.${stdenvName}.pkgsStatic;
                }
              )
            )
            // prefixAttrs "llvm" (
              forAllStdenvs (
                stdenvName:
                makeShell {
                  pkgs = nixpkgsFor.${system}.nativeForStdenv.${stdenvName}.pkgsLLVM;
                }
              )
            )
            // prefixAttrs "cross" (
              forAllCrossSystems (
                crossSystem:
                makeShell {
                  pkgs = nixpkgsFor.${system}.cross.${crossSystem};
                }
              )
            )
          )
          // {
            native = self.devShells.${system}.native-stdenv;
            default = self.devShells.${system}.native;
          }
        );

      lib = {
        /**
          Creates a package set for a given Nixpkgs instance and stdenv.

          # Inputs

          - `pkgs`: The Nixpkgs instance to use.

          - `getStdenv`: _Optional_ A function that takes a package set and returns the stdenv to use.
            This needs to be a function in order to support cross compilation - the `pkgs` passed to `getStdenv` can be `pkgsBuildHost` or any other variation needed.

          # Outputs

          The return value is a fresh Nixpkgs scope containing all the packages that are defined in the Nix repository,
          as well as some internals and parameters, which may be subject to change.

          # Example

          ```console
          nix repl> :lf NixOS/nix
          nix-repl> ps = lib.makeComponents { pkgs = import inputs.nixpkgs { crossSystem = "riscv64-linux"; }; }
          nix-repl> ps
          {
            appendPatches = «lambda appendPatches @ ...»;
            callPackage = «lambda callPackageWith @ ...»;
            overrideAllMesonComponents = «lambda overrideSource @ ...»;
            overrideSource = «lambda overrideSource @ ...»;
            # ...
            nix-everything
            # ...
            nix-store
            nix-store-c
            # ...
          }
          ```
        */
        makeComponents =
          {
            pkgs,
            getStdenv ? pkgs: pkgs.stdenv,
          }:

          let
            packageSets = packageSetsFor { inherit getStdenv pkgs; };
          in
          packageSets.nixComponents;
      };
    };
}
