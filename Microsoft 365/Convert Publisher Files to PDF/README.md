# Convert Publisher Files to PDF

## Overview

A PowerShell script that bulk exports Microsoft Publisher (.pub) files to PDF by driving Publisher itself through COM automation. Point it at a single file, a folder, or a wildcard pattern, and it writes each PDF next to its source file.

This started as [Microsoft's own sample script](https://support.microsoft.com/en-us/publisher/microsoft-publisher-will-no-longer-be-supported-after-october-2026), published alongside the announcement that Publisher is being retired. The unmodified original is [the first commit in this folder](https://github.com/Sekers/Useful-Scripts/commit/70397628351ea99d8795b0bba66bb276d8829a87), so the changes since then can be read as a diff. See [Changes from Microsoft's sample](#changes-from-microsofts-sample) below for what is different and why.

> **Why this matters:** Microsoft is retiring Publisher. Microsoft 365 subscribers lost access to Publisher on or shortly after **October 1, 2026**. Support for the perpetual (non-subscription) version ended on **October 13, 2026**, when Office LTSC 2021 and Consumer Office 2021 reached end of support, but Microsoft says it can still be installed and used after that date. This script needs a working copy of Publisher, so run it on a PC that still has one.

---

## Features

- Converts a single .pub file, a folder, a folder tree, or a wildcard pattern.
- Writes each PDF beside its source file, with the same name.
- Skips files that already have a PDF, or replaces them or keeps both if you ask (see `-ExistingPdf` under [Parameters](#parameters)).
- Keeps going when a file fails, and reports how many files were converted, skipped, and failed.
- Sets an [exit code](#exit-codes) that a scheduled task can check.
- Closes Publisher when it finishes, even if the run fails partway.

---

## Prerequisites

- **Windows with Microsoft Publisher installed and licensed.** The script drives Publisher through COM, so the application has to be present and able to open the files.
- **Windows PowerShell 5.1 or PowerShell 7.** Both are tested.
- **Permission to run the script.** By default, Windows won't run a script downloaded from the internet. To allow it in one PowerShell window, run `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` there first, or start the script with `powershell.exe -ExecutionPolicy Bypass -File ".\Convert-PubToPDF.ps1" -Path "C:\Documents"`. See [about_Execution_Policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies).
- **An interactive desktop session.** Office automation is not supported as an unattended service; run this signed in as a user who can open the files.
- **Close Publisher first.** The script calls `Quit` when it finishes. It starts and closes its own instance rather than taking over one you already have open, but closing your own work first is the safe habit.

---

## Parameters

- **Path (String):** A folder to search, the path of a single .pub file, or a wildcard pattern such as `C:\Documents\*.pub` or `C:\Documents\Newsletter*.pub`. Defaults to the current directory. With `-Recurse`, a pattern also matches in every subfolder.
  - A path that exists exactly as typed is always taken literally, so file and folder names containing `[` or `]` work as expected. In a wildcard pattern, `[` and `]` are wildcards, so for a folder whose name contains them, pass the folder itself rather than a pattern.
  - `-Filter` is another name for this parameter, kept so the commands in Microsoft's original instructions still work.
- **Recurse (Switch):** Search subfolders as well. Has no effect when `-Path` is a single file.
- **ExistingPdf (String):** What to do when a .pub file's PDF already exists: a file with the same name and a `.pdf` extension in the same folder. Only the name is compared, not dates or contents.
  - `Skip` (default): leave the existing PDF, don't convert that file, and list it as skipped. An interrupted run picks up where it stopped, and a scheduled run converts only new files. A PDF with the right name counts as done even if it came from somewhere else or the .pub has changed since; use `Replace` to convert those files again.
  - `Replace`: convert the file and overwrite the existing PDF.
  - `KeepBoth`: convert the file to a numbered PDF, such as `Flyer (2).pdf`, and leave the existing one.

---

## Usage

Convert every .pub file in the folder PowerShell is currently in:

```powershell
.\Convert-PubToPDF.ps1
```

Convert one specific file:

```powershell
.\Convert-PubToPDF.ps1 -Path "C:\Documents\MyFile.pub"
```

Convert every .pub file in a folder, optionally including subfolders:

```powershell
.\Convert-PubToPDF.ps1 -Path "C:\Documents"
.\Convert-PubToPDF.ps1 -Path "C:\Documents" -Recurse
```

Convert by wildcard pattern:

```powershell
.\Convert-PubToPDF.ps1 -Path "C:\Documents\*.pub"
.\Convert-PubToPDF.ps1 -Path "*.pub" -Recurse
```

Convert only files whose name matches something more specific:

```powershell
.\Convert-PubToPDF.ps1 -Path "C:\Documents\Newsletter*.pub" -Recurse
```

Convert everything again, replacing the PDFs from an earlier run, or keeping them alongside numbered new copies:

```powershell
.\Convert-PubToPDF.ps1 -Path "C:\Documents" -Recurse -ExistingPdf Replace
.\Convert-PubToPDF.ps1 -Path "C:\Documents" -Recurse -ExistingPdf KeepBoth
```

The commands from Microsoft's original instructions still work:

```powershell
.\Convert-PubToPDF.ps1 -Filter "C:\Documents\*.pub" -Recurse
```

---

## Exit Codes

| Code | Meaning |
| ---- | ------- |
| 0 | No matched file failed to convert. Files skipped because their PDF already exists are not failures. |
| 1 | Nothing matched, the path was not found, the path was not a .pub file, a folder could not be searched, Publisher could not be started, or at least one file failed to convert. |

---

## Notes

- **There is no output folder option.** Each PDF goes in its source file's folder.
- **Problems are reported as they happen.** Each file that can't be opened or exported is reported, and so is each subfolder that can't be read. The run carries on, and the last line summarizes it, for example `Converted: 12, skipped: 3, failed: 2.` With `Replace`, a PDF that another program has locked can't be overwritten, so that file fails and its old PDF is left as it was.
- **An interrupted run leaves no partial PDFs.** Publisher exports to a temporary file in the same folder and renames it only when the export finishes, so the default `Skip` never mistakes a half-written PDF for a finished one. If a run is stopped partway, that temporary file (named like `mso1234.tmp`) can be left in the folder of the publication being exported; delete it.
- **Test on copies first.** This drives a real Publisher install against real files. Microsoft provides the original for instructional purposes and recommends modifying and testing it for your own needs.
- **Other formats and export options are available.** See [Document.ExportAsFixedFormat](https://learn.microsoft.com/en-us/office/vba/api/publisher.document.exportasfixedformat) for the parameters this script does not set, including [PbFixedFormatType](https://learn.microsoft.com/en-us/office/vba/api/publisher.pbfixedformattype) (PDF or XPS) and [PbFixedFormatIntent](https://learn.microsoft.com/en-us/office/vba/api/publisher.pbfixedformatintent) (output quality). To export to something other than a fixed format, look at [Document.SaveAs](https://learn.microsoft.com/en-us/office/vba/api/publisher.document.saveas) with a [PbFileFormat](https://learn.microsoft.com/en-us/office/vba/api/publisher.pbfileformat) constant, such as RTF or filtered HTML.

---

## Changes from Microsoft's Sample

Compared with the original:

- **Renamed** from Microsoft's `Convert-PubFileToPDF.ps1` to `Convert-PubToPDF.ps1`.
- **`-Path` replaces `-Filter`.** The original took a required `-Filter` holding a file or pattern. `-Path` also takes a folder and defaults to the current directory, and `-Filter` still works as another name for it, so every command in Microsoft's article works unchanged.
- **No Office interop assemblies.** The original loaded `Office` and `Microsoft.Office.Interop.Publisher` with `Add-Type`, which resolves them from the GAC and fails under PowerShell 7. The script now passes the PDF format as its value (`pbFixedFormatTypePDF` is `2`) through late-bound COM, so it runs in both editions.
- **Existing PDFs are skipped, not counted as errors.** The original refused to convert a file whose PDF already existed and counted it as a failure. `-ExistingPdf` can also replace the PDF or keep both.
- **Literal path handling.** The path you give is checked as typed before it is treated as a pattern, so names containing `[` or `]` work. The original always treated it as a pattern, which misreads them.
- **Office owner files are skipped.** Files named `~$...`, which Office uses as lock files, are left out even when they end in `.pub`.
- **Publications are opened read-only,** so the conversion never changes a .pub file, and the files it opens stay out of Publisher's Recent list.
- **Works around a Publisher export hang.** In Windows PowerShell 5.1, checking for an existing PDF with `Test-Path` while Publisher is running can make the export hang, with no error, until `mspub.exe` is ended. The script checks for files with .NET calls instead, which avoids it.
- **Meaningful exit codes.** The original exited 0 even when every file failed. Now a failed file, or a folder that couldn't be searched, makes it 1. See [Exit Codes](#exit-codes).
- **Clearer errors.** When Publisher can't be started, the error now includes the reason.

---

## Editing Converted Content Later

PDF preserves what the publication looks like, but it is not an editable format. If you need to keep editing the content after Publisher is gone, Microsoft suggests either of these:

- **PDF to Word:** Convert the .pub to PDF with this script, then open the PDF in Word (File > Open, then OK at the conversion prompt). The result is optimized for text editing, so the layout can shift, especially on graphics-heavy documents.
- **A third-party conversion tool** that goes directly from Publisher to another file type. These vary in quality and capability, and Microsoft does not support them.

Many common Publisher scenarios (branded templates, envelopes and labels, calendars, business cards, programs) are already covered by Word and PowerPoint, and there are customizable templates at [Microsoft Create](https://create.microsoft.com/).
