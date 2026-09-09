# eset-config: what ESET is installed on this server, whether it is actually protecting
# it, and - the point of the script - how its NOTIFICATIONS are configured
# (Advanced setup -> Tools -> Notifications: email/SMTP notifications, desktop
# notifications, minimum verbosity).
#
# WHERE THE SETTINGS COME FROM
# ----------------------------
# HKLM\SOFTWARE\ESET\ESET Security\CurrentVersion. That is the effective settings tree
# ekrn actually runs on: always present, needs no ESET feature to be switched on, and it
# already reflects any ESET PROTECT policy merged over the local settings. The two CLI
# tools that can dump a nicer XML config - ermm.exe and ecmd.exe - are deliberately NOT
# used here: ecmd.exe only answers when "ESET CMD" has been enabled in Advanced setup, and
# both return a full config document that would blow the output budget below.
#
# THE 4096-BYTE OUTPUT BUDGET
# ---------------------------
# Azure Run-Command returns only the LAST 4096 bytes of stdout, and truncation happens
# silently in Azure, not here - a clipped JSON object would reach the caller as an
# unparseable string with no clue why. So this emits a summary, not a config dump, and the
# one free-text field (NotificationSettings) is hard-capped with an explicit '...(+N more)'
# marker so a trimmed list can never pass for a complete one.
#
# WHY THE NOTIFICATION FIELDS ARE MATCHED, NOT LOOKED UP
# ------------------------------------------------------
# ESET keys its settings by opaque plugin id - Plugins\01000103\Settings\... - and those
# ids move between product versions and between Endpoint and Server Security. A hardcoded
# path would silently report "not configured" on the next version, which is the worst
# possible failure for a notification check: it looks like a finding. So the fields below
# are matched by value name within notification-ish keys, and every matched leaf is also
# returned raw in NotificationSettings. On the first run against your build, read that
# field - it tells you the real key names on YOUR product, and it is the thing to widen
# $notifyPattern with if a setting you expect is missing.
#
# Continue (not Stop) so an individual probe failure degrades to nulls rather than
# yielding no row at all.
$ErrorActionPreference = 'Continue'

$nowUtc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Both registry views plus the pre-rename 'Nod' path used by older builds. ESET installs
# exactly one of these; first hit wins.
$infoKey = $null
foreach ($candidate in @(
    'HKLM:\SOFTWARE\ESET\ESET Security\CurrentVersion\Info'
    'HKLM:\SOFTWARE\WOW6432Node\ESET\ESET Security\CurrentVersion\Info'
    'HKLM:\SOFTWARE\ESET\Nod\CurrentVersion\Info'
    'HKLM:\SOFTWARE\WOW6432Node\ESET\Nod\CurrentVersion\Info'
)) {
    if (Test-Path -Path $candidate) { $infoKey = $candidate; break }
}

if (-not $infoKey) {
    # "No ESET on this server" is a legitimate audit finding, not a script failure - emit a
    # normal row so the VM appears in the report instead of as a Status=Failed blank.
    [pscustomobject]@{
        NowUtc    = $nowUtc
        Installed = $false
        Compliant = $false
        Notes     = 'No ESET product found under HKLM\SOFTWARE\ESET.'
    } | ConvertTo-Json -Compress
    return
}

$info = Get-ItemProperty -Path $infoKey -ErrorAction SilentlyContinue

# The settings tree is Info's parent. Derived rather than hardcoded so the WOW6432Node and
# legacy 'Nod' layouts resolve without a second list to keep in sync.
$settingsRoot = Split-Path -Path $infoKey -Parent

# ekrn is the kernel service. If it is not running, every setting below describes what ESET
# WOULD do rather than what it is doing - which is the more urgent finding of the two.
$ekrn = Get-Service -Name 'ekrn' -ErrorAction SilentlyContinue
$ekrnState = if ($ekrn) { [string] $ekrn.Status } else { $null }

# An ESET PROTECT agent means the console policy, not the local GUI, decides these
# settings - so it tells the reader where to go and change anything found wrong here.
$managed = $false
foreach ($agentKey in @(
    'HKLM:\SOFTWARE\ESET\RemoteAdministrator\Agent\CurrentVersion\Settings'
    'HKLM:\SOFTWARE\WOW6432Node\ESET\RemoteAdministrator\Agent\CurrentVersion\Settings'
)) {
    if (Test-Path -Path $agentKey) { $managed = $true; break }
}

# ---- walk the settings tree, keeping only notification-ish leaves -----------------------
#
# Widen this if a setting you expect is missing from NotificationSettings. It over-matches
# slightly on purpose: a false positive is a row you skip, a false negative is a setting
# you wrongly believe is unset.
$notifyPattern = 'notif|smtp|mail|sender|recipient|verbosity|desktop|tray|balloon|alert|popup'

# It is matched against "<path>\<name>" rather than either half alone: some settings are
# named for what they configure ('SMTP_Server'), others are generic leaves under a
# notification-named key ('...\Notifications\Enabled'). Either half can be the only hit.

# Things that trip $notifyPattern without being notification config. Every entry is a false
# positive seen in real output, not a guess:
#   scanners\...\MailEnable        the email SCANNER (scan mail files) - nothing to do with
#                                  notifying anyone. One per scan profile, so on a stock
#                                  install these alone outnumber the real settings. Matched
#                                  as (^|\\)scanners\\ because the same keys sit at the root
#                                  on some products and under Config\ on others.
#   LicenseInfo\ExpirationNotify*  licence expiry warning lead time.
#   State\EmailClients\*           mail-client integration state, not notifications.
# Without these the verdict below gets computed from junk and reports a false finding.
$notifyExclude = '(^|\\)scanners\\|ExpirationNotify|(^|\\)State\\EmailClients\\'

# REG_BINARY -> something you can put in a column.
#
# The v4-generation products (ESET File Security 4.x) store nearly every string setting as
# REG_BINARY rather than REG_SZ, so 'Config\plugins\01000600\settings\EKRN_CFG\SMTP_Address'
# is 15 raw bytes holding NUL-terminated ASCII. Ports and on/off flags in the same tree are
# little-endian integers in 4 bytes. Both have to be decoded here or every notification
# field reads as empty on exactly the products that need this script most.
function ConvertFrom-EsetBinary {
    param([byte[]] $Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }

    # All zero. Short = a numeric 0 - a flag that is OFF, which must NOT read as blank,
    # because blank means "not found" everywhere else in this script. Long = empty string.
    if (-not ($Bytes | Where-Object { $_ -ne 0 })) {
        if ($Bytes.Length -le 4) { return 0 }
        return ''
    }

    # UTF-16LE FIRST, on the UNTRIMMED array. Trimming trailing NULs before this test
    # desyncs it: the terminator plus the high byte of the final character are three zero
    # bytes, the trim eats all three, and what is left is an odd-length span that can no
    # longer look like UTF-16 at all.
    if ($Bytes.Length -ge 2 -and $Bytes.Length % 2 -eq 0) {
        $wide = $true
        for ($i = 1; $i -lt $Bytes.Length; $i += 2) { if ($Bytes[$i] -ne 0) { $wide = $false; break } }
        if ($wide) {
            $decoded = [System.Text.Encoding]::Unicode.GetString($Bytes).TrimEnd([char] 0)
            if ($decoded.Length -and $decoded -match '^[\x20-\x7E]+$') { return $decoded }
        }
    }

    $end = $Bytes.Length
    while ($end -gt 0 -and $Bytes[$end - 1] -eq 0) { $end-- }
    $trim = $Bytes[0..($end - 1)]

    $printable = $true
    foreach ($b in $trim) { if ($b -lt 0x20 -or $b -gt 0x7E) { $printable = $false; break } }
    if ($printable) { return [System.Text.Encoding]::UTF8.GetString($trim) }

    # Small non-text blob: a little-endian integer. Ports and flags land here.
    if ($Bytes.Length -le 4) {
        $n = 0
        for ($i = $Bytes.Length - 1; $i -ge 0; $i--) { $n = ($n -shl 8) -bor $Bytes[$i] }
        return $n
    }

    return "<binary:$($Bytes.Length)b>"
}

$all       = New-Object System.Collections.ArrayList   # every leaf, for the value-shape scan
$leaves    = New-Object System.Collections.ArrayList   # the notification-ish subset
$readError = 0

# -ErrorAction SilentlyContinue is load-bearing: ESET self-defense ACLs some of its own
# subkeys against read even for SYSTEM, and one such key would otherwise abort the walk.
# -ErrorVariable then COUNTS what was skipped: silently walking a tree whose interesting
# half was unreadable is what makes an empty result look like a configured-nothing server.
$blocked = $null
$keys = @(Get-Item -Path $settingsRoot -ErrorAction SilentlyContinue) +
        @(Get-ChildItem -Path $settingsRoot -Recurse -ErrorAction SilentlyContinue -ErrorVariable blocked)
$blockedCount = @($blocked).Count

foreach ($key in $keys) {
    if (-not $key) { continue }

    # Trim the fixed prefix so the emitted paths stay short (output budget) and stay
    # comparable between a 64-bit and a WOW6432Node server.
    $path = $key.Name -replace '^HKEY_LOCAL_MACHINE\\SOFTWARE\\(WOW6432Node\\)?ESET\\[^\\]+\\CurrentVersion\\', ''

    foreach ($name in $key.GetValueNames()) {
        $value = $null
        try { $value = $key.GetValue($name) } catch { $readError++; continue }

        # REG_BINARY is where the v4-generation products keep their notification config -
        # SMTP_Address arrives as 15 raw bytes, not as a string - so this has to decode
        # rather than summarise. Reporting it as '<binary:15b>' is what made the SmtpServer
        # column come back empty on a server that had the setting populated all along.
        if ($value -is [byte[]]) { $value = ConvertFrom-EsetBinary -Bytes $value }

        # Redacted unconditionally - the SMTP password for email notifications lands here,
        # and this output is meant to end up in an audit CSV. ESET stores it obfuscated
        # rather than in clear, but it is still a credential leaving the server.
        if ($name -match 'pass|secret|token|credential') { $value = '<redacted>' }

        $leaf = [pscustomobject]@{ Path = $path; Name = $name; Value = $value }
        [void] $all.Add($leaf)

        if ("$path\$name" -match $notifyPattern -and "$path\$name" -notmatch $notifyExclude) {
            [void] $leaves.Add($leaf)
        }
    }
}

# ---- value-shape scan: find the addresses regardless of what the keys are called --------
#
# The keyword match above depends on ESET naming a key something recognisable, which on an
# older product it may simply not do. This does not: if event notifications are configured
# at all, SOME value holds a recipient address. Matching the VALUE shape instead of the key
# name finds it whatever the key is called, and the paths it returns are how you learn the
# real key names on a product version nobody has mapped yet.
$mailish = @(
    $all | Where-Object {
        $_.Value -is [string] -and
        $_.Value -match '^[^@\s;,]+@[^@\s;,]+\.[A-Za-z]{2,}$'
    }
)

# ---- tree inventory: which top-level subkeys yielded anything ---------------------------
#
# The cheapest way to tell "this product genuinely has no notification settings here" apart
# from "the subtree holding them was not readable". A top-level key present in the registry
# but reporting 0 values is the signature of the second case.
$counts = @{}
foreach ($leaf in $all) {
    $top = ($leaf.Path -split '\\')[0]
    if (-not $counts.ContainsKey($top)) { $counts[$top] = 0 }
    $counts[$top]++
}
foreach ($child in @(Get-ChildItem -Path $settingsRoot -ErrorAction SilentlyContinue)) {
    if (-not $counts.ContainsKey($child.PSChildName)) { $counts[$child.PSChildName] = 0 }
}
$treeSummary = (($counts.Keys | Sort-Object | ForEach-Object { "$_`:$($counts[$_])" }) -join ',')

# Pick one leaf by value-name pattern, preferring those under a mail/SMTP-named key so a
# generic name like 'Server' resolves to the SMTP server and not to something unrelated.
function Get-Leaf {
    param([string] $NamePattern, [string] $PreferPath = 'smtp|mail|notif')

    $hits = @($leaves | Where-Object { $_.Name -match $NamePattern })
    if (-not $hits.Count) { return $null }

    # Preference is tested against "path\name", not the path alone. The v4 layout carries
    # the meaning in the value NAME (EKRN_CFG\SMTP_Address) while the path says only which
    # plugin id owns it, so a path-only test never prefers anything and the tie-break falls
    # back to registry order.
    $preferred = @($hits | Where-Object { "$($_.Path)\$($_.Name)" -match $PreferPath })
    if ($preferred.Count) { return $preferred[0].Value }
    return $hits[0].Value
}

# ESET stores these as DWORD 0/1. A missing leaf stays $null ("we did not find this
# setting") rather than collapsing to $false ("it is switched off") - the two mean very
# different things in a notification audit. The try/catch covers the leaf that is neither:
# some of these are stored as text on some builds, and an uncastable value is likewise
# unknown rather than off.
function ConvertTo-Flag {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Value -match '^(?i:true|yes|on|enabled)$')  { return $true }
        if ($Value -match '^(?i:false|no|off|disabled)$') { return $false }
    }
    try   { return [bool][int] $Value }
    catch { return $null }
}

# The on/off patterns are ANCHORED, the descriptive ones are not, and that asymmetry is
# deliberate. An unanchored 'send' matches SenderAddress before it matches Enabled, so the
# email-enabled flag comes back holding an email address, fails the cast, and reports as
# "unknown" on a server that has notifications switched on perfectly well. A wrong value
# for a descriptive field is visible in the output; a wrong value for a flag is not.
#
# The SMTP_* names are EKRN_CFG's, confirmed against a real ESET Server Security 12.1 tree:
#
#     SMTP_Server        smtp.elasticemail.com        the server
#     SMTP_Address       soc@example.com              the RECIPIENT, despite the name
#     SMTP_SenderAddress no-reply@example.net
#     SMTP_Username      person@example.com           SMTP auth account
#
# SMTP_Address reads like a server address and is a mailbox. Matching it as the server -
# which an earlier version of this script did - puts a recipient in SmtpServer and leaves
# the real hostname unreported, so the server pattern below excludes 'address' on purpose
# and the recipient pattern claims it explicitly.
$smtpServer = Get-Leaf -NamePattern '^(smtp)?server$|smtpserver|mailserver|smtphost|^smtp_?(host|server)$'
$recipients = Get-Leaf -NamePattern 'recipient|addressee|mailto|^smtp_?(to|address)$'
$sender     = Get-Leaf -NamePattern 'sender|mailfrom|fromaddress|^smtp_?from$'
$smtpUser   = Get-Leaf -NamePattern '^smtp_?(username|user|login|account)$|^(mail|smtp)auth'
$smtpPort   = Get-Leaf -NamePattern '^(smtp_?)?port$'
$emailOn    = ConvertTo-Flag (Get-Leaf -NamePattern '^(enabled?|active|send(mail|email|notifications?)?)$|^(email|smtp)_?notification|^smtp_?(enabled?|active|on)$' -PreferPath 'smtp|mail')
$desktopOn  = ConvertTo-Flag (Get-Leaf -NamePattern '^(enabled?|active|show|display|visible)$|^(show|display)' -PreferPath 'desktop|tray|balloon|popup')
$tls        = ConvertTo-Flag (Get-Leaf -NamePattern '^(use)?(tls|ssl|starttls)$|securesmtp|^smtp_?(tls|ssl)')
$verbosity  = Get-Leaf -NamePattern 'verbosity|minlevel|loglevel|severity'

# Fall back to the value-shape scan when the key names gave nothing. An address found this
# way is real config - it just lives under a key this script cannot yet name - so it is
# better evidence than the $null the keyword match produced.
#
# Addresses already identified as the sender or the SMTP auth account are subtracted first.
# Without that, a server whose recipient key simply was not matched reports every mailbox in
# the tree as a recipient - which is how one run came back claiming three recipients when
# two of them were the from-address and the login.
if ([string]::IsNullOrWhiteSpace([string] $recipients) -and $mailish.Count) {
    $claimed    = @([string] $sender, [string] $smtpUser) | Where-Object { $_ }
    $candidates = @($mailish | ForEach-Object { $_.Value } |
                        Where-Object { $_ -notin $claimed } | Select-Object -Unique)
    if ($candidates.Count) { $recipients = $candidates -join ',' }
}

# ---- detection engine age ----------------------------------------------------------------
#
# ScannerVersion reads '30023 (20241009)' - build, then the engine's release date. The date
# is the part that matters: a server can be running, licensed and fully "configured" while
# detecting nothing newer than the day its updates stopped, and that failure is invisible in
# every other field here.
$engineDate = $null
$engineAge  = $null
$match = [regex]::Match([string] $info.ScannerVersion, '\((\d{8})\)')
if ($match.Success) {
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParseExact($match.Groups[1].Value, 'yyyyMMdd', $null, 'None', [ref] $parsed)) {
        $engineDate = $parsed.ToString('yyyy-MM-dd')
        $engineAge  = [int] ([DateTime]::UtcNow - $parsed).TotalDays
    }
}

# ---- the raw matched leaves, capped ------------------------------------------------------
#
# Capped at 1200 chars: the fixed fields above run to roughly 700, and Azure returns only the
# last 4096 bytes of stdout. The '(+N more)' marker means a trimmed list can never be
# mistaken for the complete one.
function Format-Capped {
    param([string[]] $Lines, [int] $Budget)

    $text = ''
    $used = 0
    foreach ($line in $Lines) {
        if ($text.Length + $line.Length + 2 -gt $Budget) { break }
        if ($text) { $text += '; ' }
        $text += $line
        $used++
    }
    if ($used -lt $Lines.Count) { $text += " ...(+$($Lines.Count - $used) more)" }
    return $text
}

$blob     = Format-Capped -Lines @($leaves  | ForEach-Object { "$($_.Path)\$($_.Name)=$($_.Value)" }) -Budget 1200
$mailBlob = Format-Capped -Lines @($mailish | ForEach-Object { "$($_.Path)\$($_.Name)=$($_.Value)" }) -Budget 400

# ---- verdict ------------------------------------------------------------------------------
#
# Compliant answers one question: will this server tell anyone when something happens?
# So it needs a delivery target - an SMTP server, or an address found by shape - on top of
# ESET actually running.
#
# It is $null, NOT $false, whenever the evidence is merely absent rather than negative.
# Getting this backwards is the failure this script had on its first real run: eight junk
# leaves matched, none of them notification config, and it reported Compliant=False - a
# confident finding of "notifications are off" drawn from having found nothing at all.
# $false is now reserved for the case where the settings were genuinely readable and
# genuinely name no destination.
$haveTarget   = -not [string]::IsNullOrWhiteSpace([string] $smtpServer) -or
                -not [string]::IsNullOrWhiteSpace([string] $recipients)
# Did anything at all look like real notification config, as opposed to leaves that merely
# tripped a keyword? If not, this script has not yet been mapped to this product version.
$haveEvidence = $haveTarget -or ($null -ne $emailOn) -or ($null -ne $desktopOn) -or
                @($leaves | Where-Object { $_.Path -match 'notif|smtp' }).Count -gt 0

$compliant = $null
if ($haveEvidence) { $compliant = ($ekrnState -eq 'Running') -and $haveTarget }

$notes = New-Object System.Collections.ArrayList
if ($ekrnState -and $ekrnState -ne 'Running') {
    [void] $notes.Add("ekrn is '$ekrnState' - protection is not active.")
}
if (-not $haveEvidence) {
    # The actionable version of "no verdict": it names the two fields that say where to
    # look next, so the reader is not left guessing why the row came back empty.
    [void] $notes.Add('No notification config recognised on this product version - no verdict. Use TreeSummary and MailLeaves to find the real keys, then widen $notifyPattern.')
}
if ($blockedCount -or $readError) {
    [void] $notes.Add("$blockedCount key(s) and $readError value(s) unreadable (ESET self-defense); the tree is partial.")
}
if ($null -ne $engineAge -and $engineAge -gt 30) {
    [void] $notes.Add("Detection engine is $engineAge days old ($engineDate) - updates are not arriving.")
}
if ($managed) {
    [void] $notes.Add('ESET PROTECT agent present - change these in the console policy, not locally.')
}

[pscustomobject]@{
    NowUtc                = $nowUtc
    Installed             = $true
    Product               = $info.ProductName
    Version               = $info.ProductVersion
    # ESET calls this the detection engine in the UI and the scanner in the registry.
    DetectionEngine       = $info.ScannerVersion
    DetectionEngineDate   = $engineDate
    DetectionEngineAgeDays = $engineAge
    EkrnState             = $ekrnState
    ManagedByProtect      = $managed
    EmailNotifyEnabled    = $emailOn
    SmtpServer            = $smtpServer
    SmtpPort              = $smtpPort
    SmtpUsername          = $smtpUser
    SmtpSender            = $sender
    SmtpRecipients        = $recipients
    SmtpTls               = $tls
    MinVerbosity          = $verbosity
    DesktopNotifyEnabled  = $desktopOn
    NotificationCount     = $leaves.Count
    Compliant             = $compliant
    Notes                 = ($notes -join ' ')
    # The three discovery fields, last: they are the ones worth losing bytes off if anything
    # ever does overflow the budget, and the verdict above them stays intact either way.
    # TreeSummary is 'TopLevelKey:valueCount' for every top-level key under CurrentVersion -
    # one reporting 0 is a subtree that exists but yielded nothing, which is what an
    # unreadable Plugins tree looks like from here.
    TreeSummary           = $treeSummary
    MailLeaves            = $mailBlob
    NotificationSettings  = $blob
} | ConvertTo-Json -Compress
