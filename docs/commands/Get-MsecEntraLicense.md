---
external help file: Msec-help.xml
Module Name: Msec
online version:
schema: 2.0.0
---

# Get-MsecEntraLicense

## SYNOPSIS
Lists the tenant's subscribed licence SKUs as flat rows, with the service
plans each one turns on.

## SYNTAX

```
Get-MsecEntraLicense [<CommonParameters>]
```

## DESCRIPTION
Calls Microsoft Graph /v1.0/subscribedSkus and projects each SKU to a
PSCustomObject.
This is the tenant's licence inventory: what was bought,
how much of it is assigned, and which underlying service plans it enables.

Use this to answer "is this workload even licensed here".
That question is
the difference between a real security gap and a not-applicable one: a
tenant with no AAD_PREMIUM service plan cannot have Conditional Access at
all, so an empty CA policy list is expected rather than alarming.
The
derived, question-shaped version of this lives in
Get-MsecEntraTenantSecuritySetting, which turns these plans into
capability flags (ConditionalAccessAvailable, IntuneProvisioned, ...).

Requires the 'Organization.Read.All' application permission.
A clearer
error is raised on the typical 403.

## EXAMPLES

### EXAMPLE 1
```
Get-MsecEntraLicense | Sort-Object SkuPartNumber
```

### EXAMPLE 2
```
# What is actually assigned to someone (bought-but-unused SKUs excluded)?
Get-MsecEntraLicense | Where-Object Assigned -gt 0
```

### EXAMPLE 3
```
# Does this tenant have Entra ID premium (and therefore Conditional Access)?
Get-MsecEntraLicense | Where-Object ServicePlans -contains 'AAD_PREMIUM'
```

## PARAMETERS

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per subscribed SKU. See .NOTES for the projection.
## NOTES
Each row is a \[PSCustomObject\] with PSTypeName 'MsecEntraLicense', whose
DefaultDisplayPropertySet (SkuPartNumber, Enabled, Assigned,
CapabilityStatus) is registered in Msec.psm1 - so Format-Table shows a
clean 4-column view and the Raw / ServicePlans columns stay accessible
without cluttering it.

Projection (Graph field path -\> output property):
  skuId                                  -\> SkuId
  skuPartNumber                          -\> SkuPartNumber
  appliesTo                              -\> AppliesTo        ('User' / 'Company')
  capabilityStatus                       -\> CapabilityStatus ('Enabled' / 'Warning' / 'Suspended')
  prepaidUnits.enabled                   -\> Enabled          (units bought and usable)
  prepaidUnits.warning / .suspended      -\> WarningUnits / SuspendedUnits
  consumedUnits                          -\> Assigned
  servicePlans\[\].servicePlanName          -\> ServicePlans     (names with provisioningStatus 'Success')
         (where provisioningStatus eq Success)
  servicePlans\[\]                         -\> ServicePlanDetail (full objects: name, status, appliesTo)
  \<entire SKU object verbatim\>           -\> Raw

Only service plans whose provisioningStatus is 'Success' land in
ServicePlans.
A plan can be present but PendingProvisioning or Disabled,
in which case the capability is not actually usable - so filtering on
ServicePlans is the honest test.
ServicePlanDetail keeps every plan
regardless of status for when you need to see the difference.

## RELATED LINKS
