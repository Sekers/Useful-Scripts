# Microsoft 365 Email Remediation Toolkit

An interactive PowerShell toolkit for searching, reviewing, and removing harmful email from Exchange Online mailboxes using Microsoft Purview. It preserves incident evidence and keeps searching separate from deletion.

The workflow targets cases without eDiscovery premium features, such as the standard A3/E3 workflow. It does not require Microsoft Graph, Defender for Office 365 Plan 2, or Data Security Investigations billing. Licensing and permissions still apply. See [Microsoft's search-and-delete guidance](https://learn.microsoft.com/en-us/purview/edisc-search-mailbox-data).

## Start here

Open PowerShell 7 in this directory and run:

```powershell
.\Invoke-MailRemediation.ps1
```

The menu offers:

1. **Search:** enter an incident number, administrator account, expected tenant ID, sender, optional subject, UTC dates, and mailbox scope. Choose all mailboxes, a searchable mailbox list, members of a group, or pasted addresses. No messages are removed.
2. **Remove:** select a recent saved run, review the corresponding Purview report, and explicitly confirm removal.
3. **Status:** select a saved run to check the search and purge status and generate a current ticket summary.
4. **Clone:** select a saved search, adjust its filters, and create a new search with separate evidence and review.

**B. Browse runs/evidence** opens a searchable history, and **S. Settings** displays or edits saved defaults and the approved evidence folder. The menu returns after each action until you choose **Q**. Most invalid inputs can be corrected in place. Type `:cancel` or `:back` at an action prompt to return to the menu. Canceling never retries a server mutation.

Saved runs are sorted by their recorded creation time, with ticket, subject, sender, search and removal status, match count, and UTC time. Type `/text` to filter, `/` to clear the filter, and `N` or `P` to page through the complete history. You can also paste a full run folder path. Recent statuses come from saved snapshots; use Status to refresh them from Microsoft.

After an action, quick actions open **P**urview, the **E**vidence folder, or the latest **T**icket summary, or **C**opy that summary to the clipboard. Enter returns to the menu. These actions do not upload evidence or contact a ticket system.

Use a dedicated PowerShell session. Purview uses the `MR` connection prefix. Directory selection uses a separate `MRD` Exchange connection, which closes before the Purview search begins. Both connections check the signed-in account and tenant and close only their own connections. The tenant ID is available in the Entra admin center's Overview page.

## Remembered settings

After a successfully completed Search or Clone, the tool remembers these defaults in **`%LOCALAPPDATA%\M365-EmailRemediationToolkit\settings.json`** for your Windows account:

- Expected tenant ID.
- Administrator sign-in email address.
- Existing Purview case name.
- The stable Purview eDiscovery landing page.
- Approved evidence folder when saved through Settings or a completed Search/Clone.

These identifiers and preferences are stored as plain JSON. They are not authentication secrets; the sign-in address can identify a person, so the file remains in your user profile. Passwords, access tokens, refresh tokens, and application secrets are never stored by this tool. Microsoft's module handles sign-in.

Subsequent searches reuse the saved values. The interactive menu displays the tenant and administrator as defaults you can accept with Enter or change. Explicit command parameters override saved defaults. Case and portal defaults are reused only for the same tenant. Remove and Status always use the selected run's tenant, and reuse the saved administrator only when it belongs to that tenant. The connection identity check still runs.

Only these non-secret defaults are remembered. Ticket numbers, message filters, dates, mailbox/group membership, reports, and deletion choices are not copied into the settings file. Incident evidence stays in the configured evidence directory. A run-specific Purview deep link is kept only with that run; it is never reused for another search.

Use **S. Settings** to view/edit tenant defaults and the evidence location, or type `RESET` to clear defaults while preserving a backup of the exact previous file. You can configure an evidence folder before entering tenant details. Changes to defaults do not modify existing runs.

Use `-NoSavedSettings` to ignore remembered defaults and prevent saving them for that invocation. Use `-SettingsPath 'C:\ApprovedLocation\settings.json'` to change the settings location. Explicit `-DataDirectory` takes precedence over the saved location. Search/Clone saves defaults after completion; Remove, Status, canceled runs, and `-WhatIf` never save defaults. Settings edits are an explicit local action.

By default, run evidence is stored in **`%LOCALAPPDATA%\M365-EmailRemediationToolkit\Runs`**, with one subfolder per run. Settings and run evidence share the same AppData parent folder. Choose another evidence folder through Settings or `-DataDirectory`.

Updates use a file lock, a validated temporary file, atomic replacement, and a unique `.bak` copy of the previous file. Identical defaults are not rewritten. Invalid or unsupported settings are ignored with a warning and preserved. A settings-write failure reports a warning and does not undo or obscure a completed search. Backups contain the same non-secret defaults and remain beside the settings file.

## Prerequisites

- PowerShell **7.4 or later** with ExchangeOnlineManagement 3.9.x, or PowerShell **7.6 or later** with ExchangeOnlineManagement 3.10+. The preflight selects the newest compatible installed module when none is loaded, and rejects an incompatible loaded module before sign-in. [Microsoft compatibility requirements](https://learn.microsoft.com/en-us/powershell/exchange/exchange-online-powershell-v2?view=exchange-ps)
- ExchangeOnlineManagement **3.9.0 or later**. The tool checks the minimum version and uses `Connect-IPPSSession -EnableSearchOnlySession`. It does not automatically install or uninstall modules. [Connection and purge requirements](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-compliancesearchaction?view=exchange-ps)
- A licensed administrator with **Compliance Search** or eDiscovery Manager permissions to search, plus the Purview **Search And Purge** role to remove messages. The Exchange Online and Purview Organization Management groups are separate. [Purview permissions](https://learn.microsoft.com/en-us/purview/edisc-permissions)
- An existing case without premium features. The default is **Content Search**. Use `-CaseName` to select a different existing standard case. The script does not create cases, enable premium features, change roles, or create holds. [Case parameter](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-compliancesearch?view=exchange-ps#-case)
- Directory selection and explicit mailbox validation also require Exchange permission to read mailboxes, recipients, and the selected group's membership. The toolkit uses `Get-Mailbox`, `Get-Recipient`, `Get-DistributionGroupMember`, and `Get-UnifiedGroupLinks` through its prefixed connection. It requests no Microsoft Graph consent and changes no directory objects. All-mailbox searches do not need this directory connection.

If the required module is missing, install it yourself:

```powershell
Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion 3.9.0
```

## Search, review, remove

### 1. Preview the proposed search offline

```powershell
.\Invoke-MailRemediation.ps1 -Mode Search -Ticket INC-1234 `
    -UserPrincipalName admin@contoso.com `
    -TenantId 11111111-1111-1111-1111-111111111111 `
    -SenderAddress suspicious@example.com `
    -Subject 'Update your details' `
    -ReceivedFrom 2026-10-05 -ReceivedThrough 2026-10-06 `
    -WhatIf
```

`-WhatIf` displays the plan without connecting, creating files, creating searches, or submitting removal. Remove previews use saved metadata only and do not verify the current tenant state. This is the wrapper's behavior; it does not rely on the cloud purge command's ineffective `-WhatIf` parameter. [Underlying command](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-compliancesearchaction?view=exchange-ps#-whatif)

### 2. Run the search

Run the same command without `-WhatIf`. For a pilot, add:

```powershell
-Mailboxes 'pilot@contoso.com'
```

For several mailboxes, invoke from PowerShell and pass an array:

```powershell
-Mailboxes @('pilot1@contoso.com', 'pilot2@contoso.com')
```

The default scope is `All`. Specific mailbox addresses scope where to search; they do not add a `to:` condition that could miss Bcc or distribution-list deliveries.

### Mailbox and group selection

| Choice | Behavior |
| --- | --- |
| **All mailboxes** | Uses Purview's `All` scope. This remains an all-mailbox scope when the search is rerun. |
| **Select mailboxes** | Searches the accessible mailbox directory by name, primary address, or SMTP alias. Comma-separated displayed numbers toggle multiple selections; `D` finishes. Selections remain checked while filtering or paging. |
| **Members of a group** | Searches distribution groups, mail-enabled security groups, and Microsoft 365 groups. Expands the selected group's members, including nested supported groups, into individual mailbox addresses. |
| **Paste addresses** | Accepts comma-separated individual mailbox addresses or PowerShell arrays. Resolves aliases to primary addresses, removes duplicates, and rejects addresses that do not resolve to accessible individual mailboxes. Use the group choice for group addresses. |

The directory includes user, shared, room, and equipment mailboxes. Inactive, soft-deleted, public-folder, and group mailboxes are not offered as individual selections. A Microsoft 365 group selection searches its members' mailboxes, rather than the group's own mailbox. Dynamic distribution groups and non-mail-enabled security groups are not offered.

Before accepting a picker/group scope, review the exact mailbox list and type `USE <count>`. External contacts and other confirmed non-mailbox members are displayed as exclusions. An unresolved mailbox, group, or unknown recipient type blocks the search rather than silently narrowing it. Directory access failures return an error; partial results are not silently accepted.

The resolved addresses, source group, expanded nested groups, exclusions, and resolution time are recorded in `run.json`. Purview receives individual mailbox addresses, never a group address. Remove and Status use that saved scope without expanding the group again. A clone keeps the original mailbox list unless you choose a different scope; select the group again to refresh membership intentionally.

Command-line examples:

```powershell
# Supply these scope options with the other Search parameters.
-MailboxMode All
-MailboxMode Select
-MailboxMode Group -GroupAddress 'staff@contoso.com'
-Mailboxes 'alice@contoso.com','bob@contoso.com'
-Mailboxes 'alice@contoso.com,bob@contoso.com'
```

Use the array examples inside PowerShell, not through `pwsh -File`, which cannot pass array arguments. A single comma-separated string works for both entry methods. `-WhatIf` performs no directory sign-in or enumeration; Group and Select previews show that directory resolution is pending.

Directory commands: [mailboxes](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-mailbox?view=exchange-ps), [groups](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-recipient?view=exchange-ps), [distribution/security group members](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-distributiongroupmember?view=exchange-ps), [Microsoft 365 group members](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-unifiedgrouplinks?view=exchange-ps).

Every run gets a unique search name containing its ticket and timestamp. The search description also contains the incident number and a unique run ID. A repeated ticket creates a fresh run; it does not modify an older search.

Dates are **UTC calendar days**, not the workstation's local time. The whole end date is included by searching up to the following day's midnight. Subject input is a phrase filter, not an exact whole-subject match. Longer subjects, replies, or forwards may also match. Double quotes, wildcards, and control characters are rejected rather than silently rewritten. [Query guidance](https://learn.microsoft.com/en-us/purview/edisc-search-query)

To search every available date for a sender, explicitly supply `-AllDates` and omit both dates. If running without parameters, type `ALL` at the first-date prompt. This widens the search; removal still stops if a location has more than ten matches.

### 3. Review in Purview

Open the displayed [Purview eDiscovery link](https://purview.microsoft.com/ediscovery/), select the stated case, and find the exact search name.

Review the actual matches, then use **report-only export** and extract the message metadata CSV from the downloaded export. Check senders, subjects, dates, mailbox locations, and the total matching count. A sample of matches is insufficient for the review attestation. The script's `location-counts.csv` is only a count summary and must not substitute for the message-level Purview report.

The script supplies the stable eDiscovery landing page by default. If you copy a case or search link from your portal, pass it using `-PurviewUrl`; the link is stored only in that run and its ticket summaries. It must use HTTPS on `purview.microsoft.com`. The script does not invent case/search deep-link formats.

### 4. Submit removal

Use the menu's Remove option or:

```powershell
.\Invoke-MailRemediation.ps1 -Mode Remove `
    -RunPath (Join-Path $env:LOCALAPPDATA 'M365-EmailRemediationToolkit\Runs\<saved-run-folder>') `
    -UserPrincipalName admin@contoso.com `
    -ReportPath 'C:\Reports\Results.csv'
```

Remove verifies ownership, query, and mailbox scope, then starts a fresh PowerShell search and waits for a new completed job. Counts and location distributions must match the original run. You must supply the reviewed CSV, enter the reviewed total, type `REVIEWED`, and type a confirmation containing the ticket, count, and removal type. `-Confirm:$false` cannot bypass these typed prompts.

At the report prompt, paste a path (quoted paths are accepted) or type **F** to open the Windows CSV file picker. If the dialog is unavailable or canceled, you can paste a path. The toolkit displays the filename, size, and columns. Invalid prompted paths and counts can be corrected without restarting the action.

The CSV is validated as a non-empty metadata table, copied into the run folder, and recorded with its SHA-256 hash. The script does not automatically prove that the CSV came from the selected Purview search or that you reviewed every row. That remains the administrator's explicit attestation. Matching counts are not proof that individual message identities are identical.

**HardDelete is the default for harmful mail:** users cannot recover it. The interactive Remove action lets you choose HardDelete or SoftDelete; an explicit `-PurgeType` is respected. SoftDelete allows user recovery during the configured retention period. Holds and single item recovery can retain service copies after HardDelete. The tool does not disable those protections or start the Managed Folder Assistant across the tenant. [Deletion behavior](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-compliancesearchaction?view=exchange-ps#-purgetype)

### 5. Verify the result

```powershell
.\Invoke-MailRemediation.ps1 -Mode Status `
    -RunPath (Join-Path $env:LOCALAPPDATA 'M365-EmailRemediationToolkit\Runs\<saved-run-folder>') `
    -UserPrincipalName admin@contoso.com
```

Status saves the provider's latest search/action results and generates a ticket summary. A completed action reports server processing status. To verify removal from normal mailbox folders, run a fresh search/report in Purview and inspect message locations. Retained Recoverable Items copies can still appear in search results.

## Clone and adjust a saved search

Choose **4. Clone** in the menu. Select a run, then accept or change its ticket, sender, subject phrase, dates, mailbox scope, and existing case. Enter keeps a value, including the existing fixed mailbox list at the scope chooser. Type `NONE` to clear an optional subject or ticket URL; type `ALL` to remove date bounds. Choose All mailboxes in the scope chooser to widen mailbox scope.

For a command-line clone, supply only the changes:

```powershell
.\Invoke-MailRemediation.ps1 -Mode Clone `
    -RunPath (Join-Path $env:LOCALAPPDATA 'M365-EmailRemediationToolkit\Runs\<original-run-folder>') `
    -UserPrincipalName admin@contoso.com `
    -Subject 'More distinctive phrase' `
    -ReceivedFrom 2026-10-05 -ReceivedThrough 2026-10-05 `
    -Mailboxes 'pilot@contoso.com' -WhatIf
```

Run without `-WhatIf` to create the new search. Unspecified filters, ticket information, and case are inherited from the selected run. `-Subject ''` clears the subject filter; `-TicketUrl ''` clears that optional link. `-AllDates` clears inherited dates. Supplying date bounds replaces an inherited all-dates choice; provide both bounds when the source had no dates. Clones remain in the source tenant. The Purview link resets to the landing page so an original search deep link cannot point at the wrong search; supply `-PurviewUrl` if you have an appropriate case link.

The clone receives a new search name, run ID, results, and evidence folder. Its `ClonedFrom` record and ticket summary identify the original run. Original searches and files are preserved. Reports, review attestations, and purge actions are not inherited; removal requires a new report review and confirmation for the clone. Cloning never submits removal. If an earlier submission outcome is uncertain, use Status on that original run before deciding on another removal.

Only this tool's saved runs can be cloned. Existing searches created elsewhere in Purview are outside this feature. Purview itself supports query and scope changes through [Set-ComplianceSearch](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/set-compliancesearch?view=exchange-ps). This tool creates a new search to preserve the recorded criteria and evidence. Editing a tool-owned search externally causes its original removal checks to reject the changed search.

## Parameters worth knowing

| Parameter | Purpose |
| --- | --- |
| `-Mode Clone` | Create a new search from a saved run with specified filter changes. |
| `-Ticket`, `-TicketUrl` | Incident identifier and optional HTTPS link; the tool does not contact your ticket system. |
| `-TenantId` | Expected tenant GUID for Search; Remove and Status use the saved run's tenant. |
| `-SenderAddress`, `-Subject` | Sender filter and optional subject phrase. No arbitrary KQL is accepted. |
| `-ReceivedFrom`, `-ReceivedThrough` | First and last UTC dates, formatted `yyyy-MM-dd`. |
| `-AllDates` | Explicitly omit date restrictions. |
| `-Mailboxes` | `All`, or one or more mailbox email addresses. |
| `-MailboxMode` | `All`, `Select`, `Group`, or `Paste` (default). |
| `-GroupAddress` | Primary email address of the group to expand; otherwise Group opens the searchable picker. |
| `-CaseName` | Existing non-premium case; defaults to `Content Search`. |
| `-PurviewUrl` | Landing page or an actual portal link you copied. |
| `-DataDirectory` | Evidence location; explicit value overrides the saved preference. Defaults to `%LOCALAPPDATA%\M365-EmailRemediationToolkit\Runs` when no preference is saved. |
| `-SettingsPath` | User settings JSON; defaults to `%LOCALAPPDATA%\M365-EmailRemediationToolkit\settings.json`. |
| `-NoSavedSettings` | Ignore and do not save user defaults for this invocation. |
| `-RunPath`, `-ReportPath` | Saved run folder and reviewed Purview CSV for removal. |
| `-PurgeType` | `HardDelete` by default, or `SoftDelete`. |
| `-TimeoutSeconds`, `-PollSeconds` | Wait deadline and polling interval; defaults are 1,800 and 5 seconds. |

## Evidence and interrupted runs

Each run contains:

- `run.json`: ticket, tenant, criteria, scope, search name, links, and any resolved directory/group membership snapshot.
- `search.json`: original completed search results.
- `location-counts.csv`: parsed per-location totals when available.
- `events.jsonl`: timestamps, administrator identity, stages, review attestation, report hash, and errors.
- Timestamped search and purge snapshots, including best-effort diagnostics after an error.
- A copy of the reviewed report and timestamped plain-text ticket summaries.

Existing evidence files are never overwritten. A file lock prevents two processes using the same local run folder at once. The lock file can remain on disk; its OS handle is released when the process exits. The tool does not remove the Purview search or purge action afterward.

If Search is interrupted while waiting, use **Status** on its saved run. Once the owned search completes without errors, Status creates the missing original `search.json` and count summary, records `SearchRecovered`, and tells you to review a fresh report. It never replaces an existing baseline, recovers an altered search, or reconstructs a baseline after a removal submission attempt. Recovery does not approve or submit removal.

The submission attempt is written to disk **before** the server call. If the connection is lost or the process is interrupted, use Status. The tool refuses a second submission for that run, even when no action is yet visible or an action has failed. Investigate the original action before manually deciding whether a separate new run is appropriate. This is a local safeguard, not an organization-wide distributed lock.

Search and Status create/read service metadata but do not remove mail. Report copies, summaries, and logs can contain sensitive mailbox information. Run evidence defaults to your local AppData folder. Protect it with appropriate filesystem permissions or use an approved location through `-DataDirectory`. Keep incident evidence outside version control; the tool does not send email or upload it to a ticket system.

## Provider limits and deliberate boundaries

This is an incident-response tool, not a mailbox cleanup or retention tool. Microsoft permits up to **10 items per mailbox/location per PowerShell purge**, across up to **50,000 locations**. `NumBindings` counts primary mailboxes and archives, not people. There is no 100-item tenant-wide cutoff here. [Purge limits](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-compliancesearchaction?view=exchange-ps#-purge), [binding count](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/get-compliancesearch?view=exchange-ps#-identity)

The tool blocks removal if parsed location totals do not cover the search's total count or if a location exceeds ten matches. Provider statistics are text and can change format; an unfamiliar format is blocked rather than assumed safe. Narrow the date, subject, or mailbox scope when needed. There is no automatic loop to work around the limit.

Only indexed email items are targeted. Raw KQL, message-ID filters, sensitivity-label filters, Teams content, SharePoint, OneDrive, arbitrary pre-existing searches, and premium Graph purging are outside this tool's scope. Message-ID conditions are specifically unsuitable for non-premium search-and-delete. [Supported workflow](https://learn.microsoft.com/en-us/purview/edisc-search-mailbox-data)

## Offline validation

The tests replace every Microsoft 365 operation with a mock. They verify query construction, scope/ownership checks, result changes, confirmation gates, wrong-tenant checks, existing-action handling, ambiguous submission outcomes, and offline previews. Toolkit regressions also cover zero/one/many runs, chronological paging and filtering, settings compatibility/reset, interrupted search recovery, directory selection, nested groups/cycles, exclusions, fixed mailbox snapshots, file selection, clipboard/browser actions, and menu recovery. They do not verify live tenant permissions, portal export formats, actual removal, or current service responses. The Windows file dialog itself is not exercised by the mocked tests.

With Pester 5.3 or later installed:

```powershell
Import-Module Pester -MinimumVersion 5.3
$configuration = New-PesterConfiguration
$configuration.Run.Path = '.\Tests'
$configuration.TestRegistry.Enabled = $false
$configuration.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $configuration
```

The registry fixture is disabled because these tests do not use the Windows registry. For static analysis, `PSAvoidUsingWriteHost` can be excluded because console messages are part of the interactive interface.

Validation on October 6, 2026, with PowerShell 7.6.6: all 103 mocked tests passed from the final project folder, all five PowerShell files parsed, production static analysis returned no warnings or errors with the intentional console-output rule excluded, and All/Group entry-point previews passed offline. No tenant connection or live purge was performed. Start with a reviewed search scoped to a pilot mailbox before broad use, including a check of live rerun status/identifiers, scope values returned by Purview, and report export format.
