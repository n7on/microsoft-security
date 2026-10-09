function Get-MsecDefenderTeamsMessage {
    <#
    .SYNOPSIS
        Teams messages from the Defender advanced-hunting MessageEvents table, one row each,
        with recipients and URL domains resolved - narrowed server-side, then filtered in
        PowerShell.

    .DESCRIPTION
        The Teams counterpart to Get-MsecDefenderEmail, with three differences that are not
        cosmetic and will change how you query it.

        THERE IS NO SENDER IP, SO THERE IS NO COUNTRY. Teams is not SMTP: a message arrives
        through Microsoft's service from an authenticated identity, and MessageEvents has no
        address column of any kind. The geography question that SenderCountry answers for mail
        cannot be asked here at all. What replaces it is identity and trust boundary -
        SenderType (User, Anonymous, Applications), IsExternalThread, and whether the thread is
        owned by this tenant.

        ONE ROW PER MESSAGE, NOT PER RECIPIENT - the opposite of EmailEvents. Recipients arrive
        as the RecipientDetails JSON array and are flattened into RecipientAddress, a string[],
        so a message to nine people is one row with nine addresses. Test it with -contains, not
        -eq. A sum over rows is a count of messages; a count of people needs the array.

        SUBJECT IS EMPTY FOR CHAT AND MEETING MESSAGES. It is populated for channel posts
        (ThreadType 'space' and 'topic') and essentially never for one-to-one or group chat,
        which is most of the traffic. -Subject will therefore silently match nothing across the
        bulk of the table; -ThreadName is the usable handle for chat, because that carries the
        conversation name. Both are offered rather than one, because channel posts really do
        have subjects.

        THE MESSAGE BODY IS NOT IN THIS TABLE AND NEITHER IS ANY ATTACHMENT CONTENT. What is
        here is metadata plus Defender's verdict. For the links, UrlCount and UrlDomains are
        joined from MessageUrlInfo on TeamsMessageId - both tables cover the same window, so a
        message with no row there genuinely has no URLs and counts as zero rather than unknown.

        VERDICT COLUMNS CAN BE EMPTY ACROSS THE WHOLE TABLE AND THAT IS NOT A BUG. ThreatTypes,
        DetectionMethods, ConfidenceLevel and SafetyTip are populated only where Defender for
        Office 365 acted on a Teams message. A tenant that has had none will see them blank
        everywhere; they are returned regardless, because their absence is the finding when you
        expected otherwise.

        POST-DELIVERY ACTIONS ARE NOT JOINED. MessagePostDeliveryEvents is a separate table
        holding what happened to a message after it landed, so there is no equivalent of mail's
        LatestDeliveryLocation here: DeliveryLocation says where it was delivered, not whether
        it was removed afterwards.

        Runs as the msec app and needs 'ThreatHunting.Read.All'. Advanced hunting retains 30
        days, which is what -Days is capped at.

    .PARAMETER Days
        How far back to look. Default 7, maximum 30 - the advanced-hunting retention ceiling.

    .PARAMETER SenderAddress
        Sender's SMTP address. Exact, case-insensitive.

    .PARAMETER RecipientAddress
        Substring match against the raw RecipientDetails JSON, because recipients are an array
        rather than a column. An address matches wherever it appears in that array.

    .PARAMETER Subject
        Substring match, case-insensitive. Only meaningful for channel posts - see the
        description. Use -ThreadName for chat.

    .PARAMETER ThreadName
        Substring match on the conversation name. The usable handle for chat, where Subject is
        empty.

    .PARAMETER ThreadType
        Observed values are 'chat', 'space' (channel), 'meeting' and 'topic'. Not a ValidateSet
        on purpose - Microsoft adds thread types, and rejecting an unknown one here would hide
        traffic rather than reveal it.

    .PARAMETER SenderType
        Observed values are 'User', 'Anonymous' and 'Applications'. Anonymous and Applications
        are worth separating out: one is an unauthenticated participant, the other a bot or
        connector posting on its own.

    .PARAMETER ExternalOnly
        Only threads that cross the tenant boundary (IsExternalThread). The closest thing Teams
        has to mail's inbound direction.

    .PARAMETER ThreatType
        Phish, Spam or Malware. ThreatTypes is multi-valued, so asking for one does not exclude
        the other.

    .PARAMETER ThreatsOnly
        Any verdict at all - ThreatTypes non-empty.

    .PARAMETER MaxMessages
        Row ceiling, newest first. Defaults to the /security/runHuntingQuery ceiling, so it only
        binds where the service would have.

    .EXAMPLE
        Get-MsecDefenderTeamsMessage -Days 30 -ExternalOnly |
            Group-Object SenderEmailAddress | Sort-Object Count -Descending

        Who is talking to this tenant from outside it, and how much.

    .EXAMPLE
        Get-MsecDefenderTeamsMessage -Days 30 -SenderType Anonymous, Applications

        Messages that did not come from a signed-in person in this tenant.

    .EXAMPLE
        Get-MsecDefenderTeamsMessage -Days 30 -ExternalOnly |
            Where-Object UrlCount -gt 0 |
            Select-Object Timestamp, SenderEmailAddress, ThreadName, UrlDomains

        External messages carrying links - the Teams phishing shape.

    .EXAMPLE
        Get-MsecDefenderTeamsMessage -Days 30 |
            Where-Object RecipientAddress -contains 'anton.lindstrom@viedoc.com'

        Everything that reached one person. -contains, not -eq: recipients are an array.

    .EXAMPLE
        Get-MsecDefenderTeamsMessage -Days 30 -ThreatsOnly

        Every Teams message Defender gave a verdict to. An empty result is a real answer.

    .OUTPUTS
        PSCustomObject per message, PSTypeName 'MsecDefenderTeamsMessage'.

    .NOTES
        TeamsMessageId is the join key to MessageUrlInfo and MessagePostDeliveryEvents.
        ThreadId identifies the conversation across messages.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter()]
        [ValidateRange(1, 30)]
        [int] $Days = 7,

        [Parameter()]
        [string[]] $SenderAddress,

        [Parameter()]
        [string[]] $RecipientAddress,

        [Parameter()]
        [string[]] $Subject,

        [Parameter()]
        [string[]] $ThreadName,

        [Parameter()]
        [string[]] $ThreadType,

        [Parameter()]
        [string[]] $SenderType,

        [Parameter()]
        [switch] $ExternalOnly,

        [Parameter()]
        [ValidateSet('Phish', 'Spam', 'Malware')]
        [string[]] $ThreatType,

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
    $any  = {
        param([string] $Expr, [string[]] $Values)
        '(' + (($Values | ForEach-Object { "$Expr contains $(& $lit $_)" }) -join ' or ') + ')'
    }

    # Every filter is on a raw MessageEvents column, so the count query needs neither the
    # mv-apply nor the join - and still counts exactly the population the rows come from.
    $filters = @("Timestamp >= ago(${Days}d)")
    if ($SenderAddress) { $filters += "SenderEmailAddress in~ ($(& $list $SenderAddress))" }
    if ($ThreadType)    { $filters += "ThreadType in~ ($(& $list $ThreadType))" }
    if ($SenderType)    { $filters += "SenderType in~ ($(& $list $SenderType))" }
    if ($ExternalOnly)  { $filters += 'IsExternalThread' }
    if ($ThreatsOnly)   { $filters += 'isnotempty(ThreatTypes)' }
    if ($ThreatType)    { $filters += "ThreatTypes has_any ($(& $list $ThreatType))" }
    # contains, not has: `has` is token-based, and an address or a hyphenated thread name is not
    # one token. Recipients are matched against the raw JSON because they are an array.
    if ($RecipientAddress) { $filters += & $any 'tostring(RecipientDetails)' $RecipientAddress }
    if ($Subject)          { $filters += & $any 'Subject'    $Subject }
    if ($ThreadName)       { $filters += & $any 'ThreadName' $ThreadName }

    $where = '| where ' + ($filters -join "`n    and ")
    $base  = "MessageEvents`n$where"

    $total = [int](((& $invoke "$base`n| count").Results | Select-Object -First 1).Count ?? 0)

    if ($total -gt $MaxMessages) {
        Write-Warning ("{0} message(s) match; returning the {1} newest. Any filtering you do downstream is over that subset only - narrow with the filter parameters, which apply BEFORE the ceiling." -f $total, $MaxMessages)
    }

    # mv-apply flattens the recipient array into a string[] so callers can use -contains exactly.
    # Joining the addresses into one string here would force -like '*someone@x*' on every such
    # query, and a substring match reports 'anna@x' as a hit for 'joanna@x'.
    $kql = @"
$base
| mv-apply r = todynamic(RecipientDetails) on (
    summarize RecipientAddress = make_list(tostring(r.RecipientSmtpAddress)))
| join kind=leftouter (
    MessageUrlInfo
    | summarize UrlCount = count(), UrlDomains = make_set(UrlDomain, 10) by TeamsMessageId
  ) on TeamsMessageId
| project Timestamp, ThreadType, ThreadSubType, ThreadName, IsExternalThread, IsOwnedThread,
          SenderEmailAddress, SenderDisplayName, SenderType, SenderObjectId,
          RecipientAddress, Subject, MessageType, MessageSubtype,
          ThreatTypes, DetectionMethods, ConfidenceLevel, SafetyTip,
          DeliveryAction, DeliveryLocation, UrlCount, UrlDomains,
          TeamsMessageId, ThreadId, MessageId, GroupName, LastEditedTime
| sort by Timestamp desc
| take $MaxMessages
"@

    # A leftouter join that misses returns an EMPTY PSCustomObject, not $null - so ?? never
    # fires and a cast is what breaks. [int] on it throws; [bool] on it would be worse, because
    # a non-null object is $true and a missing IsExternalThread would silently read as external.
    # Everything coming back from the API therefore goes through these.
    $text = { param($v) if ($null -eq $v) { '' } else { [string]$v } }
    $num  = { param($v) $n = 0; if ([int]::TryParse((& $text $v), [ref] $n)) { $n } else { 0 } }
    $flag = { param($v) (& $text $v) -in @('1', 'true', 'True') }
    $when = { param($v) $d = [datetime]::MinValue
              if ([datetime]::TryParse((& $text $v), [ref] $d)) { $d } else { $null } }
    $str  = { param($v) $s = & $text $v; if ($s) { $s } else { $null } }
    $arr  = { param($v) @($v) | Where-Object { (& $text $_) } }
    foreach ($r in @((& $invoke $kql).Results)) {
        [PSCustomObject]@{
            PSTypeName         = 'MsecDefenderTeamsMessage'
            Timestamp          = & $when $r.Timestamp
            ThreadType         = & $str $r.ThreadType
            ThreadSubType      = & $str $r.ThreadSubType
            ThreadName         = & $str $r.ThreadName
            # The trust boundary. Teams has no sender IP, so this and SenderType are what stand
            # in for mail's direction and geography.
            IsExternalThread   = & $flag $r.IsExternalThread
            IsOwnedThread      = & $flag $r.IsOwnedThread
            SenderEmailAddress = & $str $r.SenderEmailAddress
            SenderDisplayName  = & $str $r.SenderDisplayName
            SenderType         = & $str $r.SenderType
            SenderObjectId     = & $str $r.SenderObjectId
            # string[], so -contains tests it exactly. One row is one MESSAGE, not one recipient.
            RecipientAddress   = @(& $arr $r.RecipientAddress)
            # Empty on chat and meeting messages - see the help. Not a gap in the data.
            Subject            = & $str $r.Subject
            MessageType        = & $str $r.MessageType
            MessageSubtype     = & $str $r.MessageSubtype
            # Blank across the whole table in a tenant Defender has never acted on in Teams.
            ThreatTypes        = & $str $r.ThreatTypes
            DetectionMethods   = & $str $r.DetectionMethods
            ConfidenceLevel    = & $str $r.ConfidenceLevel
            SafetyTip          = & $str $r.SafetyTip
            DeliveryAction     = & $str $r.DeliveryAction
            # Where it was delivered. NOT whether it was removed afterwards - that lives in
            # MessagePostDeliveryEvents, which this command does not join.
            DeliveryLocation   = & $str $r.DeliveryLocation
            # Joined from MessageUrlInfo over the same window, so absence is a measured zero.
            UrlCount           = & $num $r.UrlCount
            UrlDomains         = @(& $arr $r.UrlDomains)
            TeamsMessageId     = & $str $r.TeamsMessageId
            ThreadId           = & $str $r.ThreadId
            MessageId          = & $str $r.MessageId
            GroupName          = & $str $r.GroupName
            LastEditedTime     = & $when $r.LastEditedTime
        }
    }
}
