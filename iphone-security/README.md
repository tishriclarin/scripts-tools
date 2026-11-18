# Supervised iPhone Security

An unsigned Apple XML configuration profile for authorized, already-supervised iPhones. It contains 37 restrictions/preferences; support differs by iOS version. No credentials, device identifiers or private keys are included.

## Before installation

- Confirm the iPhone reports that it is supervised in Settings.
- Back up the device, save the supervision identity securely, and confirm that the supervising Mac or MDM can manage/remove profiles.
- Configure Face ID/passcode, Find My, Location Services, cellular plans and trusted accounts before locking changes.
- Test on a spare supervised iPhone first. Do not deploy if an administrator recovery path is unavailable. The profile blocks user removal and installation of other profiles on supported devices.

## Install

### Apple Configurator for Mac (recommended)

1. Download [iphone-supervised-security.mobileconfig](./iphone-supervised-security.mobileconfig) using GitHub's Raw/Download control.
2. Connect the supervised iPhone to its authorized Mac using USB.
3. Open Apple Configurator and select the device.
4. Choose Actions > Add > Profiles and select the downloaded file.
5. Verify in Settings > General > VPN & Device Management.

For an existing MDM, upload the profile as a custom device configuration and deploy to a test device first.

### Directly from iPhone

If manual profile installation is currently allowed, open the downloaded .mobileconfig using Safari or AirDrop. In Settings, select Profile Downloaded and Install; authenticate and review the unsigned-profile warning. Install only a copy you have reviewed and trust. Verify in VPN & Device Management. Prefer Configurator/MDM for ongoing administration. A profile download alone does not enable supervision.

### Validate XML on macOS

```sh
plutil -lint iphone-supervised-security.mobileconfig
```

## What it restricts

- User app installation, updates, deletion, system app removal, app hiding, alternate distribution and enterprise developer trust.
- Account, passcode, biometric, cellular/eSIM, device-name and VPN changes.
- Manual profile installation, Settings-based device erase, untrusted TLS prompts, Files USB drive access, unpaired external recovery boot, iPhone Mirroring and supported video-conferencing remote control.
- Password sharing/proximity requests and diagnostic-submission changes.
- Safari history clearing and private browsing on iOS 26 or later where supported.
- Keeps USB Restricted Mode enabled and enforces encrypted local backups, automatic time, authentication before autofill, and Safari fraud warnings.
- Legacy security-response preferences are deprecated from iOS 26 and removed in iOS 27 according to Apple's schema; use the supported MDM software-update declaration on newer releases.

## Maintenance and limitations

The app-installation restriction also blocks user app updates and may block local installation with Configurator. Use MDM-managed updates or an authorized maintenance window with the restriction removed/reapplied. The profile intentionally leaves host pairing policy unchanged for administrator recovery. To remove a Configurator-installed profile, use the authorized supervising Mac (Actions > Remove > Profiles); for an MDM-installed profile, use its MDM removal workflow. Verify removal capability before rollout. Do not erase a device merely to test profile removal.

Set Location Services and Share My Location restrictions separately using Screen Time where available. Configure Find My, Stolen Device Protection, automatic OS updates, App Privacy Report and, if warranted, Lockdown Mode separately. This is not malware detection or a guarantee of continuous location availability. It cannot prevent all recovery restores, diagnostic log rotation/deletion, third-party browser-history deletion, or account-side changes. Export relevant diagnostics to secure storage when needed.

The XML was checked for structure and its restriction names were checked against Apple's published schema; no physical iPhone installation test has been performed.

## Apple references

- [Restrictions schema](https://github.com/apple/device-management/blob/release/mdm/profiles/com.apple.applicationaccess.yaml)
- [Apple Configurator: add or remove profiles](https://support.apple.com/guide/apple-configurator-mac/cadb67fcd4f/mac)
- [Introduction to device management profiles](https://support.apple.com/guide/deployment/depc0aadd3fe/web)
