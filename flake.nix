{
  description = "Spirula Studio -- 3D Gaussian Splatting trainer (Vulkan backend, no GUI)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      # Linux only: the macOS build fetches MoltenVK and pins a different Slang
      # release (cmake/SsVulkan.cmake, cmake/SsSlang.cmake), which is a second
      # set of fixed-output derivations nobody has needed yet.
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: rec {
        default = spirula-studio;

        # The upstream slangc release, byte-for-byte.
        #
        # cmake/SsSlang.cmake compares `slangc -v` against SS_SLANG_VERSION as
        # an exact string and downloads the pinned release on any mismatch --
        # which a sandboxed build cannot do. nixpkgs' shader-slang is 2026.5.2,
        # so pointing -DSS_SLANGC at it would still trip that fetch. Fetching
        # the pinned release ourselves compiles the shaders with exactly the
        # compiler upstream tests against.
        slangc-pinned = pkgs.callPackage ({ lib, stdenvNoCC, fetchurl
                                          , autoPatchelfHook, zlib, stdenv }:
          let
            version = "2026.12.0.1";
            arch = if stdenv.hostPlatform.isAarch64 then "aarch64" else "x86_64";
            hashes = {
              x86_64 = "sha256-u9NpaLWu/fkcLt4NLhMfi1Usum7SRE2lnxoLwL/GeS0=";
              aarch64 = "sha256-itaoRJ4Y0YOqO3XLPIQh/V61OW7ksJXrpprsdcAi9dM=";
            };
          in
          stdenvNoCC.mkDerivation {
            pname = "slangc-pinned";
            inherit version;

            src = fetchurl {
              url = "https://github.com/shader-slang/slang/releases/download/v${version}"
                + "/slang-${version}-linux-${arch}.tar.gz";
              hash = hashes.${arch};
            };

            # The tarball holds bin/, include/ and lib/ at its root, not one
            # directory to descend into.
            sourceRoot = ".";

            nativeBuildInputs = [ autoPatchelfHook ];
            # libslang-llvm.so wants libz. slangc itself needs only the C++
            # runtime, but autoPatchelfHook checks every ELF it ships.
            buildInputs = [ stdenv.cc.cc.lib zlib ];

            # slang-glslang -- which is how slangc runs spirv-opt -- and
            # slang-llvm are dlopened by bare name rather than linked, so
            # nothing puts them in a DT_NEEDED for autoPatchelfHook to resolve.
            # It rewrites the upstream `$ORIGIN/../lib` runpath away, and the
            # dlopen then fails with E00100 on the first .spv. Put the output's
            # own lib directory back.
            appendRunpaths = [ "${placeholder "out"}/lib" ];

            # slangc reaches libslang-compiler.so and the Slang standard module
            # through that runpath, so the layout has to survive intact.
            #
            # slangd is the language server and libgfx is Slang's graphics
            # abstraction layer; this build wants a shader compiler and neither
            # is on that path. Dropping libgfx is also what keeps libX11 out of
            # the closure -- it is the only thing in the release linking it.
            installPhase = ''
              runHook preInstall
              mkdir -p "$out"
              cp -r bin include lib "$out/"
              rm -f "$out"/bin/slangd "$out"/bin/slangi "$out"/lib/libgfx.so*
              runHook postInstall
            '';

            dontStrip = true;

            meta = {
              description = "Slang shader compiler, the release cmake/SsSlang.cmake pins";
              homepage = "https://github.com/shader-slang/slang";
              license = with lib.licenses; [ asl20 llvm-exception ];
              platforms = [ "x86_64-linux" "aarch64-linux" ];
              mainProgram = "slangc";
            };
          }) { };

        spirula-studio = pkgs.callPackage ({ lib, stdenv, cmake, ninja, makeWrapper
                                          , vulkan-headers, vulkan-loader
                                          , curl, ffmpeg, withFfmpeg ? true }:
          let
            # Must match cmake/SsOptions.cmake's SS_VERSION, which postPatch
            # rewrites to carry the revision.
            version = "2026.9.30";
            rev = self.shortRev or self.dirtyShortRev or "unknown";
          in
          stdenv.mkDerivation {
            pname = "spirula-studio";
            inherit version;

            # Deliberately not `self`: that would make every edit to flake.nix
            # (or a regenerated flake.lock) a new source hash and rebuild the
            # whole tree. Nothing excluded here is read by the build.
            src = lib.cleanSourceWith {
              name = "spirula-studio-source";
              src = lib.cleanSource ./.;
              filter = path: type:
                let base = baseNameOf (toString path); in
                !(lib.hasPrefix "flake." base) && base != ".github";
            };

            nativeBuildInputs = [ cmake ninja slangc-pinned makeWrapper ];
            buildInputs = [ vulkan-headers vulkan-loader ];

            # SsOptions.cmake reads the commit with git for the string
            # `--version` prints. A flake source carries no .git, so hand it
            # the revision rather than ship a binary that cannot name its tree.
            postPatch = ''
              substituteInPlace cmake/SsOptions.cmake \
                --replace-fail 'set(SS_VERSION "${version}")' \
                               'set(SS_VERSION "${version} (${rev})")'
            '';

            # SsOptions.cmake sets -O3 itself and leaves CMAKE_BUILD_TYPE empty
            # on purpose; nixpkgs' default of Release would also define NDEBUG,
            # which no upstream build does.
            cmakeBuildType = "None";

            cmakeFlags = [
              (lib.cmakeFeature "SS_BACKEND" "vulkan")
              (lib.cmakeBool "SS_BUILD_GUI" false)
              (lib.cmakeFeature "SS_SLANGC" "${slangc-pinned}/bin/slangc")
              # It reads the uncommitted git diff, so it is a no-op on a source
              # with no .git; off explicitly keeps python out of the build.
              (lib.cmakeBool "SS_CHECK_COMMENTS" false)
            ];

            # Roughly 750 MB of RAM per compile job, which is what
            # build_develop.bash caps its job count on. Lower NIX_BUILD_CORES if
            # the build gets OOM-killed.
            enableParallelBuilding = true;

            # Every sfm_*, nn_*, sam_* and backend/vulkan test executable is
            # built, but they all want a Vulkan device, which the sandbox has
            # no access to.
            doCheck = false;

            # The build declares no install rules: one executable, dispatching
            # on argv[1] (src/app/Tools.h).
            installPhase = ''
              runHook preInstall
              install -Dm755 spirula "$out/bin/spirula"
              runHook postInstall
            '';

            # Checkpoints (SAM, BiRefNet, GroundingDINO, ALIKED, LoMa, Metric3D,
            # MoGe) are fetched on first use by shelling out to `curl`
            # (src/nn/io/Fetch.cpp), and with SS_ENABLE_PATENTED off, frame
            # extraction and video encoding shell out to `ffmpeg`. Neither is
            # reached through a library, so both have to be on PATH.
            postFixup = ''
              wrapProgram "$out/bin/spirula" \
                --prefix PATH : ${lib.makeBinPath ([ curl ] ++ lib.optional withFfmpeg ffmpeg)}
            '';

            meta = {
              description = "3D Gaussian Splatting trainer, Vulkan backend, command-line tools only";
              longDescription = ''
                The `spirula` executable with the Vulkan compute backend and no
                GUI: `spirula train`, `spirula sfm`, `spirula sam` and
                `spirula mesh`. Video decode and encode go through the external
                `ffmpeg`, since SS_ENABLE_PATENTED is off -- read that section
                of docs/build.md before turning it on.
              '';
              homepage = "https://github.com/spirulae/spirula-studio";
              license = lib.licenses.gpl3Only;
              platforms = systems;
              mainProgram = "spirula";
            };
          }) { };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.system}.spirula-studio ];
          # What build_develop.bash wants beyond the build itself: python3 for
          # codegen and the lints, fontTools for check_font_coverage.py, git for
          # the version string and the comment-length check, curl and ffmpeg at
          # runtime.
          packages = [
            pkgs.python3
            pkgs.python3Packages.fonttools
            pkgs.git
            pkgs.curl
            pkgs.ffmpeg
          ];
          # Without this build_develop.bash finds no slangc and tries to fetch
          # the pinned release.
          SS_SLANGC = "${self.packages.${pkgs.system}.slangc-pinned}/bin/slangc";
          shellHook = ''
            echo "spirula dev shell -- bash build_develop.bash -DSS_BACKEND=vulkan \\"
            echo "    -DSS_BUILD_GUI=OFF -DSS_SLANGC=\$SS_SLANGC"
          '';
        };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = "${self.packages.${pkgs.system}.spirula-studio}/bin/spirula";
          meta.description = "Run the spirula command-line tools";
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
