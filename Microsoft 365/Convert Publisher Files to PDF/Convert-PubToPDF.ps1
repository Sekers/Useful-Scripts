<#
.SYNOPSIS
	Converts Microsoft Publisher .pub files to PDF format.

.DESCRIPTION
	Automates the conversion of Microsoft Publisher (.pub) files to PDF using the Publisher COM
	automation interface. Each PDF is written next to its source .pub file with the same base name.

	When a PDF of that name already exists, -ExistingPdf decides what happens: skip that file (the
	default), replace the PDF, or keep both by writing a numbered copy such as "Flyer (2).pdf".

	Close Microsoft Publisher before running this script. The script starts its own instance of
	Publisher and quits it when done, leaving one you already have open alone, but closing your own
	work first is the safe habit.

.PARAMETER Path
	The folder to search for .pub files, the path of a single .pub file, or a wildcard pattern such
	as "C:\Documents\*.pub" or "C:\Documents\Newsletter*.pub". Defaults to the current directory.
	With -Recurse, a pattern also matches in every subfolder.

	A path that exists exactly as typed is taken literally, so names containing [ or ] work. In a
	wildcard pattern, [ and ] are wildcards, so for a folder whose name contains them, pass the
	folder itself rather than a pattern.

	-Filter is another name for this parameter, kept so the commands in Microsoft's original
	instructions still work.

.PARAMETER Recurse
	Search subfolders as well. Has no effect when -Path is a single file.

.PARAMETER ExistingPdf
	What to do when a .pub file's PDF already exists: a file with the same name and a .pdf
	extension in the same folder. Only the name is compared, not dates or contents.

	  Skip      Leave the existing PDF and do not convert that file. The default, so an
	            interrupted run picks up where it stopped, and a scheduled run converts only
	            new files.
	  Replace   Convert the file and overwrite the existing PDF.
	  KeepBoth  Convert the file to a numbered PDF, such as "Flyer (2).pdf", and leave the
	            existing one.

.EXAMPLE
	Convert-PubToPDF.ps1
	Converts every .pub file in the current directory.

.EXAMPLE
	Convert-PubToPDF.ps1 -Path "C:\Documents\MyFile.pub"
	Converts the specified Publisher file to PDF.

.EXAMPLE
	Convert-PubToPDF.ps1 -Path "C:\Documents"
	Converts every .pub file directly inside C:\Documents.

.EXAMPLE
	Convert-PubToPDF.ps1 -Path "C:\Documents" -Recurse
	Converts every .pub file in C:\Documents and all of its subfolders.

.EXAMPLE
	Convert-PubToPDF.ps1 -Path "C:\Documents\*.pub"
	Converts every .pub file directly inside C:\Documents, selected by wildcard pattern.

.EXAMPLE
	Convert-PubToPDF.ps1 -Path "C:\Documents\Newsletter*.pub" -Recurse
	Converts the .pub files whose name starts with "Newsletter", in C:\Documents and its subfolders.

.EXAMPLE
	Convert-PubToPDF.ps1 -Path "C:\Documents" -Recurse -ExistingPdf Replace
	Converts every .pub file in C:\Documents and its subfolders, replacing PDFs from an earlier run.

.EXAMPLE
	Convert-PubToPDF.ps1 -Filter "C:\Documents\*.pub" -Recurse
	The form used in Microsoft's original instructions, which still works.

.NOTES
	Exit codes: 0 when no matched file failed to convert; files skipped because their PDF exists
	are not failures. 1 if nothing matched, if a folder could not be searched, if Publisher could
	not be started, or if any file failed to convert.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Colored status messages for the person running it. Write-Host writes to the information stream, so they can still be captured or redirected.')]
param
(
	[Parameter(Position = 0)]
	[Alias('Filter')]
	[ValidateNotNullOrEmpty()]
	[string]
	$Path = '.',

	[switch]
	$Recurse,

	[ValidateSet('Skip', 'Replace', 'KeepBoth')]
	[string]
	$ExistingPdf = 'Skip'
)

# The script reports each failure, carries on with the next file, and sets the exit code at the
# end. A 'Stop' preference inherited from the caller, or passed as -ErrorAction, would end the run
# at the first unreadable folder or bad file instead.
$ErrorActionPreference = 'Continue'

# pbFixedFormatTypePDF. Passed as a literal because the Office interop assemblies cannot be loaded
# in PowerShell 7 (no GAC probing), and COM late binding does not need them.
$PdfFormat = 2

# 0 unless something fails; skipped files are not failures. Set to 1 by any failure so this is safe
# to run as a task.
$exitCode = 0

function Test-AnyPath {
	param
	(
		[Parameter(Mandatory, Position = 0)]
		[string]
		$LiteralPath
	)

	# Deliberately .NET rather than Test-Path. Under Windows PowerShell 5.1, when a folder already
	# held a publication's PDF, checking for it with Test-Path while Publisher was running made the
	# export hang, with no dialog and no error, until mspub.exe was ended. It hung every time in
	# testing with Windows PowerShell 5.1.26100 and Publisher 16.0.20326. The same checks through
	# .NET never hung, and PowerShell 7.6 did not hang either way. Use .NET calls, not Test-Path or
	# Join-Path, for every check made while Publisher is running. [IO.File]::Exists is false for a
	# directory, so check for one too, as Test-Path would.
	return ([System.IO.File]::Exists($LiteralPath) -or [System.IO.Directory]::Exists($LiteralPath))
}

function Get-AvailablePath {
	param
	(
		[Parameter(Mandatory, Position = 0)]
		[string]
		$CandidatePath
	)

	# Test-AnyPath and Path.Combine rather than Test-Path and Join-Path: see Test-AnyPath.
	if (-not (Test-AnyPath $CandidatePath)) { return $CandidatePath }

	$dir  = [System.IO.Path]::GetDirectoryName($CandidatePath)
	$base = [System.IO.Path]::GetFileNameWithoutExtension($CandidatePath)
	$ext  = [System.IO.Path]::GetExtension($CandidatePath)

	$n = 2
	do {
		$next = [System.IO.Path]::Combine($dir, ('{0} ({1}){2}' -f $base, $n, $ext))
		$n++
	} while (Test-AnyPath $next)

	return $next
}

try {
	$files = @()
	$searchErrors = @()

	# -Path is a folder, a single file, or a wildcard pattern. Anything that exists as typed is
	# taken literally first: [ and ] are legal in file names but are also wildcard character
	# classes, so "[draft] promo.pub" has to be matched as typed rather than as a pattern. Only a
	# path that does not exist as typed is treated as a pattern.
	# A folder that can't be read is reported and the search goes on, rather than ending the run.
	# The errors are kept so the exit code can say that some files may have been missed.
	if (Test-Path -LiteralPath $Path -PathType Container) {
		$files = @(Get-ChildItem -LiteralPath $Path -Filter '*.pub' -File -Recurse:$Recurse -ErrorVariable searchErrors)
	} elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
		# -Force so a hidden file asked for by name is still found.
		$file = Get-Item -LiteralPath $Path -Force

		if ($file.Extension -ne '.pub') {
			Write-Error "Not a Publisher file: $($file.FullName). Specify a .pub file, a folder, or a pattern such as '*.pub'.";
			exit 1;
		}

		$files = @($file)
	} elseif ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Path)) {
		$files = @(Get-ChildItem -Path $Path -File -Recurse:$Recurse -ErrorVariable searchErrors)
	} else {
		# Not a pattern and not on disk. Get-Item raises the clean "cannot find path" error for us.
		$null = Get-Item -LiteralPath $Path -ErrorAction Stop
	}

	# A pattern can match any file, and in the folder branch the filesystem provider handles
	# -Filter, which under Windows PowerShell also matches 8.3 short names: "*.pub" there returns
	# report.publish (REPORT~1.PUB) and draft.pubx (DRAFT~1.PUB). PowerShell 7 does not do this.
	# Re-check the real extension so both behave the same.
	# Also skip files named like Office owner files (~$...), which are lock files, not publications.
	$files = @($files | Where-Object { $_.Extension -eq '.pub' -and $_.Name -notlike '~$*' })

	if ($files.Count -eq 0) {
		Write-Error "No .pub files found matching: $Path";
		exit 1;
	}

	$successCount = 0;
	$skipCount = 0;
	$failCount = 0;

	# Skip before starting Publisher, so a run with nothing left to convert never starts it.
	if ($ExistingPdf -eq 'Skip') {
		$toConvert = [System.Collections.Generic.List[object]]::new()
		foreach ($file in $files) {
			$pdfFilePath = [System.IO.Path]::ChangeExtension($file.FullName, '.pdf');
			if (Test-AnyPath $pdfFilePath) {
				Write-Host "Skipped, PDF already exists: $pdfFilePath" -ForegroundColor Yellow;
				$skipCount++;
			} else {
				$toConvert.Add($file)
			}
		}
		$files = $toConvert
	}

	if ($files.Count -eq 0) {
		Write-Host "Nothing to convert: every matched file already has a PDF." -ForegroundColor Green;
	} else {
		Write-Host "Running...";

		try {
			$app = New-Object -ComObject Publisher.Application -ErrorAction Stop;
		} catch {
			Write-Error "Microsoft Publisher is not installed or accessible. $_";
			exit 1;
		}

		$fileNumber = 0;
		foreach ($file in $files) {
			$fileNumber++;
			$fileFullName = $file.FullName;
			# Named before the work starts, so a run that stops responding shows which file it is on.
			Write-Host "Converting $fileNumber of $($files.Count): $fileFullName" -ForegroundColor Cyan;
			$pdfFilePath = [System.IO.Path]::ChangeExtension($fileFullName, '.pdf');
			$replacing = $false;

			if ($ExistingPdf -eq 'KeepBoth') {
				# Chosen here rather than up front: an earlier file in this run may have just taken
				# the name, such as Flyer.pub writing "Flyer (2).pdf" before "Flyer (2).pub" comes up.
				$pdfFilePath = Get-AvailablePath $pdfFilePath;
			} elseif ($ExistingPdf -eq 'Replace') {
				# Only for the message. Publisher's export overwrites an existing PDF without asking.
				$replacing = Test-AnyPath $pdfFilePath;
			}

			# Clear it so a failed Open cannot leave the previous iteration's closed document in place.
			$doc = $null;

			# Open the file read-only, and keep it out of Publisher's Recent list.
			try {
				$doc = $app.Open($fileFullName, $true, $false);
			} catch {
				$failCount++;
				Write-Error "Error opening file: $fileFullName $_";
				continue;
			}

			if (-not($doc)) {
				$failCount++;
				Write-Error "Failed to open file: $fileFullName";
				continue;
			}

			try {
				# Export file as PDF. Publisher writes to a temporary file in the same folder and
				# renames it when done, so an interrupted export never leaves a partial PDF.
				$doc.ExportAsFixedFormat($PdfFormat, $pdfFilePath);
				# .NET rather than Test-Path: see Test-AnyPath.
				if ([System.IO.File]::Exists($pdfFilePath)) {
					if ($replacing) {
						Write-Host "Exported to $pdfFilePath, replacing the existing PDF" -ForegroundColor Green;
					} else {
						Write-Host "Exported to $pdfFilePath" -ForegroundColor Green;
					}
					$successCount++;
				} else {
					$failCount++;
					Write-Error "Failed to export file: $fileFullName";
				}
			} catch {
				$failCount++;
				Write-Error "Error exporting file: $fileFullName $_";
			} finally {
				# Close it whatever happened above.
				try { $doc.Close() } catch { }
			}
		}
	}

	#Log output
	$summaryColor = if ($failCount -gt 0 -or $searchErrors.Count -gt 0) { 'Red' } else { 'Green' };
	Write-Host "Converted: $successCount, skipped: $skipCount, failed: $failCount." -ForegroundColor $summaryColor;

	if ($searchErrors.Count -gt 0) {
		Write-Error "Some folders could not be searched (see the errors above), so any .pub files in them were not converted.";
	}

	if ($failCount -gt 0 -or $searchErrors.Count -gt 0) {
		$exitCode = 1;
	}
} catch {
	Write-Error $_;
	$exitCode = 1;
} finally {
	if ($app) {
		#Quit Publisher
		try { $app.Quit() } catch { }
	}
}

exit $exitCode
