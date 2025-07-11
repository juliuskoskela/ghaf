# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Kernel patch to disable built-in gk20a driver
{
  name = "disable-gk20a-driver";
  patch = null;
  extraStructuredConfig = with lib.kernel; {
    # Disable the open-source gk20a driver
    TEGRA_GK20A = no;

    # Also disable nouveau if it's enabled
    DRM_NOUVEAU = no;
  };
}
