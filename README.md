# BAR Fight widget

BAR Fight shows historical player traits inside Beyond All Reason. This repository contains the two Lua widgets, the Windows profile helper, the authenticated updater, the per-user installer, and their build and test scripts.

The website is [bar-fight.com](https://bar-fight.com/). This client requests public player profiles from the website; it does not record gameplay, read local replay files, or upload replays. See [PRIVACY.md](PRIVACY.md) for the fields sent and the independent controls for profile lookups and automatic updates.

The website, hosted API implementation, replay analysis services, databases, research data, and game assets are outside this repository. The client license does not license those separately operated services or their data. Beyond All Reason and its bundled player list are external dependencies; no game distribution is included here.

## Install and use

Follow the [widget guide](widget/README.md). Windows installers and their checksums are published on the [releases page](https://github.com/jehalvar/BAR-fight-widget/releases).

## Code signing policy

Our application to [SignPath Foundation](https://signpath.org/) is pending. Current installers are unsigned; Foundation signing is not yet active. Read the [Code signing policy](CODE_SIGNING_POLICY.md) for maintainer responsibilities, manual release approval and signing scope, and the [privacy policy](PRIVACY.md) for the client's network requests and controls.

## Build

Requires Windows 10 or later, .NET Framework 4.x with its C# compiler, PowerShell, and a separately installed [Inno Setup](https://jrsoftware.org/isdl.php). No NuGet packages are needed.

```powershell
./widget/build.ps1 -Version 0.1.7 -InnoCompiler 'C:\Path\To\Inno Setup\ISCC.exe'
```

Build output is excluded from Git. Builds without an explicit signing configuration are unsigned. Signing-provider approval, certificate issuance, and publication are separate release steps. The RSA update-manifest signature is distinct from Windows Authenticode signing; the public update-verification key is source-controlled, and no private release key is included.

## Verify

Run from the repository root:

```powershell
./widget/tests/test_metadata.ps1
./widget/bridge/test_bridge.ps1
./widget/updater/test_updater.ps1
python -m unittest discover -s widget/tests -v
```

The PowerShell checks use temporary installations and do not contact the production service. Lua integration checks require the optional Python `lupa` package and otherwise report skipped tests. The installer lifecycle test, `widget/test_installer.ps1`, requires a built setup executable and a clean Windows user without an existing BAR Fight installation.

Both compiled Windows components receive metadata from the same generated `WidgetBuild.cs`:

| Field | 0.1.7 value |
| --- | --- |
| ProductName | BAR Fight |
| ProductVersion | 0.1.7 |
| FileVersion | 0.1.7.0 |
| AssemblyVersion | 0.1.7.0 |

`test_metadata.ps1` compiles the actual helper and updater, reads their PE version resources, verifies all four fields, and runs the helper's offline self-tests. It removes its temporary binaries afterward. The installer uses the same product name and release version.

## License

Copyright (C) 2026 BAR Fight contributors.

This client project is free software: you may redistribute it and/or modify it under the GNU General Public License as published by the Free Software Foundation, either version 2 of the License, or, at your option, any later version. It is distributed without any warranty; see [COPYING](COPYING) for the full license and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency boundaries.

The installer includes the license. Public API availability and website content are separate from the rights granted for this client source.
