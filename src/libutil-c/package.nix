{ lib
, stdenv
, mkMesonLibrary

, nix-util

# Configuration Options

, version
}:

let
  inherit (lib) fileset;
in

mkMesonLibrary (finalAttrs: {
  pname = "nix-util-c";
  inherit version;

  workDir = ./.;
  fileset = fileset.unions [
    ../../build-utils-meson
    ./build-utils-meson
    ../../.version
    ./.version
    ./meson.build
    ./meson.options
    (fileset.fileFilter (file: file.hasExt "cc") ./.)
    (fileset.fileFilter (file: file.hasExt "hh") ./.)
    (fileset.fileFilter (file: file.hasExt "h") ./.)
  ];

  propagatedBuildInputs = [
    nix-util
  ];

  preConfigure =
    # "Inline" .version so it's not a symlink, and includes the suffix.
    # Do the meson utils, without modification.
    ''
      chmod u+w ./.version
      echo ${version} > ../../.version
    '';

  mesonFlags = [
  ];

  env = lib.optionalAttrs (stdenv.isLinux && !(stdenv.hostPlatform.isStatic && stdenv.system == "aarch64-linux")) {
    LDFLAGS = "-fuse-ld=gold";
  };

  meta = {
    platforms = lib.platforms.unix ++ lib.platforms.windows;
  };

})
