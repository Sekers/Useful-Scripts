# Microsoft 365 Email Remediation Toolkit

A guided PowerShell tool that finds harmful email, such as phishing, in your organization's Exchange Online mailboxes and deletes it after you review what it found. You answer a few plain questions; the toolkit handles Microsoft Purview and Exchange Online for you, shows you the messages before anything is deleted, and keeps a record of every step.

You do not need to know how Purview searches, cases, or message trace work to use it. This page explains them where it helps.

It works without premium eDiscovery features (for example with Microsoft 365 A3 or E3), without Microsoft Graph, and without Defender for Office 365 Plan 2.

## What you need

- **Windows with PowerShell 7.4 or later.** With ExchangeOnlineManagement 3.10 or later, use PowerShell 7.6 or later.
- **The ExchangeOnlineManagement module, version 3.9.0 or later.** If it is missing, install it:

  ```powershell
  Install-Module ExchangeOnlineManagement -Scope CurrentUser -MinimumVersion 3.9.0
  ```

- **An admin account with these roles:**

  | To do this | The account needs |
  | --- | --- |
  | Search mailboxes | The Purview **eDiscovery Manager** role group, or the **Compliance Search** role |
  | Create a case from the toolkit | The Purview **Case Management** role, which the **eDiscovery Manager** role group includes |
  | Delete messages | The Purview **Search And Purge** role (in the Organization Management or Data Investigator role groups) |
  | Check message trace, pick mailboxes and groups | An Exchange role that includes message trace and recipient lookups, such as **Exchange Administrator** |

  The Exchange Online and Purview "Organization Management" groups are separate; membership in one does not grant the other. [Microsoft's role details](https://learn.microsoft.com/en-us/purview/edisc-search-mailbox-data#before-you-begin)

- **A Purview case for the incident, or permission to create one.** A case is a folder in Purview that holds the searches for one incident. The toolkit can create it for you during a new search (see [Cases](#cases)). You can also make one yourself: open [Purview eDiscovery](https://purview.microsoft.com/ediscovery/), choose **Cases > Create case**, give it a name such as `INC-1234 Phishing`, and leave premium features off. You can reuse the case for every search about that incident.

## Quick start

Open PowerShell 7 in this folder and run:

```powershell
.\Invoke-MailRemediation.ps1
```

The first time, the toolkit offers to remember your Tenant ID, admin account, and evidence folder, so you do not have to type them again. It only saves them on this computer; it does not sign in.

A typical phishing incident looks like this:

1. **Choose 1 (New search).** The toolkit signs you in, then asks, one question at a time:
   - the Purview case for the incident: one you already have, or a new one,
   - your ticket number (suggested from the case name when it contains one) and an optional ticket link,
   - the sender's email address (you can paste it as Outlook shows it, such as `John Reyes <john@example.com>`),
   - optional words from the subject,
   - the first and last day the message arrived,
   - which mailboxes to search (all of them, a list you pick from, the members of a group, or addresses you type).

   It then shows everything on one review screen. Press Enter to create the search (and the case, if you chose a new one), or type an item's number to change it. Nothing is deleted at this stage.

2. **Read the results.** While Purview searches (usually a few minutes for all mailboxes), the toolkit checks Exchange message trace for the same sender and dates. When both finish, you see:
   - how many messages the Purview search found, in how many mailboxes,
   - what message trace says the sender delivered, grouped by subject,
   - any mailbox where the two disagree.

3. **Choose 2 (Delete)** when you are ready, and pick the run. The toolkit runs the search again to make sure nothing changed, shows the review again (type L to list every message), asks whether to delete permanently or recoverably, and asks you to type a short confirmation such as `REMOVE 5678 40 HardDelete`.

4. **Choose 3 (Check status)** at any time to see where a search or deletion stands and to save a fresh ticket summary.

## Moving around

| Type this | To do this |
| --- | --- |
| **Enter** | Keep the value shown in [brackets], or take the default choice |
| **B** | Go back one step, keeping what you already entered |
| **?** | Show help for the current question |
| **:cancel** | Return to the main menu |
| A number or letter in [brackets] | Choose that option |
| **/word** | In a list, show only entries containing that word; **/** alone shows everything |

Capital letters never matter, including in typed confirmations. A wrong answer asks again rather than canceling.

Colors always mean the same thing:

| Color | Meaning |
| --- | --- |
| Cyan | A screen or step title |
| Gray | A hint or background detail |
| Yellow | Needs your attention, or your answer was not accepted and the question is asked again |
| Yellow with `WARNING:` | A problem found in the search results, such as mailboxes where the search and message trace disagree |
| Green | Finished as intended |
| Red | Something failed, or the next step cannot be undone |

## Signing in

The toolkit uses two Microsoft services, so you may see two sign-in windows the first time:

- **Microsoft Purview** for cases, searches, and deletion.
- **Exchange Online** for the mailbox and group lists and for message trace.

Sign-in windows can open behind the PowerShell window. After you sign in, the toolkit stays signed in for that PowerShell window, so later actions, and later runs of the script in the same window, do not ask again. If you sign in with a different account or tenant, it signs out of the old one first. Choose **O** in the main menu to sign out, or close the PowerShell window.

## The review before deleting

Purview's PowerShell commands report how many messages a search found in each mailbox, but not which messages. (Microsoft disabled the PowerShell preview and report actions for searches in May 2025.) So the toolkit adds its own check:

- **Message trace** is Exchange's delivery log. It lists each message the sender delivered, with the recipient, subject, time, and whether it reached the inbox, Junk Email, or quarantine. The toolkit compares it with the search, mailbox by mailbox.
- **When they agree**, you can be confident the search found the messages you meant. A typical result is "40 messages, one subject, 40 mailboxes; search and trace agree for all 40 mailboxes".
- **When they differ**, the toolkit lists the mailboxes. If the trace shows more, the user usually deleted the message already, or it went to quarantine; that is harmless, because only what the search finds is deleted.
- **If the search found messages the trace does not show**, nobody has seen those messages yet, so the toolkit asks for a report from the Purview portal before it will delete anything.

When message trace cannot cover a search, the toolkit says which of these situations it is and what you can do, right after the search finishes (so you can start the export) and again at Delete:

| Situation | Why message trace misses it | What you can do |
| --- | --- | --- |
| The mail is older than 90 days, or you chose all dates | Message trace keeps only the last 90 days | If the phishing is recent, copy the search (menu 4) with dates inside the last 90 days, and no report is needed |
| Message trace finds no mail from the sender | Message trace looks up the hidden sender address (the MAIL FROM, usually in the Return-Path header), not the From address Outlook shows; phishing often uses a different one ([Microsoft's note](https://learn.microsoft.com/exchange/monitoring/trace-an-email-message/message-trace-faq)) | Export the portal report. To confirm, compare the Return-Path and From lines in the message headers |
| The sender has a mailbox in your organization | Their own copies, such as in Sent Items, are not deliveries | Export the portal report to check those copies |
| Some mailboxes have more copies than were delivered | For example, a message redirected or forwarded to that mailbox, or one sent with a different hidden sender address | Export the portal report |
| Message trace is not available | Your account lacks an Exchange role that can run message trace, or Exchange Online did not sign in | Fix the cause and choose Delete again, which runs message trace again; or export the portal report |

The toolkit shows the export steps with the case and search names filled in: open the case and the search in the portal, choose **Export**, choose **Export items report only** under Export type, download it from **Process manager**, extract it, and give the toolkit the item report CSV. You can also attach such a report as extra evidence when message trace is available.

Other limits come from Microsoft:

- Purview deletes at most **10 messages per mailbox** at a time. The toolkit refuses to delete if any mailbox has more; narrow the dates or subject words.
- One deletion can cover at most **50,000 mailboxes**.
- Messages that Purview could not index are not deleted.

**Permanent (HardDelete)** deletion means users cannot get the messages back; use it for phishing. **Recoverable (SoftDelete)** moves them to Recoverable Items, where users can restore them for a while. Either way, holds and retention policies can keep copies inside Microsoft 365. [Deletion details](https://learn.microsoft.com/en-us/powershell/module/exchangepowershell/new-compliancesearchaction?view=exchange-ps#-purgetype)

## Cases

Use one case per incident, with as many searches in it as you need (for example a first search by sender, then a narrower one by subject).

The first question of a new search asks which case to use:

- **1 (Choose an existing case)** lists the cases your account can use, Active ones first. Type **L** to see closed cases, **T** for all of them, and **/word** to find a case by name. A closed case can be viewed but not searched; reopen it in the portal first. If none of the cases fits, type **C** to create a new one instead.
- **2 (Create a new case)** asks for its name without showing the list.

A new case is created only when you accept the review screen, so going back or canceling before that leaves nothing in Purview. If Purview refuses the name, the review screen opens again with every answer kept, so you can change the case or try again.

Case names can be up to 64 characters and must be unique across your organization. Including the ticket number, such as `Ticket #5678 Phishing`, lets the next question suggest it. If you type the name of a case you can already see, the toolkit offers to use that case instead of making a duplicate. A name can also belong to another admin's case that you cannot see; Purview then refuses it and you choose another. The new case has no premium features, and its description notes the ticket and that the toolkit created it. Other admins see it only if they are eDiscovery Administrators or you add them to the case in the portal.

The toolkit does not offer Purview's built-in **Content Search** case. In testing on October 8, 2026, a search the toolkit created there did not appear in the Purview portal, while a search created the same way in an ordinary case did. The toolkit can still show searches already in Content Search under **5 (Purview cases)**, but it only creates new searches in incident cases.

## Ticket links

The ticket link is optional and works with any helpdesk or ticketing system. If the link you type contains the ticket number, the toolkit remembers the pattern, such as `https://helpdesk.example.com/tickets/{ticket}`, and fills in the next ticket number for you. If your system's links do not contain the ticket number, nothing is remembered and you type or skip the link each time. You can also set or clear the pattern in **S (Settings)**.

## Records and logs

Every search gets its own folder, by default under `%LOCALAPPDATA%\M365-EmailRemediationToolkit\Runs`. Choose another place in Settings, such as a folder approved for incident records.

| File | What it holds |
| --- | --- |
| `run.json` | The ticket, case, sender, subject, dates, mailboxes, and the exact Purview query, plus when the toolkit created the case if it did |
| `search.json`, `location-counts.csv` | What the search found when it first completed, per mailbox |
| `message-trace-messages-*.csv` | Every message trace row, with recipient, subject, time, and delivery status |
| `message-trace-comparison-*.csv` | The per-mailbox comparison of search and trace |
| `message-trace-review-*.json` | The summary shown on screen |
| `reviewed-report-*.csv` | A copy of any portal report you attached, with its SHA-256 hash recorded |
| `events.jsonl` | Each step for this run, with times, the admin account, and the session ID |
| `ticket-summary-*.txt` | A plain-text summary you can paste into your ticket |
| `search-*.json`, `purge-*.json` | Snapshots of what Purview reported at each step |

Existing files are never overwritten. Subjects in the CSV files that start with `=`, `+`, `-`, or `@` get a leading `'` so a spreadsheet does not run them as formulas.

**Session log.** Each time the toolkit starts, it writes a log in `%LOCALAPPDATA%\M365-EmailRemediationToolkit\Logs` (change it with `-LogDirectory`). It records every answer typed, every action started and finished, each sign-in and sign-out, each Purview and message trace step, and errors. The Windows user, computer, and toolkit version are recorded at the start. Each run's `events.jsonl` includes the session ID, so you can match a run to the session that created or deleted it. Open the folder from **S (Settings) > L**. Previews (`-WhatIf`) are not logged.

These files contain email addresses, subjects, and ticket numbers. Keep them in a protected location and out of version control. The toolkit never uploads them anywhere.

**Settings** are saved in `%LOCALAPPDATA%\M365-EmailRemediationToolkit\settings.json`: the Tenant ID, admin sign-in email, last case used, ticket link pattern, and evidence folder. No passwords or tokens are ever saved; Microsoft's module handles sign-in. Settings changes keep a backup of the previous file.

## Running from the command line

Every action also works with parameters, for scripts or repeat use. Preview any of them with `-WhatIf`, which signs in to nothing and writes nothing.

```powershell
# Create a search (nothing is deleted), and the case too if it does not exist yet
.\Invoke-MailRemediation.ps1 -Mode Search -CaseName 'INC-1234 Phishing' -CreateCase -Ticket INC-1234 `
    -TenantId 11111111-1111-1111-1111-111111111111 -UserPrincipalName admin@contoso.com `
    -SenderAddress phish@example.com -ReceivedFrom 2026-10-05 -ReceivedThrough 2026-10-06

# Review and delete what a saved run found (asks for the typed confirmation)
.\Invoke-MailRemediation.ps1 -Mode Remove -RunPath 'C:\IncidentEvidence\MR-INC-1234-20261006T120000Z-1a2b3c4d'

# Check a saved run, or sign out of this window
.\Invoke-MailRemediation.ps1 -Mode Status -RunPath 'C:\IncidentEvidence\MR-INC-1234-20261006T120000Z-1a2b3c4d'
.\Invoke-MailRemediation.ps1 -Mode SignOut
```

| Parameter | Purpose |
| --- | --- |
| `-Mode` | `Menu` (default), `Search`, `Clone` (copy a saved run), `Remove`, `Status`, `BrowsePurview`, or `SignOut` |
| `-CaseName` | The Purview case for a new search. Required on the command line; the menu offers a list or creates one |
| `-CreateCase` | Create the `-CaseName` case if it does not exist yet. An Active case with that name is used as it is; a closed one stops the search |
| `-Ticket`, `-TicketUrl` | Ticket number and optional https link |
| `-TenantId`, `-UserPrincipalName` | Tenant ID and admin sign-in email; saved settings are used when omitted |
| `-SenderAddress`, `-Subject` | Sender address and optional subject words |
| `-ReceivedFrom`, `-ReceivedThrough`, `-AllDates` | First and last UTC day (yyyy-MM-dd), or every date |
| `-Mailboxes`, `-MailboxMode`, `-GroupAddress` | `All`, specific addresses, a picker (`Select`), or a group's members (`Group`) |
| `-RunPath`, `-ReportPath` | A saved run folder, and an optional portal report CSV for Remove |
| `-PurgeType` | `HardDelete` (default) or `SoftDelete` |
| `-DataDirectory`, `-SettingsPath`, `-LogDirectory` | Where runs, settings, and session logs are kept |
| `-NoSavedSettings` | Ignore saved settings for this run and do not save new ones |
| `-TimeoutSeconds`, `-PollSeconds` | How long to wait for Purview (default 1,800 seconds) and how often to check |

In PowerShell, pass several mailboxes as `-Mailboxes 'alice@contoso.com','bob@contoso.com'`. With `pwsh -File`, use one comma-separated string instead.

## What the toolkit will not do

- Delete anything during a search, or delete without showing you the review and getting your typed confirmation.
- Delete if the search now finds different messages than when it was created, or if anything about the search was changed outside the toolkit.
- Submit a second deletion for the same run, even after a lost connection. Use Check status, and create a new search if more is needed.
- Delete from a search it did not create. Under **5 (Purview cases)** you can view existing searches, or copy their criteria into a new search with its own review.
- Change roles, holds, retention settings, or existing cases. Besides searches and deletions, the only thing it creates in Purview is a new case, and only when you ask for one.
- Send email, update your helpdesk, or upload records anywhere.

## Testing

The tests replace every Microsoft 365 call with a fake, and fail if any code tries a real sign-in. With Pester 5.3 or later:

```powershell
Import-Module Pester -MinimumVersion 5.3
$configuration = New-PesterConfiguration
$configuration.Run.Path = '.\Tests'
$configuration.TestRegistry.Enabled = $false
$configuration.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $configuration
```

For static analysis, exclude `PSAvoidUsingWriteHost`, because console messages are the interface.

Validation on October 8, 2026, with PowerShell 7.6.6 and Pester 6.1.0: all 287 tests passed, and static analysis found no warnings or errors in the toolkit files. The script was also run with typed input: a full guided search in preview mode (including going back and changing an answer from the review screen), and a normal start and quit that wrote a session log. The new message trace review, sign-in reuse, session log, and case creation have not yet been run against a live tenant. Before relying on them, run a search scoped to your own mailbox, check the trace review against what you see in Outlook, and try Delete with recoverable deletion. To check case creation, create a test case from the toolkit and confirm it appears in the Purview portal with the search in it.
