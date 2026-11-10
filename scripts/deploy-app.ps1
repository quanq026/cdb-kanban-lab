param(
  [switch]$SkipIndex
)
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$key = "$env:USERPROFILE\.ssh\id_rsa_azure"
$target = "azureuser@20.48.104.156"

scp -q -i $key (Join-Path $Root "app\app.py") "${target}:/tmp/app.py.new"
if (-not $SkipIndex) {
  scp -q -i $key (Join-Path $Root "app\index.html") "${target}:/tmp/index.html.new"
} else {
  ssh -i $key $target "cp -a /opt/cdb/app/index.html /tmp/index.html.new"
}
scp -q -i $key (Join-Path $Root "app\nginx-cdb.conf") "${target}:/tmp/nginx-cdb.conf.new"
scp -q -i $key (Join-Path $Root "infra\nginx-cloudflare-realip.conf") "${target}:/tmp/cf-realip.conf.new"
foreach ($asset in @("app.css", "app.js", "login.html", "register.html")) {
  $path = Join-Path $Root ("app\" + $asset)
  if (Test-Path $path) { scp -q -i $key $path "${target}:/tmp/$asset.new" }
}

$tmp = Join-Path $env:TEMP ("deploy-" + [guid]::NewGuid().ToString("N") + ".sh")
$text = [System.IO.File]::ReadAllText((Join-Path $Root "infra\app-deploy.sh"))
[System.IO.File]::WriteAllText($tmp, $text.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
scp -q -i $key $tmp "${target}:/tmp/deploy.sh"
Remove-Item $tmp -Force

ssh -i $key $target "sudo bash /tmp/deploy.sh"
exit $LASTEXITCODE
