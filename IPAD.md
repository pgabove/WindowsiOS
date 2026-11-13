# Windows 11 26H2 on an M5 iPad Pro (branch `ipad-26h2`)

What this branch adds to WindowsiOS, and how the pieces are built.

## What changed

| Area | Change |
|---|---|
| Windows | Windows 11 26H2 (build 26300) Arm64, from Microsoft's own Media Creation Tool catalog |
| RAM | 8 GB guest RAM on 16 GB iPads (6 GB, then the stock tiers, as fallbacks) |
| Internet | virtio-win NetKVM (attestation-signed by Microsoft) installed during Windows setup |
| Screen | patched UEFI firmware lets the app choose Windows' resolution: **Smooth** = half the iPad's pixels (Windows at 100%), **Sharp** = all of them (Windows at 200%) |
| Drawing | 120 Hz ProMotion pacing, GPU reads the guest framebuffer directly where possible, crisp nearest-neighbour scaling at 1x/2x, full-screen Windows when the toolbar is hidden |
| Speed | Windows tuned during setup (`scripts/windows/winios-setup.ps1`): animations, transparency, background apps, Widgets, Copilot, Spotlight and preinstalled extras off; Windows Update asks before downloading; Defender stays on with scans limited to 20% CPU |
| Delivery | the finished disk is LZFSE-compressed, cut into parts under GitHub's 2 GiB file limit and uploaded to a **draft** release (visible only to people with write access); the app joins and checks the parts |

## Workflows

- **Build iPad IPA** (`build-ipad.yml`): unsigned app, ad-hoc signed with its entitlements, as the artifact `WindowsiOS-iPad-ipa`.
- **Build UEFI firmware** (`firmware.yml`, `firmware/build.sh`): QEMU's EDK2 build (edk2-stable202408) plus `firmware/edk2-ramfb-host-resolution.patch`.
- **Provision Windows 11 26H2 image** (`provision-26h2.yml`): builds the installer from Microsoft's ESD, installs Windows under the engine on a GitHub Mac runner, uploads the draft release, then joins/unpacks the uploaded files and boots them at 1376x1032 and 2752x2064 as a check. The live screen of a running job is on the `ci-status` branch.
- **Display test** (`display-test.yml`): boots the newest draft image with the newest firmware at both resolutions.

## On the iPad

1. Install the IPA from the newest successful **Build iPad IPA** run.
2. From the newest draft release, download `code.fd`, `vars.fd`, `windows11.hvsparse.parts` and every `windows11.hvsparse.NNN` part.
3. Put them in Files > On My iPad > Windows 11 > Machines > Win11.
4. Open the app, pick Smooth or Sharp, tap ENABLE JIT, then BOOT WINDOWS 11. The app joins the parts, unpacks the disk and starts Windows.

The draft release holds Microsoft's Windows files: keep it a draft. Windows is not activated.
