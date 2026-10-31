# Changelog for M365 Teams Membership Sync

## 2.0.0 (2026-10-30)

### Changed

- **BREAKING CHANGE:** Requires PowerShell 7.6 or later, because Microsoft is [retiring Windows PowerShell 5.1 support in the Microsoft Graph PowerShell SDK](https://devblogs.microsoft.com/microsoft365dev/investing-in-a-more-reliable-microsoft-graph-powershell-experience/).
- **BREAKING CHANGE:** Requires Microsoft.Graph.Authentication 2.41.2 or later.
- The script calls the Microsoft Graph API directly with `Invoke-MgGraphRequest` instead of the Graph SDK's cmdlets, so it no longer waits on fixes for bugs in those cmdlets, such as [the channel member bug](https://github.com/microsoftgraph/msgraph-sdk-powershell/issues/3471) that kept it on Graph SDK 2.25.0. It still signs in with the SDK's Microsoft.Graph.Authentication module, which is safer than handling certificates, secrets, and tokens in the script, and its requests still get the SDK's retries for throttled calls.
- A PowerShell version that's too old, or a missing or too old Microsoft.Graph.Authentication module, now stops the script with a logged error, and the error email when it's enabled.

### Fixed

- Exchange group support works with ExchangeOnlineManagement 3.10.1, which fails to sign in when Graph SDK 2.25.0 is loaded in Windows PowerShell 5.1.
- Removing disabled accounts from a Team now checks every member of the Team, not only the first 100.
- When Microsoft Graph adds only some of a Team's new members, each one it couldn't add now gets a warning, in the log and the warning email, instead of being logged as added.

---

## [1.0.0](https://github.com/Sekers/Useful-Scripts/tree/5222a16a5c1959049214f6196b3d556ea8ba4528/Microsoft%20365/Teams%20Membership%20Sync) (2026-10-12)

First version with a version number. Earlier changes are in the [git history](https://github.com/Sekers/Useful-Scripts/commits/main/Microsoft%20365/Teams%20Membership%20Sync).
