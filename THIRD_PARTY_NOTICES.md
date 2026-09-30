# Third-party notices

BAR Fight's own client code is licensed under the GNU General Public License, version 2 or any later version (`GPL-2.0-or-later`). External components retain their own copyrights and license terms.

## Beyond All Reason

The client runs inside [Beyond All Reason](https://www.beyondallreason.info/). Its player-list adapter reads the `gui_advplayerslist.lua` supplied by the installed game's archive and adds the historical-trait hover integration at runtime. The client package does not ship a copy of the game's full player-list implementation or the game itself. The installed game's code and assets remain subject to their respective upstream licenses and notices.

The adapter is identified as BAR Fight code and does not replace a user's separately named player-list widget. Beyond All Reason's name identifies compatibility; it does not imply endorsement.

## Inno Setup

The Windows installer is generated with [Inno Setup](https://jrsoftware.org/). Its upstream installer runtime is included in the generated setup executable under the Inno Setup license, rather than the license for BAR Fight's own code.

Copyright (C) 1997–2026 Jordan Russell. All rights reserved.

Portions Copyright (C) 2000–2026 Martijn Laan. All rights reserved.

Preserve the upstream runtime's copyright notices, website addresses and license conditions. Retain upstream signatures where supplied; do not represent or submit that runtime as BAR Fight-authored code for signing. Any redistributed modified upstream component must be identified as modified. The Inno Setup distribution used for building includes its full `License.txt`.

## Windows and .NET Framework

The helper and updater use the Microsoft .NET Framework and Windows system APIs supplied by the user's Windows installation. The client installer does not bundle a separate .NET runtime or Windows system libraries. Those external system components remain subject to Microsoft's terms and their own update and privacy settings.

The client uses framework libraries and does not embed NuGet packages. Development tools and test dependencies are not part of the installed client.

## Hosted services and signing

The client requests profiles and update files from the separately operated BAR Fight service. Its private server implementation is not included in this client repository. Network behavior is described in [PRIVACY.md](PRIVACY.md).

SignPath is a proposed release-signing service, not a bundled client library. The application is pending; see [CODE_SIGNING_POLICY.md](CODE_SIGNING_POLICY.md). No SignPath signing service is claimed as currently provided.
