param(
  [Parameter(Mandatory = $true)][string]$Path,
  [switch]$NoSudo
)
$ErrorActionPreference = "Stop"
$key = "$env:USERPROFILE\.ssh\id_rsa_azure"
$target = "azureuser@20.48.104.156"
$tmp = Join-Path $env:TEMP ("step-" + [guid]::NewGuid().ToString("N") + ".sh")
$text = [System.IO.File]::ReadAllText((Resolve-Path $Path))
[System.IO.File]::WriteAllText($tmp, $text.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
scp -q -i $key $tmp "${target}:/tmp/step.sh"
Remove-Item $tmp -Force
if ($NoSudo) {
  ssh -i $key $target "bash /tmp/step.sh"
} else {
  ssh -i $key $target "sudo bash /tmp/step.sh"
}
exit $LASTEXITCODE
