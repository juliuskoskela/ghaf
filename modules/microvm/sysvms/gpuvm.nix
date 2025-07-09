# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# This file now just imports the refactored gpuvm module
{ inputs }: import ./gpuvm/default.nix { inherit inputs; }
