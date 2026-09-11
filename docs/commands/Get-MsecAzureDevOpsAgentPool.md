---
external help file: msec-help.xml
Module Name: msec
online version:
schema: 2.0.0
---

# Get-MsecAzureDevOpsAgentPool

## SYNOPSIS
Agent pools in an Azure DevOps organization, with what runs in them - one row per pool.

## SYNTAX

```
Get-MsecAzureDevOpsAgentPool [-Organization] <String> [-SelfHostedOnly] [-IncludeExposure] [<CommonParameters>]
```

## DESCRIPTION
A self-hosted agent executes pipeline code on a machine you own, as whatever account the
agent service runs under.
Anyone who can queue a pipeline against the pool can run code
there.
That makes pool membership a permission question and the agents themselves an
estate question - what they are, how old, and whether they are still reachable.

MICROSOFT-HOSTED POOLS ARE DISPOSABLE; SELF-HOSTED ONES ARE NOT.
A hosted agent is a
fresh VM per job.
A self-hosted agent keeps its disk, its credentials and whatever the
last job left behind, so a compromised pipeline persists there.

AUTOPROVISION MEANS EVERY NEW PROJECT GETS THE POOL.
It is how a pool intended for one
team ends up reachable from projects nobody associated with it.

AGENT VERSIONS AND OPERATING SYSTEMS ARE REPORTED AS DISTINCT LISTS, not summarised.
A
pool where most agents are current and one is three major versions behind is the case
worth seeing, and an average or a maximum would hide exactly that agent.

AN OFFLINE AGENT THAT IS STILL ENABLED IS NOT DECOMMISSIONED.
It is a machine that will
rejoin and start taking jobs the moment it comes back, which is a different thing from
one that was removed.
LongestOfflineDays says how long the most absent of them has been
gone - measured on a live organization, two years, on an agent two major versions behind.

## EXAMPLES

### EXAMPLE 1
```
Connect-Msec -KeyVaultName kv-msec
Get-MsecAzureDevOpsAgentPool -Organization 'contoso' -SelfHostedOnly
```

### EXAMPLE 2
```
# Pools reachable from every project, running on machines you own.
Get-MsecAzureDevOpsAgentPool -Organization 'contoso' |
    Where-Object { -not $_.IsHosted -and $_.AutoProvision }
```

## PARAMETERS

### -Organization
Azure DevOps organization name: the path segment after dev.azure.com/.

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

### -SelfHostedOnly
Only pools running on your own machines.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeExposure
Which projects can queue work on each pool, and whether any pipeline in those projects
may do so without approval.

OPT-IN and the most expensive thing here: one call per project to list queues, plus one
per queue belonging to a pool being reported.
AutoProvision answers "will FUTURE
projects get this pool"; this answers "which ones have it NOW", which is the question
an access review actually asks.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: False
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

## OUTPUTS

### PSCustomObject per pool, PSTypeName 'MsecAzureDevOpsAgentPool'.
## NOTES
Needs Connect-Msec and organization membership.
Everything here is readable by any
member, including -IncludeExposure.

THERE IS DELIBERATELY NO ROLE-ASSIGNMENT COLUMN.
Reading distributedtask.agentqueuerole
was not enabled by 'View' or by 'Use' on the DistributedTask namespace - both were
granted at the organization root against a live organization and the read still returned
403.
The only remaining candidate is 'AdministerPermissions', the right to CHANGE
permissions, which this module has no business holding to display four counts.

The question those counts would answer - who can put work on this pool - is answered by
-IncludeExposure instead: which projects have a queue for it, and whether any pipeline in
those projects may use it without approval.
That needs no extra permission.

## RELATED LINKS
