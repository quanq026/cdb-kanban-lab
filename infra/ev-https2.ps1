param(
  [string]$EnvFile = "C:\aws_lightsail_migration.env",
  [string]$OutFile = "C:\QuanNewData\Demo cho ae vps devops\evidence\https-hardening.md"
)
$ErrorActionPreference = "Continue"
$ossl = "C:\Program Files\Git\usr\bin\openssl.exe"
$envMap = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^\s*#' -or $_ -notmatch '=') { return }
  $k, $v = $_ -split '=', 2
  $envMap[$k.Trim()] = $v.Trim()
}
$h = @{ Authorization = "Bearer $($envMap['CF_API_TOKEN'])" }
$zid = "fc94e4214166b8219e611c7129d37cf8"
$stamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssK")

function Section($title) { "## $title"; "" }
function Cmd($text) { '```bash'; $text; '```'; "" }
function Block($text) { '```text'; $text; '```'; "" }

$settings = foreach ($s in @("ssl", "min_tls_version", "always_use_https", "automatic_https_rewrites", "tls_1_3", "http3", "brotli")) {
  $r = Invoke-RestMethod -Uri "https://api.cloudflare.com/client/v4/zones/$zid/settings/$s" -Headers $h -TimeoutSec 60
  "$s = $($r.result.value)"
}

$httpHeaders = (curl.exe -sS -o NUL -D - --max-time 30 http://kanban.akaine.io.vn/ 2>&1) -join "`n"
$httpsHeaders = (curl.exe -sS -o NUL -D - --max-time 30 https://kanban.akaine.io.vn/ 2>&1) -join "`n"
$health = (curl.exe -sS --max-time 30 https://kanban.akaine.io.vn/api/health 2>&1) -join "`n"
$acme = (curl.exe -sS -o NUL -w "code=%{http_code}" --max-time 30 http://kanban.akaine.io.vn/.well-known/acme-challenge/probe 2>&1) -join "`n"
$tls12 = ("" | & $ossl s_client -connect kanban.akaine.io.vn:443 -servername kanban.akaine.io.vn -tls1_2 2>&1) -join "`n"
$tls11 = ("" | & $ossl s_client -connect kanban.akaine.io.vn:443 -servername kanban.akaine.io.vn -tls1_1 2>&1) -join "`n"
$edgeCert = ("" | & $ossl s_client -connect kanban.akaine.io.vn:443 -servername kanban.akaine.io.vn 2>&1 | & $ossl x509 -noout -subject -issuer -dates 2>&1) -join "`n"

$selected = ($httpsHeaders -split "`n" | Where-Object { $_ -match '^(HTTP/|server:|strict-transport-security|x-content-type-options|x-frame-options|referrer-policy|permissions-policy)' }) -join "`n"
$httpSelected = ($httpHeaders -split "`n" | Where-Object { $_ -match '^(HTTP/|Location:)' }) -join "`n"
$tls11Result = if (($tls11 -match 'alert|no protocols|handshake failure') -or ($tls11 -match 'Cipher is \(NONE\)')) { "TLS1.1 bi tu choi (handshake failure)" } else { ($tls11 -split "`n" | Select-String -Pattern 'Protocol|Cipher is') -join "`n" }

$md = @()
$md += "# HTTPS hardening - kanban.akaine.io.vn"
$md += ""
$md += "- Thoi diem chay: ``$stamp``"
$md += "- Zone Cloudflare: ``akaine.io.vn`` (chi zone nay; 2 zone khac khong bi dong toi)"
$md += "- Token Cloudflare doc tu file ngoai repo, khong in ra output"
$md += ""
$md += Section "1. Cloudflare zone settings (doc lai tu API)"
$md += Cmd "GET /zones/fc94e4214166b8219e611c7129d37cf8/settings/<name>"
$md += Block ($settings -join "`n")
$md += Section "2. HTTP -> HTTPS (Cloudflare Always Use HTTPS + nginx redirect)"
$md += Cmd "curl -sS -o /dev/null -D - http://kanban.akaine.io.vn/"
$md += Block $httpSelected
$md += Section "3. Security headers tren HTTPS (nginx origin, di xuyen Cloudflare)"
$md += Cmd "curl -sS -o /dev/null -D - https://kanban.akaine.io.vn/"
$md += Block $selected
$md += Section "4. Health sau khi doi cau hinh"
$md += Cmd "curl -sS https://kanban.akaine.io.vn/api/health"
$md += Block $health
$md += Section "5. ACME path van truy cap duoc (de gia han cert)"
$md += Cmd "curl -o /dev/null -w '%{http_code}' http://kanban.akaine.io.vn/.well-known/acme-challenge/probe"
$md += Block $acme
$md += Section "6. TLS negotiation tai edge Cloudflare"
$md += Cmd "openssl s_client -connect kanban.akaine.io.vn:443 -servername kanban.akaine.io.vn -tls1_2"
$md += Block (($tls12 -split "`n" | Select-String -Pattern 'Protocol|Cipher is|Verify return code') -join "`n")
$md += Cmd "openssl s_client ... -tls1_1"
$md += Block $tls11Result
$md += Section "7. Chung chi edge (Cloudflare Universal SSL)"
$md += Block $edgeCert
$md += Section "Ghi chu"
$md += "- ``ssl=strict``: Cloudflare xac minh cert origin (Let's Encrypt cua kanban.akaine.io.vn). Apex ``akaine.io.vn`` hien tra 522 vi origin 167.254.69.146 khong truy cap duoc; neu sau nay tro apex ve origin khac thi origin do phai co cert hop le, neu khong se la 526."
$md += "- ``min_tls_version=1.2`` ap dung cho ca zone akaine.io.vn; TLS 1.0/1.1 bi tu choi."
$md += "- HSTS dat o nginx (chi server ``kanban.akaine.io.vn``) voi ``max-age=15552000``, khong ``includeSubDomains``/``preload`` de khong anh huong subdomain khac va con rollback duoc."
$md += "- Rollback: ``PATCH /settings/ssl {value:full}``, ``PATCH /settings/min_tls_version {value:1.0}``; tren VM bo cac dong ``add_header`` va ``return 301`` neu can."

$md -join "`n" | Set-Content -Path $OutFile -Encoding utf8
"WROTE $OutFile"
