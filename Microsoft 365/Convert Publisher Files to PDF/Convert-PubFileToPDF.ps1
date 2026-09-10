<#
.SYNOPSIS
	Converts Microsoft Publisher .pub files to PDF format.

.DESCRIPTION
	This script automates the conversion of Microsoft Publisher (.pub) files to PDF format using the Microsoft Office Interop Publisher library.
	It processes all files matching the specified filter, checks if a PDF already exists for each file, and skips conversion if the PDF is present.
	The script logs successful conversions and any errors encountered during the process.

.PARAMETER Filter
	Specifies the file filter to select Publisher files for conversion.
	This can be a specific file name (e.g., "document.pub") or a wildcard pattern (e.g., "*.pub").

.PARAMETER Recurse
	If specified, searches for Publisher files recursively in all subdirectories that match the filter. If omitted, only the current directory is searched.

.EXAMPLE
	Convert-PubFileToPDF.ps1 -Filter "C:\Documents\MyFile.pub"
	Converts the specified Publisher file to PDF format.

.EXAMPLE
	Convert-PubFileToPDF.ps1 -Filter "*.pub"
	Converts all Publisher files in the current directory to PDF format.

.EXAMPLE
	Convert-PubFileToPDF.ps1 -Filter "*.pub" -Recurse
	Converts all Publisher files in the current directory and all subdirectories to PDF format.
#>
param
(
	[ValidateNotNullOrEmpty()]
	[string]
	$Filter,

	[switch]
	$Recurse
)

if (-not $PSBoundParameters.ContainsKey('Filter')) {
	Write-Error "The -Filter parameter is required."
	exit 1
}

if (-not ($Filter -like "*.pub")) {
	Write-Error "The filter must specify .pub files (e.g., '*.pub' or 'file.pub').";
	exit 1;
}

try {
	$files = Get-ChildItem $Filter -File -Recurse:$Recurse;
	if (-not $files) {
		Write-Error "No Publisher files found for the filter: $Filter";
		exit 1;
	}

	Write-Output "Running...";

	Add-type -AssemblyName Office;
	Add-type -AssemblyName Microsoft.Office.Interop.Publisher;
	try {
		$app = New-Object -ComObject Publisher.Application;
	} catch {
		Write-Error "Microsoft Publisher is not installed or accessible.";
		exit 1;
	}

	$successCount = 0;
	$failCount = 0;

	foreach ($file in $files) {
		if ($file.Extension -eq ".pub") {
			$fileFullName = $file.FullName;
			$pdfFilePath = [System.IO.Path]::ChangeExtension($fileFullName, '.pdf')
			if (Test-Path $pdfFilePath) {
				Write-Error "PDF file already exists: $pdfFilePath";
				$failCount++;
				Continue;
			}

			# Open the file
			try {
				$doc = $app.Open($fileFullName);
			} catch {
				$failCount++;
				Write-Error "Error opening file: $fileFullName $_";
				Continue;
			}

			if (-not($doc)) {
				$failCount++;
				Write-Error "Failed to open file: $fileFullName";
				Continue;
			}

			try {
				# Export file as PDF
				$doc.ExportAsFixedFormat([Microsoft.Office.Interop.Publisher.PbFixedFormatType]::pbFixedFormatTypePDF, $pdfFilePath);
				if (Test-Path $pdfFilePath) {
					Write-Output "Exported to $pdfFilePath.";
					$successCount++;
				} else {
					$failCount++;
					Write-Error "Failed to export file: $fileFullName";
				}
			} catch {
				$failCount++;
				Write-Error "Error during export: $_";
			}

			$doc.Close();
		}
	}

	#Log output
	Write-Output "Converted $successCount files with $failCount errors.";
}catch{
	Write-Error $_;
}finally {
	if ($app) {
		#Quit Publisher
		$app.Quit();
	}
}
