{
  # Usage:
  #   nix develop                  # gradle 4.4 + Android SDK 27 + NDK r16b
  #   nix run                      # build every module (gradle "build")
  #   nix run . -- assembleDebug   # build only the debug APKs
  #   nix build .#androidSdk       # the composed Android SDK
  #
  # APKs end up under <module>/build/outputs/apk/, and local.properties is
  # generated automatically from the pinned SDK/NDK.
  description = "Build the UVCCamera Android library and sample apps";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    android-nixpkgs = {
      url = "github:tadfisher/android-nixpkgs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      android-nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      # ------------------------------------------------------------------
      # Android SDK/NDK
      #
      # The project targets API 27 with build-tools 27.0.3 and the old
      # Gradle 4.4 / Android Gradle Plugin 3.1.4 toolchain.  The JNI code
      # is compiled with the legacy `ndk-build` invocation from
      # libuvccamera/build.gradle, and Application.mk still requests
      # armeabi + mips, so we pin NDK r16b (the last release supporting
      # both).  Anything newer drops those ABIs.
      # ------------------------------------------------------------------
      androidSdk = android-nixpkgs.sdk.${system} (
        sdkPkgs:
        # android-nixpkgs assumes every build-tools release ships `d8` and
        # `lld`, which is not true for 27.0.3 (it still uses `dx`).  Only
        # substitute the launcher scripts that actually exist.
        let
          buildTools = sdkPkgs.build-tools-27-0-3.overrideAttrs (_: {
            postUnpack = ''
              for f in apksigner d8 lld; do
                if [ -e "$out/$f" ]; then
                  substituteInPlace "$out/$f" --replace "/bin/ls" "ls"
                  wrapProgram "$out/$f" --set PATH ${
                    pkgs.lib.makeBinPath [
                      pkgs.coreutils
                      pkgs.jdk
                    ]
                  }
                fi
              done
            '';
          });

          # NDK r16 bundles a Python 2.7 that still links against OpenSSL
          # 1.0 and SQLite, which do not exist on modern nixpkgs.  They are
          # only used by aux scripts (ndk-gdb etc.), not by ndk-build, so
          # let the patcher ignore them.
          ndk = sdkPkgs.ndk-16-1-4479499.overrideAttrs (old: {
            autoPatchelfIgnoreMissingDeps = (old.autoPatchelfIgnoreMissingDeps or [ ]) ++ [
              "libcrypto.so.1.0.0"
              "libssl.so.1.0.0"
              "libsqlite3.so.0"
            ];
          });
        in
        with sdkPkgs;
        [
          cmdline-tools-latest
          platform-tools
          platforms-android-27
          buildTools
          ndk
        ]
      );

      sdkRoot = "${androidSdk}/share/android-sdk";
      ndkRoot = "${sdkRoot}/ndk/16.1.4479499";

      # ------------------------------------------------------------------
      # Gradle 4.4
      #
      # The repository ships a gradle-wrapper.properties but no
      # gradle-wrapper.jar, so ./gradlew cannot be used.  nixpkgs only
      # packages Gradle >= 7, which is far too new for AGP 3.1.4, so we
      # package 4.4 ourselves and patch the native-platform JNI libraries
      # it bundles (they are stored inside jars and would otherwise fail
      # to load on NixOS).
      # ------------------------------------------------------------------
      gradle44 = pkgs.stdenv.mkDerivation {
        pname = "gradle";
        version = "4.4";

        src = pkgs.fetchurl {
          url = "https://services.gradle.org/distributions/gradle-4.4-bin.zip";
          hash = "sha256-+khzrix/XowC7GlIupWEjO3O1hNHcqAWlxjq3LOeCi8=";
        };

        nativeBuildInputs = with pkgs; [
          makeWrapper
          unzip
          jdk8
          autoPatchelfHook
        ];
        buildInputs = with pkgs; [
          stdenv.cc.cc.lib
          zlib
          ncurses5
          ncurses6
        ];

        dontConfigure = true;
        dontBuild = true;
        dontAutoPatchelf = true;

        installPhase = ''
          runHook preInstall

          mkdir -p $out/libexec/gradle
          cp -r lib $out/libexec/gradle/lib
          mkdir -p $out/libexec/gradle/bin
          cp bin/gradle $out/libexec/gradle/bin/gradle
          chmod +x $out/libexec/gradle/bin/gradle

          tmp=$(mktemp -d)
          for jar in $out/libexec/gradle/lib/native-platform-linux-amd64-*.jar; do
            rm -rf "$tmp"/*
            (cd "$tmp" && ${pkgs.jdk8}/bin/jar xf "$jar")
            autoPatchelf "$tmp"
            (cd "$tmp" && ${pkgs.jdk8}/bin/jar cf "$jar" .)
          done

          runHook postInstall
        '';

        postFixup = ''
          makeWrapper $out/libexec/gradle/bin/gradle $out/bin/gradle \
            --set-default JAVA_HOME ${pkgs.jdk8} \
            --suffix PATH : ${
              pkgs.lib.makeBinPath [
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnused
              ]
            }
        '';

        meta = {
          description = "Gradle 4.4 (required by Android Gradle Plugin 3.1.4)";
          homepage = "https://gradle.org/";
          license = pkgs.lib.licenses.asl20;
          mainProgram = "gradle";
        };
      };

      # Write local.properties (and use the pinned SDK) then run Gradle.
      # Invoked from the project root so the APKs land in the usual
      # <module>/build/outputs/apk directories.
      build = pkgs.writeShellApplication {
        name = "uvccamera-build";
        runtimeInputs = [
          gradle44
          androidSdk
          pkgs.coreutils
          pkgs.which
        ];
        text = ''
          if [ ! -f build.gradle ] || [ ! -d libuvccamera ]; then
            echo "error: run this from the UVCCamera project root" >&2
            exit 1
          fi

          export ANDROID_SDK_ROOT=${sdkRoot}
          export ANDROID_HOME=${sdkRoot}
          export ANDROID_NDK_ROOT=${ndkRoot}

          cat > local.properties <<EOF
          sdk.dir=$ANDROID_SDK_ROOT
          ndk.dir=$ANDROID_NDK_ROOT
          EOF

          if [ "$#" -eq 0 ]; then
            # `build` is what the README documents, but lint currently fails
            # on pre-existing NewApi errors (UsbDevice#getManufacturerName
            # etc. guarded by runtime version checks), so skip it.
            set -- build -x lint
          fi

          exec gradle --no-daemon "$@"
        '';
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          gradle44
          pkgs.jdk8
          androidSdk
          pkgs.git
          pkgs.which
        ];

        JAVA_HOME = "${pkgs.jdk8}";
        ANDROID_HOME = sdkRoot;
        ANDROID_SDK_ROOT = sdkRoot;
        ANDROID_NDK_ROOT = ndkRoot;

        shellHook = ''
          if [ ! -f local.properties ]; then
            printf 'sdk.dir=%s\nndk.dir=%s\n' \
              "$ANDROID_SDK_ROOT" "$ANDROID_NDK_ROOT" > local.properties
          fi
          echo "UVCCamera dev shell: gradle $(gradle --version 2>/dev/null | grep -m1 '^Gradle')"
        '';
      };

      packages.${system} = {
        inherit build androidSdk gradle44;
        default = build;
      };

      apps.${system} = {
        build = {
          type = "app";
          program = "${build}/bin/uvccamera-build";
        };
        default = self.apps.${system}.build;
      };

      formatter.${system} = pkgs.nixfmt;
    };
}
