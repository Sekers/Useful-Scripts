# PowerShell-Install-BITS
PowerShell: Check if Program or Update is Installed and Download with BITS and Install

https://www.grimadmin.com/article.php/powershell-check-program-update-installed-download-bits-install

I recently wrote a PowerShell script for Windows that will check if a program or update is installed and, if not, download it using BITS in low priority, verify the download hash, and then install it and copy the verbose log to a central repository. The example is for the current latest Microsoft Surface Pro 7 firmware, but it can be adapted for just about any installer.

<p>Some design considerations for the script are explained below. While solid and production-ready, sometimes I try to use these scripts as a teaching method for newer sysadmins.</p>

<ul>
	<li>I left a couple of debugging lines in the code to demonstrate how to do some basic troubleshooting &amp; logging.</li>
	<li>For the few locations output is written, I used Write-Host rather than the best practice of Write-Verbose. You are welcome to read up on the differences and decide if you want to adjust.</li>
	<li>This is a simple script that most sysadmins can quickly review to understand exactly what it does and modify for their needs. If you need a more robust solution using PS, please look into the&nbsp;<a href="https://github.com/PSAppDeployToolkit/PSAppDeployToolkit" target="_blank">PowerShell App Deployment Toolkit</a>.</li>
	<li>The sample script can, but doesn't, use&nbsp;Win32_Product to query whether the product is already installed. This command is not optimized for queries and will create a delay of a few seconds while it looks up the information. It also performs&nbsp;a <a href="https://docs.microsoft.com/en-us/troubleshoot/windows-server/admin-development/windows-installer-reconfigured-all-applications#more-information" target="_blank">consistency check of installed apps</a>. This version of the script queries the registry for install information. While querying the registry is faster,&nbsp;it sometimes misses installed applications. You will need to determine what works best for your own circumstances and, therefore, the alternative lookup is mentioned in the script, commented out, for reference.</li>
</ul>

<p><span class="info"><strong>Note:</strong> BITS supports the HTTP and HTTPS protocols. In the example, the download has been made available from a web server over HTTP. BITS also supports SMB.</span></p>

<p><span class="alert"><strong>Important:</strong> This script was written to work with installers/updaters in the MSI file format. Adjust the following line in the code to match your specific installer needs.<br />
<code>Start-Process -FilePath &#39;msiexec.exe&#39; -ArgumentList &quot;/i `&quot;$DestinationFile`&quot; /qn /norestart /l*v `&quot;$InstallLogFile`&quot;&quot; -Wait -NoNewWindow</code></span></p>
