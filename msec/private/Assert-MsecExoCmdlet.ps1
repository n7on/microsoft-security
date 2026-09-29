function Assert-MsecExoCmdlet {
    <#
    .SYNOPSIS
        Throws a clear error when a Security & Compliance cmdlet is not exposed to this session.

    .DESCRIPTION
        THE COMPLIANCE ENDPOINT EXPOSES A DIFFERENT SET OF CMDLETS PER IDENTITY, not per tenant.
        It imports what the connecting identity's ROLE GROUPS allow, on top of what the tenant is
        licensed for - so a cmdlet that exists in the documentation can be absent for this app
        while a human administrator uses the same feature in the portal all day.

        THAT DISTINCTION IS EASY TO GET BACKWARDS, and getting it backwards writes "we do not
        have eDiscovery" into a compliance report about a tenant that does. Measured on one
        tenant: Get-ComplianceSearch, Get-InsiderRiskPolicy and Get-SupervisoryReviewPolicyV2 were
        all missing from an app-only session, while the eDiscoveryManager, InsiderRiskManagement
        and CommunicationCompliance role groups each had three members and the features were in
        active use. The absence said nothing about the tenant; it said the app was not in those
        role groups.

        Calling one anyway raises CommandNotFoundException - 'The term X is not recognized' -
        which surfacing from a Get-Msec* command reads as a broken module rather than as a
        tenant that does not have the feature.

        SO IT THROWS RATHER THAN RETURNING NOTHING. An empty result would say "this tenant has no
        DLP policies" when the truth is "this identity cannot ask", and on a compliance report
        those are opposite conclusions. Not measurable is not the same as measured zero - and it
        is not the same as not present, either.

    .PARAMETER Name
        The cmdlet the caller is about to use.

    .PARAMETER Feature
        Human name of what it reads, for the message.

    .PARAMETER Hint
        Optional extra sentence, e.g. a narrower parameter that would still work.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Name,

        [Parameter(Mandatory)]
        [string] $Feature,

        [Parameter()]
        [string] $Hint
    )

    if (Get-Command $Name -ErrorAction SilentlyContinue) { return }

    $message = "'$Name' is not available to THIS session, so $Feature cannot be read by the identity you are " +
               'connected as. The compliance endpoint imports cmdlets per identity, based on its Purview ROLE ' +
               'GROUPS - so this is very often an app that is not in the right role group rather than a tenant ' +
               'that lacks the feature, and someone may well be using it in the portal right now. It is not an ' +
               'API permission and granting one will not help. To let this identity read it, add it to the ' +
               'matching (view-only) Purview role group. IMPORTANT: this is not evidence that the feature is ' +
               'absent or unconfigured - treat it as not measurable from here.'
    if ($Hint) { $message += " $Hint" }
    throw $message
}
