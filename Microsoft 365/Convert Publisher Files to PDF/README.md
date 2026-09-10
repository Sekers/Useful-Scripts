# Convert Publisher Files to PDF

## Overview

A PowerShell script that bulk exports Microsoft Publisher (.pub) files to PDF using the Publisher COM automation interface. Point it at a single file, a folder of files, or an entire folder tree, and it exports each publication to a PDF sitting next to the original.

This is Microsoft's own sample script, provided in the support article announcing Publisher's retirement. It is committed here unmodified so that any customizations can be tracked as changes against the original.

> **Why this matters:** Microsoft Publisher reaches end of life in October 2026. Microsoft 365 subscribers will not be able to open or edit Publisher files in Publisher after **October 1, 2026**. Support for the perpetual version ends **October 13, 2026**, when Office LTSC 2021 and Consumer Office 2021 reach end of support. Existing .pub files need to be converted to another format before then, and this script needs a working copy of Publisher to do the conversion, so run it while you still have one.
>
> More info: [Microsoft Publisher will no longer be supported after October 2026](https://support.microsoft.com/en-us/publisher/microsoft-publisher-will-no-longer-be-supported-after-october-2026)

---

## Features

- Converts a single .pub file, a wildcard match, or a whole directory tree.
- Writes each PDF beside its source file, using the same base name.
- Skips any file that already has a matching PDF, so a rerun does not clobber earlier output.
- Continues on error rather than stopping at the first bad file.
- Reports each exported file as it goes and finishes with a converted/error count.
- Closes each publication and quits Publisher when finished, even if the run errors out.

---

## Prerequisites

- **Windows with Microsoft Publisher installed and licensed.** The script drives Publisher itself through COM, so the application has to be present and able to open the files.
- **The Office primary interop assemblies (PIAs).** The script calls `Add-Type -AssemblyName Office` and `Add-Type -AssemblyName Microsoft.Office.Interop.Publisher`, both of which are resolved out of the GAC. If Office was installed without the PIAs, these calls fail before any conversion happens.
- **Windows PowerShell 5.1.** `Add-Type -AssemblyName` looks in the GAC, which PowerShell 7 does not use, so the interop load will usually fail there. Run this one in Windows PowerShell.
- **An execution policy that permits running the script.** For example, launch with `powershell.exe -ExecutionPolicy Bypass -File ".\Convert-PubFileToPDF.ps1" -Filter "*.pub"`, or set the policy for the session or the user. See [about_Execution_Policies](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies).
- **Interactive desktop session.** Office automation is not supported as an unattended service; run this signed in as a user who can open the files.

---

## Parameters

- **Filter (String, required):** The file or wildcard pattern selecting the Publisher files to convert. It must end in `.pub`; the script rejects anything else. It can be a specific file (`"C:\Documents\MyFile.pub"`), a pattern in the current directory (`"*.pub"`), or a pattern in another directory (`"C:\Documents\*.pub"`).
- **Recurse (Switch, optional):** Also search subdirectories of the filter's directory. Without it, only the one directory is searched.

---

## Usage

Convert one specific file:

```powershell
.\Convert-PubFileToPDF.ps1 -Filter "C:\Documents\MyFile.pub"
```

Convert every Publisher file in the current directory:

```powershell
.\Convert-PubFileToPDF.ps1 -Filter "*.pub"
```

Convert every Publisher file in the current directory and all subdirectories:

```powershell
.\Convert-PubFileToPDF.ps1 -Filter "*.pub" -Recurse
```

Convert every Publisher file in a specified directory:

```powershell
.\Convert-PubFileToPDF.ps1 -Filter "C:\Documents\*.pub"
```

Convert every Publisher file in a specified directory and all subdirectories:

```powershell
.\Convert-PubFileToPDF.ps1 -Filter "C:\Documents\*.pub" -Recurse
```

---

## Notes

- **Output location is not configurable.** Each PDF is written to the source file's own folder with the extension swapped to `.pdf`. There is no output directory parameter.
- **Existing PDFs are treated as errors, not successes.** If `MyFile.pdf` already exists next to `MyFile.pub`, the script reports an error, counts it against the error total, and moves on without overwriting. Delete or rename the conflicting file and run again if you want it reconverted.
- **The run continues through failures.** Files that cannot be opened or exported are reported individually, and the final line summarizes how many converted and how many errored, for example `Converted 12 files with 2 errors.`
- **Test on copies first.** This drives a real Publisher install against real files. Microsoft provides the script for instructional purposes and recommends modifying and testing it for your own needs.
- **Other formats and export options are available.** See [Document.ExportAsFixedFormat](https://learn.microsoft.com/en-us/office/vba/api/publisher.document.exportasfixedformat) for the parameters this script does not set, including [PbFixedFormatType](https://learn.microsoft.com/en-us/office/vba/api/publisher.pbfixedformattype) (PDF or XPS) and [PbFixedFormatIntent](https://learn.microsoft.com/en-us/office/vba/api/publisher.pbfixedformatintent) (output quality). To export to something other than a fixed format, look at [Document.SaveAs](https://learn.microsoft.com/en-us/office/vba/api/publisher.document.saveas) with a [PbFileFormat](https://learn.microsoft.com/en-us/office/vba/api/publisher.pbfileformat) constant, such as RTF or filtered HTML.

---

## Editing Converted Content Later

PDF preserves what the publication looks like, but it is not an editable format. If you need to keep editing the content after Publisher is gone, Microsoft suggests either of these:

- **PDF to Word:** Convert the .pub to PDF with this script, then open the PDF in Word (File > Open, then OK at the conversion prompt). The result is optimized for text editing, so the layout can shift, especially on graphics-heavy documents.
- **A third-party conversion tool** that goes directly from Publisher to another file type. These vary in quality and capability, and Microsoft does not support them.

Many common Publisher scenarios (branded templates, envelopes and labels, calendars, business cards, programs) are already covered by Word and PowerPoint, and there are customizable templates at [Microsoft Create](https://create.microsoft.com/).
