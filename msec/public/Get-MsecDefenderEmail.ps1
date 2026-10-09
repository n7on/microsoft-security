function Get-MsecDefenderEmail {
    <#
    .SYNOPSIS
        Messages from the Defender advanced-hunting EmailEvents table, one row each, with the
        sending server's country resolved - narrowed server-side, then filtered in PowerShell.

    .DESCRIPTION
        The general mail-flow pivot. Returns messages as objects and leaves the question to the
        caller, rather than shipping a command per question:

            Get-MsecDefenderEmail -Days 30 -SenderCountry Israel
            Get-MsecDefenderEmail -Days 30 | Group-Object SenderCountry | Sort-Object Count -Descending
            Get-MsecDefenderEmail -Days 30 | Where-Object { $_.AuthenticationDetails -match 'dmarc.*fail' }

        EmailEvents IS NOT A SPAM TABLE. It holds every message Exchange Online Protection
        processed - inbound, outbound and intra-org, clean mail included, one row per recipient.
        The verdict is a column, not a filter: ThreatTypes is empty on clean mail, and
        DeliveryAction and LatestDeliveryLocation say what happened to it.

        SENDERCOUNTRY IS THE SENDING INFRASTRUCTURE, NOT THE AUTHOR. SenderIPv4 is the last SMTP
        hop that connected to Exchange Online - the server Microsoft accepted the message from.
        A message relayed through Gmail or SendGrid geolocates to that provider's egress and says
        nothing about where the person was; a self-hosted sender's own server does appear.
        Nothing in EmailEvents holds the author's client address - it never reaches the
        recipient's mail system. AuthenticationDetails is the stronger signal next to it: SPF,
        DKIM and DMARC answer whether that infrastructure was AUTHORISED to send for the domain
        it claims, which geography cannot.

        A MESSAGE THAT ARRIVED OVER IPv6 HAS NO COUNTRY AT ALL. geo_info_from_ip_address resolves
        IPv4, so an IPv6 delivery carries SenderCountry = '(IPv6 - not geolocated)' rather than a
        blank or a guess. Those rows are in the output like any other - a country filter that
        silently omitted them would read as "there was none from there" when it means "this one
        could not be placed anywhere".

        THE FILTER PARAMETERS EXIST TO KEEP THE FETCH HONEST, not to replace Where-Object. Every
        one of them is applied in KQL before the row ceiling, so narrowing server-side changes
        WHICH messages are available to filter downstream. Filtering a truncated fetch in
        PowerShell does not: ask for a window holding 40,000 messages, get the newest ceiling-
        worth, filter to one country, and the answer looks complete and is wrong.

        THE CEILING CANNOT BE REMOVED, ONLY MOVED. /security/runHuntingQuery caps its own result
        set, so a command with no -MaxMessages would still be truncated - it would just stop
        saying so. MaxMessages therefore defaults to that API ceiling rather than to a smaller
        number of msec's own invention: it binds only where the service would have bound anyway,
        and the total matching count is measured separately so truncation is reported either
        way, with both numbers.

        Runs as the msec app and needs 'ThreatHunting.Read.All'. Advanced hunting retains 30
        days, which is what -Days is capped at - a larger window would silently return a smaller
        one.

    .PARAMETER Days
        How far back to look. Default 7, maximum 30 - the advanced-hunting retention ceiling.

    .PARAMETER Direction
        Inbound, Outbound, IntraOrg, or All. Default All.

    .PARAMETER SenderCountry
        Country of the sending server, as the geo database spells it ("United States", not "US").
        Case-insensitive. The unplaceable buckets can be asked for by name too:
        '(IPv6 - not geolocated)', '(no sender IP)', '(IP not in geo database)'.

    .PARAMETER SenderDomain
        Matches EITHER the header From domain or the envelope MailFrom domain. Relayed mail
        carries different values in the two, and matching only one would quietly miss it.

    .PARAMETER SenderAddress
        Matches either the header From address or the envelope MailFrom address, for the same
        reason.

    .PARAMETER RecipientAddress
        The internal recipient. One row per recipient, so a message to five people is five rows.

    .PARAMETER SenderIp
        Sending server address. Matches IPv4 or IPv6.

    .PARAMETER Subject
        Substring match, case-insensitive, any of the given strings. `contains` rather than
        `has`: `has` matches whole tokens, so it would find "Invoice" in "Invoice due" and NOT
        in "Invoice-2451", which is the wrong half of the time for subject lines.

    .PARAMETER ThreatType
        Phish, Spam or Malware. ThreatTypes is multi-valued - one message can be both Phish and
        Spam - so asking for one does not exclude the other.

    .PARAMETER DeliveryLocation
        Where the message ENDED UP, after ZAP (LatestDeliveryLocation) - Inbox, 'Junk folder',
        Quarantine, 'Deleted items'. Not where it was first delivered: a phish that reached a
        mailbox and was pulled back later is not something a user could still open.

    .PARAMETER ThreatsOnly
        Any verdict at all - ThreatTypes non-empty. Broader than -ThreatType, and the cheapest
        way to cut volume when the question is about threats rather than about one kind.

    .PARAMETER MaxMessages
        Row ceiling, newest first. Defaults to the /security/runHuntingQuery ceiling, so it only
        binds where the service would have. Lower it deliberately when a quick look will do.

    .EXAMPLE
        Get-MsecDefenderEmail -Days 30 -Direction Inbound |
            Group-Object SenderCountry | Sort-Object Count -Descending

        Inbound volume by sending country - the summary, built client-side.

    .EXAMPLE
        Get-MsecDefenderEmail -Days 30 -Direction Inbound -SenderCountry Israel, Lithuania

        Two countries' sending infrastructure, narrowed before the row ceiling applies.

    .EXAMPLE
        Get-MsecDefenderEmail -Days 30 -ThreatsOnly -DeliveryLocation Inbox

        Threats still sitting in a mailbox after ZAP - what a user could actually open.

    .EXAMPLE
        Get-MsecDefenderEmail -Days 30 -Subject 'invoice', 'payment' -ThreatsOnly |
            Select-Object Timestamp, SenderFromAddress, RecipientEmailAddress, Subject

        Who got the invoice-themed run, and from where.

    .EXAMPLE
        Get-MsecDefenderEmail -Days 30 -Direction Inbound |
            Where-Object { $_.AuthenticationDetails -match 'dmarc.*fail' } |
            Group-Object SenderFromDomain

        Domains whose claimed identity the sending infrastructure was not authorised to use.

    .OUTPUTS
        PSCustomObject per message, PSTypeName 'MsecDefenderEmail'.

    .NOTES
        NetworkMessageId is the join key to EmailUrlInfo, EmailAttachmentInfo,
        EmailPostDeliveryEvents and UrlClickEvents - the message, its links, what happened after
        delivery, and whether anybody clicked.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $Days = 7,

        [Parameter()]
        [ValidateSet('Inbound', 'Outbound', 'IntraOrg', 'All')]
        [string] $Direction = 'All',

        [Parameter()]
        [string[]] $SenderCountry,

        [Parameter()]
        [string[]] $SenderDomain,

        [Parameter()]
        [string[]] $SenderAddress,

        [Parameter()]
        [string[]] $RecipientAddress,

        [Parameter()]
        [string[]] $SenderIp,

        [Parameter()]
        [string[]] $Subject,

        [Parameter()]
        [ValidateSet('Phish', 'Spam', 'Malware')]
        [string[]] $ThreatType,

        [Parameter()]
        [string[]] $DeliveryLocation,

        [Parameter()]
        [switch] $ThreatsOnly,

        [Parameter()]
        [ValidateRange(1, 100000)]
        [int] $MaxMessages = 100000
    )

    Assert-MsecSession

    $invoke = {
        param([string] $Kql)
        try {
            Invoke-MsecGraphRequest -Path '/v1.0/security/runHuntingQuery' -Method POST -Body @{ Query = $Kql }
        }
        catch {
            if ($_.Exception.Message -match '403|Forbidden') {
                throw "Forbidden when calling /security/runHuntingQuery. The msec app needs the 'ThreatHunting.Read.All' application permission (admin consent required). Original error: $($_.Exception.Message)"
            }
            throw
        }
    }

    # .Replace, not -replace: a regex replacement string eats $ and ` sequences, and these are
    # caller-supplied subjects and addresses.
    $lit  = { param([string] $s) '"' + $s.Replace('\', '\\').Replace('"', '\"') + '"' }
    $list = { param([string[]] $v) ($v | ForEach-Object { & $lit $_ }) -join ', ' }

    # SenderCountry is a computed column, so the extend has to come before the where - and the
    # same extend has to be in the count query, or the count describes a different population
    # from the rows.
    $extend = @'
| extend SenderCountry = case(
      isnotempty(SenderIPv4), tostring(geo_info_from_ip_address(SenderIPv4).country),
      isnotempty(SenderIPv6), "(IPv6 - not geolocated)",
                              "(no sender IP)")
| extend SenderCountry = iff(isempty(SenderCountry), "(IP not in geo database)", SenderCountry)
'@

    $filters = @("Timestamp >= ago(${Days}d)")
    if ($Direction -ne 'All')  { $filters += "EmailDirection == `"$Direction`"" }
    if ($ThreatsOnly)          { $filters += 'isnotempty(ThreatTypes)' }
    if ($SenderCountry)        { $filters += "SenderCountry in~ ($(& $list $SenderCountry))" }
    if ($RecipientAddress)     { $filters += "RecipientEmailAddress in~ ($(& $list $RecipientAddress))" }
    if ($DeliveryLocation)     { $filters += "LatestDeliveryLocation in~ ($(& $list $DeliveryLocation))" }

    # Header From and envelope MailFrom disagree on relayed mail. Matching one would quietly
    # miss the other, so both are tried.
    if ($SenderDomain) {
        $d = & $list $SenderDomain
        $filters += "(SenderFromDomain in~ ($d) or SenderMailFromDomain in~ ($d))"
    }
    if ($SenderAddress) {
        $a = & $list $SenderAddress
        $filters += "(SenderFromAddress in~ ($a) or SenderMailFromAddress in~ ($a))"
    }
    if ($SenderIp) {
        $i = & $list $SenderIp
        $filters += "(SenderIPv4 in ($i) or SenderIPv6 in ($i))"
    }
    # has_any is token-based and would match 'Phish' inside nothing useful here, but ThreatTypes
    # really is a comma-separated token list, so has_any is correct for it - unlike Subject.
    if ($ThreatType) { $filters += "ThreatTypes has_any ($(& $list $ThreatType))" }
    if ($Subject) {
        $clauses = ($Subject | ForEach-Object { "Subject contains $(& $lit $_)" }) -join ' or '
        $filters += "($clauses)"
    }

    $where = '| where ' + ($filters -join "`n    and ")
    $base  = "EmailEvents`n$extend$where"

    # Counted separately, because truncation is undetectable from the rows themselves: a full
    # page looks identical whether the window held exactly that many or ten times as many.
    $total = [int](((& $invoke "$base`n| count").Results | Select-Object -First 1).Count ?? 0)

    if ($total -gt $MaxMessages) {
        Write-Warning ("{0} message(s) match; returning the {1} newest. Any filtering you do downstream is over that subset only - narrow with the filter parameters, which apply BEFORE the ceiling." -f $total, $MaxMessages)
    }

    $kql = @"
$base
| project Timestamp, EmailDirection, SenderCountry, SenderIPv4, SenderIPv6, SenderDisplayName,
          SenderFromAddress, SenderFromDomain, SenderMailFromAddress, SenderMailFromDomain,
          RecipientEmailAddress, Subject, ThreatTypes, DetectionMethods, DeliveryAction,
          DeliveryLocation, LatestDeliveryLocation, AuthenticationDetails, UrlCount,
          AttachmentCount, NetworkMessageId
| sort by Timestamp desc
| take $MaxMessages
"@

    foreach ($r in @((& $invoke $kql).Results)) {
        [PSCustomObject]@{
            PSTypeName             = 'MsecDefenderEmail'
            Timestamp              = if ($r.Timestamp) { [datetime]$r.Timestamp } else { $null }
            EmailDirection         = $r.EmailDirection
            # Where the message was INJECTED, not where its author was. See the description.
            SenderCountry          = $r.SenderCountry
            SenderIPv4             = $r.SenderIPv4
            SenderIPv6             = $r.SenderIPv6
            SenderDisplayName      = $r.SenderDisplayName
            SenderFromAddress      = $r.SenderFromAddress
            SenderFromDomain       = $r.SenderFromDomain
            # The envelope sender. Differs from the header From on relayed mail, which is the
            # cheapest signal that something sat between the author and Microsoft.
            SenderMailFromAddress  = $r.SenderMailFromAddress
            SenderMailFromDomain   = $r.SenderMailFromDomain
            RecipientEmailAddress  = $r.RecipientEmailAddress
            Subject                = $r.Subject
            # Empty on clean mail - blank is the honest rendering, not "none detected".
            ThreatTypes            = $r.ThreatTypes
            DetectionMethods       = $r.DetectionMethods
            DeliveryAction         = $r.DeliveryAction
            DeliveryLocation       = $r.DeliveryLocation
            # Where it ended up AFTER ZAP - what a user could still have opened.
            LatestDeliveryLocation = $r.LatestDeliveryLocation
            AuthenticationDetails  = $r.AuthenticationDetails
            UrlCount               = $r.UrlCount
            AttachmentCount        = $r.AttachmentCount
            NetworkMessageId       = $r.NetworkMessageId
        }
    }
}
