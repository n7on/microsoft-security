---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsOrganizationPolicy

## SYNOPSIS
The organization-wide Azure DevOps policies from Organization Settings \> Policies -
third-party OAuth access, SSH, PAT creation, guest access, public projects, audit
logging - as one row per policy.

## SYNTAX

```
Get-MsecAzureDevOpsOrganizationPolicy [-Organization] <String>
 [<CommonParameters>]
```

## DESCRIPTION
These are the ORGANIZATION's ceiling, the same role the SharePoint tenant settings and
the Teams Global policy play: a well-governed project inside an organization that allows
third-party OAuth apps and unrestricted PAT creation is still exposed, and reviewing
projects or pipelines one at a time never surfaces it.

THERE IS NO REST API FOR THIS, and that is worth knowing before you rely on it.
_apis/organizationpolicy/policies does not exist - it 404s on every api-version and on
both hosts.
The only source is the data provider behind the portal's own settings page:

    GET https://dev.azure.com/{org}/_settings/organizationPolicy?__rt=fps&__ver=2

That is an INTERNAL route.
It needs no extra permission beyond organization membership,
it returns the same data the page renders, and Microsoft can change or remove it without
notice or a version bump.
If this command starts returning nothing, that is the first
thing to suspect.

THE PORTAL SHOWS SOME TOGGLES INVERTED.
Four policies are named for what they forbid -
Policy.DisallowOAuthAuthentication and friends - so the page renders the opposite of the
stored value: DisallowOAuthAuthentication = True appears as "Third-party application
access via OAuth: Off".
Value is reported RAW, as the API gives it, and IsInverted says
when the page disagrees.
Reading the raw value together with the policy name is
unambiguous; reading it against the page's label is not.

IsExplicit MATTERS AS MUCH AS THE VALUE.
A policy nobody ever set reports its default,
and the provider says so separately.
A default that happens to be safe today is not a
decision anyone made, and nothing stops it changing.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' |
    Format-Table Category, Setting, Value, IsExplicit
```

### EXAMPLE 2
```
# Everything still sitting on its default, i.e. never decided by anyone.
Get-MsecAzureDevOpsOrganizationPolicy -Organization 'contoso' |
    Where-Object { -not $_.IsExplicit }
```

## PARAMETERS

### -Organization
Azure DevOps organization name: the path segment after dev.azure.com/, e.g.
'contoso'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per policy, PSTypeName 'MsecAzureDevOpsOrganizationPolicy'.
## NOTES
Needs Connect-Msec, and the msec app's service principal must be a member of the ADO
organization (Organization Settings \> Users \> Add) with Basic access.
That is granted
INSIDE Azure DevOps, not through Entra API permissions, so New-MsecApp cannot do it.

Verified against a live organization: 13 policies in 4 groups.

A POLICY THAT IS ON IS A SETTING, NOT A CAPABILITY.
These rows report what the
organization has configured; they do not report what Azure DevOps will actually let
anyone do.
The two can disagree, and 'Allow public projects' is the case where they
did: measured on a live organization it read Value True and IsExplicit True - somebody
had deliberately turned it on - while the product refused to create a public project at
all, offering GitHub instead.
The reason is that PUBLIC PROJECTS ARE RETIRED: Microsoft
removed the ability to create one or to make a private project public, and existing
public projects convert to private during 2027.
The toggle still renders, still stores
a value and still reports IsExplicit - and means nothing.
A vestigial setting is a
worse failure than a wrong one, because it reads as a live permission in both
directions.

So an enabled policy here is the right place to START a question, not the answer to it.
Reading 'Allow public projects: True' as "this organization can publish its code" was
wrong on the one organization it was tested against - the only way to know is to try it,
or to check what the projects actually are (Get-MsecAzureDevOpsRepository reports the
repositories; project visibility is on the project).
The reverse error is not possible
in the same way: a policy that is OFF really does mean the capability is unavailable.

## RELATED LINKS
