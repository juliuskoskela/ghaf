# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{ inputs, lib, ... }:
{
  imports = [
    inputs.devshell.flakeModule
  ];
  perSystem =
    {
      config,
      pkgs,
      system,
      self',
      ...
    }:
    {
      devshells = {
        # the main developer environment
        default = {
          devshell = {
            name = "Ghaf devshell";
            meta.description = "Ghaf development environment";
            packages =
              [
                pkgs.jq
                pkgs.nodejs
                pkgs.nix-eval-jobs
                pkgs.nix-fast-build
                pkgs.nix-output-monitor
                pkgs.nix-tree
                pkgs.nixVersions.latest
                pkgs.reuse
                config.treefmt.build.wrapper
                self'.legacyPackages.ghaf-build-helper
                pkgs.dtc
              ]
              ++ config.pre-commit.settings.enabledPackages
              ++ lib.attrValues config.treefmt.build.programs # make all the trefmt packages available
              ++ lib.optional (pkgs.hostPlatform.system != "riscv64-linux") pkgs.cachix;

            startup.hook.text = config.pre-commit.installationScript;
          };
          commands = [
            {
              help = "Format";
              name = "format-repo";
              command = "treefmt";
              category = "checker";
            }
            {
              help = "Check license";
              name = "check-license";
              command = "reuse lint";
              category = "linters";
            }
            {
              help = "Ghaf nixos-rebuild command";
              name = "ghaf-rebuild";
              command = "ghaf-build-helper $@";
              category = "builder";
            }
            {
              help = "Deploy Ghaf system to Jetson device via SSH";
              name = "deploy-to-jetson";
              command = ''
                								set -euo pipefail

                								# Default values
                								TARGET_HOST="''${TARGET_HOST:-ghaf@ghaf-host}"
                								FLAKE_TARGET="''${FLAKE_TARGET:-nvidia-jetson-orin-agx-debug-nodemoapps-from-x86_64}"

                								# Parse command line arguments
                								while [[ $# -gt 0 ]]; do
                										case $1 in
                												--target-host)
                														TARGET_HOST="$2"
                														shift 2
                														;;
                												--flake-target)
                														FLAKE_TARGET="$2"
                														shift 2
                														;;
                												--help)
                														echo "Usage: deploy-to-jetson [OPTIONS]"
                														echo ""
                														echo "Options:"
                														echo "  --target-host HOST      SSH target (default: ghaf@ghaf-host)"
                														echo "  --flake-target TARGET   Flake configuration to build (default: nvidia-jetson-orin-agx-debug-nodemoapps-from-x86_64)"
                														echo "  --help                  Show this help message"
                														exit 0
                														;;
                												*)
                														echo "Unknown option: $1"
                														exit 1
                														;;
                										esac
                								done

                								echo "=== Ghaf Jetson Deployment ==="
                								echo "Target host: ''${TARGET_HOST}"
                								echo "Flake target: ''${FLAKE_TARGET}"
                								echo ""

                								# Check SSH connection
                								echo "1. Testing SSH connection..."
                								if ! ssh -o ConnectTimeout=5 "''${TARGET_HOST}" "echo 'SSH connection successful'"; then
                										echo "Failed to connect to ''${TARGET_HOST}"
                										exit 1
                								fi

                								# Build the system
                								echo "2. Building system configuration..."
                								echo "This may take a while..."
                								RESULT_PATH=$(nix build ".#nixosConfigurations.''${FLAKE_TARGET}.config.system.build.toplevel" --no-link --print-out-paths)
                								echo "Built system at: ''${RESULT_PATH}"

                								# Copy closure to target
                								echo "3. Copying system closure to target..."
                								nix-copy-closure --to "''${TARGET_HOST}" "''${RESULT_PATH}"

                								# Create activation script
                								echo "4. Creating activation script on target..."
                								ssh "''${TARGET_HOST}" "cat > /home/ghaf/activate-ghaf-system.sh << 'EOF'
                                #!/bin/bash
                                set -euo pipefail
                                SYSTEM_PATH=\"\''${1:-}\"
                                if [ -z \"\''${SYSTEM_PATH}\" ]; then
                                    echo \"Usage: \$0 <system-path>\"
                                    exit 1
                                fi
                                echo \"Activating system: \''${SYSTEM_PATH}\"
                                sudo nix-env --profile /nix/var/nix/profiles/system --set \"\''${SYSTEM_PATH}\"
                                sudo /nix/var/nix/profiles/system/bin/switch-to-configuration boot
                                echo \"System activation complete! Reboot to use new system.\"
                                EOF"
                                                ssh "''${TARGET_HOST}" "chmod +x /home/ghaf/activate-ghaf-system.sh"

                                                echo ""
                                                echo "=== Deployment complete! ==="
                                                echo "To activate on target device:"
                                                echo "  1. SSH: ssh ''${TARGET_HOST}"
                                                echo "  2. Run: sudo bash /home/ghaf/activate-ghaf-system.sh ''${RESULT_PATH}"
                                                echo "  3. Reboot: sudo reboot"
              '';
              category = "builder";
            }
          ];
        };

        smoke-test = {
          devshell = {
            name = "Ghaf smoke test";
            meta.description = "Ghaf smoke test environment";
            packagesFrom = [ inputs.ci-test-automation.devShell.${system} ];
          };

          commands = [
            {
              help = "
                Usage: robot-test -i [ip] -d [device] -p [password]
                                  -t [tag] -c [commit] -n [threads] -f [configpath] -o [outputdir]

                Runs automated tests (only pre-merge tests by default) on the defined target.

                Required arguments:
                -i  --ip          IP address of the target device
                                  (if running locally from ghaf-host of the target device use
                                  127.0.0.1 for orin-agx
                                  192.168.100.1 for lenovo-x1 and orin-nx)
                -d  --device      Device name of the target. Use exactly one of these options:
                                    Lenovo-X1
                                    Orin-AGX
                                    Orin-NX
                                    NUC
                -p  --password    Password for the ghaf user

                Optional arguments:
                -t  --tag         Test tag which defines which test cases will be run.
                                  Defaults to 'pre-merge'.
                -c  --commit      This can be commit hash or any identifier.
                                  Relevant only if running performance tests.
                                  It will be used in presenting preformance test results in plots.
                                  Defaults to 'smoke'.
                -n  --threads     How many threads the device has.
                                  This parameter is relevant only for performance tests.
                                  Defaults to
                                    20 with -d Lenovo-X1
                                    12 with -d Orin-AGX
                                    8 with other devices
                -f  --configpath  Path to config directory.
                                  Defaults to 'None'.
                -o  --outputdir   Path to directory where all helper files and result files are saved.
                                  Defaults to '/tmp/test_results'
              ";
              name = "robot-test";
              command = ''
                tag="pre-merge"
                commit="smoke"
                configpath="None"
                outputdir="/tmp/test_results"
                threads=8
                threads_manual_set=false

                while [ ''$# -gt 0 ]; do
                  if [[ ''$1 == "-i" || ''$1 == "--ip" ]]; then
                    ip="''$2"
                    shift
                  elif [[ ''$1 == "-d" || ''$1 == "--device" ]]; then
                    device="''$2"
                    shift
                  elif [[ ''$1 == "-p" || ''$1 == "--password" ]]; then
                    pw="''$2"
                    shift
                  elif [[ ''$1 == "-t" || ''$1 == "--tag" ]]; then
                    tag="''$2"
                    shift
                  elif [[ ''$1 == "-c" || ''$1 == "--commit" ]]; then
                    commit="''$2"
                    shift
                  elif [[ ''$1 == "-n" || ''$1 == "--threads" ]]; then
                    threads="''$2"
                    threads_manual_set=true
                    shift
                  elif [[ ''$1 == "-f" || ''$1 == "--config" ]]; then
                    configpath="''$2"
                    shift
                  elif [[ ''$1 == "-o" || ''$1 == "--outputdir" ]]; then
                    outputdir="''$2"
                    shift
                  else
                    echo "Unknown option: ''$1"
                    exit 1
                  fi
                  shift
                done

                if [[ ''${threads_manual_set} == false ]]; then
                  grep -q "X1" <<< "''$device" && threads=20
                  grep -q "AGX" <<< "''$device" && threads=12
                fi

                cd ${inputs.ci-test-automation.outPath}/Robot-Framework/test-suites
                ${
                  inputs.ci-test-automation.packages.${system}.ghaf-robot
                }/bin/ghaf-robot -v CONFIG_PATH:''${configpath} -v DEVICE_IP_ADDRESS:''${ip} -v THREADS_NUMBER:''${threads} -v COMMIT_HASH:''${commit} -v DEVICE:''${device} -v PASSWORD:''${pw} -i ''${device,,}AND''${tag} --outputdir ''${outputdir} .
              '';
              category = "test";
            }
            {
              help = "Show path to ci-test-automation repo in nix store";
              name = "robot-path";
              command = "echo ${inputs.ci-test-automation.outPath}";
              category = "test";
            }
          ];
        };
      };
    };
}
