# BAR Fight client release process

The current source version is 0.1.10. Building locally does not upload a release or change the live update feed.

## Build and metadata

From the repository root, run:

```powershell
./widget/build.ps1 -Version 0.1.10 -InnoCompiler 'C:\Path\To\Inno Setup\ISCC.exe'
./widget/tests/test_metadata.ps1 -Version 0.1.10
```

`write-build-metadata.ps1` generates one metadata source consumed by both Windows components. Their ProductName is `BAR Fight`, ProductVersion is `0.1.10`, and FileVersion and AssemblyVersion are `0.1.10.0`. The installer uses the same product name and release version. The metadata test verifies real compiled executables, runs the helper's offline tests, then removes its temporary output.

Builds are unsigned unless a verified signing configuration is supplied. `sign-binary.ps1` supports the provider configurations documented by the example JSON files. They contain placeholders, not credentials. SignPath onboarding and approval do not themselves configure this script or sign an artifact; the approved signing workflow must be connected explicitly before declaring a release publisher-signed.

Sign executable artifacts before calculating release hashes. Any signature or documentation change changes release bytes and requires a new version once the preceding version has been published.

## Authenticated updates

The public verification key is pinned in `widget/updater/UpdateTrust.cs`. The corresponding private key is intentionally absent. Ordinary contributors can build and test the client without it. Only an authorized release maintainer with the private key can prepare a manifest accepted by installed official clients.

`publish-update.ps1` prepares a local `widget/dist/updates/widget/` tree; despite its name, it does not upload files. It validates that the private key matches the pinned public key. Do not run `new-update-key.ps1` to replace that key: changing the pin requires a deliberate migration for existing clients.

The feed contains the helper, updater, two Lua widgets, and bundled widget README. Manifests have a bounded expiry and must be renewed by an authorized release maintainer before expiry. Versioned release files are immutable; the preparation script refuses altered files in an existing version directory.

Verify locally prepared update artifacts using Windows PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File ./widget/release/verify-update.ps1
```

`-Published` instead downloads and verifies the public feed; it does not install downloaded files. This is an explicit network check and is separate from the offline test suite.

## Release boundaries

No production private key, publisher signing credential, website backend, user data, or game asset belongs in the public client repository. Keep generated binaries, downloaded build tools, local configuration, and test output outside source control. GPL-2.0-or-later applies to the client source; it does not imply that separately hosted website services or data are included.
