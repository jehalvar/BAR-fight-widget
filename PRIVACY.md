# Privacy policy

This policy describes the BAR Fight Windows client in this repository: its Lua widgets, helper, updater and installer. The client obtains historical traits from a separately hosted BAR Fight API. That private service and its replay-analysis backend are not included in this repository or the client's SignPath application.

## Player-profile requests

When profile fetching is enabled and the widget is active, the helper sends the current map name and up to 16 public BAR account IDs to `https://bar-fight.com/api/widget/traits` over HTTPS. These are the identified players in the current roster, not just the person running the client. The service returns cached historical profiles, including names, traits, dates and sample sizes. Requests for profiles still being prepared can retry every 30 seconds.

The helper may use the existing BAR Fight fallback endpoint, `https://replay.164.90.210.36.sslip.io/api/widget/traits`, when the primary service fails in a supported way. Both endpoints receive the same request fields. TLS certificate validation remains enabled.

When you open Build timings, the helper requests the selected account, supported
map and selected unit code or group from `https://bar-fight.com/api/widget/timings`.
It also fetches and caches the public list at
`https://bar-fight.com/api/widget/timing-units`. The same approved fallback host
may be used. The service returns historical average and median first-ready times,
positions, dates, sample sizes and measurement coverage. Unit codes and groups
are URL query parameters and may appear in server logs. These lookups use the
same profile-fetching privacy control; they do not send current build orders.

The server and its hosting infrastructure receive the source IP address, requested URL, request time and HTTP headers, including the helper's `BARFightBridge/1.0` User-Agent. Account IDs and the map name are URL query parameters and can therefore appear in server access logs. The service can also retain requested public account IDs and request times to prioritize background profile preparation. This client policy does not set a retention period for the separately operated service's access logs.

The client does not upload replay files, local game history, chat, player commands, screenshots or local filesystem paths. It does not record gameplay or run replay simulations. It uses the game's current roster to identify accounts; public replay analysis happens separately on the service.

## Local files

The widget and helper exchange JSON data through `LuaUI/Config/bar_fight_traits_request.json` and `LuaUI/Config/bar_fight_traits_response.json` in the selected BAR data folder. These local files can contain the requested public account IDs, map name and returned public profiles. Panel settings are stored through BAR's widget configuration. The installer stores the selected data folder and client settings locally.

Timing lookups use separate `LuaUI/Config/bar_fight_timings_request.json` and
`LuaUI/Config/bar_fight_timings_response.json` files. **Copy timing** writes the
selected player name, historical position, unit label and average time to your
clipboard only when clicked. It does not send the copied text to game chat.

Downloaded updates, their verification metadata and temporary recovery copies are stored beneath the client installation folder. They contain client release files, not uploaded gameplay data.

## Automatic updates

While the helper runs and automatic updates are enabled, the updater fetches `https://bar-fight.com/updates/widget/stable.json` and, when a newer release is available, the release files identified by its signed manifest. Normal release checks are six hours apart; failed checks retry after 30 minutes. Downloaded files wait for BAR to close before installation.

Update requests expose ordinary connection metadata, including the IP address and a `BAR-Fight-Updater/<version>` User-Agent identifying the updater version. They do not contain player account IDs, the current map or profile contents. The updater verifies the manifest signature and file hashes before applying an update.

## Your choices

Setup offers two independent options, selected by default: **Fetch player profiles from bar-fight.com** and **Keep BAR Fight updated automatically**. Uncheck either option to disable that activity. Starting the helper with Windows is a separate, optional setting.

To change these choices later, edit `bar-fight.ini` in the client installation folder, normally `%LOCALAPPDATA%\BARFight`:

```ini
[Privacy]
FetchProfiles=0

[Updates]
Enabled=0
```

`FetchProfiles=0` disables new profile HTTP requests and displays a disabled-lookups message. Existing local profile files or in-memory results are not automatically erased. Set it to `1` to resume lookups. `Enabled=0` independently disables future automatic update checks and application; set it to `1` to enable them again. Stopping the helper stops profile fetching and scheduling further update checks; an updater process already started may finish its current work. Changing a setting cannot recall information already sent to a server.

Uninstalling removes the helper, updater, BAR Fight's widget files and its request/response files. It leaves other BAR widgets and game data in place. Windows, BAR and websites opened through their own shortcuts have their own behavior outside this client's profile and update requests.

## Maintainer

The client is maintained by [Jens Halvarsson (jehalvar)](https://github.com/jehalvar). Use the public repository's issue tracker for questions about this policy; do not post private account or system information in a public issue.
