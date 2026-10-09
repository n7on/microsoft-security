# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- The `Connect-MsecAdmin`, `Set-MsecDefenderAlert` and `Set-MsecDefenderIncident` tests failed on
  the macOS CI runner and passed on Windows and Ubuntu.

  They mock `Get-MgContext`, `Connect-MgGraph` and `Disconnect-MgGraph`, and Pester's `Mock`
  requires the command to EXIST - a missing one fails as "Could not find Command Get-MgContext"
  rather than as anything pointing at the real cause. `Microsoft.Graph.Authentication` is
  preinstalled on the Windows and Ubuntu GitHub images but not the macOS one, so the same suite
  passed on two runners and failed on the third.

  Installing it in CI was the wrong fix: unlike Az, it is deliberately NOT a dependency of msec -
  only `Connect-MsecAdmin` needs it, and it checks at run time. The tests now stub those three
  commands, and ONLY when they are genuinely absent, so a machine with the real module still
  mocks the real command and the two behave identically. Same pattern the Purview tests already
  use for the optional ExchangeOnlineManagement cmdlets.

  THE STUBS CARRY THE REAL PARAMETER NAMES, which the first attempt at this did not. A stub of
  `param()` with no `[CmdletBinding()]` is a SIMPLE function: it accepts any argument into
  `$args` rather than rejecting it, so `Connect-MgGraph -TenantId x` did not fail - `$TenantId`
  simply never bound. A `-ParameterFilter { $TenantId -eq 'tenant-1' }` then matched nothing and
  the assertion failed as "expected 1 call, got 0", which reads as the command never having been
  called. Every stub now declares `[CmdletBinding()]` and the parameters the tests filter on.

### Added
- `Get-MsecPurviewActivity` - Purview Activity Explorer events, one row each, with policy, rule
  and sensitivity-label names resolved. Narrow server-side with `-Activity`, then `Group-Object`
  the rest.

  THIS IS THE ONLY WAY TO MEASURE DLP IN A TENANT WITHOUT DEFENDER FOR CLOUD APPS. Advanced
  hunting has no DLP table at all, and `CloudAppEvents` is present but empty unless Defender for
  Cloud Apps is onboarded - so "how often does this policy actually fire" is unanswerable from
  hunting and answerable from here.

  THE API HAS THREE WAYS OF SILENTLY RETURNING NOTHING, and the command exists mostly to stop
  each from reading as "there was no activity". All three were hit while writing it.

  A WINDOW OF 30 DAYS OR MORE RETURNS A WHOLLY EMPTY RESPONSE - no rows, no total, no result
  code, and no error. Measured: 29 days returned 143,952 events, 30 days returned silence.
  `-Days` is capped at 29 rather than the 30 the documentation implies, and the empty-response
  shape is detected and thrown on by testing `ResultCode`, because row count alone cannot tell
  it from a quiet window.

  THE FILTER TAKES THE `ActivityId` TOKEN, NOT THE DISPLAYED NAME. `DLPRuleMatch` matches;
  `DLP rule matched` - the string the portal and the `Activity` column both show - returns an
  empty result rather than an error. `-Activity` refuses the displayed form and names the token
  to use instead.

  ONE CALL IS ONE PAGE, NOT THE RESULT SET. The response carries `TotalResultCount` for the
  whole query and at most `PageSize` rows; paging continues through `WaterMark` until
  `LastPage`. Summarising page one of a 29,000-row week is a confident answer drawn from 17% of
  it. The command pages to the end and warns when the pull falls materially short of the total,
  while tolerating the small drift from events landing mid-pull.

  NESTED FIELDS ARE FLATTENED because the useful ones are not top-level. `PolicyName` and
  `RuleName` live inside `PolicyMatchInfo`, so grouping by `PolicyName` on the raw output puts
  every row under one blank key - which reads as "no policy matched". `SensitivityLabel` is a
  bare GUID and is resolved to the label's display name; a label deleted since the event is
  reported as its GUID rather than as a blank, because historical events outlive their labels
  and blank would read as "unlabelled".

- `Get-MsecDefenderEmail` - messages from the Defender `EmailEvents` table, one row each, with
  the sending server's country resolved as a column. A general pivot rather than a command per
  question: narrow server-side with `-SenderCountry`, `-SenderDomain`, `-SenderAddress`,
  `-RecipientAddress`, `-SenderIp`, `-Subject`, `-ThreatType`, `-DeliveryLocation`,
  `-ThreatsOnly` or `-Direction`, then `Where-Object` and `Group-Object` the rest.

  `EmailEvents` IS NOT A SPAM TABLE. It holds every message Exchange Online Protection
  processed - inbound, outbound and intra-org, clean mail included. The verdict is a column,
  not a filter.

  SENDERCOUNTRY IS THE SENDING INFRASTRUCTURE, NOT THE AUTHOR. `SenderIPv4` is the last SMTP hop
  that connected to Exchange Online, so a message relayed through Gmail or SendGrid geolocates
  to that provider's egress and says nothing about where the person was. Nothing in
  `EmailEvents` holds the author's client address - it never reaches the recipient's mail
  system. `AuthenticationDetails` sits next to it because SPF/DKIM/DMARC answer the stronger
  question: was that infrastructure authorised to send for the domain it claims.

  A MESSAGE THAT ARRIVED OVER IPv6 HAS NO COUNTRY AT ALL and carries
  `(IPv6 - not geolocated)` rather than a blank. `geo_info_from_ip_address` resolves IPv4, and a
  blank would be swallowed by a `-eq` filter exactly like a real miss. The unplaceable buckets
  can be asked for by name, so they are reachable and not merely visible.

  THE FILTER PARAMETERS ARE NOT A CONVENIENCE WRAPPER AROUND `Where-Object`. They apply in KQL
  before the row ceiling, so they change which messages are available to filter downstream -
  filtering a truncated fetch in PowerShell does not. Ask for a window holding 40,000 messages,
  take the newest ceiling-worth, filter to one country, and the answer looks complete and is
  wrong.

  THE CEILING CANNOT BE REMOVED, ONLY MOVED, which is why `-MaxMessages` defaults to the
  `/security/runHuntingQuery` ceiling instead of a smaller number of msec's own invention: a
  command without the parameter would still be truncated by the service, it would just stop
  saying so. The matching total is counted separately and compared with what was returned, so
  truncation is reported with both numbers either way. Both queries are built from one filter
  expression - a count over a different population than the rows would be worse than no count.

  `-SenderDomain` and `-SenderAddress` match the header From OR the envelope MailFrom, because
  relayed mail carries different values in the two and matching one would quietly miss it.
  `-Subject` uses `contains` rather than `has`: `has` is token-based and finds "Invoice" in
  "Invoice due" but not in "Invoice-2451".

- `Get-MsecDefenderTeamsMessage` - Teams messages from the Defender `MessageEvents` table, one
  row each, with recipients flattened out of `RecipientDetails` and URL counts and domains
  joined from `MessageUrlInfo`. Same shape as `Get-MsecDefenderEmail`: narrow server-side with
  `-SenderAddress`, `-RecipientAddress`, `-Subject`, `-ThreadName`, `-ThreadType`,
  `-SenderType`, `-ExternalOnly`, `-ThreatType` or `-ThreatsOnly`, then filter the rest in
  PowerShell.

  THERE IS NO SENDER IP, SO THERE IS NO COUNTRY. Teams is not SMTP - a message arrives through
  Microsoft's service from an authenticated identity, and `MessageEvents` has no address column
  of any kind. The geography question `SenderCountry` answers for mail cannot be asked here.
  What stands in its place is identity and trust boundary: `SenderType` (User, Anonymous,
  Applications) and `IsExternalThread`.

  ONE ROW PER MESSAGE, NOT PER RECIPIENT - the opposite of `EmailEvents`. `RecipientAddress` is
  a `string[]`, so test it with `-contains`. Joining the addresses into one string would force
  `-like '*someone@x*'` on every such query, and a substring match reports `anna@x` as a hit
  for `joanna@x`.

  SUBJECT IS EMPTY FOR CHAT AND MEETING MESSAGES - populated only for channel posts. `-Subject`
  therefore matches nothing across the bulk of the table, so `-ThreadName` is offered beside it
  as the usable handle for chat. Both exist because channel posts really do have subjects.

  A LEFTOUTER JOIN THAT MISSES RETURNS AN EMPTY OBJECT, NOT NULL, which `??` does not catch and
  a cast does not survive: `[int]` on it throws, and `[bool]` on it returns `$true` - so a
  missing `IsExternalThread` would have silently reported an internal thread as crossing the
  tenant boundary. Every value from the API is coerced through a string first.

  VERDICT COLUMNS CAN BE EMPTY ACROSS THE WHOLE TABLE AND THAT IS NOT A BUG. `ThreatTypes`,
  `DetectionMethods`, `ConfidenceLevel` and `SafetyTip` are populated only where Defender for
  Office 365 acted on a Teams message; they are returned regardless, because their absence is
  the finding when you expected otherwise. `MessagePostDeliveryEvents` is NOT joined, so there
  is no equivalent of mail's `LatestDeliveryLocation`: `DeliveryLocation` says where a message
  was delivered, not whether it was removed afterwards.

- `Get-MsecAppGatewayClientActivity` - everything one or more client IPs did through an
  Application Gateway, and whether any of them ever completed an authentication.

  REACHING A LOGIN PAGE IS NOT LOGGING IN, and that distinction is the command. A gateway access
  log has no usernames and no authentication result, so a 200 on a login page says only that a
  page was rendered - crawlers produce those constantly. Authentication is inferred from the two
  points a client cannot reach unless the identity provider already authenticated it:
  `POST /signin-oidc` and `GET /connect/authorize/callback`. Treating a login-page 200 as a
  sign-in turns every search engine into an intruder.

  `Authenticated` is `$null`, never `$false`, on hourly-summary rows: that table carries client
  IP and a status class but NO HTTP method and NO full URI, so the question is unanswerable
  there and `$false` would assert something unmeasured. `-SummaryOnly` keeps the same
  distinction per address - `$false` only where a per-request log existed and showed none.

  `Grain` says which source each row came from, because a window can change grain part-way
  through: a gateway switched to resource-specific logging stops writing AzureDiagnostics, and
  on the Basic plan the replacement table cannot be read by KQL at all. An address whose detail
  stops on a given day was not necessarily quiet from then on.

  A malformed address is refused before the query rather than filtered - a CIDR suffix or a
  stray space matches nothing, and an empty result reads as "this address did nothing".

- Two bundled KQL queries for the same ground: `Law/AppGateway/ClientGeography` (traffic by
  client country across both log modes) and `Law/AppGateway/AuthenticationByCountry` (completed
  sign-ins only), plus `Hunting/Email/SenderGeography` (inbound mail by sending-server country,
  with delivered share and threat counts).

  `SenderGeography` documents that `SenderIPv4` is the LAST HOP, not the author - mail from a
  Russian sender relayed through Gmail geolocates as the United States - and buckets IPv6
  senders explicitly rather than letting them vanish from a country breakdown.

  BOTH UNION LEGS MUST AGREE ON COLUMN TYPE. A bare integer literal in KQL is a `long` while
  `toint()` returns an `int`; mismatched legs make Kusto emit `Requests_long` and `Requests_int`
  as two columns instead of failing, and the later `sum(Requests)` then references a column that
  does not exist - surfacing only as `BadRequest` with nothing naming the cause. Found the hard
  way; `tolong()` on both legs is the fix, and the same trap is already documented for
  `TransactionId` in `Law/Waf/All.kql`.

- `Get-MsecEntraConditionalAccessChange` - who changed which Conditional Access policy, when,
  and the before/after of each setting that actually moved.

  Entra records a CA change as ONE audit property whose old and new values are the entire policy
  as a JSON string. Read raw that is two multi-kilobyte blobs and no answer; this parses both and
  reports only the differing fields, so "MFA was removed from policy X" is a row.

  `modifiedDateTime` is EXCLUDED from the diff because it changes on every edit by definition -
  left in, every change carries a meaningless entry and the real one is harder to find. Same for
  `id` and `createdDateTime`, which cannot change at all.

  `state` is lifted into its own column. A policy moving `enabled` to `disabled`, or out of
  `enabledForReportingButNotEnforced` into enforcement, is the highest-signal CA change there is
  and is otherwise one field inside a large object.

  AN APP CAN CHANGE CONDITIONAL ACCESS AND USUALLY DOES. Measured on one tenant, 11 of 15 changes
  came from a Microsoft365DSC orchestrator service principal and 4 from people, so the actor
  falls back from user principal name to application display name - reading only
  `initiatedBy.user` would report the majority of changes as authorless.

  An empty result WARNS: the directory audit log retains 30 days on Entra ID P1/P2 and 7 on the
  free tier, so silence is not stability. `ModifiedDateTime` on the policy object persists
  indefinitely, and the help points at comparing the two.

  Needs only `AuditLog.Read.All`, which `New-MsecApp` already grants.

- `New-MsecDefenderDetectionRule` - creates a Defender XDR custom detection rule from an
  advanced hunting query, after running the query to check it works.

  THE VALIDATION IS THE POINT, NOT THE POST. A custom detection whose query is malformed,
  references a table the tenant does not have, or omits a column its entity mapping names is
  accepted by the portal and by the API, then fails on its schedule - and Defender eventually
  marks it `autoDisabled` while it carries on looking live in the rule list. So the query is
  executed first through the app's read-only hunting access and creation is refused if it does
  not run, naming the missing column, because Defender's own rejection does not say which.

  Row count is checked too: the other way a new detection goes wrong is working perfectly and
  matching eight hundred things. A query matching more than `-MaxExpectedRows` warns before
  anything is created.

  A query matching NOTHING is explicitly allowed - that is the normal state of a good detection,
  and refusing it would block exactly the rules worth having. Column names simply cannot be
  checked against an empty result, which the verbose stream says rather than passing silently.

  TWO IDENTITIES BY DESIGN: validation reads through the app certificate
  (`ThreatHunting.Read.All`); creation writes through the delegated session from
  `Connect-MsecAdmin -Scope CustomDetection.ReadWrite.All`, which is the only scope this API
  accepts - there is no read-only or lesser one. A read-only app that could add alert rules
  would not be read-only in any sense that matters.

- `Get-MsecDefenderDetectionRule` - Defender XDR custom detection rules: the scheduled advanced
  hunting queries that raise alerts, with their run status, schedule and query.

  NOT THE SAME AS `Get-MsecSentinelRule`, and the two are easy to confuse because Microsoft
  calls both "detection rules". They are different products reading different stores, and
  neither can see the other's. Measured on one tenant: 53 Sentinel rules, none of them able to
  see a Defender device event, because no `Device*` table exists in that workspace. Asking the
  wrong command returns a confident list of the wrong rules.

  'AUTODISABLED' IS THE REASON IT EXISTS. Defender switches a custom detection off by itself
  when its query starts failing - a renamed column, a table that stops resolving. The rule
  still exists, still appears in the portal list, and has silently stopped running. That is
  indistinguishable from a rule that works and finds nothing, which is the most expensive
  failure a detection can have.

  `status`, NOT `isEnabled`: that property was removed from the resource on 2026-10-01 along
  with `detectorId` and `lastRunDetails`. Code still reading it gets `$null`, which is falsy,
  and reports every live rule as disabled. The retired property is read only as a fallback when
  `status` is absent, and neither present reports `$null` - unknown, not off.

  Needs `CustomDetection.Read.All`, added to `New-MsecApp`. RUNNING a hunting query and SEEING
  the scheduled detections built on it are separate grants: `ThreatHunting.Read.All` covers only
  the first, so without this the module could execute any query it liked and still not answer
  "do we detect that?".

- `Get-MsecIntuneReusableSetting` - the device groups and setting blocks endpoint security
  policies reference, with how many policies use each and what is inside them.

  A Device Control policy says "Allow only authorized USBs" and then points at a reusable
  setting by GUID. The policy is the rule; the reusable setting is the answer - which devices,
  by serial number. Reading the policy alone tells you a decision is being made and not what it
  decides, and `Get-MsecIntuneAsrRule` prints that GUID unresolved.

  AN UNREFERENCED REUSABLE SETTING IS A LEFTOVER AND INTUNE DOES NOT CLEAN THEM UP. Deleting a
  policy leaves its reusable settings behind, unreferenced and shown as unused by no blade -
  measured on one tenant, deleting two Device Control policies left two orphans.

  BOTH THE REFERENCE COUNT AND THE CONTENTS ARE ABSENT WITHOUT AN EXPLICIT `$select`. A plain
  GET returns id, displayName, description, settingDefinitionId and lastModifiedDateTime, and
  silently omits `referencingConfigurationPolicyCount` and `settingInstance` - not null,
  absent. Code that reads them without asking gets `$null` and reports every setting as
  unreferenced and empty, which is how an in-use allow-list gets deleted.

  A missing count is therefore reported as `$null`, never `0`, and `-UnreferencedOnly` excludes
  unknowns: orphaned and unmeasured are different, and only one of them justifies deletion.

  Entries nest at varying depths in the payload, so they are collected by walking the whole
  setting instance rather than assuming a fixed shape.

- `Get-MsecDefenderCertificateUsage` and `New-MsecDefenderIndicator` - the code-signing
  certificates in use on the fleet, and the ability to allow or block one.

  `SignerHash` IS THE WINDOWS THUMBPRINT, which is what makes the pair useful rather than merely
  informative. Verified both ways on one tenant: the value Defender reported and the SHA-1
  computed from the vendor's own installer were identical. The Defender portal's wizard wants a
  `.CER` upload and derives the thumbprint from it; the API takes the thumbprint directly, so
  "notice a new signing certificate, allow it" needs nothing downloaded or extracted.

  A CERTIFICATE EXPIRY IS A ROTATION, AND A ROTATION BREAKS INDICATORS SILENTLY. Only leaf
  certificates can be used in an indicator, so when a publisher renews, everything signed
  afterwards carries a thumbprint no existing indicator matches - while the old indicator keeps
  covering everything already signed, because timestamped Authenticode signatures outlive the
  certificate. Old files keep working, new ones stop. `-ExpiringWithinDays` is how that is seen
  coming; measured on one tenant it surfaced a vendor certificate 13 days from expiry and the
  organisation's own signing certificate 17 days from expiry.

  `New-MsecDefenderIndicator` RUNS AS THE SIGNED-IN USER and could not do otherwise: the
  indicator API has no read-only permission, so even listing indicators needs `Ti.ReadWrite` -
  the same scope that creates and deletes them. Granting that to the msec app would let a
  certificate in Key Vault allow-list arbitrary publishers across every onboarded device, which
  is the ability to disable blocking for malware of someone's choosing. It takes a delegated
  token from the Az context instead, and the app keeps its read-only property.

  A malformed thumbprint is rejected before the call, because the API accepts one without
  complaint and the indicator then matches nothing - indistinguishable from a working indicator
  the product is ignoring. `-Description` is mandatory although the API treats it as optional:
  an allow indicator with no recorded reason is indistinguishable from a mistake six months
  later. `ConfirmImpact` is High and an existing identical indicator is reported rather than
  duplicated.

- `Get-MsecIntuneAsrRule` - every Attack Surface Reduction rule, the mode it is set to, which
  policy sets it, who that policy reaches, and the rules no policy configures at all.

  THE UNCONFIGURED RULES ARE THE POINT AND THEY ARE INVISIBLE IN THE PORTAL. A policy blade
  shows the rules that policy sets; a rule set by no policy appears nowhere, so the gap can only
  be found by diffing against the full catalogue by hand. Measured on one tenant: two baselines
  of 16 rules each, with 'Block rebooting machine in Safe Mode' and 'Block Webshell creation for
  Servers' in neither.

  The catalogue is read from the Graph setting definitions rather than hardcoded, so a rule
  Microsoft adds appears the day it ships instead of being silently absent. Only the GUIDs are
  local, and a rule with no GUID mapping is still emitted with `RuleId` `$null`.

  `Mode` is `$null` for an unconfigured rule and `'off'` for one explicitly disabled - different
  states, because an explicit off wins a policy conflict and an absent rule does not.

  TWO MODES IS NOT AUTOMATICALLY A CONFLICT. The commonest deliberate ASR design is a rule in
  audit for one group and block for everyone else, with the policies excluding each other's
  groups; on the tenant this was built against, the only rule set to two modes was exactly that.
  `ModesDiffer` is the fact and `Conflicting` the judgement - true only where the policies do not
  carve each other out.

  Two defects found against live data and covered by tests: Device Control policies share the
  `endpointSecurityAttackSurfaceReduction` template family, and their settings sliced at the ASR
  prefix length produced rules named `uleid}_ruledata`; and `exclusionGroupAssignmentTarget` also
  matches the wildcard `*groupAssignmentTarget` while PowerShell's `switch` runs every matching
  branch, so carve-out groups landed in the included list and "everyone except developers" read
  as "everyone".

  ASR set through the older intents API, classic endpoint protection profiles, Group Policy or
  local PowerShell is not read; where the first two exist a warning names them, because an
  unqualified `Configured = $false` would claim a completeness the command cannot deliver.

  PER-RULE EXCLUSIONS ARE NESTED UNDER THE RULE, NOT BESIDE IT. The setting id reads
  `<rule>_perruleexclusions`, which suggests a sibling; Intune actually hangs the list off the
  rule's own `choiceSettingValue`, one level deeper. The first version indexed at the wrong
  depth and reported no exclusions on a policy that had one - and the test fixture encoded the
  same wrong assumption, so it passed. Found only when a live Git exclusion was added and did
  not appear. The rule's subtree is now walked rather than indexed, a sibling is still accepted
  in case the shape varies elsewhere, and a test asserts one rule is never handed its
  neighbour's exclusions.

  Fixing it surfaced a pre-existing fleet-wide exclusion of `msiexec.exe` from the LSASS
  credential-theft rule - a standard-protection rule - which had been invisible.

- `Get-MsecIntuneAuditEvent` - the Intune audit log: who changed which policy, when, and the
  before/after value of every setting that moved.

  This is a DIFFERENT STORE from the Entra directory audit log, with a different and much
  longer retention. Entra keeps 30 days on P1/P2 and 7 on the free tier, which is the ceiling
  `Get-MsecEntraDisabledUser` is built around; a policy change long gone from there is usually
  still here. Nothing in the endpoint path hints at the distinction - both are "the audit log"
  in conversation, and reaching for the wrong one returns an empty result rather than an error.

  THE PERMISSION IS THE LEAST GUESSABLE IN THE MODULE: `/deviceManagement/auditEvents` is gated
  by `DeviceManagementApps.Read.All`, the Intune APPS scope. It is not covered by
  `DeviceManagementConfiguration.Read.All` - which reads the very policies whose changes are
  logged here - nor by `DeviceManagementManagedDevices.Read.All`, nor by `AuditLog.Read.All`.
  Added to `New-MsecApp`, so an app created before this must re-run it and re-consent. The 403
  is rewritten to say all of that rather than returning Graph's bare status line.

  `ChangedProperties` is the reason the command exists: an audit event names the policy that was
  touched, but only the modified properties say what moved, as `Setting: old -> new`. That is
  what tells an ASR rule going from Audit to Block apart from someone renaming the policy.

  An empty result WARNS rather than returning silence: "nothing changed" and "the window does
  not reach back that far" are the same empty array, and the second is the answer that matters
  when dating a change somebody rolled back. `-Days` sets what is asked for, never what is
  available - the verbose stream reports the oldest event that actually came back, because
  Microsoft does not document the retention and guessing it in a module anyone can run against
  any tenant would be inventing a number.

  `-Category` uses an ArgumentCompleter rather than a ValidateSet: the category set is not
  documented and differs between tenants, so a ValidateSet would reject real values.
- Three bundled queries for the Application Insights estate: where telemetry lands, and whether
  it holds things it should not.

  `Search-MsecAzureResourceGraph -ResourceType ApplicationInsights` maps every component to the
  Log Analytics workspace it writes into. A component is a front door, not a store - since the
  workspace-based model the telemetry lives in a workspace - so "what is in our telemetry" can
  only be asked once you know which workspace to ask. Measured on one estate: 703 components
  across 66 workspaces, 44 of them auto-created `managed-*` or `DefaultWorkspace-*` rather than
  chosen.

  `Search-MsecLogAnalytics -Subject AppInsights -Name Secrets` and `-Name PersonalData` scan the
  free-text columns of the App* and AppService* tables.

  THEY REPORT WHERE A SECRET IS, NEVER WHAT IT IS. A query returning the matching line would
  move every secret it found into a console scrollback, an exported CSV, a ticket and a chat
  transcript - multiplying the exposure it was run to measure. Only the SHAPE is projected: six
  characters, which are the pattern's own literal prefix (`eyJhbG` is the base64 of every JWT
  header), plus a length. `DistinctValues` separates one secret logged a thousand times from a
  thousand secrets.

  PERSONAL DATA IS REDACTED HARDER, because six characters of an email address identifies
  somebody where six characters of a token does not: emails keep only their domain - enough to
  tell staff addresses from participants' - and everything else keeps only a length.

  ONE UNION BRANCH PER COLUMN. The first version concatenated CsUriQuery and Cookie into one
  haystack and labelled every hit `CsUriQuery`. Every JWT it found was in the Cookie header - an
  ordinary place for a session token - and the report said they were in URLs, which is a far
  more serious and completely different finding. Measured after the fix: 13,566 in Cookie across
  19 apps, 61 in Url across 4. A Column value that is not the column the match came from is
  worse than no Column value at all.

  WORD BOUNDARIES ON PREFIXED-TOKEN PATTERNS. Without `\b`, `AKIA` and `eyJ` match INSIDE
  base64, and ASP.NET data-protection cookies carry those sequences as ordinary substrings. An
  exploratory scan without them reported 302 "GitHub tokens" and 222 "npm tokens" that were all
  auth cookies.
  `extract()` CANNOT TAKE A COMPUTED PATTERN. Selecting a regex with `case()` fails at parse
  time with SEM0040, so each pattern is extracted with its own constant regex and the first
  non-empty match wins.

  NO TIME FILTER IN THE FILES. The repo already had a test failing any `kql/Law` query that
  contains `ago()`, and the first draft of these tripped it: a window baked into a file
  intersects silently with the one the caller asked for, so `-Days 30` would have quietly
  returned one day. Verified after the fix - one day returns 1,664 occurrences and three days
  5,453.

  The IBAN pattern was tightened to real issuing-country prefixes after the unrestricted form -
  any two letters then two digits - matched base64 and GUID fragments in URL query strings on
  every hit. All ten matches it produced were false positives.

- `Get-MsecSentinelRule` - Sentinel analytics rules with their tuning state, and the id that
  joins them to the alerts they produced.

  RULEID IS THE JOIN TO THE ALERTS. A rule's resource name is a GUID, and that GUID is the
  `alertPolicyId` on every alert the rule raised - so `RuleId` joins straight to
  `Get-MsecDefenderAlert`'s `Raw.alertPolicyId`. Matching on display name looks equivalent and
  is not: titles get edited, duplicated between a stock rule and a tuned copy, and localised.

  TUNING STATE IS THE POINT, NOT THE QUERY. `GroupingEnabled`, `SuppressionEnabled` and
  `TriggerThreshold` decide how much noise a rule makes. Measured on one workspace: 48 rules,
  45 enabled, 48 still stock from their Content Hub template, and `0` with alert grouping or
  suppression enabled. With grouping off, every alert becomes its own incident.

  GROUPING ABSENT IS NOT GROUPING DISABLED. A Fusion rule carries no `incidentConfiguration`,
  so `GroupingEnabled` is ``; a Scheduled rule with it switched off is ``.

  A NAMED WORKSPACE THAT IS NOT FOUND THROWS. Building the request URL from an empty
  ResourceId yields `/providers/Microsoft.SecurityInsights/...` with no scope, and Azure
  rejects that as an AUTHORIZATION failure - sending the reader to check RBAC for a workspace
  that was never located. That happened while writing the command, so there is a test for it.
  A workspace that exists but is not Sentinel-onboarded is named too; one found during
  discovery is skipped quietly, since most Log Analytics workspaces are not Sentinels.

  Runs as the signed-in user through ARM, like `Get-MsecAzureSecureScore` - the app
  certificate holds Graph permissions, not Azure RBAC.

- `Get-MsecAzureDevOpsWorkItem` - work items with tags, state category and age, for tracking
  whether security findings are actually being closed.

  THIS MEASURES YOUR PROCESS, NOT YOUR TENANT. Every other Get-Msec* command reads a Microsoft
  system and reports how it is configured; this reads your own backlog and reports how the team
  is responding. Both are security questions but they are different ones, so it stays out of
  `Export-MsecPostureReport` - a remediation count must not blur into a posture score.

  NO BUNDLED QUERIES. Area paths, tags, states and type names differ in every organisation, so
  the conventions are PARAMETERS rather than shipped WIQL files. Shipping a query that referred
  to one tenant's taxonomy would return nothing, or something misleading, in anyone else's.

  'OPEN' IS NOT A STATE NAME, IT IS A STATE CATEGORY. Agile uses New/Active/Resolved/Closed,
  Scrum uses New/Approved/Committed/Done, Basic uses To Do/Doing/Done. `System.StateCategory`
  is NOT a queryable WIQL field, so `-OpenOnly` resolves each type's states through the states
  API and keeps anything not Completed or Removed. An item whose state could not be classified
  is KEPT, never dropped - shrinking the list someone uses to chase outstanding work is the
  worst available failure.

  `Invoke-MsecAzureDevOpsRequest` gained `-Method` and `-Body` so it can POST to wiql and
  workitemsbatch. Additive: every existing caller omits both and is unaffected. Note the helper
  ALREADY UNWRAPS the response's `value` array - taking `.value` again yields nothing, and the
  symptom is a correct row count with every field blank.

  AZURE DEVOPS PUTS THE REAL REASON IN THE RESPONSE BODY, not the status line, and
  `Invoke-MsecAzureDevOpsRequest` was discarding it - so every ADO command reported 400s as an
  indistinguishable 'Response status code does not indicate success'. It now surfaces the body's
  message, which is how 'VS402337: The number of work items returned exceeds the size limit of
  20000' and 'TF51005: The query references a field that does not exist' reach the caller. This
  improves all 14 ADO commands, not just the new one.

  ROWS ARE NOT IN BOARD ORDER unless you ask for it. They come back newest-first by Id; board
  order is a drag-and-drop rank, and WHICH FIELD HOLDS IT DEPENDS ON THE PROCESS - Scrum writes
  `Microsoft.VSTS.Common.BacklogPriority`, Agile and CMMI write `Microsoft.VSTS.Common.StackRank`.
  Both are requested and whichever is populated becomes `BacklogRank`, so `Sort-Object
  BacklogRank` reproduces the backlog. An item never ranked has a NULL rank, not 0: zero would
  sort it to the top as though someone had deliberately put it first. `BoardColumn` is returned
  too, and is not the same as State - a board can map several columns onto one state.

  A TEAM'S BACKLOG IS SEVERAL AREA PATHS, NOT ONE, and each carries its own includeChildren
  flag, so `-Team` reads the team's real definition from Azure DevOps instead of making the
  caller guess it. Measured on one project, 'Security and Regulatory compliance' spans four
  area paths and one of them excludes its children - UNDER for all four would over-report, `=`
  for all four would drop most of the backlog. `-AreaPath` now takes several values too.

  THE 20,000 LIMIT IS ENFORCED BEFORE ANY RESULT IS RETURNED, so `-MaxItems` cannot help - it
  caps a list Azure DevOps refused to produce. WIQL has no TOP clause on this endpoint (it
  answers TF51006), so `-ChangedWithinDays` was added as the server-side lever, and the
  size-limit error names it instead of suggesting a larger cap.

  TAGS IS A string[], NOT THE JOINED STRING AZURE DEVOPS SENDS. ADO returns 'Exchange; Internal
  IT'; keeping that shape forces every caller onto `-like '*Internal IT*'`, which also matches a
  tag named 'Internal IT Legacy' and silently returns NOTHING for the `-contains` and `-in` that
  people reach for first. msec.format.ps1xml joins it for the table, the data stays typed - the
  rule the format file already stated for AssignmentGroup, which this got wrong on the first
  pass and a real query then hit.

  A 404 from the wiql endpoint is AMBIGUOUS - a misspelled organization, a misspelled project,
  and a project the identity cannot see all return the same Not Found - so the error names both
  rather than sending the reader to check a spelling that was already right.

  Measured on one project: 143 items, 124 open, 7 open longer than 90 days, and 98 of the 124
  carrying no tag at all.

- `Get-MsecPowerPlatformEnvironment` - Power Platform environments and whether a connector DLP
  policy actually covers each one.

  A Power Automate flow runs as the person who built it, needs no approval, and can move data
  between any two connectors it is permitted to use. A connector DLP policy is the only thing
  constraining that, and an environment no policy is scoped to has no connector restriction at
  all - not a weak one, none. Measured on one tenant: 8 environments, 0 DLP policies, so every
  one of them is unrestricted.

  RUNS AS THE SIGNED-IN USER, NOT AS THE APP. The Power Platform admin APIs return 403 to the
  msec certificate, and app-only access requires registering the application as a Power
  Platform MANAGEMENT APPLICATION - which grants administrative, not read-only, access to the
  whole estate. Taking that route would break the promise that the Key Vault certificate
  cannot change the tenant, so this follows Search-MsecAzureResourceGraph and uses the Az
  context. One command, one identity.

  DLP SCOPE IS A FILTER TYPE, NOT A LIST. A policy carries `environmentFilterType` of `none`
  (every environment), `include` or `exclude`. Reading only the environment array would report
  a tenant-wide policy - filter type `none`, empty list - as covering nothing, turning a
  protected tenant into a page of false findings and burying any real one. An unrecognised
  filter type is not credited as covering.

  Policies unreadable leaves `IsCoveredByDlp` ``, never ``.

- `Get-MsecEntraPimPolicy` - the Privileged Identity Management rules for each directory role.

  `Get-MsecEntraRoleHolder` says who holds a role and whether it is active or eligible. This
  says what the eligibility is worth: a role activatable for eight hours with no MFA, no
  approval and no ticket is barely different from a permanent assignment, and nothing in the
  holder list shows that.

  TWO SETS OF RULES ANSWERING DIFFERENT QUESTIONS. The EndUser rules are what an eligible
  person must do to switch the role on; the Admin rules are what an administrator may hand out,
  which is where `PermanentActiveAllowed` lives - the setting that decides whether standing
  privilege is possible at all.

  `isExpirationRequired` IS INVERTED into `PermanentActiveAllowed`. Reading it straight reports
  a tenant that forbids standing privilege as one that permits it. There is a test for it.

  `ActivationRequiresMfa = False` DOES NOT MEAN ACTIVATION HAPPENS WITHOUT MFA - the person may
  already be covered by Conditional Access. The setting controls whether PIM demands a FRESH
  authentication at activation, which is what stops an already-authenticated stolen session
  switching a role on. The help says so, because the short reading over-claims.

  AN ABSENT RULE IS NULL, NEVER FALSE: a policy carrying no enablement rule was not measured,
  and `` would claim PIM was asked and said no.

  A POLICY ON A ROLE NOBODY IS ELIGIBLE FOR GOVERNS NOTHING, so `HasEligibleHolder` is on every
  row - measured on one tenant, 34 of 147 roles had an eligible holder. Rows are still returned
  for the rest: a policy may be deliberately pre-configured ahead of an assignment.

  `` IS NOT SUPPORTED on `/roleManagement/directory/roleDefinitions` and returns 400; all
  147 come back in one page regardless.

- `Get-MsecExchangeInboxRule` - user-created inbox rules, flagging the ones that send mail out
  of the tenant or hide it from the person who owns the mailbox.

  Mailbox forwarding is an admin setting and `Get-MsecExchangeMailbox` already reads it. An
  INBOX RULE is set by the user, or by whoever is holding the user's session, and is where
  business email compromise actually lives: forward anything matching 'invoice' outside, then
  file it into RSS Feeds and mark it read so the owner never sees the thread.

  SLOW AND SCOPED ON PURPOSE. There is no bulk endpoint - `Get-InboxRule` takes one mailbox at
  a time, measured at ~1.7 seconds each. `-Mailbox` exists so an investigation can read ten
  mailboxes in twenty seconds, and the default is UserMailbox rather than every recipient type.

  A MAILBOX THAT COULD NOT BE READ GETS A ROW SAYING SO, because in an investigation "no rules"
  and "could not read the rules" are opposite answers and skipping makes them identical. A
  mailbox genuinely holding no rules emits nothing, which is a real measurement.

  RECIPIENTS ARE `Display Name [SMTP:addr]`, NOT BARE ADDRESSES. Comparing the whole string
  against the accepted-domain list matches nothing and reports every forward as internal, so
  the address is extracted first. Where accepted domains cannot be read, `ForwardsExternally`
  is `` rather than ``.

  WHAT COUNTS AS RISKY IS WRITTEN DOWN: forwards or redirects outside the tenant, deletes, or
  files mail into a CONCEALING folder (RSS Feeds, Archive, Junk Email, Deleted Items,
  Conversation History, Notes). An earlier version flagged filing into ANY folder plus
  mark-as-read, and measured across 265 mailboxes that fired on 292 of 1373 rules - almost all
  of them people filing study correspondence into per-study folders. Flagging 21%% of all rules
  buries the three that actually forward outside the tenant. `StopProcessingRules` and a plain `MoveToFolder` are
  ordinary mail management and are reported but not flagged - measured on 25 mailboxes, 73 of
  108 rules moved mail to a folder, so flagging that alone would bury the three that mattered.

  Invalid rules (`IsValid = `) are flagged: they still exist, may still run, and a corrupt
  rule is as often tampering as a broken client.

- `Get-MsecDefenderOfficePolicy` - the Defender for Office 365 and Exchange Online Protection
  policies that filter mail, with whether each one applies to anyone.

  msec already read Exchange MAIL FLOW - transport rules, remote domains, outbound forwarding.
  This reads the protection stack on top of it: anti-phishing, Safe Links, Safe Attachments,
  anti-spam, anti-malware, outbound spam, and the advanced delivery overrides.

  A POLICY AND THE RULE THAT APPLIES IT ARE SEPARATE OBJECTS in Exchange Online Protection, so
  a custom policy with no rule is inert however carefully it was written. Every row carries
  `IsApplied` and `AppliedBy`, making `Where-Object { -not # Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Fixed
- The `Connect-MsecAdmin`, `Set-MsecDefenderAlert` and `Set-MsecDefenderIncident` tests failed on
  the macOS CI runner and passed on Windows and Ubuntu.

  They mock `Get-MgContext`, `Connect-MgGraph` and `Disconnect-MgGraph`, and Pester's `Mock`
  requires the command to EXIST - a missing one fails as "Could not find Command Get-MgContext"
  rather than as anything pointing at the real cause. `Microsoft.Graph.Authentication` is
  preinstalled on the Windows and Ubuntu GitHub images but not the macOS one, so the same suite
  passed on two runners and failed on the third.

  Installing it in CI was the wrong fix: unlike Az, it is deliberately NOT a dependency of msec -
  only `Connect-MsecAdmin` needs it, and it checks at run time. The tests now stub those three
  commands, and ONLY when they are genuinely absent, so a machine with the real module still
  mocks the real command and the two behave identically. Same pattern the Purview tests already
  use for the optional ExchangeOnlineManagement cmdlets.

  THE STUBS CARRY THE REAL PARAMETER NAMES, which the first attempt at this did not. A stub of
  `param()` with no `[CmdletBinding()]` is a SIMPLE function: it accepts any argument into
  `$args` rather than rejecting it, so `Connect-MgGraph -TenantId x` did not fail - `$TenantId`
  simply never bound. A `-ParameterFilter { $TenantId -eq 'tenant-1' }` then matched nothing and
  the assertion failed as "expected 1 call, got 0", which reads as the command never having been
  called. Every stub now declares `[CmdletBinding()]` and the parameters the tests filter on.

### Added
- `Get-MsecEntraAppConsent` - which applications have been granted access to tenant data, what
  they can do, and who agreed to it. One row per permission.

  `Get-MsecEntraAppCredential` says which apps hold a key; this says what those apps are allowed
  to DO. Illicit consent needs no password, survives a password reset, and leaves the attacker
  holding a token rather than an account - and nothing in msec could see it.

  DELEGATED AND APPLICATION GRANTS ARE DIFFERENT SIZES OF PROBLEM and are labelled as such. A
  delegated grant acts as a user and inherits that user's limits; an application grant acts as
  itself with no user and no limits, so `Mail.Read` there is every mailbox in the tenant.
  `ConsentType` separates a single user agreeing for themselves from an administrator agreeing
  on behalf of everyone.

  APP ROLE ASSIGNMENTS ARE READ FROM THE RESOURCE SIDE. The obvious route - `$expand=
  appRoleAssignments` on each service principal - SILENTLY TRUNCATES at one page and does not
  paginate. Measured on one tenant it returned 203 assignments where the resource-side read
  returned 410, and 20 of msec's own 24. The command pays ~200 extra calls and about 30 seconds
  to not under-report permissions by half.

  ASSIGNMENTS TO USERS AND GROUPS ARE EXCLUDED: an app role assigned to a user or group says who
  may USE an app, not what the app may do to your data. Including them inflated the count from
  208 to 410 with a different question's answer.

  An unresolvable app role reports `Permission` and `IsHighRisk` as `$null`, never `$false` -
  `$false` would claim it was checked against the risk list and found safe.

- `Get-MsecTeamsPolicyAssignment` - how many users each per-user Teams policy actually applies to.

  `Get-MsecTeamsPolicy` says what a policy CONTAINS. It cannot say who gets it, and that is the
  half that decides whether a setting matters: a tenant holding a carefully restrictive meeting
  policy assigned to three people is indistinguishable, from the policy list alone, from a tenant
  that is actually restrictive. Measured on one tenant: 535 of 538 users on a Global meeting
  policy with `AllowAnonymousUsersToJoinMeeting = True`, and the restrictive
  `RestrictedAnonymousAccess` policy on 3. Messaging, AppPermission and Files had ZERO explicit
  assignments - every policy beyond Global was decoration.

  POLICIES WITH NO HOLDERS ARE RETURNED, NOT OMITTED. That is the finding, not an empty result -
  a policy nobody holds is configuration someone wrote and believes is in force. The policy list
  is read separately from the user list precisely so a policy with zero holders still appears.

  A USER WITH NO EXPLICIT ASSIGNMENT GETS GLOBAL, and Teams reports that as a NULL property
  rather than as the string `Global`. Counting only explicit assignments would have reported
  Global as applying to nobody.

  UNREADABLE IS NOT ZERO: if the user list cannot be read, `UserCount` is `$null` on every row
  and a warning says so. A failed read printing "0 users" against every policy is both wrong and
  the most alarming possible misreading.

  Federation and Client are deliberately absent from `-PolicyType`: they are tenant-wide
  configuration with no per-user assignment, so asking who holds them is meaningless.

  `Get-CsOnlineUser -ResultSize` is a 32-bit INTEGER on this cmdlet, not the `Unlimited` keyword
  the Exchange-family cmdlets take - and `[uint32]::MaxValue` overflows the Int32 it binds to.

- `Get-MsecExchangeTransportRule` and `Get-MsecExchangeOrganizationSetting`, completing the mail
  side of the Exchange commands.

  A TRANSPORT RULE RUNS ON EVERY MESSAGE BEFORE THE USER SEES IT, which makes it a favourite for
  persistence - and it lives in a part of the portal nobody browses. `BypassesFiltering` says in
  words what `SetSCL = -1` means: trust the message completely, skip spam, phishing and bulk
  filtering. Measured on one tenant, 7 of 12 rules set it and 3 are live.

  `IsActive` NEEDS BOTH `State` AND `Mode`. A rule can be Enabled and completely inert because
  its Mode is Audit rather than Enforce, so a filter on State alone over-reports what is running.

  THERE ARE FOUR WAYS A RULE SENDS MAIL ELSEWHERE, not one: `RedirectMessageTo`, `BlindCopyTo`,
  `CopyTo` and `AddToRecipients`. They behave differently for the sender and the original
  recipient, and a check written against one misses the other three. `RedirectsMail` covers all
  four; `ExternalRecipients` names the targets outside every accepted domain, and is `$null`
  rather than empty when those domains could not be read.

  THERE ARE TWO AUTO-FORWARDING CONTROLS AND BOTH MUST BE CLOSED. The outbound spam filter
  policy's `AutoForwardingMode` governs it at the Defender layer; the Default remote domain's
  `AutoForwardEnabled` governs it at the transport layer. Closing one and leaving the other is
  the common half-fix, so they are adjacent columns on the same row. Note the safe value is not
  "Off": `Automatic` is Microsoft's system-controlled default, and `On` opens the path outright.

  Each organisation setting is read independently, so one refused lookup leaves that column
  `$null` instead of failing the row - a partial answer about tenant posture beats none, as long
  as the gaps are visible as gaps.
- `Get-MsecExchangeMailbox` - mailboxes with the two things that actually leak mail: where it is
  forwarded, and which legacy protocols are open. Measured on one tenant: 34 of 305 mailboxes
  forward, 11 by raw SMTP, four of those outside every accepted domain.

  FORWARDING COMES IN TWO SHAPES AND THEY ARE NOT THE SAME RISK. `ForwardingSmtpAddress` is a raw
  address that can point anywhere; `ForwardingAddress` must resolve to an existing recipient
  object, so it cannot name an arbitrary stranger. Reporting them as one column loses that.
  `IsForwardingExternal` is `$null` for a recipient forward rather than `$false` - judging it
  needs a lookup this command does not do, and `$false` would claim the mail stays inside.

  `DeliverToMailboxAndForward` IS ITS OWN COLUMN because `$false` means no copy stays behind:
  the mail leaves and the owner has no way to notice. On the measured tenant exactly one mailbox
  was in that state.

  SMTP AUTH IS RESOLVED, NOT REPORTED RAW. The per-mailbox setting is usually `$null`, meaning
  "inherit the tenant default", and `$null` read as a boolean is false - so an unresolved value
  reports SMTP AUTH disabled on every mailbox that never set it, for the one protocol that
  bypasses MFA outright. `SmtpAuthEnabled` is the effective answer and `SmtpAuthSource` says
  whether it came from the mailbox or the tenant.

  Protocol columns are `$null` for a mailbox with no CAS record rather than `$false` - measured,
  five Bookings (`SchedulingMailbox`) mailboxes, which genuinely have no protocols to report.

  Two bulk calls rather than one per mailbox: 305 mailboxes in about seven seconds.

## [0.4.0] - 2026-09-29

### Added
- `Get-MsecIntuneDevice` now returns `EnrollmentType`, `IsSupervised`, `EnrollmentProfile` and
  `IsAutomatedEnrollment`. How a device was enrolled decides whether a user can simply remove
  management, and nothing in the previous output could answer that.

  An Apple device enrolled through Automated Device Enrollment has a management profile the user
  cannot remove. One enrolled manually does not - so every configuration profile, compliance
  check and Conditional Access decision resting on management can be ended by whoever is holding
  the laptop. Measured live: 9 of 19 Macs and 128 of 130 iOS devices were manually enrolled, and
  on the Mac side both devices on an unsupported OS version and both devices that had stopped
  checking in were in that group.

  `IsSupervised` IS NOT THE ANSWER and is included so nobody reaches for it: it came back True
  on all 19 Macs regardless of enrolment method, so a filter on it finds nothing.

  `IsAutomatedEnrollment` IS `$null` ON WINDOWS AND ANDROID, not `$false`. The enum reports
  `windowsAzureADJoin` for both an Autopilot deployment and a manual Entra join, so it cannot
  answer the question there and a `$false` would claim that it had.

  NB `autopilotEnrolled` is beta-only and returns HTTP 400 against v1.0 `managedDevice` - it was
  tried and removed, and there is a comment in the `$select` list saying so.
- `Get-MsecPurviewAlertPolicy` - Purview alert policies, the area every other Purview command
  here was missing. The rest report what is PREVENTED; this reports what is NOTICED, and it was
  a blind spot: measured live, 65 policies of which 14 were the organisation's own, and all 7
  disabled ones were theirs rather than Microsoft's.

  A DISABLED ALERT POLICY IS SILENT IN EXACTLY THE WAY A WORKING ONE IS, which is why nobody
  finds these until an incident review asks why no one was told. "Shared files externally" and
  "User copies a file with sensitive data to a removable drive" were both off.

  `IsEnabled` INVERTS THE RAW PROPERTY. The service stores `Disabled`, so a filter written
  against it reads backwards and `Where-Object Disabled` quietly returns the healthy policies.
  Both are on the row, positive form first.

  `NotificationEnabled` IS NOT WHETHER THE ALERT FIRES - it is whether anyone is emailed. An
  enabled policy with it off raises the alert in the portal and tells nobody. Measured live,
  three custom policies were in that state, including the alert attached to the one GDPR DLP
  rule that actually enforces.

  `IsSystemRule` separates Microsoft's built-ins from local configuration, because a count that
  mixes them says nothing about how much alerting anyone here set up. `-CustomOnly` narrows to
  the latter.
- `Get-MsecPurviewDlpPolicy` now returns `WorkloadClaims` and `ClaimsEmailWithoutTarget`, because
  the raw `Workload` property is the most misleading thing about a DLP policy and omitting it
  left no way to see why.

  `Workload` IS DECLARATIVE, NOT DERIVED. Measured live: all eight policies on one tenant listed
  "Exchange" in `Workload` while every Exchange targeting property - `ExchangeLocation`,
  `ExchangeSender`, `ExchangeSenderMemberOf`, `ExchangeAdaptiveScopes` - was empty. Microsoft's
  parameter reference is explicit that this means email is excluded: "If you don't want to
  include email messages in the policy, don't use this parameter." So a policy can assert email
  coverage it does not have, and an experienced admin reading `Workload` will reasonably conclude
  the opposite of the truth.

  Hiding the property would have been the wrong fix - the scopes were already right, and someone
  checking msec against the portal or against `Get-DlpCompliancePolicy` would keep rediscovering
  the discrepancy and assuming msec was wrong. `ClaimsEmailWithoutTarget` names it instead.
- `Get-MsecPurviewAutoLabelingPolicy` and `Get-MsecPurviewInformationBarrier`, closing the two
  gaps that would otherwise have gone into a Purview review with no command behind them.

  AUTO-LABELING IS THE ONLY THING THAT APPLIES A SENSITIVITY LABEL WITHOUT A USER. A tenant with
  labels published and no auto-labeling policy relies entirely on people classifying their own
  content - so zero rows is a finding, not an empty section, and the command answers cleanly
  rather than erroring on it. Same configured-versus-enforcing split as the DLP command: only
  Mode 'Enable' labels anything, every Test* mode simulates.

  Information barriers are absent on most tenants and that is a legitimate answer - they exist
  for regulated separation. Reporting the absence is the point, because a deliberate "no
  barriers" and an overlooked one look identical until someone asks. `State` is not `IsActive`:
  a barrier is authored inactive and protects nobody until applied, while still counting as a
  policy.

  BOTH PROJECTIONS ARE UNVERIFIED AGAINST LIVE DATA, and say so in their help. They were written
  on a tenant with zero of each, and Microsoft's cmdlet reference does not document the returned
  properties. So they are built to degrade rather than guess: a property PowerShell cannot find
  is `$null` rather than an error, locations go through `Resolve-MsecPurviewLocation` which
  already handles absent ones, and `Raw` carries the untouched object so a missed column can be
  recovered without a module change. A test pins that `Raw` survives.

  `RuleCount` is `$null` rather than `0` when `Get-AutoSensitivityLabelRule` is not exposed:
  "this policy has no conditions" and "the rules could not be read" are different claims.
- Microsoft Purview coverage: `Connect-MsecPurview`, `Get-MsecPurviewDlpPolicy`,
  `Get-MsecPurviewSensitivityLabel` and `Get-MsecPurviewRetention`.

  NO NEW CONSENT WAS NEEDED. Purview's configuration is not in Graph - DLP policies, DLP rules,
  sensitivity label actions and label policies have no Graph endpoint - so this goes through
  Security & Compliance PowerShell. `Connect-IPPSSession` takes `-AccessToken` and `-AppId`, the
  same shape `Connect-MsecExchangeOnline` already uses, so the existing Key Vault certificate
  reaches the compliance endpoint as the app. The app does need a directory role (Global Reader
  or Compliance Administrator) and a 403 there is translated into a message saying so, because
  it is a role problem far more often than a permission one. `-Organization` is optional and
  resolved from Graph.

  CONFIGURED IS NOT ENFORCING, and the count people quote is the configured one. A DLP policy's
  `Mode` is independent of its `Enabled` flag: `Disable` does nothing, `TestWithNotifications`
  reports without blocking, only `Enable` stops anything. `IsEnforcing` collapses that, with
  `Mode` and `Enabled` kept on the row. `BlockingRuleCount` matters just as much - measured
  live, a policy enforcing across all SharePoint and OneDrive had zero blocking rules.

  GET-LABEL HAS NO EncryptionEnabled PROPERTY. Asking for one returns empty on every label,
  which reads exactly like "nothing encrypts anything" - an earlier pass at this tenant reported
  precisely that, and it was wrong. The settings live in `LabelActions`, a collection of JSON
  documents, one per action. `EncryptionConfigured` and `EncryptionEnabled` are therefore
  separate columns: measured live, `Internal` and `Confidential` both carry an encrypt action
  and both have it switched off, which is a decision to revisit rather than work never done.

  THE `disabled` FLAG IS THE STRING `'true'`/`'false'`, and `[bool]'false'` is `$true` in
  PowerShell, so a truthiness test marks every configured action as disabled. The comparison is
  explicit and a test pins it.

  `'All'` IS AN ORDINARY MEMBER of a DLP location collection rather than a flag, so an
  estate-wide policy and a single site named "All" are indistinguishable until you inspect the
  type. `Resolve-MsecPurviewLocation` turns each workload into a `Scope` of All/Named/None plus
  a count of named locations - and the count is 0 for All, because there is no list to count and
  reading it as coverage would be backwards.

  Rule columns go `$null` rather than `0` when the rules cannot be read: on a control question,
  "no blocking rule" and "could not tell" must not look alike. Same for `IsPublished` when the
  label policies are unreadable.
- `Search-MsecDefenderHunting` - runs bundled advanced hunting KQL against the Defender XDR
  event store, completing the set alongside `Search-MsecAzureResourceGraph` and
  `Search-MsecLogAnalytics`. Nine queries under `kql/Hunting/`: SignIn (All, Failed, ByUser),
  Device (All, Logon), Email (All, Threats), Alert (All), Vulnerability (All). Every one was run
  against a live tenant before shipping rather than eyeballed.

  THE THREE SEARCH COMMANDS READ THREE DIFFERENT STORES, and the README now says so in a table.
  Advanced hunting is Defender's own lake of roughly thirty days of raw telemetry - not a Log
  Analytics workspace. Nothing a diagnostic setting routes lands there; nothing there reaches a
  workspace without the Sentinel connector.

  THE .kql FILES CARRY NO TIME FILTER. Graph's `runHuntingQuery` takes `timespan` as its own
  parameter - confirmed from `$metadata` and then live: one query returned 12 / 57 / 2245 / 6544
  rows at PT1H / P1D / P7D / P30D. Same split as `Search-MsecLogAnalytics`, and a lint test
  holds the rule for the new tree.

  AN UN-ONBOARDED TABLE FAILS TO RESOLVE RATHER THAN RETURNING ZERO ROWS, and the command
  translates that into a plain sentence naming the likely cause. "0 results" and "this product
  is not installed" reading alike is the worst failure available to a security query. Measured
  on one tenant: every `Identity*` table at zero (no Defender for Identity sensors on a managed
  domain) and `CloudAppEvents` at zero, against 2.4M rows in `AADSignInEventsBeta`.

  `-Days` is capped at 30 because that is the store's retention, not an arbitrary limit, and a
  bare-integer `-Timespan` is refused - PowerShell reads it as TICKS, so `-Timespan 7` means
  700 nanoseconds and returns nothing that looks exactly like "nothing to find".
- `Connect-MsecAdmin` - a delegated, interactive sign-in for the commands that will write.
  Reads stay on the app certificate; writes run as a named person.

  THE APP CANNOT WRITE, BY DESIGN. Every Graph permission `New-MsecApp` consents is
  `*.Read.All`, so the certificate in Key Vault cannot change anything - the module's promise
  is enforced by the token rather than by naming. Writing as a person instead makes each
  change attributable, subject to Conditional Access and MFA, bounded by that person's own
  RBAC, and impossible from an unattended pipeline by accident.

  IT IS NOT THE `-AsCurrentUser` PATTERN, AND COULD NOT BE. `Connect-MsecTeams` borrows the Az
  context's token, which works because Azure PowerShell's first-party app holds the scopes
  those commands need. Measured on a live tenant, its Graph token carries
  `Application.ReadWrite.All`, `Group.ReadWrite.All`, `Directory.AccessAsUser.All` and
  `User.Read.All` - and nothing for security. Borrowing it cannot resolve an alert, so this
  requests consent properly.

  CONSENT REQUESTED IS NOT CONSENT GRANTED. `Connect-MgGraph` succeeds when a tenant declines
  a scope - the context simply returns without it, and the first write then 403s naming
  nothing. Granted scopes are checked against requested ones at connect time and a missing one
  is reported by name.

  It also REFUSES a tenant different from the one `Connect-Msec` is reading, and closes the
  half-open Graph session on the way out. Reading one tenant and writing to another is
  invisible at the time and obvious afterwards.

  Needs `Microsoft.Graph.Authentication`, which is not a dependency of msec - only the write
  commands require it.

- `Set-MsecDefenderAlert` - resolve, classify and assign Defender XDR alerts. The first command
  that changes anything outside the module's own app registration, and it runs as you: it
  requires the `Connect-MsecAdmin` session and refuses the app one by name, because every
  permission `New-MsecApp` consents is `*.Read.All` and a write on that session can only 403.

  IT COUNTS BEFORE IT ACTS. Piped ids are buffered and the breadth check runs against the whole
  set, then writes. A guard that checks per item has already changed 25 alerts by the time it
  refuses the 26th - which is the exact failure it exists to prevent. `-MaxCount` defaults to 25;
  measured live, `Get-MsecDefenderAlert -Status new` on this tenant returns 201 rows, so
  `Get-… | Set-…` is one pipe away from a mass update.

  IT REPORTS WHAT A RE-READ RETURNED, NOT WHAT IT ASKED FOR. The PATCH response is the service
  echoing the request; a separate GET is the service being asked what the alert now is. Defender
  can accept a PATCH and not hold part of it - a determination that conflicts with the
  classification is the usual way - so every requested field is compared after the write and
  `Changed` is false when any of them did not stick. When the re-read itself fails, the `*After`
  columns are `$null` rather than the requested values: an unverified write must never render as
  a confirmed one.

  THE ENUM VALUES ARE NOT THE GUESSABLE ONES. Taken from Graph's own `$metadata`, determinations
  are `notMalicious` and `notEnoughDataToValidate`, not `clean` and `insufficientData`. And note
  the status vocabulary: the CSDL names the first member `newAlert` while the wire value is
  `new` - the wire value is what this takes and what `Get-MsecDefenderAlert` returns.

  `SupportsShouldProcess` with `ConfirmImpact = 'High'`, so a bare call prompts and `-WhatIf`
  lists the ids that would change without touching any of them.

- `Set-MsecDefenderIncident` - resolve, classify, re-grade, tag and COMMENT on Defender XDR
  incidents, with the same guards as `Set-MsecDefenderAlert`.

  THE RESOLUTION COMMENT LIVES ON THE INCIDENT, BECAUSE GRAPH HAS NO WRITABLE COMMENT ON AN
  ALERT. Checked against both `$metadata` documents and both Update alert pages: `comments` on
  `alerts_v2` is a read-only structural property, there is no comments navigation property and
  no action to add one, and neither v1.0 nor beta lists it as updatable. Incidents have
  `resolvingComment`, which Microsoft describes as explaining the resolution and the
  classification choice - so `-ResolvingComment` is the supported way to record why something
  was closed, and alerts roll up into incidents anyway.

  `-CustomTags` REPLACES the tag array rather than appending - that is Graph's behaviour for a
  collection property, not a choice made here. The command reads the incident first and warns,
  naming the tags about to be dropped, before the write rather than after.

  `redirected` is deliberately absent from `-Status`: Defender assigns it when it merges an
  incident into another, and offering it would imply this command can merge incidents. On the
  other side, `inProgress` and `awaitingAction` ARE offered - they are in `$metadata` even
  though the Update incident doc lists only active, resolved and redirected.

  `displayName`, `summary` and `description` are updatable through Graph but are not exposed:
  they are the incident's narrative rather than a triage decision, and rewriting them from a
  pipeline is a good way to lose Defender's own text.

### Fixed
- `Get-MsecIntuneCompliancePolicy` returned only name, platform, type and assignment count - so
  a policy that ENFORCES NOTHING was indistinguishable from a healthy one, which is the single
  most misleading thing a compliance-policy list can do.

  A policy with no settings configured reports every device as compliant, because there is
  nothing to fail. Measured live: a macOS baseline assigned to all licensed users since 2021,
  with `osMinimumVersion` empty and password, encryption, firewall and system-integrity all
  false, showed 17 of 19 devices compliant - including two on an unsupported major version. The
  same tenant's properly configured macOS policy, with 11 checks and a minimum version, was
  assigned to nobody. From the old output the two looked equally fine.

  Rows now always carry `OsMinimumVersion`, `ConfiguredCheckCount`, `ChecksNothing` and
  `ConfiguredChecks`, and `-IncludeSettings` attaches every setting. None of it costs an extra
  API call - the list endpoint already returned all 26 properties and the command was throwing
  them away.

  WHAT COUNTS AS "CONFIGURED" IS WRITTEN DOWN, in `Get-MsecCompliancePolicyCheck`, rather than
  guessed at: a boolean counts only when true (false means "not required", not "required to be
  false"); a string counts unless it is one of Graph's do-nothing sentinels (`deviceDefault`,
  `unavailable`, `notConfigured`, `userDefined` - measured, those account for nine of fourteen
  string values on one tenant); a number counts only when non-zero. The test is deliberately
  generic rather than a per-platform allowlist, because Microsoft adds compliance settings and
  an allowlist would silently stop counting them.
- `Assert-MsecExoCmdlet` said an absent cmdlet meant the TENANT lacked the feature. It does not:
  the compliance endpoint imports cmdlets per IDENTITY, based on Purview role groups, so a
  cmdlet missing from an app-only session says nothing about whether the feature exists or is in
  daily use by people in the portal.

  THE OLD WORDING PUT A FALSE STATEMENT INTO A COMPLIANCE REPORT. Measured on one tenant:
  `Get-ComplianceSearch`, `Get-InsiderRiskPolicy` and `Get-SupervisoryReviewPolicyV2` were all
  absent from the app session, while `eDiscoveryManager`, `InsiderRiskManagement` and
  `CommunicationCompliance` each had three members and were actively used. Inferring "we do not
  have eDiscovery" from that is the kind of error that is worse than no report at all, because
  it reads as evidence.

  The message now says the feature may well be in use, that it is a role-group problem rather
  than an API permission one, that granting an API permission will not help, and that the fix is
  to add the identity to the matching view-only Purview role group. "Not measurable from here"
  replaced "not measurable" - the qualifier is the whole point.
- `Get-MsecPurviewDlpPolicy` and `Get-MsecPurviewAutoLabelingPolicy` reported the wrong name for
  any policy that had been renamed, so the output did not match the Purview portal and a reader
  could not find the policy being described.

  A DLP POLICY HAS TWO NAMES. Renaming one changes its `DisplayName` and leaves `Name` at
  whatever it was created as, so they drift apart the moment anyone tidies a name up. Measured
  live on one tenant, two of eight had drifted: the portal's `DLP - Confidential document shared`
  is still `TEST - Label-based DLP (pilot)` underneath, and `DLP - Passwords` is still
  `DLP - Passwords - Teams + SharePoint/OneDrive`. `Name` now carries the display name, with
  `InternalName` beside it and a `Renamed` flag; `-Name` matches either, because a portal reader
  and a script author know different strings.

  THE RULE JOIN STILL USES THE INTERNAL NAME, and that is not incidental. `ParentPolicyName`
  tracks `Name`, never `DisplayName` - measured at 10 of 10 rules, matching the display name only
  where the two happened to be equal. Switching the join to the display name would silently drop
  the rules of every renamed policy, and `RuleCount = 0` reads as "this policy has no
  conditions". A test pins both halves: the row shows the display name, the join finds the rule.
- The `Get-MsecPurview*` commands now say a tenant CANNOT BE ASKED rather than returning nothing
  when the feature is absent. The compliance endpoint imports only the cmdlets a tenant is
  licensed for and the connecting identity's role group allows, so on a tenant without DLP or
  labels the cmdlet is simply not there - measured on a fully working tenant,
  `Get-ComplianceSearch`, `Get-InsiderRiskPolicy` and `Get-SupervisoryReviewPolicyV2` are all
  absent while the DLP and label ones are present.

  Calling one anyway raised `CommandNotFoundException` - "The term X is not recognized" -
  surfacing from a `Get-Msec*` command as though the module were broken. Worse would have been
  catching it and returning an empty result: "this tenant has no DLP policies" and "this tenant
  cannot be asked" are opposite conclusions on a compliance report, and only one of them is
  true. `Assert-MsecExoCmdlet` names the cmdlet, says it is a capability limit rather than a
  missing API permission (so nobody spends an afternoon granting one), and states plainly that
  it is not the same as "none are configured".

  `Get-MsecPurviewRetention` checks per half and only for the half being read, so a tenant that
  exposes retention labels but not retention policies can still answer `-Kind Label` - and the
  error for the other half says so.
- A workload session is now reused only when it belongs to the tenant the msec session is
  currently on. It previously matched on "is something connected to this endpoint", which is
  wrong the moment anyone switches tenant: `Connect-Msec` to tenant B after using Purview or
  Exchange on tenant A left the old session live, and the next command happily read TENANT A'S
  DATA and reported it under tenant B's name. Nothing about that looks like an error, which is
  what makes it worth a test rather than a comment. `Get-ConnectionInformation` carries
  `TenantID`, so the comparison was available all along.

  A stale session is CLOSED, not left alongside a new one - two live sessions let the cmdlets
  pick between them invisibly, turning a consistently wrong tenant into an intermittent one. The
  warning names both tenants.

  Identity is deliberately NOT part of the check. A caller who signed in as themselves has
  rights the app lacks, and reconnecting as the app would quietly remove them - the trap
  `Get-MsecTeamsPolicy` already avoids with its `-AsCurrentUser` guard. Tenant is the
  correctness question; a different `AppId` on the right tenant is only noted verbosely.

### Changed
- `tools/Grant-MsecAzureDevOpsPermission.ps1` is now the `Grant-MsecAzureDevOpsPermission`
  command, shipped with the module.

  THE HELP POINTED AT A FILE NOBODY HAD. `tools/` sits outside the module folder, so it is not
  published - but four places referenced it, including the 403 guidance in
  `Get-MsecAzureDevOpsRepository` and `Get-MsecAzureDevOpsServiceConnection`. Anyone who
  installed from the Gallery, hit a permissions error and followed the help was sent to
  `./tools/Grant-MsecAzureDevOpsPermission.ps1`, which did not exist on their machine.

  Its stated reason for living outside was "msec is read-only and this WRITES". That premise was
  removed by `Connect-MsecAdmin` and the `Set-*` commands, and `New-MsecApp` already ships a
  setup command that writes considerably more - it creates an app registration, grants API
  permissions and assigns directory roles.

  THE PERSONAL ACCESS TOKEN IS GONE. It took a PAT; it never needed one. The security namespace,
  access control list and identity APIs all accept an ordinary Entra token for the Azure DevOps
  resource - verified against all three before the parameter was removed. A PAT is a long-lived
  credential, and asking people to create one for a setup task is worse than using the sign-in
  they already have. That also makes the command single-identity, which is now the module's rule.

  It runs as the SIGNED-IN USER rather than as the app, deliberately: the app is usually the
  grantee, and an identity that could grant itself permissions would make the exercise circular.

  `-Apply` is replaced by the standard `-WhatIf` / `-Confirm` with `ConfirmImpact = 'High'`, and
  the list modes emit objects instead of `Write-Host`, so `-ListPermissions` and `-ListRoles`
  can be filtered and exported like every other command's output.
- `Get-MsecExchangeMailboxPermission` now opens its Exchange session on first use, which was the
  last command in the module still demanding a manual connect. `Get-MsecTeamsPolicy` and
  `Get-MsecSharePointSiteUser` already connected themselves, and the Purview commands now do -
  Exchange was the odd one out rather than the rule.

  Its connected-check was also wrong: `Get-Command Get-EXOMailbox` answers whether the MODULE IS
  INSTALLED, not whether anything is connected. It returned true on a machine that had never
  signed in, and every call after it then failed on transport instead of on a sentence.

- `Connect-MsecExchangeOnline -Organization` is now optional, resolved from Graph like
  `Connect-MsecPurview` - shared as `Get-MsecTenantDomain`, since the app already holds
  `Organization.Read.All`. A mandatory argument the caller rarely has to hand was the only
  reason Exchange could not connect itself.

- Exchange and Purview now share one session initializer, `Initialize-MsecExoSession -Endpoint`.
  They differ only in endpoint and connect cmdlet, and the part that is easy to get wrong - the
  tenant check - must not exist in two copies. `Get-MsecExoConnection` keeps the two endpoints
  apart; they come from one module and differ only by URI, which carries a regional prefix
  (`eur01b.ps.compliance...`), so the match is a substring by design.
- `Set-MsecDefenderAlert` now reports comment refusals ONCE per run instead of once per alert,
  and hands over the command that does work. Every non-endpoint alert fails the same rule, so a
  near-identical warning per row buried the ones that were actually specific to an alert. The
  summary names the count and the serviceSource, then gives the exact follow-up with the
  incident ids collected from the alerts themselves:

      WARNING: 3 alert(s) did not take a comment: serviceSource unknownFutureValue, and the
      Defender for Endpoint API only knows endpoint alerts. ... Put the note on their
      incident(s) instead: Set-MsecDefenderIncident -Id 5846,5901 -ResolvingComment '...'

  `CommentAdded` is still `$false` on each row, so nothing is dropped quietly - the per-row fact
  is in the object, and the warning stream carries the instruction rather than the repetition.
- The post-write verification in `Set-MsecDefenderAlert` and `Set-MsecDefenderIncident` now waits
  for Defender XDR to settle instead of reading once, immediately.

  IT WAS REPORTING FAILURES THAT HAD NOT HAPPENED. Observed live: an alert PATCHed successfully
  at 16:37:00 - status, classification and assignedTo all applied - read back as unchanged when
  the verification GET fired right behind the PATCH, producing "did not keep: status,
  classification, assignedTo" for a write that had entirely worked. XDR is eventually consistent;
  the re-read was simply too early. This is the same class of bug the re-read exists to catch,
  running backwards, and it is arguably worse: a check that cries wolf teaches people to ignore
  it, which costs more than never having checked.

  The read-back now polls on a bounded budget (immediate, then 2s, 3s, 5s) and stops the moment
  every requested field matches, so the normal case costs nothing. A warning is raised only when
  a value is still wrong after the last attempt, and its wording changed from "did not keep" to
  "still does not show ... after N reads" to say what was actually observed. Extracted to
  `Get-MsecAdminWriteResult` so both commands verify identically; collection properties such as
  `customTags` compare as joined strings, which removed the incident command's bespoke branch.

- `Id` is back in the default columns for alert change rows. It was dropped when `ServiceSource`
  and `CommentAdded` were added, which made a row impossible to match to the warnings printed
  beside it - the failure that surfaced the bug above. `ServiceSource` moved out of the default
  table to make room; `Select-Object *` still has it.
- `Set-MsecDefenderAlert` gains `-Comment`, correcting an earlier claim in this changelog that a
  comment could not be written to an alert at all. That was wrong: it is not a MICROSOFT GRAPH
  operation, but the Defender for Endpoint API has one, and its docs state a comment may be
  submitted with or without updating any other property. This is the field the portal's "Classify
  alert" box writes.

  The comment goes to `PATCH /api/alerts/{providerAlertId}` on the Defender host while status and
  classification continue to go to Graph. Splitting them keeps the two vocabularies apart - the
  Defender API spells determinations `InsufficientData` and `CompromisedUser` and statuses
  `Resolved`, against Graph's `notEnoughDataToValidate`, `compromisedAccount` and `resolved` - so
  nothing has to translate between them.

  IT ONLY COVERS ENDPOINT ALERTS. Measured live, that API returns 29 of 569 alerts over ninety
  days; the rest are Defender for Office 365, DLP and serviceSource `unknownFutureValue`.
  `-Comment` on one of those is refused by name, naming the serviceSource and pointing at
  `Set-MsecDefenderIncident -ResolvingComment`, rather than being silently dropped. The portal
  works on all of them because it uses an unpublished internal API.

  Authentication differs too: the Defender host will not take a Graph token, so the comment is
  written with an Az-context token carrying `user_impersonation` - bounded by the caller's own
  'Alerts investigation' role. The app registration still cannot write; it holds only
  `Score.Read.All`, `Machine.Read.All` and `Vulnerability.Read.All` on Defender.

  `CommentAdded` reports whether the comment was found in the thread on re-read - `$null` when
  not requested or not verifiable, `$false` when refused or absent, never `$true` merely because
  a PATCH returned 200.

- `Get-MsecDefenderAlert` now returns `ProviderAlertId`, the alert's id in the product that
  raised it. It is the key the Defender API needs, and was previously read from Graph but dropped.

- A failed Graph PATCH in `Set-MsecDefenderAlert` now emits a row with `Changed = $null` instead
  of emitting nothing. With a comment in play a write is no longer all-or-nothing - the comment
  can land while the Graph fields do not - and a row plus a warning beats silence a pipeline
  swallows. `$null` rather than `$false`: the change was never verified, not observed to fail.
- Documented, in `Set-MsecDefenderAlert`'s help, that Microsoft's Update alert page still lists
  the retired determinations `clean` and `insufficientData` for the enum shared with incidents.
  `$metadata` and the Update incident page both give `notMalicious` and
  `notEnoughDataToValidate`, which is what both commands accept - the note exists so nobody
  "corrects" the ValidateSet from the stale page.

### Changed
- The `Get-MsecPurview*` commands now open their compliance session themselves on first use, so
  `Connect-Msec` is all a caller needs. `Connect-MsecPurview` stays public and is now optional -
  use it to pass a specific `-Organization`, or to choose when a few hundred compliance cmdlet
  names land in the runspace - measured at 102, none clashing with the ExchangeOnlineManagement
  module's own exports.

  Requiring a manual connect for exactly one area of the module was an implementation detail
  leaking into the interface. It is not an identity difference - Purview uses the same Key Vault
  certificate as every other command - it is that this endpoint has no usable per-request REST
  model. Calling `/adminapi/beta/{org}/InvokeCommand` directly with the app token was tried:
  it authenticates (500s, never 401 or 403) and then fails on `orgUnit` routing state that only
  the module's handshake establishes, which is undocumented internal plumbing no published
  module should depend on.

  THE CONNECT IS REPORTED, NOT SILENT. The handshake takes about nine seconds and imports
  hundreds of cmdlets; a `Get-` command doing that quietly reads as a hang. `Write-Progress`
  says what is happening, stays out of the pipeline and clears itself. Measured end to end:
  ~15s for the first call, ~5s for each one after, and a test pins that a second call does not
  reconnect.
- `-MaxCount` is REMOVED from `Set-MsecDefenderAlert` and `Set-MsecDefenderIncident`. It capped a
  run at 25 objects and refused the whole pipeline above that, which got in the way of the
  bulk triage these commands exist for. There is now no cap: the pipeline writes everything the
  filter selected.

  What still stands between a broad filter and a mass update is `ConfirmImpact = 'High'`, which
  prompts per object on a bare call, and `-WhatIf`, which lists every id it would touch and
  changes nothing. `-Confirm:$false` turns off the prompt, so `-WhatIf` is worth running first on
  any pipeline you have not run before.

  Ids are still collected before the first write rather than acted on as they arrive - that was
  also what made the cap possible, but it independently ensures a duplicated id is written once.
- The module description and README no longer say "read-only by design" without qualification.
  The app registration is still read-only and that is what the promise was always about, but
  with a write command in the box the accurate statement is that the *certificate* cannot change
  your tenant, and writes run as a signed-in person.

### Added
- `Get-MsecDefenderIncident` and `Get-MsecDefenderAlert` - the row-level view of Defender XDR.
  `Get-MsecDefenderIncidentStats` already answered "how many, how severe, how fast"; these
  answer "which ones".

  REDIRECTED INCIDENTS ARE THE SAME ATTACK TWICE. Defender merges incidents it decides are one
  attack, leaving the absorbed one with status 'redirected' and a RedirectedToIncidentId.
  Measured live: 51 of 474 in ninety days, so a naive count overstates by 12%. They are
  returned by default with the merge target named, and `-ExcludeRedirected` drops them - an
  incident that silently vanished from a count would have no explanation.

  SERVICESOURCE IS OFTEN 'unknownFutureValue', WHICH IS GRAPH, NOT THE DATA. It is the enum
  placeholder for a source this API version has no name for - measured live, 231 of 569 alerts,
  40%. Passed through verbatim rather than folded into 'other' or guessed at; ProductName and
  DetectionSource are carried alongside and are usually populated when it is not.

  THE TWO STATUS VOCABULARIES DIFFER. An alert is new/inProgress/resolved; an incident is
  active/inProgress/resolved/redirected. An alert is never 'active'. Filtering both with one
  string finds nothing in one of them, silently, so the two ValidateSets differ and a test
  asserts it.

  ResolveDays is `$null` while an item is open, never 0 - zero reads as "closed instantly",
  the opposite of a running investigation. Alert evidence is counted rather than flattened:
  the shape differs per entity type, so the array stays on `Raw.evidence`.

  Measured live on a 90-day window: 474 incidents (128 active), 569 alerts (21 high and still
  new), and every single incident classified 'unknown' - which measures triage effort rather
  than the incidents.
### Added
- `Search-MsecAzureResourceGraph -ResourceType SqlServer` - Azure SQL logical servers and the
  settings that decide who can reach them and who can authenticate: public network access, the
  SQL authentication admin login, the Entra admin and its principal type, Entra-only
  authentication, and minimum TLS. `-Name Databases` lists the databases on each server with
  their server's FQDN.

  THE SQL ADMIN LOGIN IS NOT AN ENTRA IDENTITY. It lives in the server's own master database,
  is authenticated by password, bypasses Conditional Access and MFA, never appears in Entra
  sign-in logs, is shared rather than per-person, and cannot be deleted - only disabled
  wholesale by turning on Entra-only authentication. Measured live: three servers, none with
  Entra-only auth set, so the shared login was live on all three; one of them had no Entra
  admin configured at all, making SQL authentication the only way in.

  A SERVER HAS A SINGLE ENTRA ADMIN SLOT and setting it REPLACES the previous holder, so a
  server whose admin is a named person loses all Entra-authenticated administration the day
  that person leaves - and only an Entra-authenticated connection may create Entra database
  users. Measured live: one server's admin was a user whose account had been disabled two
  months earlier, which left nobody able to create a database user at all.

  RESOURCE GRAPH LAGS ARM. Minutes after an Entra admin was changed, this query still returned
  the previous holder even with `-NoCache`, while ARM and live connections already reflected
  the change. Noted in the query rather than worked around.

  Auditing settings are deliberately absent: they are a child resource Resource Graph does not
  project, like MySQL's firewall rules.
### Added
- `Get-MsecDefenderDevice -OnboardingStatus` and the same passthrough on
  `Export-MsecDefenderDeviceReport`, because a Defender inventory is mostly NOT onboarded
  devices and nothing said so.

  Defender's device DISCOVERY returns things it merely saw on the network - phones, printers,
  unmanaged laptops - from the same API as real endpoints. Measured on a live tenant:

      total             717
      Onboarded         217   Defender is protecting these
      InsufficientInfo  209   discovered
      CanBeOnboarded    178   discovered
      Unsupported       113   discovered

  So the evidence report ran three times the size of the protected estate, and 164 of those
  rows had NO DEVICE NAME AT ALL - every unnamed one discovered rather than onboarded. The
  command's own synopsis said "every device onboarded to Defender for Endpoint", which was
  simply untrue; it is corrected.

  NOTHING IS FILTERED BY DEFAULT. An unmanaged laptop on the corporate network is a finding in
  its own right and CanBeOnboarded is a worklist - they answer a different question from the
  one an exposure report asks, which is not the same as being noise. Pass
  `-OnboardingStatus Onboarded` for the protected estate.
### Fixed
- `Get-MsecEntraMfaRegistrationStats` and the posture report's `MfaCoverage` sheet divided
  every coverage percentage by the WHOLE directory, so guests diluted them. On a live tenant
  of 177 members and 202 guests the report claimed 44.33% SSPR coverage and 61.48% MFA
  coverage, against true member figures of 94.92% and 95.48% - understating recovery coverage
  by more than fifty points.

  The two errors differ in kind. A guest CAN be MFA-capable and some are, so the all-user MFA
  number was blunt. A guest resets their password in their HOME tenant and so can essentially
  never be SSPR-capable in yours - measured, 0 of 202 - which made every guest dead weight in
  that denominator.

  `NotMfaCapable` was the worst of them, because it is a COUNT of a problem rather than a
  percentage: it read 146 where the true member figure is 8. "146 users cannot do MFA" is a
  sentence somebody repeats in a meeting, and it was wrong by a factor of eighteen.

  Added `MembersMfaCapablePercent`, `MembersSsprCapablePercent`,
  `MembersPasswordlessCapablePercent`, `MembersMfaCapable`, `MembersNotMfaCapable`,
  `MembersSsprCapable` and `GuestsSsprCapable`. The last one exists so a reader can SEE that guests contribute nothing
  to SSPR rather than taking it on trust.

  THE ALL-USER COLUMNS ARE KEPT. The posture report is a time series and removing them would
  strand the history already in every workbook. The dashboard chart now plots the member-scoped
  series; existing charts keep their old lines as well, because chart series are added but
  never removed.
### Added
- `Search-MsecAzureResourceGraph -ResourceType ResourceChange` - what changed on Azure resources
  in the last 14 days, who changed it and through which client. `-Name Properties` expands one
  row per changed PROPERTY with the previous and new values, which is what answers "who changed
  this setting, and what was it before".

  FOURTEEN DAYS IS A HARD CEILING and there is no setting to extend it. An empty result for last
  month is "out of retention", not "nothing changed" - for longer, the Activity Log keeps 90 days.

  IT IS A SNAPSHOT DIFF, NOT AN AUDIT LOG. Two changes between snapshots collapse into one, and a
  change reverted before the next snapshot leaves no trace. The Activity Log stays authoritative
  for who called what.

  Attribution is carried through as it comes: `ChangedByType` is 'User', 'Application', 'System'
  or 'Unspecified' and is NOT normalised, because "Azure did it" and "nobody recorded who did it"
  are different answers. Measured live: 1,848 Application, 580 System, 490 User, 46 Unspecified
  over 14 days. Platform churn is left in rather than filtered, since "the platform restarted
  this" is a real answer - filter on `ChangedByType` to get to changes a person made.

  Patch orchestration is covered: `patchMode` is on the VM resource body, so moving a machine
  between 'Windows Automatic Updates' and an Azure-orchestrated mode is diffed like any other
  property, whichever tool did it.

  `mv-expand` in the Properties query sets an explicit `limit 2000`. Resource Graph's default
  RowLimit is 128 and truncates silently; the largest record measured carried 48 properties, so
  the limit exists to make truncation impossible rather than merely unlikely. The repo's lint
  test now covers this folder.
### Added
- `Get-MsecAzureDomainService` - every Microsoft Entra Domain Services managed domain, the security
  settings that decide what its authentication may look like, and where its security audit logs
  go. A managed domain exists so that things which cannot speak modern protocols - VPN
  concentrators, RADIUS, file servers - can authenticate people's ordinary Entra accounts over
  Kerberos, NTLM and LDAP. That is also the whole security question.

  A MANAGED DOMAIN SHIPS WITH ITS WEAK SETTINGS ON: NTLM v1, RC4 Kerberos and unsigned LDAP are
  enabled by default, and NTLM password hashes are synchronised in by default. None of it is a
  change anybody made, which is why it survives review - there is nothing in a change log to
  find, and the portal spreads nine toggles across two blades. `WeakSettings` names the ones
  currently in the weak state in one string. Measured live: six of them.

  `AuditLogsEnabled` is `$false` when security audit is off - the default, and a finding, since
  a managed domain keeps no local store to go back to - and `$null` when the diagnostic settings
  could not be read, which is a permission problem rather than a finding.

  `AuditLogWorkspace` is the workspace NAME, because that is what `Search-MsecLogAnalytics
  -WorkspaceName` takes and the workspace a managed domain writes to is not guessable.

- `Search-MsecLogAnalytics -Subject DomainServices` - the other half: what the managed domain's
  authentication actually looked like. `-Name All` gives one row per credential validation
  (Kerberos 4768/4771, NTLM 4776, failed logons 4625) with the account, client address, outcome
  and decoded reason; `-Name Accounts` summarises the same rows per account for an access
  review; `-Name Sessions` summarises the logon-session events server-side.

  SUCCESS AND FAILURE SHARE AN EVENT ID. 4776 is emitted whether the password was right or
  wrong, and the outcome is a status code inside the message TEXT - not the event id, not a
  column. Counting 4776 rows counts attempts, not logons. Measured live: 942 of them, of which
  725 succeeded, 378 were an unknown user name, 19 a wrong password, 7 a locked-out account and
  2 a disabled one.

  KERBEROS AND NTLM STATUS CODES ARE DIFFERENT CODE SPACES and are decoded separately. 0x18 is
  a Kerberos pre-authentication failure (wrong password) and is not an NT status code at all;
  0xC000006A is the NTLM wrong-password status and is not a Kerberos result code. One shared
  lookup would mislabel every row of whichever protocol it was not written for.

  `-Name All` deliberately does NOT read event 4624. On a managed domain that is the domain
  controllers' own session churn - 1,088,013 rows in thirty days against 2,673 credential
  validations - which would bury the answer and blow the API's 500,000-row cap. `-Name Sessions`
  reads those, summarised server-side.

  Machine accounts are labelled `AccountType` 'Computer' rather than dropped - and labelled
  rather than flagged with a boolean, because the Log Analytics API is untyped on the wire and
  every column reaches PowerShell as a string. A boolean column arrives as the string 'false',
  which is non-empty and therefore TRUE in a condition, so `Where-Object { -not $_.IsMachine }`
  would return nothing at all, silently. 'User' and 'Computer' compare the way they read.

- `Search-MsecAzureResourceGraph -ResourceType DomainServices` - the managed domain settings on
  their own, without the audit-log lookup `Get-MsecAzureDomainService` adds.
### Added
- `Export-MsecAzureDevOpsReport` - a whole Azure DevOps organization's security posture in one
  workbook. A sheet per area (repositories, alerts, service connections, variable groups, secure
  files, environments, agent pools, extensions, pipeline settings, organization policies, users),
  a Summary counting each area by category, and a Dashboard of fourteen charts laid out one per
  printed page.

  A SNAPSHOT, NOT A TREND: every sheet is replaced on each run. That is the opposite of
  `Export-MsecPostureReport`, which appends a row per run to build a time series.

  A FAILED AREA GETS NO CHART. A chart of zeros and no chart at all say different things -
  "measured, found none" against "could not measure" - and Azure DevOps permissions are granted
  per area, so a 403 on one area is the normal case rather than the exceptional one. Failures
  land on a RunLog sheet with the message that caused them, and every other area still writes.

  Two of the charts are deliberately NOT partitions: on pipeline settings and organization
  policies each bar is an independent measurement, so a project appears under every risk it
  carries and the bars must not be summed. They are drawn as horizontal bars so they read
  differently from the eleven that do partition.

  Categories are fixed and always present at zero, so two runs' charts line up; a value no
  category was written for is added as its own bar rather than folded into 'Other'.

  Alerts are charted by TYPE as well as severity. Azure DevOps rates every secret alert
  critical, so an organization running secret scanning alone fills the critical bar and leaves
  the other four severities empty - which reads as "no medium or low findings" when it means
  "no scanner that emits them is switched on". Measured live: 300 alerts, all of them secrets.

  Measured live on a 36-project organization: 215 repositories, 82 with no reviewer requirement
  and 49 without secret push protection; 243 service connections, of which 153 authenticate with
  a service principal secret against 61 federated, and 43 are open to every pipeline in their
  project; 77 variable groups holding secrets; 50 environments with no checks; 36 projects
  without shell argument sanitising; and 169 of 292 members who are local Azure DevOps accounts
  rather than Entra identities. Public projects are allowed at organization level.

- `Get-MsecAzureDevOpsSecureFile` - the certificates, keystores and private keys stored in a
  project's pipeline library, with their age and which pipelines may use them. Secure files are
  where signing material ends up when it cannot be put in a variable group, and nothing in Azure
  DevOps expires or reviews them.

  THE CONTENTS ARE NEVER FETCHED. There is a download endpoint and this command does not call
  it - an inventory of private keys that reads the private keys to produce itself would be worse
  than no inventory at all. Everything reported comes from the file's metadata and its pipeline
  permissions.

  `Kind` is a guess from the file extension and is documented as one, so `Name` is always
  reported alongside it - a `.key` can be anything, and on a live organization most of them were
  empty migration markers rather than key material.

  Measured live: 9 secure files across an organization, none open to all pipelines. Eight were
  `.key` migration markers uploaded between 875 and 1479 days ago and never removed; the ninth
  was a `fullchain.pfx` certificate.
## [0.3.0] - 2026-09-09

### Added
- `Get-MsecAzureDevOpsEnvironment` - deployment environments, the checks guarding them, who
  approves, and whether any pipeline may deploy to them. An environment is what a pipeline
  deploys TO, and its checks are the last thing between a run and production.

  NO CHECKS IS THE FINDING, and it looks like nothing. An environment with none configured
  reports `CheckCount` 0; one whose checks could NOT be read reports `$null`, and `-Unchecked`
  excludes the second - otherwise a list of unguarded targets fills up with ones that may be
  perfectly protected.

  An approval check with no approver named on it is reported as having an approval and an
  `ApproverCount` of 0, because it is not the protection the check count implies. Approvers
  configured as a group are reported as the group; who is in it is `Get-MsecAzureDevOpsUser`.

  Measured live: 71 environments, 50 with no checks at all, 21 with an approval, one approval
  with nobody on it, and three unchecked environments open to every pipeline in their project -
  one of them named CN-PROD.

- `Get-MsecAzureDevOpsOrganization` - every Azure DevOps organization connected to the Entra
  tenant, with its owner. Anyone in a tenant can create one and nothing announces it, so the
  result is organizations nobody reviews: created for a trial, owned by one person, holding
  repositories and service connections no governance process knows about. Measured on a live
  tenant: 28 organizations, most named after individuals, several owned by people with two each.

  THIS IS THE COMMAND THAT TELLS YOU WHAT TO POINT THE OTHERS AT. Every other
  `Get-MsecAzureDevOps*` command takes `-Organization`, and its answer is only as complete as the
  list of organizations somebody thought to check.

  THE ENDPOINT IS INTERNAL and returns CSV rather than JSON - it is the route behind the Azure
  DevOps organization list in the Entra admin portal, and there is no documented equivalent. An
  empty result warns rather than reporting a tenant with no organizations, because a changed
  route is far likelier than an empty tenant and would otherwise end an investigation that should
  have started.

- `Get-MsecAzureDevOpsPipelineSetting` - the project-level switches that decide what a pipeline
  may do: fork builds and whether secrets reach them, job authorization scope, referenced-repo
  scoped tokens, settable variables at queue time, and shell argument sanitising. They are set
  once per project and not visible from a pipeline definition, so a well-governed repository can
  sit in a project that lets a fork's build read its secrets.

  THE FORK SETTINGS ARE REPORTED SEPARATELY rather than as one verdict, because which half is
  wrong decides what to fix. `SecretsWithheldFromForks` is named for the SAFE state; the
  underlying field, `enforceNoAccessToSecretsFromForks`, is a double negative that reads
  backwards easily, and a test pins the mapping.

  `OtherSettings` names any setting without a column, with its value. On the first run against a
  live organization it surfaced `enforceReferencedRepoScopedToken`, which varied between projects
  and has since been promoted to a column of its own - the catch-all working as intended.

  Measured live across 36 projects: 11 allow fork builds and all 11 withhold secrets from them;
  13 do not limit job authorization scope; 12 allow settable variables at queue time; and none
  have shell argument sanitising enabled.

- `Get-MsecAzureDevOpsVariableGroup` - variable groups across an organization: how many variables
  and how many of those are secret, whether the group is backed by a Key Vault, how many projects
  it is shared with, and whether ANY pipeline in the project may reference it.

  THE COMBINATION IS THE FINDING, not the presence of secrets. Secrets in a group, open to every
  pipeline, in a project whose repositories require no reviewer, means anyone who can push can
  author a pipeline that reads them. Measured against a live organization: 114 groups, 77 holding
  secrets, 13 open to all pipelines, and 11 that are both - several with 18 to 21 secrets each.

  VALUES ARE NEVER EMITTED. Secret values are not returned by the API at all; NON-secret values
  are, and are dropped deliberately - this output goes into mailboxes and spreadsheets, and
  pipeline variables carry connection strings often enough that copying them into a report is a
  poor default. Variable and secret NAMES are kept, because knowing a group holds
  `AZURE_CLIENT_SECRET` is the point.

  A Key Vault-backed group counts as holding secrets under `-WithSecrets` even though it declares
  none of its own: everything it exposes is one, fetched from the vault at run time.

- `Get-MsecAzureDevOpsAgentPool` - agent pools, whether they are Microsoft-hosted or run on your
  own machines, whether every new project gets them automatically, and what the agents in them
  are. A self-hosted agent executes pipeline code on a machine you own and keeps its disk between
  jobs, so anyone who can queue against the pool can run code there and leave things behind.

  AGENT VERSIONS AND OPERATING SYSTEMS ARE DISTINCT LISTS, not summarised. A live pool held
  agent versions 2.213.2, 3.244.1 and 4.264.2 at once, on Windows builds 14393, 19044 and 19045 -
  an average or a maximum would have hidden the agent two majors behind, which is the one worth
  finding.

  AN OFFLINE AGENT THAT IS STILL ENABLED IS COUNTED SEPARATELY from a disabled one: it will
  rejoin and start taking jobs when it comes back, which is not the same as decommissioned.

  `LongestOfflineDays` says how long the most absent ENABLED agent has been gone. Measured live:
  731 days in one pool and 2261 - over six years - in another, both still enabled. A count of
  offline agents does not convey that; the age does. Disabled agents are excluded, because they
  will not come back.

  `-IncludeExposure` maps which projects can queue work on each pool today, and which of them let
  ANY pipeline do so without approval - the same "grant access to all pipelines" trap service
  connections have. `AutoProvision` answers the question for FUTURE projects; this answers it for
  the ones that already have it. Measured live: three self-hosted pools reachable from all 36
  projects, one of them open to every pipeline in a project.

  A hosted pool reports 0 agents without being asked - it has none to enumerate - while a pool
  whose agents could not be read reports `$null`. `-IncludeSecurity` adds the pool role counts
  and needs `View` on the `DistributedTask` namespace; without it those columns are `$null`.
  Both switches are opt-in because each costs calls: exposure is one per project plus one per
  queue.

- `Get-MsecAzureDevOpsExtension` - marketplace extensions installed in an organization and the
  access each one holds. An extension is third-party code running inside the organization with
  delegated access to it; the scopes granted at install are permanent until someone uninstalls
  it, apply organization-wide, and nothing prompts a review afterwards.

  `Access` groups the scopes - Manage (`*_manage`), Write (`*_write`, `*_execute`), Read, None -
  and that grouping is the command's JUDGEMENT, not something the API states, so the raw `Scopes`
  are always returned beside it. A scope this module has never seen still appears there.

  A disabled extension is kept: disabling does not revoke its scopes, and re-enabling asks nobody
  to consent again. `IsMicrosoftPublisher` is a column rather than a filter - Microsoft-published
  is not the same as safe, and judging the publisher is the reader's job.

  Verified against a live organization: 50 extensions, 7 third-party, and two holding manage
  scopes - `vso.code_manage` and `vso.serviceendpoint_manage`.

- `Get-MsecAzureDevOpsRepository` - every Git repository with the protections on its default
  branch: minimum reviewers, whether the author's own vote counts, build validation, merge
  strategy, secret push protection, and Advanced Security state. Verified against a live
  organization: 215 repositories across 31 projects, 116 of them requiring no reviewer at all.

  A POLICY ONLY COUNTS IF IT IS ENABLED AND BLOCKING. Azure DevOps allows enabled-but-advisory
  policies that appear in a pull request and stop nothing; counting those as protection would
  overstate the posture.

  `-Unprotected` means NO REVIEWER REQUIREMENT, not "no blocking policy". On a real organization
  every repository had at least one blocking policy, because a single project-wide
  secrets-scanning rule applied to all of them - by that measure nothing was ever unprotected,
  which is true and useless. The reviewer requirement is what decides whether a human sees the
  change.

  EVERY CONTROL THE POLICY API EXPOSES IS REPORTED, not only the ones a given tenant happens to
  use. Alongside the minimum reviewer count: named required reviewers, whether the last pusher
  may approve, whether votes and rejections survive a push, whether approval must be on the final
  iteration, downvotes, comment resolution, work item linking, merge strategy, file size limit,
  and the Advanced Security features. A tenant where a control is uniformly set is not a reason
  to drop the column - the module is not written for one tenant.

  `OtherPolicies` NAMES ANY BLOCKING POLICY TYPE WITHOUT A COLUMN. Azure DevOps adds policy types
  and organizations write custom ones, so a report with a column per known type silently drops
  the rest. This surfaced `Reserved names restriction` and `Path Length restriction` on the first
  run against a live organization - neither had appeared in a twelve-project sample.

  Policies are read once per PROJECT rather than once per repository, and a project whose
  policies cannot be read reports `$null` rather than 0 - a 403 must not make its repositories
  look unprotected.

- `Get-MsecAzureDevOpsAlert` - Advanced Security alerts across an organization: secret,
  dependency and code scanning findings, one row per alert with severity, state, confidence,
  file path and how long it has been sitting there. Verified against a live organization: 172
  active critical secret alerts across 45 repositories, the oldest 41 days old.

  THERE IS NO ORGANIZATION-WIDE ALERTS ENDPOINT - established by enumerating the Advanced
  Security service's own routes. Every alerts route is project- and repository-scoped, and the
  portal's org view aggregates client-side, so this makes one call per enabled repository.

  THE WORK LIST COMES FROM `_apis/management/enablement`, NOT from the git repository list.
  `_apis/git/repositories` returns only what the caller can see, with a 200 - measured live, the
  app saw 95 repositories where a person with a PAT saw 220 - so driving off it would skip
  repositories silently. Enablement is organization-scoped and authoritative about what has
  scanning switched on; the git list is used only to put names to ids.

  A REPOSITORY THAT REFUSES ITS ALERTS IS COUNTED AND NAMED. Alerts return 403, never an empty
  list, so unreadable repositories cannot pass as clean - 42 of 87 did refuse, because the app
  holds organization membership but not Advanced Security alert read.

  `truncatedSecret` IS NEVER EMITTED. The API returns a fragment of the credential it found, and
  this output ends up in mailboxes and spreadsheets. `Title` carries the secret TYPE, which is
  what triage needs.

### Changed
- `Get-MsecAzureDevOpsServiceConnection -IncludeSecurity` reports who can administer or use each
  connection, and which pipelines may reference it: `Administrators`, `AdministratorCount`,
  `UserCount`, `ReaderCount`, `OpenInProjects`, `AuthorizedPipelineCount`.

  OPT-IN, because it costs two extra calls per connection - 243 connections on the organization
  it was built against. Without the switch those columns are `$null`, which reads as "not
  collected" rather than "nobody has access".

  `OpenInProjects` is the setting worth finding: any pipeline in the project may
  authenticate through the connection without a further approval. The API OMITS the field when
  the setting is off, so absence is reported as false - but a failed call stays `$null`, which is
  a different claim.

- `Get-MsecAzureDevOpsServiceConnection` now reports what it could not see. Service connections
  are permissioned per connection, and the endpoints API answers 200 with an empty list for
  connections the caller cannot read - never a 403 - so an inventory can miss whole projects
  while looking complete. Measured on a live organization: an app in `[Project]\Readers` on 36
  projects saw 70 connections in 1 project where a person saw 155 across 14.

  Every project that returns nothing is now counted and named, and the warning says plainly that
  this is not proof they have none. What governs the visibility is NOT established: it is not the
  endpoint Reader role - an endpoint carrying `[Project]\Readers -> Reader` by inheritance was
  hidden from that app while one with no Readers entry was visible - and not the endpoint type.
  The shortfall is reported rather than explained, and no remedy is asserted that has not been
  demonstrated.

  Project names are URL-encoded now: 17 of 36 contained spaces, so `-Project 'Viedoc eTMF'` had
  been building a malformed URL.

- **Fixed on Linux:** the module folder and its manifest are lowercase - `msec/msec.psd1`,
  `msec.psm1`, `msec.format.ps1xml` - matching the PowerShell Gallery id.

  The id was set by the first publish and a Gallery id keeps the casing it was first published
  with, so `Install-Module` created `.../Modules/msec/<version>/Msec.psd1`: a lowercase directory
  holding a capitalised manifest. PowerShell resolves a module as
  `<directory>/<version>/<directory>.psd1`, and on Linux that lookup is CASE-SENSITIVE - so
  `Import-Module Msec` failed there with "no valid module file was found in any module
  directory", which reads as a module that was never installed. macOS and Windows never showed
  it. Every Linux consumer was affected, not only CI.

  The internal folders are lowercase too (`public/`, `private/`, `tests/`, `kql/`, `scripts/`).
  Folders whose names are user-facing parameter values are NOT: `kql/Graph/VM/` still backs
  `-ResourceType VM`, and `scripts/VM/Windows/` still backs `-Os Windows`. Lowercasing those
  would have changed what callers type, and broken them on Linux only.

  Command names, the `-Msec` noun prefix and the `Msec*` type names are unchanged.

- **Breaking:** the Azure DevOps commands are named `*AzureDevOps*` rather than `*Ado*`.
  `Get-MsecAdoServiceConnection`, which shipped in 0.2.0, is now
  `Get-MsecAzureDevOpsServiceConnection`. No alias is kept: an abbreviation that appears in one
  command family and nowhere else in the module is worse than a one-line fix at the call site.

### Added
- `Connect-MsecTeams` / `Get-MsecTeamsPolicy` - the Teams settings that decide who can reach
  your people: external access and federation, guest access, meeting lobby and anonymous join,
  recording, which apps users may install, and file sharing in chats with external users.

  Teams admin policy is NOT in Graph, so this goes through the MicrosoftTeams module - the
  third workload msec reaches that way, after Exchange and SharePoint. It has a wrinkle the
  others do not: `Connect-MicrosoftTeams -AccessTokens` takes an ARRAY of TWO tokens, for
  Microsoft Graph and for the 'Skype and Teams Tenant Admin API'. Separate audiences, separate
  app roles, and passing only the Graph one fails in a way that reads as a permission problem.
  Teams also needs a DIRECTORY ROLE on top of app permissions, exactly as Exchange does.

  `Get-MsecTeamsPolicy` signs in to Teams itself, so it is one call after `Connect-Msec` like
  everything else here.

  `Connect-MsecTeams -AsCurrentUser` connects as the signed-in Azure user instead of the app,
  reusing the tokens from `Connect-AzAccount`. This exists because the Teams module cannot sign
  in interactively off Windows at all - its browser flow calls into `kernel32.dll` and dies with
  a dlopen error - and device code flow, the documented workaround, is refused by any
  Conditional Access policy requiring a compliant device. Borrowing the Az session avoids both,
  since that session already cleared CA. It is also the one place msec hands over an identity
  that can WRITE: msec has no `Set-*` commands, but the connection it leaves behind carries your
  rights, so `Set-Cs*` works afterwards. `Get-MsecTeamsPolicy` will not silently replace such a
  session with the app's.

  There is deliberately NO SharePoint equivalent. Teams accepts a token whose audience is the
  service; SharePoint validates the audience against the HOST, and `Get-AzAccessToken` normalises
  every sharepoint.com URL to the service GUID. The token is issued and then refused by every
  site with a bare 401. Verified on a live tenant against both the root and the admin host, and
  written up in `Connect-MsecSharePointOnline`'s notes so nobody adds the switch back.

  ONE ROW PER SETTING, NOT PER POLICY. A meeting policy object carries roughly eighty
  properties, most about layout and captions; returning whole objects makes the handful that
  matter impossible to see and impossible to diff between two policies or two tenants. Only the
  security-relevant settings are projected - which ones is a judgement the command makes, so it
  is written out in the source and `-All` returns everything for checking it.

  `IsGlobal` marks the tenant-wide policy, because that is what a user gets unless assigned
  another: a permissive Global is a tenant-wide finding where a permissive custom policy may
  apply to nobody. A policy area that cannot be read emits an `Unreadable` row rather than
  being skipped - a missing federation configuration would otherwise read as a tenant with no
  external access, the opposite of the truth.
- `Get-MsecAzureRoleAssignment` + `Kql/Graph/Authorization/RoleAssignments.kql` - Azure RBAC
  assignments across every subscription, with role and principal names resolved.

  THE LOOKUPS ARE DELIBERATELY SPLIT ACROSS TWO IDENTITIES. `Get-AzRoleAssignment` resolves
  principal names by calling Graph ITSELF, using whatever identity holds the Az context. That
  works for a person - who has directory read by default - and silently returns BLANK names for
  a service principal without Graph permissions. A pipeline running the same code as a laptop
  therefore produces a report full of GUIDs and no error. Here assignments and role names come
  from ARM, principals from the msec Graph session, so the ARM identity needs no directory
  access at all and the answer is the same in both places.

  Principals resolve in BULK through `/directoryObjects/getByIds`, up to 1000 per call - one
  call per assignment would be 2415 round trips on a real tenant. Role names come from ARM REST
  rather than `Get-AzRoleDefinition`, which lives in Az.Resources and is NOT a msec dependency:
  using it works on a developer machine and fails on a clean agent.

  An assignment whose principal no longer exists is KEPT, with `IsResolved = $false`. On a live
  tenant that was 94 of 233 subscription-scope assignments, 85 of them deleted service
  principals whose Azure rights outlived them - the finding, not an error.

  One Resource Graph query covers the estate: 2415 assignments against the 400
  `Get-AzRoleAssignment` returns for the current subscription, and without mutating the
  caller's Az context.

### Changed
- `Get-MsecAzureDevOpsUser` - every user in an Azure DevOps organization and the groups they belong to,
  one row per membership. Replaces the hand-rolled PAT-authenticated helpers in the Reporting
  repo, and fixes three things they got wrong.

  IT PAGES. The ADO graph APIs return one page and put the cursor in the X-MS-ContinuationToken
  RESPONSE HEADER, not in the body. Reading `$response.value` gives page one with no error and
  no sign more existed - and in an access review the users that go missing look exactly like
  users who do not exist.

  Group names are resolved from ONE fetch rather than a call per membership: the direct
  translation is thousands of round trips on a few hundred users for a few dozen distinct
  groups. A user in no group still gets a row (`(none)`), because emitting nothing drops the
  account from the review; a user whose memberships could not be read gets `(unreadable)`, which
  is a different claim. `Origin` separates Entra-backed accounts from `vsts` accounts that exist
  only inside Azure DevOps, with no Conditional Access and no leaver process behind them.

- `Get-MsecAzureDevOpsOrganizationPolicy` - the policies from Organization Settings > Policies:
  third-party OAuth access, SSH, PAT creation restrictions, guest access, public projects, audit
  logging, IP Conditional Access validation. Verified against a live organization: 13 policies in
  4 groups.

  THERE IS NO REST API FOR THESE. `_apis/organizationpolicy/policies` 404s on every api-version
  and on both hosts; the only source is the data provider behind the portal's own settings page
  (`_settings/organizationPolicy?__rt=fps&__ver=2`). That route is INTERNAL and can change
  without notice, so an empty response warns rather than reporting an organization with no
  policies. Categories and labels come from the payload itself, so there is no table here to
  drift out of date.

  `Value` is the raw stored value. Four policies are named for what they FORBID
  (`DisallowOAuthAuthentication` and friends), so the settings page renders them inverted -
  `IsInverted` says which. `IsExplicit` separates a policy someone configured from one still on
  its default; the provider signals that by OMITTING `isValueUndefined`, so absence means set.

- `Get-MsecSharePointTenantSetting` - the tenant-wide SharePoint and OneDrive settings, one row
  per setting grouped into a Category, the same shape as `Get-MsecTeamsPolicy`.

  THESE ARE THE CEILING EVERY SITE SITS UNDER. A site can be locked down and still live in a
  tenant where anyone-links are on; reviewing sites one at a time never surfaces that. Covers
  the sharing capability and domain lists, external resharing, legacy auth protocols (which
  bypass Conditional Access entirely), unmanaged-device sync, and site/Loop creation.

  AN EMPTY LIST READS AS `(none)` AND A MISSING VALUE AS `(not set)`, never blank. With
  `SharingDomainRestrictionMode` set to `allowList`, an EMPTY `SharingAllowedDomainList` means
  nobody outside can be invited at all - the opposite of what a blank cell suggests.

- `New-MsecApp -Workload SharePoint` also grants `SharePointTenantSettings.Read.All` on Graph,
  which is what `/admin/sharepoint/settings` needs - the tenant-wide sharing posture:
  `SharingCapability`, the domain allow/block-list and the restriction mode. `Sites.Read.All`
  does not cover it, those being site properties rather than tenant settings, and the call
  returns a bare 403 naming no permission. It is also the only route msec has to those
  settings: the PnP equivalent needs an admin-host token that `Get-AzAccessToken` cannot mint.

- `New-MsecApp -Workload Teams` grants `application_access` on the Skype and Teams Tenant
  Admin API and assigns the directory role. Without this `Connect-MsecTeams` could not get a
  token for that audience at all, so the Teams commands shipped unusable until the app was
  configured by hand.

- `-ExchangeDirectoryRole` is now `-DirectoryRole`, because Teams needs the same role for the
  same reason and the old name said otherwise. The old name still works as an alias, so
  nothing that passed it in 0.2.0 breaks.

## [0.2.0] - 2026-09-07

### Added
- `Get-MsecSharePointSite` - every site in the tenant, classified. Completes the SharePoint
  access review: enumerate with this, then read each site's owners and members with
  `Get-MsecSharePointSiteUser -Url`.

  ENUMERATED THROUGH GRAPH, NOT THE TENANT-ADMIN API, and the reason is privilege.
  `Get-PnPTenantSite` talks to the SharePoint tenant-admin endpoint, which accepts nothing less
  than `Sites.FullControl.All` - full read, WRITE and DELETE over every site in the tenant. For
  a list of site names, in a read-only module, that is a bad trade. Graph answers the same
  question with `Sites.Read.All`.

  MOST OF WHAT GRAPH CALLS A SITE IS NOT ONE. On a live tenant `/sites?search=*` returned 432
  results of which 286 were app containers - the backing storage for Loop workspaces, Designer
  files and similar, one per artefact. Running a site access review across those is noise and
  hundreds of wasted calls, so `SiteType` classifies them (SiteCollection / AppContainer /
  Personal / Root) and the default excludes all but real sites: 146 instead of 432. `-All`
  returns everything classified, because "146 of 432" is a finding and "146" is not.

- `New-MsecApp -Workload SharePoint` now also grants `Sites.Read.All` on MICROSOFT GRAPH,
  alongside the SharePoint one it already granted. Despite the identical name these are
  separate permissions on separate resources, and both are needed: Graph's enumerates sites,
  SharePoint's lets PnP read what is inside one. Having either alone fails in a way that looks
  like the other is missing.
- Exchange Online and SharePoint support, reached the same way everything else is - a token
  signed inside Key Vault, so no certificate reaches the machine:
  - `Connect-MsecExchangeOnline` / `Get-MsecExchangeMailboxPermission` - who can open which
    shared mailbox. Standing delegated access that appears in NO Entra-side review: not in
    group membership, not in a directory role, not in Conditional Access.
  - `Connect-MsecSharePointOnline` / `Get-MsecSharePointSiteUser` - site Owners and Members,
    with security groups expanded to the people inside them.

  THESE ARE THREE DIFFERENT TOKENS, NOT ONE. Entra issues a token FOR a resource, carrying only
  the app roles granted on that resource's service principal - so Graph's `User.Read.All` buys
  nothing in Exchange or SharePoint, and a Graph token presented to either is rejected outright.
  Only the signing key is shared.

  | Command | Audience | Roles come from |
  |---|---|---|
  | `Connect-MsecGraphSdk` | `graph.microsoft.com` | Microsoft Graph SP |
  | `Connect-MsecExchangeOnline` | `outlook.office365.com` | Office 365 Exchange Online SP |
  | `Connect-MsecSharePointOnline` | the site HOST | Office 365 SharePoint Online SP |

  A SharePoint token's audience is the site HOST, so `contoso.sharepoint.com` and
  `contoso-admin.sharepoint.com` need separate tokens - which matters because tenant cmdlets
  like `Get-PnPTenantSite` only work against the admin host.

  Both modules take `-AccessToken` as a plain STRING; `Connect-MgGraph` is the odd one out in
  wanting a SecureString. Verified against ExchangeOnlineManagement 3.10.1 and PnP.PowerShell
  3.4.1. Neither is an msec dependency - both are imported only when their command is called.

  Neither workload could reach Graph anyway: mailbox permissions have no Graph endpoint at all,
  and a site's own SharePoint groups - the permission model for classic sites - are not exposed
  there either.

- `New-MsecApp -Workload Exchange, SharePoint` configures the permissions those need. OPT-IN,
  because each needs fresh admin consent and Exchange needs more than a permission.

  EXCHANGE NEEDS A DIRECTORY ROLE, NOT JUST AN APP ROLE, and this is the step that is missed.
  With `Exchange.ManageAsApp` granted and consented but no directory role, the connection
  SUCCEEDS and then every `Get-EXO*` call fails with a plain authorisation error naming no
  missing permission - from Exchange's point of view the app authenticated and has no rights.
  `-Workload Exchange` assigns one (`Global Reader` by default, the least-privilege option that
  can read mailbox permissions).

  That is a real tenant-wide privilege grant rather than an API permission, which is why the
  workloads are opt-in, why it is announced before being made, and why it is idempotent. It
  needs Privileged Role Administrator - a higher bar than the rest of the command - and a
  caller without it still gets everything else configured plus a warning saying exactly what to
  assign by hand.

  `Sites.Read.All` is granted on the SHAREPOINT service principal, not the Graph one. The two
  permissions share a name and are not the same: PnP presents a SharePoint-audience token, so
  granting the Graph one looks right in the portal and still fails.

  A resource whose service principal does not exist in the tenant - no Exchange Online, a
  sovereign cloud without SharePoint - is now skipped with a warning rather than aborting the
  bootstrap, matching how unavailable app roles were already handled.
- `Kql/Graph/Resource/NetworkExposure.kql`, reached as
  `Search-MsecAzureResourceGraph -ResourceType Resource -Name NetworkExposure` - one row per
  resource that has a network exposure setting, across twelve types: what is reachable from the
  public internet and what restricts by IP.

  It complements rather than duplicates `KeyVault/NetworkRules.kql` and
  `Storage/NetworkRules.kql`. Those answer the question per RULE for one type - which addresses
  are allowed in, and whether each rule is actually enforcing. This answers it per RESOURCE
  across the estate, so finding where to look no longer needs one query per type.

  EVERY TYPE STORES IT SOMEWHERE DIFFERENT, verified against ~1300 live resources. MySQL
  flexible servers carry `publicNetworkAccess` at `properties.network.publicNetworkAccess` and
  nothing at the top level, so the paths are coalesced nested-first; the other order reports
  every one of them as unset, which then defaults to Enabled and looks like an answer.
  Container registries use `networkRuleSet.defaultAction` where vaults and storage use
  `networkAcls.defaultAction`.

  An absent `publicNetworkAccess` means ENABLED, not unknown - defaulting it the safe-looking
  way would under-report exposure on every resource that never had it explicitly set.

  App Service IP restrictions are reported as `IpRuleCount = $null` rather than 0: they live in
  `siteConfig.ipSecurityRestrictions`, which the ARM GET returns trimmed (empty on 315 of 315
  sites), so a site that IS restricted would otherwise read as having no rules.

  `ReachableFromAnyIp` is deliberately a separate column from `NetworkExposure`. A resource with
  a Deny default and no rules at all is restricted to nobody, which is a different finding from
  one that lets anyone in - and the practical question behind a build agent, a home connection
  or anything else without a fixed address is the former.
- Three commands that between them replace the ViedocAz module the Reporting repo depended on:

  `Kql/Graph/Resource/Unused.kql`, reached as
  `Search-MsecAzureResourceGraph -ResourceType Resource -Name Unused` - unattached public IPs,
  disks, NICs, NSGs, deallocated VMs, stopped app services and empty app service plans, in ONE
  Resource Graph query rather than a Set-AzContext loop running seven Get-Az* per subscription.
  Never mutates the caller's Az context, which such a loop does and has to remember to undo.

  Two predicates in the Az-based original were wrong or missing and are fixed here. Disks: the
  attachment marker is `managedBy` at the TOP level of the resource, not under `properties`,
  and reading the latter reports every disk in the estate as unused - verified 53 of 53 against
  a live tenant where the answer is 21. NICs: a private endpoint's NIC has no virtual machine
  and is very much in use, so excluding them takes the same tenant from 58 unused NICs to 1.

  The query returns the tag bag and applies NO deferral policy. An ArchivedUntil convention is
  organisational rather than an Azure fact, so it belongs to the caller - and Resource Graph is
  the wrong place for it anyway: `todynamic()` re-parses tag JSON and infers types, so a tag
  stored as '2026-06-15' read back through a lowercased copy of the bag arrives as
  '6/15/2026 12:00:00 AM'. Verified against a real tag in a live tenant. In PowerShell the same
  filter is a case-insensitive dictionary and a TryParseExact, with no round-trip to corrupt
  the value.

  `Get-MsecKeyVaultCertificate` - certificate expiry across the accessible vaults. Certificates
  are DATA-PLANE, so Resource Graph cannot see them (`microsoft.keyvault/vaults/certificates`
  returns no rows) and this walks the vaults with Az.KeyVault instead.

  A vault that can be LISTED but not READ INTO emits an `Unreadable` row rather than
  contributing nothing. Listing vaults is control-plane (Reader); listing certificates inside
  one is data-plane, granted separately - and having the first without the second is the normal
  state for an auditor's account. On a live tenant 185 of 258 vaults were unreadable, so
  without that row the inventory would have read as "18 certificates" with nothing to say that
  71% of the estate was never examined.

  `Get-MsecAzureCost` - actual pre-tax spend per subscription or resource group, from Cost
  Management.

  THE CURRENCY IS RETURNED AND THE FIGURE IS NOT ROUNDED. The API answers with both; dropping
  the currency is how a report adds SEK to EUR, and a run spanning two warns rather than
  summing. Rounding in the collector loses the difference between 0.4 and 0, and 0 reads as
  free.

  It goes through `Invoke-AzRestMethod` rather than building the call by hand, which fixes two
  faults in the original: the ARM endpoint had to be branched on per cloud, and since
  Az.Accounts 5 `Get-AzAccessToken` returns a SecureString - so
  `"Bearer $($t.Token)"` interpolates to the literal 'Bearer System.Security.SecureString' and
  every call 401s. Verified against Az.Accounts 5.4.0.

  Cost Management throttles aggressively and the natural use - a loop over every resource group
  - is the shape that trips it. 429s are retried honouring Retry-After, and a scope still lost
  after five attempts warns that the total is short by its cost rather than contributing a
  fabricated 0.
- `Connect-MsecGraphSdk` - signs the Microsoft.Graph PowerShell SDK in with the msec session's
  token, so `Get-Mg*` commands run as the msec app while the certificate's private key stays
  in Key Vault.

  THE USUAL CERTIFICATE ROUTE CANNOT PRESERVE THAT.
  `Connect-MgGraph -CertificateThumbprint` needs the private key present on the machine, so
  anything shipping a PFX or a base64 certificate to a build agent is putting the key
  somewhere it can be copied. The token handoff is the only form that does not.

  The cloud comes from the session and is matched on the Graph ENDPOINT, not by name - the SDK
  calls the Chinese cloud `China` where Azure calls it `AzureChinaCloud`, and an endpoint no
  environment matches warns rather than silently signing in to the wrong cloud.

  The SDK is handed a STATIC token and cannot renew it, unlike msec's own commands.
  `-MinimumMinutes` is how a long report asserts it has the time it needs before starting,
  rather than working for twenty minutes and then failing partway through.

  Microsoft.Graph.Authentication is NOT a module dependency - it is imported only when this
  command is called, so msec still installs and runs on a machine without the Graph SDK.
- `Scripts/Intune/` now also holds the two hand-written scripts that used to live at
  `windows/intune/` and `macos/intune/`, moved verbatim:
  - `Windows/entra-local-admins/detect.ps1` - inventories the Entra principals in the local
    Administrators group. Detection-ONLY: Intune allows a remediation with no remediation
    script, which turns the detection output column into a fleet inventory report.
  - `macOS/local-admins/custom-attribute.sh` - the same question for Macs, as a macOS Custom
    Attribute (macOS has no Remediations feature).

  Their techniques were folded back into `remove-local-admin`, and one of them fixed a real
  bug there - see below.
- `Scripts/Intune/Windows/remove-local-admin` - the first bundled Intune Remediation: a
  detection half that reports whether a named account is in the local Administrators group,
  and a remediation half that removes it.

  A NEW SCRIPT CHANNEL, AND THE FIRST THAT WRITES. Everything under `Scripts/VM/` is read-only
  and safe to run blindly across a fleet; these change a security group on every device the
  Intune assignment covers. `Scripts/README.md` now says so explicitly - an undocumented
  exception is how someone assigns a destructive script fleet-wide expecting a report. It is
  also the one channel msec does not execute: Intune runs it, and
  `Get-MsecIntuneScriptResult -Source Remediation` reads back what happened.

  THE GROUP IS RESOLVED BY SID (`S-1-5-32-544`), NEVER BY NAME. 'Administrators' is localised -
  Administratoren, Administradores - so a script hard-coding the English name finds no group at
  all on those builds and reports every one of them as clean, which is the most dangerous way
  for this to fail.

  MEMBERS ARE ENUMERATED THROUGH ADSI, not `Get-LocalGroupMember`, which throws
  "Failed to compare two elements in the array" whenever the group holds a SID it cannot
  resolve - an orphaned domain account, an Entra principal on some builds. It throws rather
  than skipping, so one stale member makes the whole group unreadable.

  Two safety rails, both checked BEFORE anything is removed so a refusal leaves the group
  untouched: the built-in Administrator (SID ending -500, whatever it has been renamed to) is
  protected, and the group is never emptied - a device with no local administrator cannot be
  recovered locally, and a fleet-wide assignment would do it everywhere at once. After removing,
  the group is RE-READ rather than the call being trusted: the WinNT provider reports success
  for a removal that policy quietly undid, and "fixed" while the account is still an
  administrator is worse than "failed".

  MATCHING AN ENTRA ACCOUNT BY UPN NOW WORKS, AND DID NOT BEFORE. ADSI and LSA give an Entra
  member its SAM-COMPATIBLE name - 'AzureAD\JaneDoe' - never the UPN, so a `$TargetAccount`
  written as 'AzureAD\jane@contoso.com' could never match: the account stayed an administrator
  and the device reported clean. The UPN is recovered from the two IdentityStore caches, and
  the lookup is UNCONDITIONAL rather than skipped when the name already contains an '@' - the
  20-character SAM truncation can cut mid-domain and leave 'anton@examp', which looks like a
  UPN and is not one.
  Detection throws rather than exiting non-zero when the group cannot be read. Intune treats any
  non-zero exit as "issue found, run the remediation", so a machine that could not be read would
  otherwise have its administrators edited on the strength of a failed check.

  `msec/tests/IntuneRemediationScripts.Tests.ps1` guards what is testable off-Windows: both
  halves present and parsing, the group resolved by SID, the safety rails still there, and -
  the hazard the scripts warn about - `$TargetAccount` identical across the pair, since they are
  separate uploads and nothing in Intune enforces that they agree.
- `Export-MsecPostureReport` now measures the device estate itself, on two new sheets fed by
  the Intune device list it already collects - no extra API call:
  - `DevicePlatform` - one column per OS family (Windows, macOS, iOS, Android), device counts.
  - `DeviceOsVersion` - one column per OS RELEASE (Windows 11, Windows 10, iOS 17, macOS 14).

  COUNTS, NOT PERCENTAGES. The question is "how many are still on the old one", and a
  percentage hides an estate that is growing or shrinking underneath it. `TotalDevices` is on
  both sheets so the columns can be checked against it, and a device Intune reported no OS for
  lands in an `Unknown` column rather than being dropped and quietly shrinking the total.

  THE RELEASE, NOT THE RAW VERSION. `10.0.22631.3155` would be a different column on every
  patch Tuesday - the sheet would reshape every run and the chart would become a hundred
  one-point series. `ConvertTo-MsecDeviceOsRelease` collapses builds into their release.

  WINDOWS 11 REPORTS ITSELF AS 10.0, so the build is the only thing separating it from
  Windows 10 - 22000 and above is 11. Splitting on the version string, which is the obvious
  implementation, files every Windows 11 device as Windows 10: exactly backwards for the
  question this exists to answer. Windows Server is NOT guessed at and is documented as such:
  Server 2019 and Windows 10 1809 are both build 17763, and Intune calls both 'Windows'.
- `Export-MsecEntraGroupMemberReport` - the evidence shape applied to group membership: one
  worksheet per group holding its members, a Summary with one row per group, and a chart.

  THE CHART COMPARES GROUPS, not membership types within one. Groups are the x axis, so the
  question it answers is "which of these is the outlier" - the access group that grew, the one
  that is all guests, the one with a service principal in it. A chart per group would be a
  dozen tiny pictures of a number already readable in a cell.

  The Summary is the sheet a reviewer reads first: members per group, how much of that is
  standing versus PIM-eligible, and how much is guests, service principals, nested groups or
  disabled accounts. An empty group still gets a worksheet and a row - "nobody is in it" is a
  finding that disappears if empty groups are skipped - and a group whose membership could not
  be read is marked `Unreadable` rather than counted as a clean zero.

  Sheets are keyed on the group ID, not its name: Entra display names are not unique, and
  keying on the name would put two different groups' members on one sheet under one heading. A
  group actually called 'Summary' or 'Dashboard' is suffixed rather than overwriting the
  report's own sheets.

  The overwrite prompt asks ONCE for the whole run rather than once per group - a wildcard can
  match forty groups, and forty prompts is a prompt nobody reads. It comes after the collection
  here, unlike the VM reports: which worksheets are at stake is not knowable until the names
  have resolved, and reading group membership has no side effects.
- `Get-MsecEntraGroupMember` - the members of one or more Entra groups as flat rows, one per
  (group, member). Takes a list of names, wildcards included, and puts the group name on every
  row so several groups come back as a single table rather than needing a call each.

  PIM-ELIGIBLE MEMBERS ARE INCLUDED, marked `MembershipType 'Eligible'`. Where a group is
  governed by PIM for Groups, people are eligible members rather than actual ones - they appear
  on no `/members` endpoint at all, so a group whose whole membership is eligible reads as
  EMPTY. The group looks unused while a queue of people is one activation away, which is the
  most dangerous direction to be wrong in. Group OWNERS are deliberately excluded: an owner can
  add themselves and then hold what the group grants, which is a real escalation path but a
  different finding, and counting them would overstate the membership.

  MEMBERS ARE NOT ONLY USERS. `MemberType` carries user / group / servicePrincipal / device,
  because filtering to users here would quietly drop the service principal somebody added to an
  access group. A member whose type Graph did not return reads `unknown` rather than being
  assumed to be a user.

  An empty group emits a row with `MemberType 'None'`, and one whose membership could not be
  read emits `'Unreadable'` plus a warning - "the group is empty", "the group does not exist"
  and "I could not look" are three different answers and only the first is good news. A name
  matching nothing is named in a warning; a name matching SEVERAL groups returns all of them,
  since Entra display names are not unique.

  Direct members by default, matching what the portal shows - a nested group is one row.
  `-Recurse` (aliased `-Transitive`) EXPANDS nested groups instead of listing them: the people
  inside come back as members in their own right and the nested group itself does not appear,
  because the question being asked is "who is in here" and a group is not a who. Graph's
  /transitiveMembers returns the nested groups alongside their members, so listing it verbatim
  would show a group as a member AND again as everyone in it.

  Recursion reads PIM-eligible membership for every NESTED group too, not only the ones named.
  Flattening follows actual membership only, so a nested group governed by PIM contributes
  nobody - and the recursion would otherwise be quietly less complete than not recursing.
  A person reachable through two nested groups is one row; Active and Eligible are kept apart,
  since standing membership plus an eligible assignment is a real state worth seeing.- `Export-MsecDefenderDeviceReport` - the evidence shape applied to the Defender estate: one
  row per onboarded device, a worksheet named after the tenant, and a chart per tenant.

  THE CHART IS A DISTRIBUTION, NOT A TOTAL. Devices are banded by discovered-vulnerability
  count (None / 1 to 10 / 11 to 25 / 26 to 50 / 51 to 100 / Over 100), so the chart shows how
  the estate is spread rather than a tenant-wide sum. A long tail of clean machines with three
  disasters and a broad middle where everything is equally behind produce the SAME total and
  need completely different responses.

  It counts twice per band: devices, and how many of those carry at least one CRITICAL
  vulnerability. Critical is a subset of each band rather than its own band, because the two
  do not share an axis - a device with 200 vulnerabilities might have three criticals, so
  plotting them as peers would flatten one into the floor. As a subset it stays readable and
  answers what decides the work order: are the criticals concentrated in the worst machines or
  spread through ones that otherwise look fine?

  'Not assessed' is a band in its own right and sorts to the TOP. It means the vulnerability
  export could not be read at all - no Defender Vulnerability Management licence, or a missing
  permission - so the count is unknown rather than zero, and a warning says how many. Folding
  those into 'None' would report an unmeasured estate as a clean one.
- `Get-MsecDefenderDevice` - the Assets > Devices view from the Defender portal as flat rows:
  one per onboarded device, with its exposure level, risk score and how many vulnerabilities
  have been discovered on it, broken down by severity.

  TWO BULK CALLS, NOT ONE PER DEVICE. The inventory comes from `/api/machines` and the counts
  from `/api/vulnerabilities/machinesVulnerabilities`, the assessment export that returns every
  (device, software, CVE) finding in one paged stream. Per-device
  `/api/machines/{id}/vulnerabilities` would be one round trip per machine - a few thousand
  requests and a throttling wall on a real estate.

  COUNTED AS DISTINCT CVEs, which is what the portal shows. The export is one row per
  (software, CVE), so one CVE affecting three installed versions of a product is three rows and
  one vulnerability; counting rows would inflate every device by a factor that varies with how
  much software it has. `FindingCount` carries the raw row count alongside - the gap between
  the two is the remediation workload.

  A FAILED VULNERABILITY READ GIVES NULL COUNTS, NOT ZERO. Defender Vulnerability Management is
  a separate licence and answers 403 without it; reporting 0 would read as "no device has any
  vulnerability", the most dangerous wrong answer here. The device rows still come back, every
  count is null, and a warning names the permission. A device absent from a SUCCESSFUL export
  reports 0 - which for an inactive device means nobody has looked rather than that it is
  clean, so `HealthStatus` and `LastSeen` are on every row to separate the two.

  The id and severity fields are read under BOTH names Defender uses for them - `machineId` /
  `severity` from `/api/vulnerabilities/machinesVulnerabilities`, and `deviceId` /
  `vulnerabilitySeverityLevel` from `/api/machines/SoftwareVulnerabilitiesByMachine`. Reading
  only one pair is how this first shipped, and against a live tenant it produced a full device
  list with every count reading 0: the call succeeded, every row streamed in, and every row was
  discarded for carrying no id under the name being looked for. A second guard backs it up - if
  rows arrive and NONE can be attributed to a device, the counts are reported as null with a
  warning, because "a response shape this code does not understand" and "an estate with no
  vulnerabilities" are indistinguishable in the output unless one of them says so.
  `Invoke-MsecDefenderRequest` gained `-All`, following `@odata.nextLink`. Reading only the
  first page of an assessment export would silently under-report, which on a vulnerability
  report looks exactly like a clean answer.

  `New-MsecApp` now also requests the WindowsDefenderATP roles `Machine.Read.All` and
  `Vulnerability.Read.All`. An app created before this needs a re-run to pick them up.
- App Service KQL: `Kql/Graph/AppService/All.kql` (one row per site - TLS enforcement, public
  network access, client certificates, vnet integration, managed identity, plan SKU) and
  `Kql/Graph/AppService/StackSettings.kql` (the runtime stack, for the end-of-life question).
  Reached as `Search-MsecAzureResourceGraph -ResourceType AppService [-Name StackSettings]`.

  BOTH QUERIES DELIBERATELY OMIT MOST OF siteConfig. Resource Graph indexes the trimmed
  siteConfig returned by the ARM GET on a site, not the sites/config child resource, which it
  does not index at all - `microsoft.web/sites/config` returns zero rows. The keys are present
  in the property bag holding null, so projecting them yields a column of blanks that reads as
  "not configured" when it means "not visible from here". Verified against a live tenant:
  `minTlsVersion`, `ftpsState`, `ipSecurityRestrictions`, `netFrameworkVersion`, `phpVersion`,
  `nodeVersion`, `javaVersion`, `appCommandLine`, `managedPipelineMode`, `use32BitWorkerProcess`
  and `healthCheckPath` were empty on 61 of 61 sites. Only `linuxFxVersion`, `alwaysOn`,
  `http20Enabled` and `numberOfWorkers` are populated, and only those are used.

  StackSettings therefore carries a `StackSource` column - `LinuxFxVersion` when Resource Graph
  knows, `Unavailable` when it does not - and Windows sites, whose stack lives entirely in the
  fields above, sort to the TOP as `Unknown (Windows)` rather than appearing as sites with no
  stack. A container reports `DOCKER` with its image reference, because what runs inside the
  image is not something Azure knows either; `MutableTag` flags the images pinned to `latest`,
  `trunk` or a branch name, where what ran last week cannot be reconstructed from the row.
- `Get-MsecEntraAppCredential` - every client secret and certificate on the tenant's app
  registrations, one row per CREDENTIAL rather than per app: rolling up per app would have to
  pick a single expiry, which hides the secret lapsing on Friday behind the two good for a
  year. Carries `DaysUntilExpiry`, `IsExpired` and `LifetimeDays`, so it answers both halves of
  the question - the outage (a credential expiring at 3am on the integration nobody owns) and
  the security posture (a secret minted with a two-year lifetime is two years of standing
  access if it leaks).

  `-ExpiringWithinDays` always keeps ALREADY-EXPIRED credentials, whatever the window: expired
  is not less urgent than expiring, and a filter that dropped them would report the opposite of
  the truth.

  App registrations are inventoried completely, including those with NO credentials
  (`CredentialType 'None'`) - that is usually the good state, an app on federated credentials,
  and a report that omitted them could not tell "no credentials" from "not returned". Service
  principals are opt-in via `-IncludeServicePrincipal` and only appear when they actually hold
  one, because a tenant carries hundreds of Microsoft-owned ones with none. Asking for them is
  how a SAML token-signing certificate - whose expiry is a sign-in outage for every user of
  that app - shows up at all.
- `Export-MsecPostureReport` now measures privileged access, on a `PrivilegedAccess` sheet fed
  by `Get-MsecEntraRoleHolder`: standing versus PIM-eligible admins, plus the holders no MFA or
  PIM policy reaches - service principals, guests, and accounts that are disabled and privileged
  at the same time.

  Counted in PEOPLE, not assignments. Someone holding Global Administrator, Security
  Administrator and Exchange Administrator is one administrator; counting rows would report
  three and would move whenever the same faces swapped roles. Holders are counted, so a role
  reaching someone through a role-assignable group counts the person rather than the group.
  `PrivilegedAssignments` and `AllRoleAssignments` are carried alongside, so the ratio between
  people and assignments stays checkable.

  `GlobalAdminHolders` here can exceed `GlobalAdministratorCount` on the TenantSettings sheet.
  They are not in conflict: this one counts effective holders, including group-inherited and
  PIM-eligible ones; the other counts the assignment side.

- The posture report Dashboard now PACKS CHARTS DENSELY instead of reserving a slot for every
  measurement in the canonical list. A measurement that has never produced a row cost a blank
  page before, so a workbook holding only one measurement put its single chart several pages
  down with nothing in between. The canonical list still fixes the ORDER charts appear in; it
  no longer fixes their spacing.

  The trade, taken deliberately: the first time a new measurement lands, every chart below it
  moves down one page. That is a one-way, one-off move - a data sheet never loses its rows, so
  a chart that exists keeps existing and the layout only ever settles further - and position
  was already reasserted on every run, so it adds no new instability. A permanent blank page
  per uncollected measurement was the worse cost.- The Dashboard now repositions a chart whose columns are DISCOVERED from the data - one per
  subscription, per initiative, per Secure Score category - on a run that did not collect that
  measurement. Such a spec carries an empty series list on a partial run, which previously made
  the whole spec be skipped: the chart kept the row it was drawn at while the slots around it
  moved, so the next chart could be drawn straight on top of it. This is what made adding
  `PrivilegedAccess` mid-list safe to pick up with `-Measurement PrivilegedAccess` alone.- `Export-MsecEntraDisabledUserReport` - the evidence shape applied to the directory: one row
  per disabled account, a worksheet named after the tenant, and a chart counting accounts per
  age bucket with a second series for how many of those still hold licences. Graph rather than
  Az, so `Connect-Msec` and no subscription dimension.

  `Unknown` is a bucket in its own right. Entra stores no `disabledDateTime`, so the date comes
  from the audit log and anything past its retention carries a bracket instead. The bracket
  still places an account when both ends fall inside one bucket - "at least 30, at most 60" is
  squarely 30-to-90 - but where it straddles a boundary the answer is Unknown rather than a
  guess. What it is never allowed to be is "under 30 days": anything the audit log cannot see
  is OLDER than the window, never newer.

  The writing half of all three evidence reports now lives in one `Write-MsecEvidenceWorkbook` -
  worksheet naming and collision handling, replace-not-append, the Summary block, per-block
  timestamps and the dashboard. Reports supply their rows, their categories, and an ordered map
  of count columns (one entry gives one bar per category, two give two). That map is what lets
  this report chart accounts and licensed accounts side by side while the VM reports chart a
  single count.
- `Export-MsecVMNtpReport` - the same evidence shape for time synchronisation, via the bundled
  `ntp-status` script. Both the Windows and Linux versions compute the same A.8.17 rule
  (synchronised AND naming a real upstream source), so the verdict means the same thing on
  both platforms.

  `No time source` is its own verdict rather than being folded into `Not synchronised`: a
  Windows machine fallen back to Local CMOS Clock reports itself perfectly synchronised - to
  its own drifting hardware clock. It is not a machine whose daemon stalled, it is one pointed
  at nothing, and the fix is different.

  Both VM reports are now thin wrappers over a shared `Write-MsecVMEvidenceWorkbook`, which
  owns everything they had in common - discovery, running the script, worksheet naming and
  collision handling, snapshot-replace semantics, the shared Summary sheet, per-block
  timestamps and the dashboard. A report supplies only the script to run, a projection from one
  VM's answer to a row, and its ordered list of verdicts. Duplicating that machinery would have
  meant fixing every bug in it twice.

  Rows now sort worst-first by verdict, so the machines nobody could assess are at the TOP of
  the table rather than buried under the healthy ones. That was the other way round while the
  chart plotted a number per VM and a null must not lead; the chart counts per verdict now, so
  the constraint is gone.
- `Export-MsecVMUpdateReport` - an EVIDENCE document of VM patch state: one row per VM,
  showing what that machine itself reported, on a worksheet named after the subscription. A
  fresh file per run rather than a growing one, so nothing is appended and a sheet written
  twice is replaced. Re-run against the same path after `Select-MsecAzureContext` and the next
  subscription gets its own sheet and its own chart in the same document.

  In-guest via the bundled `update-status` Run-Command script rather than
  `Kql/Graph/VM/LastUpdated.kql`, which sees only what Azure Update Manager installed - a VM
  patching itself through Windows Automatic Updates or unattended-upgrades contributes nothing
  there and reads as never updated. The price is a Run-Command per VM: minutes for a fleet, and
  the machines have to be running.

  EVERY VM gets a row, including ones that could not be reached - a stopped machine, a wedged
  agent or a timeout appears with the reason in Error rather than being left out, because
  evidence that quietly omits what it failed on is not evidence. The `Assessment` column keeps
  four states distinct, since they need different follow-up: Up to date, Stale, No update
  history, No answer. Unparseable output (Azure truncates stdout at 4096 bytes) is No answer,
  never a clean machine.

  Rows are ordered worst-first, so the evidence table reads from the most overdue machine down.

  The charts count VMs per assessment rather than plotting days per machine. Days per machine
  left the VMs that could not be assessed with NO BAR - they have no number - so a reviewer
  reading the chart alone saw only the machines that answered and no sign of the ones that did
  not, which on an evidence document is the wrong emphasis entirely. Counts are also readable
  at any fleet size. They come from a shared Summary sheet in long format, one five-row block
  per subscription, and each chart reads only its own block.

  Collection time is on every sheet: `CollectedUtc` per VM row, and per subscription block on
  the Summary sheet. Subscriptions are scanned in separate runs, so one timestamp for the file
  would date every sheet by whichever ran last - claiming a subscription scanned on Monday was
  collected on Friday. The Dashboard heading reports the span rather than a single clock when
  the blocks disagree.
  Worksheet names follow Excel's rules (31 characters, no `: \ / ? * [ ]`), and two
  subscriptions truncating to the same name are told apart by the SubscriptionId on the sheet
  rather than one overwriting the other's evidence.
- `Export-MsecPostureReport` - collects the tenant's posture with the read-only Get-Msec*
  commands and appends one row per measurement to an Excel workbook (via ImportExcel), so
  repeated runs build a time series. One sheet per measurement, each written as an Excel
  TABLE - including Azure Secure Score with one column per subscription, and Intune device
  compliance aggregated from `Get-MsecIntuneDevice`.

  Every chart is on a Dashboard sheet, first in the workbook, stacked one per row and set up
  to print one chart per page - A4 landscape, fit to one page wide, a page break above each
  chart and a print area covering them (charts are drawings anchored to cells, so without a
  print area a PDF export is blank pages).

  Charts are sized for pasting into Word rather than for filling Excel's page, because Word
  pastes at true pixel size with no scaling: A4 portrait at standard margins gives about
  602 px of printable width and landscape about 930, so a chart sized to Excel's own
  landscape page (~1045 px) had to be dragged smaller on every paste. `-ChartWidth` defaults
  to 600 and fits either orientation; `-ChartHeight` defaults to 370 and also sets the row
  band, and therefore where the page breaks fall. Excel printing does not suffer: the print
  area is derived from the chart width, so fit-to-one-page-wide scales the narrow band back
  up to fill the sheet. `-ResetDashboard` rebuilds the sheet, which is how a size change
  reaches charts that already exist - they are otherwise created once and only
  range-refreshed.
  Chart series use ordinary cell ranges. Structured table references were tried first, on
  the theory that Excel would grow the series with the table - EPPlus stores and reads those
  back happily, so it tested green, and Excel rendered every chart BLANK. Ordinary ranges
  are pinned to the row count they were written with, so the ranges are refreshed in place
  as rows are appended; the chart itself is never rebuilt, and its title, position, size,
  colours and any series added by hand all survive.

  No series colours are set: Excel's own theme palette applies, so the charts match the
  workbook and follow it if the theme changes.

  `-TableStyle` sets the Excel table style on every data sheet, default `Medium2`. It is
  applied on the append path as well as on create, so changing it restyles sheets that
  already exist rather than leaving them on the old style.
  `-Target` puts goals on the charts: `@{ MfaCoverage = 95; PolicyCompliance = 80 }` writes a
  Target column holding that number on every row, which Excel draws as a flat line across the
  chart. Only the sheets named get one, so charts without a target are untouched, and the
  series is added last so it takes the final theme colour and reads as an annotation rather
  than as another measurement. The value is in the chart's own units, so a count works too -
  `@{ Incidents = 0 }` draws a zero line under the severity counts. Because it is stored per
  row, raising a target later shows as a step in the line instead of silently restating the
  earlier months at the new number.
  Chart POSITION on the Dashboard is now reasserted on every run rather than set once. Slots
  come from the index in the canonical chart list, so adding a measurement anywhere but the
  end shifts every later slot - and a chart left where it was got the newcomer drawn straight
  on top of it, invisible, with nothing to say so. Everything else about a chart is still left
  alone: title, size, colours and hand-added series.
  A `PolicyCompliance` sheet and chart, one column per Azure Policy initiative, fed by
  `Kql/Graph/Policy/Compliance.kql`. Where an initiative is assigned to several subscriptions
  the figure is recomputed from the resource counts - total compliant over total graded - and
  NOT averaged from the per-subscription percentages, which would give a four-resource sandbox
  the same weight as a four-hundred-resource production subscription. Columns are ordered by
  how much of the estate each initiative grades, so the first chart series is the broadest;
  initiatives grading nothing are left out entirely, and `-PolicyInitiative` takes wildcards
  for narrowing. Past eight initiatives it warns that the chart will be hard to read rather
  than quietly drawing it.

  This is the one measurement needing an Az context rather than just the msec session, so it
  fails on its own and lands in RunLog if `Connect-AzAccount` has not been run. It is also
  SKIPPED when the Az context is on a different tenant than the session: `Connect-Msec` does
  not move the Az context, so a per-tenant export loop would otherwise write tenant A's policy
  compliance into tenant B's workbook - a plausible number, in the wrong file, in a compliance
  report. The skip and its reason are recorded in RunLog.
  Azure Secure Score is per-subscription rather than a tenant-wide average - averaging a
  well-run production subscription with a neglected sandbox describes neither.
  `-Subscription` filters which ones appear, taking names or ids.

  Rows accumulate and are never deduped. Secure Score is trimmed to its newest snapshot,
  because `Get-MsecSecureScore` returns ~90 days on every call and appending all of it would
  add ~90 near-duplicate rows per run.

  Collection degrades rather than fails: a tenant missing a Defender or Entra P1 licence
  gets a 403 on some measurements, and those are recorded in a RunLog sheet while every
  other measurement still lands. A failed measurement contributes no row, leaving a visible
  gap rather than a fabricated zero.
- `Kql/Graph/Policy/Compliance.kql` - compliance score per initiative assignment per
  subscription, run with
  `Search-MsecAzureResourceGraph -ResourceType Policy -Name Compliance`. `-Subscription`
  scopes it server-side; the result aggregates to a few dozen rows, so picking initiatives is
  a `Where-Object` away.

  The score is per RESOURCE, matching the portal. `policystates` holds one row per resource
  per policy, so an initiative with 200 policies over 50 resources is 10,000 rows - counting
  those compliant-vs-total answers "what share of checks passed", a much flatter number where
  one bad resource failing twenty rules barely registers. The query rolls up to the resource
  first (non-compliant if ANY policy in the initiative says so), then counts resources.
  `NonCompliantChecks` is kept alongside for the size of the remediation job.
- `Get-MsecEntraDisabledUser` - every account with `accountEnabled = false`, how long it has
  been disabled, and how many licences it still holds.

  Entra records no `disabledDateTime`, so the duration comes from the directory audit log -
  an `Update user` event whose `modifiedProperties` show `AccountEnabled` going `[true]` ->
  `[false]`. Those logs retain 30 days on P1/P2 and 7 on the free tier, so an account
  disabled inside that window gets an exact `DisabledSince`, `DisabledDays` and `DisabledBy`,
  and one disabled before it gets a BRACKET instead: `DisabledAtLeastDays` (nothing found in
  the window searched) and `DisabledAtMostDays` (days since its last successful sign-in,
  since a disabled account cannot sign in). `DisabledSource` says which of the two you have
  rather than leaving it to be inferred from a null.

  The upper bound comes from `signInActivity`, which Entra persists on the user object rather
  than serving from a log - so unlike `DisabledSince` it is not capped at the audit retention
  window and reaches back years (it does need Entra ID P1). It rests specifically on
  `lastSuccessfulSignInDateTime`: `lastSignInDateTime` records the last interactive ATTEMPT,
  and a disabled account still gets attempted, so bounding on it would report "disabled at
  most 7 days" for an account switched off three years ago. Where no successful sign-in is
  recorded the bound is left blank rather than guessed. All four timestamps are surfaced -
  `LastSignIn` (newest of any kind), `LastSuccessfulSignIn`, `LastInteractiveSignIn` and
  `LastNonInteractiveSignIn`, the last being how a service account looks dead interactively
  while being busy every hour.
  "Last updated" is three columns, because Graph exposes no `lastModifiedDateTime` on a user
  and the three real signals answer different questions: `LastDirectoryChange` (+ `...What`,
  naming which properties moved) is the newest audit event against the object and is bounded
  by the same retention, so null means "not in the window" rather than "never";
  `LastPasswordChange` is unbounded and usually the best marker of when a disabled account
  was genuinely last in use; `OnPremisesLastSync` catches the orphan case, where sync is
  still enabled but the on-premises source object is gone.
  Degrades rather than fails: a tenant without Entra ID P1 rejects `signInActivity`, so the
  call is retried without it; an unreadable audit log costs the dates but not the user list.
  Needs `User.Read.All` and `AuditLog.Read.All`, both already granted by `New-MsecApp`.
- `Get-MsecIntuneScriptResult` - per-device results from all five Intune script collections:
  remediations (deviceHealthScripts), platform scripts (deviceManagementScripts and
  deviceShellScripts), macOS custom attributes and custom compliance discovery scripts.
  The data behind the portal's Excel export. Reads deviceRunStates only - per-user results
  from user-context scripts are not covered.

### Removed
- `Set-MsecDefenderAlert -Comment`, and the `Invoke-MsecAdminDefenderRequest` helper behind it.

  IT PUT TWO DIFFERENT USER IDENTITIES INSIDE ONE COMMAND. Status and classification went through
  the Connect-MsecAdmin delegated session; the comment went to the Defender for Endpoint API on a
  separate Az-context token, because that host will not accept a Graph token. Nothing stopped those
  being two different people - an alert could be resolved by one and commented by another - and
  nothing in the output said which was which.

  It bought very little. The Defender API only knows ENDPOINT alerts: measured, 29 of 569 on one
  tenant, and none of the alerts anyone there actually triaged, which are Defender for Cloud and
  report `serviceSource` `unknownFutureValue`. Five per cent coverage did not justify a second
  authentication path.

  Notes belong on the incident - `Set-MsecDefenderIncident -ResolvingComment` - which Microsoft
  describes as explaining the resolution and the classification choice and which works for every
  incident whatever raised it. `Get-MsecDefenderAlert` keeps `ProviderAlertId`: it is the alert's
  id in the product that raised it and is useful for cross-referencing the portal, independently of
  the removed feature.

  A test now asserts the command reaches only the delegated Graph session, so a second transport
  reappearing is a failure whatever it authenticates with.
- `Export-MsecWordReport`. It was the module's only optional-dependency command, requiring
  PSWriteOffice to be installed separately, and its tests skipped entirely when that module
  was absent - so on CI and on most machines it was shipped but never exercised. Pipe to
  `Export-Csv`, or to `Export-Excel` from the ImportExcel module, for the same evidence.

### Changed
- `Get-MsecSharePointSiteUser -Url <site>` now CONNECTS ITSELF. Every other command in the
  module is one call after `Connect-Msec`; requiring a separate `Connect-MsecSharePointOnline`
  first made SharePoint the exception for no good reason.

  It does so WITHOUT moving the caller's session. PnP keeps a single ambient connection, so a
  command that simply called `Connect-PnPOnline` would leave the caller pointed at a different
  site than they were on - a side effect nobody asked for that only shows up later. The
  connection is created with `Connect-MsecSharePointOnline -PassThru` (new switch, wrapping
  PnP's `-ReturnConnection`) and threaded through each PnP call explicitly. Verified live:
  reading site B left `Get-PnPConnection` pointing at site A.

  Omitting `-Url` still uses the ambient connection, so existing scripts are unaffected.- `Select-MsecAzureContext` now RECONNECTS THE MSEC APP SESSION to the tenant it switches to,
  when that tenant has been connected before. `Connect-Msec` remembers the vault name, client
  id and certificate name per tenant on a successful connection; switching context replays
  them.

  msec runs on two identities - the Az context is you, the msec session is the app
  registration - and switching one left the other pointing at the tenant you just left, so
  Graph and Defender calls kept answering for the wrong tenant. That was already detected; it
  was a warning telling you to run Connect-Msec again. Now it is fixed where it can be, and the
  warning remains for the cases it cannot (no saved profile, or -NoConnect).

  NO SECRET IS STORED, and none is needed: msec signs its client assertion inside Key Vault and
  the private key never leaves it. The profile holds what you would type on the command line,
  under the tenant's own folder beside the completion caches, so two tenants can never overwrite
  each other. `-NoSave` on Connect-Msec skips writing one; `-NoConnect` on
  Select-MsecAzureContext skips replaying one.

  Written only AFTER the tokens are obtained, so a saved profile always describes a connection
  that worked rather than one that was merely typed. A missing, malformed or incomplete profile
  is treated as no profile rather than as an error mid-switch, and a reconnect that fails warns
  without failing the context switch - the switch is what was asked for and it stands.
- The four snapshot reports (`Export-MsecVMUpdateReport`, `Export-MsecVMNtpReport`,
  `Export-MsecEntraDisabledUserReport`, `Export-MsecDefenderDeviceReport`) now ASK before
  replacing a worksheet that already holds evidence, and take `-Force` to skip the question.
  They replace rather than append - that is the point of a snapshot - which also means a
  mistyped path silently destroyed last month's evidence.

  Asked only when something would actually be lost. A new file, or a new tenant or subscription
  inside an existing file, is not a question worth interrupting for; a sheet already holding
  THIS subject's rows is. Two owners whose names truncate to the same 31 characters are a
  collision rather than an overwrite - the newcomer gets its own suffixed sheet - so that does
  not prompt either. The prompt names the sheet, its row count and when it was collected, so
  the answer can be given on the facts.

  ASKED BEFORE THE COLLECTION, NOT AFTER, so declining costs nothing: no directory enumeration,
  and on the VM reports no Run Command invocations against live machines.

  `Resolve-MsecEvidenceSheet` is shared by the prompt and by the writer, so the sheet the
  caller was asked about is necessarily the sheet that gets written - asking the question in
  two places is how a confirmation ends up guarding the wrong one.

  Unattended runs need `-Force`: a scheduled task has no one to answer, and `ShouldContinue` in
  a non-interactive host is an error rather than a default.

  `Confirm-MsecEvidenceOverwrite` also takes a SET of subjects, so a report writing many sheets
  in one run asks a single question naming all of them.

### Fixed
- `Get-MsecSharePointSiteUser` read no groups at all. `Get-PnPGroup @($spec.Param)` is an ARRAY
  SUBEXPRESSION, not splatting - it passed a one-element array that bound positionally to
  `-Identity`, so every call failed. Found on the first real run against a live site.

  The symptom was the more instructive half: the catch block reported "this site has no
  associated Owner group", asserting a cause it had not checked, so a code defect read as a
  property of the tenant. The message now says what happened before what might have caused it.
- `PrincipalType` was inconsistent between the two paths that produce it - SharePoint types a
  direct member 'User', Graph types an expanded group member '#microsoft.graph.user'. The same
  person therefore read as 'User' or 'user' depending on how they got access, and a filter on
  either silently missed the other. Both are normalised to Graph's lowercase form now.
- A missing msec session no longer degrades silently. Expanding a security group needs a Graph
  session as well as the PnP one; without it every group came back `IsResolved = $false`, which
  is exactly what a DELETED group looks like - so the output read as a tenant full of orphaned
  groups rather than as a missing connection. It now warns up front, and every unresolved row
  carries an `UnresolvedReason` distinguishing "no session" from "group could not be read".- `Search-MsecAzureResourceGraph` now fingerprints the QUERY into its cache key. The key was the
  resource type, the name and the subscription scope - none of which change when the .kql does -
  so editing a bundled query kept serving rows in the old shape, and the author reasonably
  concluded the edit had not applied. Found the hard way while editing `Resource/Unused.kql`.

  A cached result written before this has no fingerprint and is treated as a miss rather than
  trusted, since it may have been written by a different query.- An OS release or device platform that EMPTIES OUT now reports 0 rather than blank. Those
  columns are discovered from the data, so the run where the last device leaves iOS 26 simply
  stops producing that column - and `Export-Excel -Append` maps by name, leaving the cell
  empty. Excel plots a blank as a GAP, so the line stopped dead exactly where it should have
  descended to zero: "we stopped measuring" instead of "nobody is on it any more", which is the
  good news the sheet exists to show.

  It also stops the sheet being rewritten every time the release set shrinks - a column going
  missing is schema drift as much as a column appearing, and a rewrite is the one operation
  that discards manual formatting.

  Deliberately NOT done generally: this is right for counts and wrong for scores. A
  subscription that drops out of AzureSecureScore was not measured, and writing 0 there would
  report a perfect-zero score rather than an absence. History is left alone too - a release that
  did not exist yet keeps its blank, which is different from nobody being on it.
- A DAMAGED WORKBOOK COULD BE SILENTLY REPLACED BY A FRESH ONE, losing every sheet in it rather
  than just one. Export-Excel can CREATE the file, so it treats "cannot read this" and "nothing
  here yet" identically - and a zero-byte file is indistinguishable from a new one. A OneDrive
  placeholder that never downloaded, or a run killed mid-save, therefore got replaced by a
  workbook holding one sheet and one row, and the write reported success. Reproduced.

  `Assert-MsecExcelWorkbook` now runs before either writer touches the path: a file that exists
  but is empty, unopenable, or holds no worksheets is refused, and left exactly as found so
  version history can still restore it. A path that does not exist is still a normal first run.
- A SHEET REWRITE COULD SILENTLY DISCARD EVERY ROW EVER COLLECTED. `Write-MsecExcelSheet`
  rewrites with `-ClearSheet`, so whatever it reads back first is the entire surviving record -
  and it caught every failure of that read and carried on with an empty history, reporting the
  loss only through `Write-Verbose`. Any transient failure to read the workbook (open in Excel,
  a sync client mid-write) therefore reduced a posture sheet to the single row from that run.
  Reproduced at five rows in, one row out.

  It now reads the sheet's row count from the package BEFORE reading its contents, which is
  what makes "there is nothing to preserve" distinguishable from "I could not read what is
  there". Only the first proceeds; the second throws, and the file is left untouched. Reading
  back FEWER rows than the sheet holds is refused on the same grounds - a truncated history is
  not recoverable, a refusal is.

  This only ever fired on a RESHAPE (a measurement changing its column set); ordinary appends
  go through `Export-Excel -Append` and never took this path.
- A sheet that cannot be written now costs only its own row rather than the whole run, matching
  how the collect half already degraded. The refusal above would otherwise throw away nine
  successfully collected measurements to protect one, and the failure is recorded in RunLog.
- A column that appeared AFTER a posture-report chart was first drawn now gets a series on it.
  The sheets with dynamic columns - one per Azure subscription, per Secure Score category, per
  policy initiative - grow a column whenever the estate does, and the dashboard only ever
  refreshed the ranges of series the chart already carried. So a new subscription landed on the
  AzureSecureScore sheet, appeared in the schema-drift warning, and was then absent from the
  chart indefinitely: the report quietly under-reported the estate while looking complete.
  Series are only ever ADDED, so one added by hand in Excel still survives.
- A series whose column is still on the sheet but which this run did not collect now keeps
  growing with the sheet. A subscription that drops out of the Az context keeps its column
  (`Write-MsecExcelSheet` takes the UNION of old and new columns, so history is never dropped)
  but its chart range stopped at the row count it had when last collected - so the line ended
  early, reading as the data stopping rather than the subscription leaving.
- `New-MsecApp` now requests `DeviceManagementScripts.Read.All`. Intune scripts are a
  separate scope from `DeviceManagementConfiguration.Read.All`, which does not cover
  deviceHealthScripts or deviceCustomAttributeShellScripts even though both sit under
  /deviceManagement beside the configuration policies - they answer 403 without it.
- `New-MsecApp` reported its permission grants only through `Write-Verbose`, so a re-run
  that added a dozen app roles printed one line about finding the app and nothing about the
  grants - indistinguishable from having done nothing. It now prints a summary, returns
  `GrantedNow` / `AlreadyGranted` / `UnavailableRoles`, and says to reconnect: consent does
  not apply to a token that was already issued, so re-running to fix a 403 and retrying in
  the same session hits the same 403.

## [0.1.0] - 2026-08-20

First release.

### Added
- **Secure Score** - `Get-MsecSecureScore` (overall and per category, over time),
  `Get-MsecAzureSecureScore` (Defender for Cloud, per subscription),
  `Get-MsecDefenderScoreExposure`, `Get-MsecDefenderScoreDeviceConfiguration`.
- **Defender XDR** - `Get-MsecDefenderIncidentStats`, `Get-MsecDefenderEmailStats`.
- **Entra ID** - `Get-MsecEntraTenantSecuritySetting`, `Get-MsecEntraLicense`,
  `Get-MsecEntraRoleHolder`, `Get-MsecEntraConditionalAccessPolicy`,
  `Get-MsecEntraConditionalAccessStats`, `Get-MsecEntraConditionalAccessSignInLog`,
  `Get-MsecEntraMfaRegistration`, `Get-MsecEntraMfaRegistrationStats`,
  `Get-MsecEntraMfaEvidence`, `Convert-MsecEntraSid`.
- **Intune** - `Get-MsecIntuneConfigurationProfile`, `Get-MsecIntuneCompliancePolicy`,
  `Get-MsecIntuneDevice`, `Get-MsecIntuneScriptResult`.
- **Azure** - `Search-MsecAzureResourceGraph`, `Search-MsecLogAnalytics`,
  `Invoke-MsecAzureVMScript`, `Select-MsecAzureContext`.
- **Azure DevOps** - `Get-MsecAzureDevOpsServiceConnection`.
- **Session** - `New-MsecApp`, `Connect-Msec`, `Disconnect-Msec`. The private key stays
  in Azure Key Vault; tokens are JWT client assertions signed there.
- **Reporting** - `Export-MsecWordReport`.

### Notes on the output shape

These are the decisions most likely to surprise, and the reasoning is in each command's
help under `.NOTES`:

- **Directory roles are matched by `roleTemplateId`, never by display name.** Graph
  returns Global Administrator as *Company Administrator* on many tenants, display names
  are localisable, and a tenant can rename a role - so a name comparison silently reports
  zero. `Get-MsecEntraRoleHolder -Role 'Global Administrator'` resolves through the
  canonical map and matches either way.
- **`Get-MsecEntraRoleHolder` separates the assignee from the holder.** A role assigned to
  a group reports the group in `Principal*` and each member in `Effective*`, so counting
  administrators and counting grants are different questions that no longer contaminate
  each other. PIM-eligible assignments are included.
- **Intune assignment targets are typed columns, not a summary string.** `AssignmentType`,
  `AssignmentGroup` and `AssignmentExcludedGroup` are arrays, so `-contains` is exact;
  `msec.format.ps1xml` flattens them for display only. An assignment count cannot tell
  *All Users plus an exclusion group* from *two unrelated groups*.
- **Unmeasured is `$null`, measured-and-zero is `0`.** A failed read never reports the same
  value as a successful one that found nothing; where a command can say why, it does.
.IsApplied }` the whole question.

  A PRESET POLICY HAS NO RULE OF ITS OWN and is applied by the EOP/ATP protection policy rule;
  a default policy has none either, because it is the fallback. Reporting those as unapplied
  would cry wolf on the configuration Microsoft most recommends - and on a tenant using presets
  that is nearly every policy. Measured on one tenant: 21 policies, 16 of them applied through
  a preset, a default or Microsoft's built-in protection, and none genuinely inert.

  RULES UNREADABLE IS NOT RULES ABSENT: if the `*Rule` cmdlet fails, `IsApplied` stays ``
  rather than reporting every custom policy inert.

  `Get-PhishSimOverridePolicy` and `Get-SecOpsOverridePolicy` FAIL SERVER-SIDE under an app-only
  session on at least some tenants, so advanced delivery is reported as unreadable rather than
  as not configured - the difference between a tenant with a phishing-simulation exemption and
  one without.

- `Get-MsecEntraAppConsent` - which applications have been granted access to tenant data, what
  they can do, and who agreed to it. One row per permission.

  `Get-MsecEntraAppCredential` says which apps hold a key; this says what those apps are allowed
  to DO. Illicit consent needs no password, survives a password reset, and leaves the attacker
  holding a token rather than an account - and nothing in msec could see it.

  DELEGATED AND APPLICATION GRANTS ARE DIFFERENT SIZES OF PROBLEM and are labelled as such. A
  delegated grant acts as a user and inherits that user's limits; an application grant acts as
  itself with no user and no limits, so `Mail.Read` there is every mailbox in the tenant.
  `ConsentType` separates a single user agreeing for themselves from an administrator agreeing
  on behalf of everyone.

  APP ROLE ASSIGNMENTS ARE READ FROM THE RESOURCE SIDE. The obvious route - `$expand=
  appRoleAssignments` on each service principal - SILENTLY TRUNCATES at one page and does not
  paginate. Measured on one tenant it returned 203 assignments where the resource-side read
  returned 410, and 20 of msec's own 24. The command pays ~200 extra calls and about 30 seconds
  to not under-report permissions by half.

  ASSIGNMENTS TO USERS AND GROUPS ARE EXCLUDED: an app role assigned to a user or group says who
  may USE an app, not what the app may do to your data. Including them inflated the count from
  208 to 410 with a different question's answer.

  An unresolvable app role reports `Permission` and `IsHighRisk` as `$null`, never `$false` -
  `$false` would claim it was checked against the risk list and found safe.

- `Get-MsecTeamsPolicyAssignment` - how many users each per-user Teams policy actually applies to.

  `Get-MsecTeamsPolicy` says what a policy CONTAINS. It cannot say who gets it, and that is the
  half that decides whether a setting matters: a tenant holding a carefully restrictive meeting
  policy assigned to three people is indistinguishable, from the policy list alone, from a tenant
  that is actually restrictive. Measured on one tenant: 535 of 538 users on a Global meeting
  policy with `AllowAnonymousUsersToJoinMeeting = True`, and the restrictive
  `RestrictedAnonymousAccess` policy on 3. Messaging, AppPermission and Files had ZERO explicit
  assignments - every policy beyond Global was decoration.

  POLICIES WITH NO HOLDERS ARE RETURNED, NOT OMITTED. That is the finding, not an empty result -
  a policy nobody holds is configuration someone wrote and believes is in force. The policy list
  is read separately from the user list precisely so a policy with zero holders still appears.

  A USER WITH NO EXPLICIT ASSIGNMENT GETS GLOBAL, and Teams reports that as a NULL property
  rather than as the string `Global`. Counting only explicit assignments would have reported
  Global as applying to nobody.

  UNREADABLE IS NOT ZERO: if the user list cannot be read, `UserCount` is `$null` on every row
  and a warning says so. A failed read printing "0 users" against every policy is both wrong and
  the most alarming possible misreading.

  Federation and Client are deliberately absent from `-PolicyType`: they are tenant-wide
  configuration with no per-user assignment, so asking who holds them is meaningless.

  `Get-CsOnlineUser -ResultSize` is a 32-bit INTEGER on this cmdlet, not the `Unlimited` keyword
  the Exchange-family cmdlets take - and `[uint32]::MaxValue` overflows the Int32 it binds to.

- `Get-MsecExchangeTransportRule` and `Get-MsecExchangeOrganizationSetting`, completing the mail
  side of the Exchange commands.

  A TRANSPORT RULE RUNS ON EVERY MESSAGE BEFORE THE USER SEES IT, which makes it a favourite for
  persistence - and it lives in a part of the portal nobody browses. `BypassesFiltering` says in
  words what `SetSCL = -1` means: trust the message completely, skip spam, phishing and bulk
  filtering. Measured on one tenant, 7 of 12 rules set it and 3 are live.

  `IsActive` NEEDS BOTH `State` AND `Mode`. A rule can be Enabled and completely inert because
  its Mode is Audit rather than Enforce, so a filter on State alone over-reports what is running.

  THERE ARE FOUR WAYS A RULE SENDS MAIL ELSEWHERE, not one: `RedirectMessageTo`, `BlindCopyTo`,
  `CopyTo` and `AddToRecipients`. They behave differently for the sender and the original
  recipient, and a check written against one misses the other three. `RedirectsMail` covers all
  four; `ExternalRecipients` names the targets outside every accepted domain, and is `$null`
  rather than empty when those domains could not be read.

  THERE ARE TWO AUTO-FORWARDING CONTROLS AND BOTH MUST BE CLOSED. The outbound spam filter
  policy's `AutoForwardingMode` governs it at the Defender layer; the Default remote domain's
  `AutoForwardEnabled` governs it at the transport layer. Closing one and leaving the other is
  the common half-fix, so they are adjacent columns on the same row. Note the safe value is not
  "Off": `Automatic` is Microsoft's system-controlled default, and `On` opens the path outright.

  Each organisation setting is read independently, so one refused lookup leaves that column
  `$null` instead of failing the row - a partial answer about tenant posture beats none, as long
  as the gaps are visible as gaps.
- `Get-MsecExchangeMailbox` - mailboxes with the two things that actually leak mail: where it is
  forwarded, and which legacy protocols are open. Measured on one tenant: 34 of 305 mailboxes
  forward, 11 by raw SMTP, four of those outside every accepted domain.

  FORWARDING COMES IN TWO SHAPES AND THEY ARE NOT THE SAME RISK. `ForwardingSmtpAddress` is a raw
  address that can point anywhere; `ForwardingAddress` must resolve to an existing recipient
  object, so it cannot name an arbitrary stranger. Reporting them as one column loses that.
  `IsForwardingExternal` is `$null` for a recipient forward rather than `$false` - judging it
  needs a lookup this command does not do, and `$false` would claim the mail stays inside.

  `DeliverToMailboxAndForward` IS ITS OWN COLUMN because `$false` means no copy stays behind:
  the mail leaves and the owner has no way to notice. On the measured tenant exactly one mailbox
  was in that state.

  SMTP AUTH IS RESOLVED, NOT REPORTED RAW. The per-mailbox setting is usually `$null`, meaning
  "inherit the tenant default", and `$null` read as a boolean is false - so an unresolved value
  reports SMTP AUTH disabled on every mailbox that never set it, for the one protocol that
  bypasses MFA outright. `SmtpAuthEnabled` is the effective answer and `SmtpAuthSource` says
  whether it came from the mailbox or the tenant.

  Protocol columns are `$null` for a mailbox with no CAS record rather than `$false` - measured,
  five Bookings (`SchedulingMailbox`) mailboxes, which genuinely have no protocols to report.

  Two bulk calls rather than one per mailbox: 305 mailboxes in about seven seconds.

## [0.4.0] - 2026-09-29

### Added
- `Get-MsecIntuneDevice` now returns `EnrollmentType`, `IsSupervised`, `EnrollmentProfile` and
  `IsAutomatedEnrollment`. How a device was enrolled decides whether a user can simply remove
  management, and nothing in the previous output could answer that.

  An Apple device enrolled through Automated Device Enrollment has a management profile the user
  cannot remove. One enrolled manually does not - so every configuration profile, compliance
  check and Conditional Access decision resting on management can be ended by whoever is holding
  the laptop. Measured live: 9 of 19 Macs and 128 of 130 iOS devices were manually enrolled, and
  on the Mac side both devices on an unsupported OS version and both devices that had stopped
  checking in were in that group.

  `IsSupervised` IS NOT THE ANSWER and is included so nobody reaches for it: it came back True
  on all 19 Macs regardless of enrolment method, so a filter on it finds nothing.

  `IsAutomatedEnrollment` IS `$null` ON WINDOWS AND ANDROID, not `$false`. The enum reports
  `windowsAzureADJoin` for both an Autopilot deployment and a manual Entra join, so it cannot
  answer the question there and a `$false` would claim that it had.

  NB `autopilotEnrolled` is beta-only and returns HTTP 400 against v1.0 `managedDevice` - it was
  tried and removed, and there is a comment in the `$select` list saying so.
- `Get-MsecPurviewAlertPolicy` - Purview alert policies, the area every other Purview command
  here was missing. The rest report what is PREVENTED; this reports what is NOTICED, and it was
  a blind spot: measured live, 65 policies of which 14 were the organisation's own, and all 7
  disabled ones were theirs rather than Microsoft's.

  A DISABLED ALERT POLICY IS SILENT IN EXACTLY THE WAY A WORKING ONE IS, which is why nobody
  finds these until an incident review asks why no one was told. "Shared files externally" and
  "User copies a file with sensitive data to a removable drive" were both off.

  `IsEnabled` INVERTS THE RAW PROPERTY. The service stores `Disabled`, so a filter written
  against it reads backwards and `Where-Object Disabled` quietly returns the healthy policies.
  Both are on the row, positive form first.

  `NotificationEnabled` IS NOT WHETHER THE ALERT FIRES - it is whether anyone is emailed. An
  enabled policy with it off raises the alert in the portal and tells nobody. Measured live,
  three custom policies were in that state, including the alert attached to the one GDPR DLP
  rule that actually enforces.

  `IsSystemRule` separates Microsoft's built-ins from local configuration, because a count that
  mixes them says nothing about how much alerting anyone here set up. `-CustomOnly` narrows to
  the latter.
- `Get-MsecPurviewDlpPolicy` now returns `WorkloadClaims` and `ClaimsEmailWithoutTarget`, because
  the raw `Workload` property is the most misleading thing about a DLP policy and omitting it
  left no way to see why.

  `Workload` IS DECLARATIVE, NOT DERIVED. Measured live: all eight policies on one tenant listed
  "Exchange" in `Workload` while every Exchange targeting property - `ExchangeLocation`,
  `ExchangeSender`, `ExchangeSenderMemberOf`, `ExchangeAdaptiveScopes` - was empty. Microsoft's
  parameter reference is explicit that this means email is excluded: "If you don't want to
  include email messages in the policy, don't use this parameter." So a policy can assert email
  coverage it does not have, and an experienced admin reading `Workload` will reasonably conclude
  the opposite of the truth.

  Hiding the property would have been the wrong fix - the scopes were already right, and someone
  checking msec against the portal or against `Get-DlpCompliancePolicy` would keep rediscovering
  the discrepancy and assuming msec was wrong. `ClaimsEmailWithoutTarget` names it instead.
- `Get-MsecPurviewAutoLabelingPolicy` and `Get-MsecPurviewInformationBarrier`, closing the two
  gaps that would otherwise have gone into a Purview review with no command behind them.

  AUTO-LABELING IS THE ONLY THING THAT APPLIES A SENSITIVITY LABEL WITHOUT A USER. A tenant with
  labels published and no auto-labeling policy relies entirely on people classifying their own
  content - so zero rows is a finding, not an empty section, and the command answers cleanly
  rather than erroring on it. Same configured-versus-enforcing split as the DLP command: only
  Mode 'Enable' labels anything, every Test* mode simulates.

  Information barriers are absent on most tenants and that is a legitimate answer - they exist
  for regulated separation. Reporting the absence is the point, because a deliberate "no
  barriers" and an overlooked one look identical until someone asks. `State` is not `IsActive`:
  a barrier is authored inactive and protects nobody until applied, while still counting as a
  policy.

  BOTH PROJECTIONS ARE UNVERIFIED AGAINST LIVE DATA, and say so in their help. They were written
  on a tenant with zero of each, and Microsoft's cmdlet reference does not document the returned
  properties. So they are built to degrade rather than guess: a property PowerShell cannot find
  is `$null` rather than an error, locations go through `Resolve-MsecPurviewLocation` which
  already handles absent ones, and `Raw` carries the untouched object so a missed column can be
  recovered without a module change. A test pins that `Raw` survives.

  `RuleCount` is `$null` rather than `0` when `Get-AutoSensitivityLabelRule` is not exposed:
  "this policy has no conditions" and "the rules could not be read" are different claims.
- Microsoft Purview coverage: `Connect-MsecPurview`, `Get-MsecPurviewDlpPolicy`,
  `Get-MsecPurviewSensitivityLabel` and `Get-MsecPurviewRetention`.

  NO NEW CONSENT WAS NEEDED. Purview's configuration is not in Graph - DLP policies, DLP rules,
  sensitivity label actions and label policies have no Graph endpoint - so this goes through
  Security & Compliance PowerShell. `Connect-IPPSSession` takes `-AccessToken` and `-AppId`, the
  same shape `Connect-MsecExchangeOnline` already uses, so the existing Key Vault certificate
  reaches the compliance endpoint as the app. The app does need a directory role (Global Reader
  or Compliance Administrator) and a 403 there is translated into a message saying so, because
  it is a role problem far more often than a permission one. `-Organization` is optional and
  resolved from Graph.

  CONFIGURED IS NOT ENFORCING, and the count people quote is the configured one. A DLP policy's
  `Mode` is independent of its `Enabled` flag: `Disable` does nothing, `TestWithNotifications`
  reports without blocking, only `Enable` stops anything. `IsEnforcing` collapses that, with
  `Mode` and `Enabled` kept on the row. `BlockingRuleCount` matters just as much - measured
  live, a policy enforcing across all SharePoint and OneDrive had zero blocking rules.

  GET-LABEL HAS NO EncryptionEnabled PROPERTY. Asking for one returns empty on every label,
  which reads exactly like "nothing encrypts anything" - an earlier pass at this tenant reported
  precisely that, and it was wrong. The settings live in `LabelActions`, a collection of JSON
  documents, one per action. `EncryptionConfigured` and `EncryptionEnabled` are therefore
  separate columns: measured live, `Internal` and `Confidential` both carry an encrypt action
  and both have it switched off, which is a decision to revisit rather than work never done.

  THE `disabled` FLAG IS THE STRING `'true'`/`'false'`, and `[bool]'false'` is `$true` in
  PowerShell, so a truthiness test marks every configured action as disabled. The comparison is
  explicit and a test pins it.

  `'All'` IS AN ORDINARY MEMBER of a DLP location collection rather than a flag, so an
  estate-wide policy and a single site named "All" are indistinguishable until you inspect the
  type. `Resolve-MsecPurviewLocation` turns each workload into a `Scope` of All/Named/None plus
  a count of named locations - and the count is 0 for All, because there is no list to count and
  reading it as coverage would be backwards.

  Rule columns go `$null` rather than `0` when the rules cannot be read: on a control question,
  "no blocking rule" and "could not tell" must not look alike. Same for `IsPublished` when the
  label policies are unreadable.
- `Search-MsecDefenderHunting` - runs bundled advanced hunting KQL against the Defender XDR
  event store, completing the set alongside `Search-MsecAzureResourceGraph` and
  `Search-MsecLogAnalytics`. Nine queries under `kql/Hunting/`: SignIn (All, Failed, ByUser),
  Device (All, Logon), Email (All, Threats), Alert (All), Vulnerability (All). Every one was run
  against a live tenant before shipping rather than eyeballed.

  THE THREE SEARCH COMMANDS READ THREE DIFFERENT STORES, and the README now says so in a table.
  Advanced hunting is Defender's own lake of roughly thirty days of raw telemetry - not a Log
  Analytics workspace. Nothing a diagnostic setting routes lands there; nothing there reaches a
  workspace without the Sentinel connector.

  THE .kql FILES CARRY NO TIME FILTER. Graph's `runHuntingQuery` takes `timespan` as its own
  parameter - confirmed from `$metadata` and then live: one query returned 12 / 57 / 2245 / 6544
  rows at PT1H / P1D / P7D / P30D. Same split as `Search-MsecLogAnalytics`, and a lint test
  holds the rule for the new tree.

  AN UN-ONBOARDED TABLE FAILS TO RESOLVE RATHER THAN RETURNING ZERO ROWS, and the command
  translates that into a plain sentence naming the likely cause. "0 results" and "this product
  is not installed" reading alike is the worst failure available to a security query. Measured
  on one tenant: every `Identity*` table at zero (no Defender for Identity sensors on a managed
  domain) and `CloudAppEvents` at zero, against 2.4M rows in `AADSignInEventsBeta`.

  `-Days` is capped at 30 because that is the store's retention, not an arbitrary limit, and a
  bare-integer `-Timespan` is refused - PowerShell reads it as TICKS, so `-Timespan 7` means
  700 nanoseconds and returns nothing that looks exactly like "nothing to find".
- `Connect-MsecAdmin` - a delegated, interactive sign-in for the commands that will write.
  Reads stay on the app certificate; writes run as a named person.

  THE APP CANNOT WRITE, BY DESIGN. Every Graph permission `New-MsecApp` consents is
  `*.Read.All`, so the certificate in Key Vault cannot change anything - the module's promise
  is enforced by the token rather than by naming. Writing as a person instead makes each
  change attributable, subject to Conditional Access and MFA, bounded by that person's own
  RBAC, and impossible from an unattended pipeline by accident.

  IT IS NOT THE `-AsCurrentUser` PATTERN, AND COULD NOT BE. `Connect-MsecTeams` borrows the Az
  context's token, which works because Azure PowerShell's first-party app holds the scopes
  those commands need. Measured on a live tenant, its Graph token carries
  `Application.ReadWrite.All`, `Group.ReadWrite.All`, `Directory.AccessAsUser.All` and
  `User.Read.All` - and nothing for security. Borrowing it cannot resolve an alert, so this
  requests consent properly.

  CONSENT REQUESTED IS NOT CONSENT GRANTED. `Connect-MgGraph` succeeds when a tenant declines
  a scope - the context simply returns without it, and the first write then 403s naming
  nothing. Granted scopes are checked against requested ones at connect time and a missing one
  is reported by name.

  It also REFUSES a tenant different from the one `Connect-Msec` is reading, and closes the
  half-open Graph session on the way out. Reading one tenant and writing to another is
  invisible at the time and obvious afterwards.

  Needs `Microsoft.Graph.Authentication`, which is not a dependency of msec - only the write
  commands require it.

- `Set-MsecDefenderAlert` - resolve, classify and assign Defender XDR alerts. The first command
  that changes anything outside the module's own app registration, and it runs as you: it
  requires the `Connect-MsecAdmin` session and refuses the app one by name, because every
  permission `New-MsecApp` consents is `*.Read.All` and a write on that session can only 403.

  IT COUNTS BEFORE IT ACTS. Piped ids are buffered and the breadth check runs against the whole
  set, then writes. A guard that checks per item has already changed 25 alerts by the time it
  refuses the 26th - which is the exact failure it exists to prevent. `-MaxCount` defaults to 25;
  measured live, `Get-MsecDefenderAlert -Status new` on this tenant returns 201 rows, so
  `Get-… | Set-…` is one pipe away from a mass update.

  IT REPORTS WHAT A RE-READ RETURNED, NOT WHAT IT ASKED FOR. The PATCH response is the service
  echoing the request; a separate GET is the service being asked what the alert now is. Defender
  can accept a PATCH and not hold part of it - a determination that conflicts with the
  classification is the usual way - so every requested field is compared after the write and
  `Changed` is false when any of them did not stick. When the re-read itself fails, the `*After`
  columns are `$null` rather than the requested values: an unverified write must never render as
  a confirmed one.

  THE ENUM VALUES ARE NOT THE GUESSABLE ONES. Taken from Graph's own `$metadata`, determinations
  are `notMalicious` and `notEnoughDataToValidate`, not `clean` and `insufficientData`. And note
  the status vocabulary: the CSDL names the first member `newAlert` while the wire value is
  `new` - the wire value is what this takes and what `Get-MsecDefenderAlert` returns.

  `SupportsShouldProcess` with `ConfirmImpact = 'High'`, so a bare call prompts and `-WhatIf`
  lists the ids that would change without touching any of them.

- `Set-MsecDefenderIncident` - resolve, classify, re-grade, tag and COMMENT on Defender XDR
  incidents, with the same guards as `Set-MsecDefenderAlert`.

  THE RESOLUTION COMMENT LIVES ON THE INCIDENT, BECAUSE GRAPH HAS NO WRITABLE COMMENT ON AN
  ALERT. Checked against both `$metadata` documents and both Update alert pages: `comments` on
  `alerts_v2` is a read-only structural property, there is no comments navigation property and
  no action to add one, and neither v1.0 nor beta lists it as updatable. Incidents have
  `resolvingComment`, which Microsoft describes as explaining the resolution and the
  classification choice - so `-ResolvingComment` is the supported way to record why something
  was closed, and alerts roll up into incidents anyway.

  `-CustomTags` REPLACES the tag array rather than appending - that is Graph's behaviour for a
  collection property, not a choice made here. The command reads the incident first and warns,
  naming the tags about to be dropped, before the write rather than after.

  `redirected` is deliberately absent from `-Status`: Defender assigns it when it merges an
  incident into another, and offering it would imply this command can merge incidents. On the
  other side, `inProgress` and `awaitingAction` ARE offered - they are in `$metadata` even
  though the Update incident doc lists only active, resolved and redirected.

  `displayName`, `summary` and `description` are updatable through Graph but are not exposed:
  they are the incident's narrative rather than a triage decision, and rewriting them from a
  pipeline is a good way to lose Defender's own text.

### Fixed
- `Get-MsecIntuneCompliancePolicy` returned only name, platform, type and assignment count - so
  a policy that ENFORCES NOTHING was indistinguishable from a healthy one, which is the single
  most misleading thing a compliance-policy list can do.

  A policy with no settings configured reports every device as compliant, because there is
  nothing to fail. Measured live: a macOS baseline assigned to all licensed users since 2021,
  with `osMinimumVersion` empty and password, encryption, firewall and system-integrity all
  false, showed 17 of 19 devices compliant - including two on an unsupported major version. The
  same tenant's properly configured macOS policy, with 11 checks and a minimum version, was
  assigned to nobody. From the old output the two looked equally fine.

  Rows now always carry `OsMinimumVersion`, `ConfiguredCheckCount`, `ChecksNothing` and
  `ConfiguredChecks`, and `-IncludeSettings` attaches every setting. None of it costs an extra
  API call - the list endpoint already returned all 26 properties and the command was throwing
  them away.

  WHAT COUNTS AS "CONFIGURED" IS WRITTEN DOWN, in `Get-MsecCompliancePolicyCheck`, rather than
  guessed at: a boolean counts only when true (false means "not required", not "required to be
  false"); a string counts unless it is one of Graph's do-nothing sentinels (`deviceDefault`,
  `unavailable`, `notConfigured`, `userDefined` - measured, those account for nine of fourteen
  string values on one tenant); a number counts only when non-zero. The test is deliberately
  generic rather than a per-platform allowlist, because Microsoft adds compliance settings and
  an allowlist would silently stop counting them.
- `Assert-MsecExoCmdlet` said an absent cmdlet meant the TENANT lacked the feature. It does not:
  the compliance endpoint imports cmdlets per IDENTITY, based on Purview role groups, so a
  cmdlet missing from an app-only session says nothing about whether the feature exists or is in
  daily use by people in the portal.

  THE OLD WORDING PUT A FALSE STATEMENT INTO A COMPLIANCE REPORT. Measured on one tenant:
  `Get-ComplianceSearch`, `Get-InsiderRiskPolicy` and `Get-SupervisoryReviewPolicyV2` were all
  absent from the app session, while `eDiscoveryManager`, `InsiderRiskManagement` and
  `CommunicationCompliance` each had three members and were actively used. Inferring "we do not
  have eDiscovery" from that is the kind of error that is worse than no report at all, because
  it reads as evidence.

  The message now says the feature may well be in use, that it is a role-group problem rather
  than an API permission one, that granting an API permission will not help, and that the fix is
  to add the identity to the matching view-only Purview role group. "Not measurable from here"
  replaced "not measurable" - the qualifier is the whole point.
- `Get-MsecPurviewDlpPolicy` and `Get-MsecPurviewAutoLabelingPolicy` reported the wrong name for
  any policy that had been renamed, so the output did not match the Purview portal and a reader
  could not find the policy being described.

  A DLP POLICY HAS TWO NAMES. Renaming one changes its `DisplayName` and leaves `Name` at
  whatever it was created as, so they drift apart the moment anyone tidies a name up. Measured
  live on one tenant, two of eight had drifted: the portal's `DLP - Confidential document shared`
  is still `TEST - Label-based DLP (pilot)` underneath, and `DLP - Passwords` is still
  `DLP - Passwords - Teams + SharePoint/OneDrive`. `Name` now carries the display name, with
  `InternalName` beside it and a `Renamed` flag; `-Name` matches either, because a portal reader
  and a script author know different strings.

  THE RULE JOIN STILL USES THE INTERNAL NAME, and that is not incidental. `ParentPolicyName`
  tracks `Name`, never `DisplayName` - measured at 10 of 10 rules, matching the display name only
  where the two happened to be equal. Switching the join to the display name would silently drop
  the rules of every renamed policy, and `RuleCount = 0` reads as "this policy has no
  conditions". A test pins both halves: the row shows the display name, the join finds the rule.
- The `Get-MsecPurview*` commands now say a tenant CANNOT BE ASKED rather than returning nothing
  when the feature is absent. The compliance endpoint imports only the cmdlets a tenant is
  licensed for and the connecting identity's role group allows, so on a tenant without DLP or
  labels the cmdlet is simply not there - measured on a fully working tenant,
  `Get-ComplianceSearch`, `Get-InsiderRiskPolicy` and `Get-SupervisoryReviewPolicyV2` are all
  absent while the DLP and label ones are present.

  Calling one anyway raised `CommandNotFoundException` - "The term X is not recognized" -
  surfacing from a `Get-Msec*` command as though the module were broken. Worse would have been
  catching it and returning an empty result: "this tenant has no DLP policies" and "this tenant
  cannot be asked" are opposite conclusions on a compliance report, and only one of them is
  true. `Assert-MsecExoCmdlet` names the cmdlet, says it is a capability limit rather than a
  missing API permission (so nobody spends an afternoon granting one), and states plainly that
  it is not the same as "none are configured".

  `Get-MsecPurviewRetention` checks per half and only for the half being read, so a tenant that
  exposes retention labels but not retention policies can still answer `-Kind Label` - and the
  error for the other half says so.
- A workload session is now reused only when it belongs to the tenant the msec session is
  currently on. It previously matched on "is something connected to this endpoint", which is
  wrong the moment anyone switches tenant: `Connect-Msec` to tenant B after using Purview or
  Exchange on tenant A left the old session live, and the next command happily read TENANT A'S
  DATA and reported it under tenant B's name. Nothing about that looks like an error, which is
  what makes it worth a test rather than a comment. `Get-ConnectionInformation` carries
  `TenantID`, so the comparison was available all along.

  A stale session is CLOSED, not left alongside a new one - two live sessions let the cmdlets
  pick between them invisibly, turning a consistently wrong tenant into an intermittent one. The
  warning names both tenants.

  Identity is deliberately NOT part of the check. A caller who signed in as themselves has
  rights the app lacks, and reconnecting as the app would quietly remove them - the trap
  `Get-MsecTeamsPolicy` already avoids with its `-AsCurrentUser` guard. Tenant is the
  correctness question; a different `AppId` on the right tenant is only noted verbosely.

### Changed
- `tools/Grant-MsecAzureDevOpsPermission.ps1` is now the `Grant-MsecAzureDevOpsPermission`
  command, shipped with the module.

  THE HELP POINTED AT A FILE NOBODY HAD. `tools/` sits outside the module folder, so it is not
  published - but four places referenced it, including the 403 guidance in
  `Get-MsecAzureDevOpsRepository` and `Get-MsecAzureDevOpsServiceConnection`. Anyone who
  installed from the Gallery, hit a permissions error and followed the help was sent to
  `./tools/Grant-MsecAzureDevOpsPermission.ps1`, which did not exist on their machine.

  Its stated reason for living outside was "msec is read-only and this WRITES". That premise was
  removed by `Connect-MsecAdmin` and the `Set-*` commands, and `New-MsecApp` already ships a
  setup command that writes considerably more - it creates an app registration, grants API
  permissions and assigns directory roles.

  THE PERSONAL ACCESS TOKEN IS GONE. It took a PAT; it never needed one. The security namespace,
  access control list and identity APIs all accept an ordinary Entra token for the Azure DevOps
  resource - verified against all three before the parameter was removed. A PAT is a long-lived
  credential, and asking people to create one for a setup task is worse than using the sign-in
  they already have. That also makes the command single-identity, which is now the module's rule.

  It runs as the SIGNED-IN USER rather than as the app, deliberately: the app is usually the
  grantee, and an identity that could grant itself permissions would make the exercise circular.

  `-Apply` is replaced by the standard `-WhatIf` / `-Confirm` with `ConfirmImpact = 'High'`, and
  the list modes emit objects instead of `Write-Host`, so `-ListPermissions` and `-ListRoles`
  can be filtered and exported like every other command's output.
- `Get-MsecExchangeMailboxPermission` now opens its Exchange session on first use, which was the
  last command in the module still demanding a manual connect. `Get-MsecTeamsPolicy` and
  `Get-MsecSharePointSiteUser` already connected themselves, and the Purview commands now do -
  Exchange was the odd one out rather than the rule.

  Its connected-check was also wrong: `Get-Command Get-EXOMailbox` answers whether the MODULE IS
  INSTALLED, not whether anything is connected. It returned true on a machine that had never
  signed in, and every call after it then failed on transport instead of on a sentence.

- `Connect-MsecExchangeOnline -Organization` is now optional, resolved from Graph like
  `Connect-MsecPurview` - shared as `Get-MsecTenantDomain`, since the app already holds
  `Organization.Read.All`. A mandatory argument the caller rarely has to hand was the only
  reason Exchange could not connect itself.

- Exchange and Purview now share one session initializer, `Initialize-MsecExoSession -Endpoint`.
  They differ only in endpoint and connect cmdlet, and the part that is easy to get wrong - the
  tenant check - must not exist in two copies. `Get-MsecExoConnection` keeps the two endpoints
  apart; they come from one module and differ only by URI, which carries a regional prefix
  (`eur01b.ps.compliance...`), so the match is a substring by design.
- `Set-MsecDefenderAlert` now reports comment refusals ONCE per run instead of once per alert,
  and hands over the command that does work. Every non-endpoint alert fails the same rule, so a
  near-identical warning per row buried the ones that were actually specific to an alert. The
  summary names the count and the serviceSource, then gives the exact follow-up with the
  incident ids collected from the alerts themselves:

      WARNING: 3 alert(s) did not take a comment: serviceSource unknownFutureValue, and the
      Defender for Endpoint API only knows endpoint alerts. ... Put the note on their
      incident(s) instead: Set-MsecDefenderIncident -Id 5846,5901 -ResolvingComment '...'

  `CommentAdded` is still `$false` on each row, so nothing is dropped quietly - the per-row fact
  is in the object, and the warning stream carries the instruction rather than the repetition.
- The post-write verification in `Set-MsecDefenderAlert` and `Set-MsecDefenderIncident` now waits
  for Defender XDR to settle instead of reading once, immediately.

  IT WAS REPORTING FAILURES THAT HAD NOT HAPPENED. Observed live: an alert PATCHed successfully
  at 16:37:00 - status, classification and assignedTo all applied - read back as unchanged when
  the verification GET fired right behind the PATCH, producing "did not keep: status,
  classification, assignedTo" for a write that had entirely worked. XDR is eventually consistent;
  the re-read was simply too early. This is the same class of bug the re-read exists to catch,
  running backwards, and it is arguably worse: a check that cries wolf teaches people to ignore
  it, which costs more than never having checked.

  The read-back now polls on a bounded budget (immediate, then 2s, 3s, 5s) and stops the moment
  every requested field matches, so the normal case costs nothing. A warning is raised only when
  a value is still wrong after the last attempt, and its wording changed from "did not keep" to
  "still does not show ... after N reads" to say what was actually observed. Extracted to
  `Get-MsecAdminWriteResult` so both commands verify identically; collection properties such as
  `customTags` compare as joined strings, which removed the incident command's bespoke branch.

- `Id` is back in the default columns for alert change rows. It was dropped when `ServiceSource`
  and `CommentAdded` were added, which made a row impossible to match to the warnings printed
  beside it - the failure that surfaced the bug above. `ServiceSource` moved out of the default
  table to make room; `Select-Object *` still has it.
- `Set-MsecDefenderAlert` gains `-Comment`, correcting an earlier claim in this changelog that a
  comment could not be written to an alert at all. That was wrong: it is not a MICROSOFT GRAPH
  operation, but the Defender for Endpoint API has one, and its docs state a comment may be
  submitted with or without updating any other property. This is the field the portal's "Classify
  alert" box writes.

  The comment goes to `PATCH /api/alerts/{providerAlertId}` on the Defender host while status and
  classification continue to go to Graph. Splitting them keeps the two vocabularies apart - the
  Defender API spells determinations `InsufficientData` and `CompromisedUser` and statuses
  `Resolved`, against Graph's `notEnoughDataToValidate`, `compromisedAccount` and `resolved` - so
  nothing has to translate between them.

  IT ONLY COVERS ENDPOINT ALERTS. Measured live, that API returns 29 of 569 alerts over ninety
  days; the rest are Defender for Office 365, DLP and serviceSource `unknownFutureValue`.
  `-Comment` on one of those is refused by name, naming the serviceSource and pointing at
  `Set-MsecDefenderIncident -ResolvingComment`, rather than being silently dropped. The portal
  works on all of them because it uses an unpublished internal API.

  Authentication differs too: the Defender host will not take a Graph token, so the comment is
  written with an Az-context token carrying `user_impersonation` - bounded by the caller's own
  'Alerts investigation' role. The app registration still cannot write; it holds only
  `Score.Read.All`, `Machine.Read.All` and `Vulnerability.Read.All` on Defender.

  `CommentAdded` reports whether the comment was found in the thread on re-read - `$null` when
  not requested or not verifiable, `$false` when refused or absent, never `$true` merely because
  a PATCH returned 200.

- `Get-MsecDefenderAlert` now returns `ProviderAlertId`, the alert's id in the product that
  raised it. It is the key the Defender API needs, and was previously read from Graph but dropped.

- A failed Graph PATCH in `Set-MsecDefenderAlert` now emits a row with `Changed = $null` instead
  of emitting nothing. With a comment in play a write is no longer all-or-nothing - the comment
  can land while the Graph fields do not - and a row plus a warning beats silence a pipeline
  swallows. `$null` rather than `$false`: the change was never verified, not observed to fail.
- Documented, in `Set-MsecDefenderAlert`'s help, that Microsoft's Update alert page still lists
  the retired determinations `clean` and `insufficientData` for the enum shared with incidents.
  `$metadata` and the Update incident page both give `notMalicious` and
  `notEnoughDataToValidate`, which is what both commands accept - the note exists so nobody
  "corrects" the ValidateSet from the stale page.

### Changed
- The `Get-MsecPurview*` commands now open their compliance session themselves on first use, so
  `Connect-Msec` is all a caller needs. `Connect-MsecPurview` stays public and is now optional -
  use it to pass a specific `-Organization`, or to choose when a few hundred compliance cmdlet
  names land in the runspace - measured at 102, none clashing with the ExchangeOnlineManagement
  module's own exports.

  Requiring a manual connect for exactly one area of the module was an implementation detail
  leaking into the interface. It is not an identity difference - Purview uses the same Key Vault
  certificate as every other command - it is that this endpoint has no usable per-request REST
  model. Calling `/adminapi/beta/{org}/InvokeCommand` directly with the app token was tried:
  it authenticates (500s, never 401 or 403) and then fails on `orgUnit` routing state that only
  the module's handshake establishes, which is undocumented internal plumbing no published
  module should depend on.

  THE CONNECT IS REPORTED, NOT SILENT. The handshake takes about nine seconds and imports
  hundreds of cmdlets; a `Get-` command doing that quietly reads as a hang. `Write-Progress`
  says what is happening, stays out of the pipeline and clears itself. Measured end to end:
  ~15s for the first call, ~5s for each one after, and a test pins that a second call does not
  reconnect.
- `-MaxCount` is REMOVED from `Set-MsecDefenderAlert` and `Set-MsecDefenderIncident`. It capped a
  run at 25 objects and refused the whole pipeline above that, which got in the way of the
  bulk triage these commands exist for. There is now no cap: the pipeline writes everything the
  filter selected.

  What still stands between a broad filter and a mass update is `ConfirmImpact = 'High'`, which
  prompts per object on a bare call, and `-WhatIf`, which lists every id it would touch and
  changes nothing. `-Confirm:$false` turns off the prompt, so `-WhatIf` is worth running first on
  any pipeline you have not run before.

  Ids are still collected before the first write rather than acted on as they arrive - that was
  also what made the cap possible, but it independently ensures a duplicated id is written once.
- The module description and README no longer say "read-only by design" without qualification.
  The app registration is still read-only and that is what the promise was always about, but
  with a write command in the box the accurate statement is that the *certificate* cannot change
  your tenant, and writes run as a signed-in person.

### Added
- `Get-MsecDefenderIncident` and `Get-MsecDefenderAlert` - the row-level view of Defender XDR.
  `Get-MsecDefenderIncidentStats` already answered "how many, how severe, how fast"; these
  answer "which ones".

  REDIRECTED INCIDENTS ARE THE SAME ATTACK TWICE. Defender merges incidents it decides are one
  attack, leaving the absorbed one with status 'redirected' and a RedirectedToIncidentId.
  Measured live: 51 of 474 in ninety days, so a naive count overstates by 12%. They are
  returned by default with the merge target named, and `-ExcludeRedirected` drops them - an
  incident that silently vanished from a count would have no explanation.

  SERVICESOURCE IS OFTEN 'unknownFutureValue', WHICH IS GRAPH, NOT THE DATA. It is the enum
  placeholder for a source this API version has no name for - measured live, 231 of 569 alerts,
  40%. Passed through verbatim rather than folded into 'other' or guessed at; ProductName and
  DetectionSource are carried alongside and are usually populated when it is not.

  THE TWO STATUS VOCABULARIES DIFFER. An alert is new/inProgress/resolved; an incident is
  active/inProgress/resolved/redirected. An alert is never 'active'. Filtering both with one
  string finds nothing in one of them, silently, so the two ValidateSets differ and a test
  asserts it.

  ResolveDays is `$null` while an item is open, never 0 - zero reads as "closed instantly",
  the opposite of a running investigation. Alert evidence is counted rather than flattened:
  the shape differs per entity type, so the array stays on `Raw.evidence`.

  Measured live on a 90-day window: 474 incidents (128 active), 569 alerts (21 high and still
  new), and every single incident classified 'unknown' - which measures triage effort rather
  than the incidents.
### Added
- `Search-MsecAzureResourceGraph -ResourceType SqlServer` - Azure SQL logical servers and the
  settings that decide who can reach them and who can authenticate: public network access, the
  SQL authentication admin login, the Entra admin and its principal type, Entra-only
  authentication, and minimum TLS. `-Name Databases` lists the databases on each server with
  their server's FQDN.

  THE SQL ADMIN LOGIN IS NOT AN ENTRA IDENTITY. It lives in the server's own master database,
  is authenticated by password, bypasses Conditional Access and MFA, never appears in Entra
  sign-in logs, is shared rather than per-person, and cannot be deleted - only disabled
  wholesale by turning on Entra-only authentication. Measured live: three servers, none with
  Entra-only auth set, so the shared login was live on all three; one of them had no Entra
  admin configured at all, making SQL authentication the only way in.

  A SERVER HAS A SINGLE ENTRA ADMIN SLOT and setting it REPLACES the previous holder, so a
  server whose admin is a named person loses all Entra-authenticated administration the day
  that person leaves - and only an Entra-authenticated connection may create Entra database
  users. Measured live: one server's admin was a user whose account had been disabled two
  months earlier, which left nobody able to create a database user at all.

  RESOURCE GRAPH LAGS ARM. Minutes after an Entra admin was changed, this query still returned
  the previous holder even with `-NoCache`, while ARM and live connections already reflected
  the change. Noted in the query rather than worked around.

  Auditing settings are deliberately absent: they are a child resource Resource Graph does not
  project, like MySQL's firewall rules.
### Added
- `Get-MsecDefenderDevice -OnboardingStatus` and the same passthrough on
  `Export-MsecDefenderDeviceReport`, because a Defender inventory is mostly NOT onboarded
  devices and nothing said so.

  Defender's device DISCOVERY returns things it merely saw on the network - phones, printers,
  unmanaged laptops - from the same API as real endpoints. Measured on a live tenant:

      total             717
      Onboarded         217   Defender is protecting these
      InsufficientInfo  209   discovered
      CanBeOnboarded    178   discovered
      Unsupported       113   discovered

  So the evidence report ran three times the size of the protected estate, and 164 of those
  rows had NO DEVICE NAME AT ALL - every unnamed one discovered rather than onboarded. The
  command's own synopsis said "every device onboarded to Defender for Endpoint", which was
  simply untrue; it is corrected.

  NOTHING IS FILTERED BY DEFAULT. An unmanaged laptop on the corporate network is a finding in
  its own right and CanBeOnboarded is a worklist - they answer a different question from the
  one an exposure report asks, which is not the same as being noise. Pass
  `-OnboardingStatus Onboarded` for the protected estate.
### Fixed
- `Get-MsecEntraMfaRegistrationStats` and the posture report's `MfaCoverage` sheet divided
  every coverage percentage by the WHOLE directory, so guests diluted them. On a live tenant
  of 177 members and 202 guests the report claimed 44.33% SSPR coverage and 61.48% MFA
  coverage, against true member figures of 94.92% and 95.48% - understating recovery coverage
  by more than fifty points.

  The two errors differ in kind. A guest CAN be MFA-capable and some are, so the all-user MFA
  number was blunt. A guest resets their password in their HOME tenant and so can essentially
  never be SSPR-capable in yours - measured, 0 of 202 - which made every guest dead weight in
  that denominator.

  `NotMfaCapable` was the worst of them, because it is a COUNT of a problem rather than a
  percentage: it read 146 where the true member figure is 8. "146 users cannot do MFA" is a
  sentence somebody repeats in a meeting, and it was wrong by a factor of eighteen.

  Added `MembersMfaCapablePercent`, `MembersSsprCapablePercent`,
  `MembersPasswordlessCapablePercent`, `MembersMfaCapable`, `MembersNotMfaCapable`,
  `MembersSsprCapable` and `GuestsSsprCapable`. The last one exists so a reader can SEE that guests contribute nothing
  to SSPR rather than taking it on trust.

  THE ALL-USER COLUMNS ARE KEPT. The posture report is a time series and removing them would
  strand the history already in every workbook. The dashboard chart now plots the member-scoped
  series; existing charts keep their old lines as well, because chart series are added but
  never removed.
### Added
- `Search-MsecAzureResourceGraph -ResourceType ResourceChange` - what changed on Azure resources
  in the last 14 days, who changed it and through which client. `-Name Properties` expands one
  row per changed PROPERTY with the previous and new values, which is what answers "who changed
  this setting, and what was it before".

  FOURTEEN DAYS IS A HARD CEILING and there is no setting to extend it. An empty result for last
  month is "out of retention", not "nothing changed" - for longer, the Activity Log keeps 90 days.

  IT IS A SNAPSHOT DIFF, NOT AN AUDIT LOG. Two changes between snapshots collapse into one, and a
  change reverted before the next snapshot leaves no trace. The Activity Log stays authoritative
  for who called what.

  Attribution is carried through as it comes: `ChangedByType` is 'User', 'Application', 'System'
  or 'Unspecified' and is NOT normalised, because "Azure did it" and "nobody recorded who did it"
  are different answers. Measured live: 1,848 Application, 580 System, 490 User, 46 Unspecified
  over 14 days. Platform churn is left in rather than filtered, since "the platform restarted
  this" is a real answer - filter on `ChangedByType` to get to changes a person made.

  Patch orchestration is covered: `patchMode` is on the VM resource body, so moving a machine
  between 'Windows Automatic Updates' and an Azure-orchestrated mode is diffed like any other
  property, whichever tool did it.

  `mv-expand` in the Properties query sets an explicit `limit 2000`. Resource Graph's default
  RowLimit is 128 and truncates silently; the largest record measured carried 48 properties, so
  the limit exists to make truncation impossible rather than merely unlikely. The repo's lint
  test now covers this folder.
### Added
- `Get-MsecAzureDomainService` - every Microsoft Entra Domain Services managed domain, the security
  settings that decide what its authentication may look like, and where its security audit logs
  go. A managed domain exists so that things which cannot speak modern protocols - VPN
  concentrators, RADIUS, file servers - can authenticate people's ordinary Entra accounts over
  Kerberos, NTLM and LDAP. That is also the whole security question.

  A MANAGED DOMAIN SHIPS WITH ITS WEAK SETTINGS ON: NTLM v1, RC4 Kerberos and unsigned LDAP are
  enabled by default, and NTLM password hashes are synchronised in by default. None of it is a
  change anybody made, which is why it survives review - there is nothing in a change log to
  find, and the portal spreads nine toggles across two blades. `WeakSettings` names the ones
  currently in the weak state in one string. Measured live: six of them.

  `AuditLogsEnabled` is `$false` when security audit is off - the default, and a finding, since
  a managed domain keeps no local store to go back to - and `$null` when the diagnostic settings
  could not be read, which is a permission problem rather than a finding.

  `AuditLogWorkspace` is the workspace NAME, because that is what `Search-MsecLogAnalytics
  -WorkspaceName` takes and the workspace a managed domain writes to is not guessable.

- `Search-MsecLogAnalytics -Subject DomainServices` - the other half: what the managed domain's
  authentication actually looked like. `-Name All` gives one row per credential validation
  (Kerberos 4768/4771, NTLM 4776, failed logons 4625) with the account, client address, outcome
  and decoded reason; `-Name Accounts` summarises the same rows per account for an access
  review; `-Name Sessions` summarises the logon-session events server-side.

  SUCCESS AND FAILURE SHARE AN EVENT ID. 4776 is emitted whether the password was right or
  wrong, and the outcome is a status code inside the message TEXT - not the event id, not a
  column. Counting 4776 rows counts attempts, not logons. Measured live: 942 of them, of which
  725 succeeded, 378 were an unknown user name, 19 a wrong password, 7 a locked-out account and
  2 a disabled one.

  KERBEROS AND NTLM STATUS CODES ARE DIFFERENT CODE SPACES and are decoded separately. 0x18 is
  a Kerberos pre-authentication failure (wrong password) and is not an NT status code at all;
  0xC000006A is the NTLM wrong-password status and is not a Kerberos result code. One shared
  lookup would mislabel every row of whichever protocol it was not written for.

  `-Name All` deliberately does NOT read event 4624. On a managed domain that is the domain
  controllers' own session churn - 1,088,013 rows in thirty days against 2,673 credential
  validations - which would bury the answer and blow the API's 500,000-row cap. `-Name Sessions`
  reads those, summarised server-side.

  Machine accounts are labelled `AccountType` 'Computer' rather than dropped - and labelled
  rather than flagged with a boolean, because the Log Analytics API is untyped on the wire and
  every column reaches PowerShell as a string. A boolean column arrives as the string 'false',
  which is non-empty and therefore TRUE in a condition, so `Where-Object { -not $_.IsMachine }`
  would return nothing at all, silently. 'User' and 'Computer' compare the way they read.

- `Search-MsecAzureResourceGraph -ResourceType DomainServices` - the managed domain settings on
  their own, without the audit-log lookup `Get-MsecAzureDomainService` adds.
### Added
- `Export-MsecAzureDevOpsReport` - a whole Azure DevOps organization's security posture in one
  workbook. A sheet per area (repositories, alerts, service connections, variable groups, secure
  files, environments, agent pools, extensions, pipeline settings, organization policies, users),
  a Summary counting each area by category, and a Dashboard of fourteen charts laid out one per
  printed page.

  A SNAPSHOT, NOT A TREND: every sheet is replaced on each run. That is the opposite of
  `Export-MsecPostureReport`, which appends a row per run to build a time series.

  A FAILED AREA GETS NO CHART. A chart of zeros and no chart at all say different things -
  "measured, found none" against "could not measure" - and Azure DevOps permissions are granted
  per area, so a 403 on one area is the normal case rather than the exceptional one. Failures
  land on a RunLog sheet with the message that caused them, and every other area still writes.

  Two of the charts are deliberately NOT partitions: on pipeline settings and organization
  policies each bar is an independent measurement, so a project appears under every risk it
  carries and the bars must not be summed. They are drawn as horizontal bars so they read
  differently from the eleven that do partition.

  Categories are fixed and always present at zero, so two runs' charts line up; a value no
  category was written for is added as its own bar rather than folded into 'Other'.

  Alerts are charted by TYPE as well as severity. Azure DevOps rates every secret alert
  critical, so an organization running secret scanning alone fills the critical bar and leaves
  the other four severities empty - which reads as "no medium or low findings" when it means
  "no scanner that emits them is switched on". Measured live: 300 alerts, all of them secrets.

  Measured live on a 36-project organization: 215 repositories, 82 with no reviewer requirement
  and 49 without secret push protection; 243 service connections, of which 153 authenticate with
  a service principal secret against 61 federated, and 43 are open to every pipeline in their
  project; 77 variable groups holding secrets; 50 environments with no checks; 36 projects
  without shell argument sanitising; and 169 of 292 members who are local Azure DevOps accounts
  rather than Entra identities. Public projects are allowed at organization level.

- `Get-MsecAzureDevOpsSecureFile` - the certificates, keystores and private keys stored in a
  project's pipeline library, with their age and which pipelines may use them. Secure files are
  where signing material ends up when it cannot be put in a variable group, and nothing in Azure
  DevOps expires or reviews them.

  THE CONTENTS ARE NEVER FETCHED. There is a download endpoint and this command does not call
  it - an inventory of private keys that reads the private keys to produce itself would be worse
  than no inventory at all. Everything reported comes from the file's metadata and its pipeline
  permissions.

  `Kind` is a guess from the file extension and is documented as one, so `Name` is always
  reported alongside it - a `.key` can be anything, and on a live organization most of them were
  empty migration markers rather than key material.

  Measured live: 9 secure files across an organization, none open to all pipelines. Eight were
  `.key` migration markers uploaded between 875 and 1479 days ago and never removed; the ninth
  was a `fullchain.pfx` certificate.
## [0.3.0] - 2026-09-09

### Added
- `Get-MsecAzureDevOpsEnvironment` - deployment environments, the checks guarding them, who
  approves, and whether any pipeline may deploy to them. An environment is what a pipeline
  deploys TO, and its checks are the last thing between a run and production.

  NO CHECKS IS THE FINDING, and it looks like nothing. An environment with none configured
  reports `CheckCount` 0; one whose checks could NOT be read reports `$null`, and `-Unchecked`
  excludes the second - otherwise a list of unguarded targets fills up with ones that may be
  perfectly protected.

  An approval check with no approver named on it is reported as having an approval and an
  `ApproverCount` of 0, because it is not the protection the check count implies. Approvers
  configured as a group are reported as the group; who is in it is `Get-MsecAzureDevOpsUser`.

  Measured live: 71 environments, 50 with no checks at all, 21 with an approval, one approval
  with nobody on it, and three unchecked environments open to every pipeline in their project -
  one of them named CN-PROD.

- `Get-MsecAzureDevOpsOrganization` - every Azure DevOps organization connected to the Entra
  tenant, with its owner. Anyone in a tenant can create one and nothing announces it, so the
  result is organizations nobody reviews: created for a trial, owned by one person, holding
  repositories and service connections no governance process knows about. Measured on a live
  tenant: 28 organizations, most named after individuals, several owned by people with two each.

  THIS IS THE COMMAND THAT TELLS YOU WHAT TO POINT THE OTHERS AT. Every other
  `Get-MsecAzureDevOps*` command takes `-Organization`, and its answer is only as complete as the
  list of organizations somebody thought to check.

  THE ENDPOINT IS INTERNAL and returns CSV rather than JSON - it is the route behind the Azure
  DevOps organization list in the Entra admin portal, and there is no documented equivalent. An
  empty result warns rather than reporting a tenant with no organizations, because a changed
  route is far likelier than an empty tenant and would otherwise end an investigation that should
  have started.

- `Get-MsecAzureDevOpsPipelineSetting` - the project-level switches that decide what a pipeline
  may do: fork builds and whether secrets reach them, job authorization scope, referenced-repo
  scoped tokens, settable variables at queue time, and shell argument sanitising. They are set
  once per project and not visible from a pipeline definition, so a well-governed repository can
  sit in a project that lets a fork's build read its secrets.

  THE FORK SETTINGS ARE REPORTED SEPARATELY rather than as one verdict, because which half is
  wrong decides what to fix. `SecretsWithheldFromForks` is named for the SAFE state; the
  underlying field, `enforceNoAccessToSecretsFromForks`, is a double negative that reads
  backwards easily, and a test pins the mapping.

  `OtherSettings` names any setting without a column, with its value. On the first run against a
  live organization it surfaced `enforceReferencedRepoScopedToken`, which varied between projects
  and has since been promoted to a column of its own - the catch-all working as intended.

  Measured live across 36 projects: 11 allow fork builds and all 11 withhold secrets from them;
  13 do not limit job authorization scope; 12 allow settable variables at queue time; and none
  have shell argument sanitising enabled.

- `Get-MsecAzureDevOpsVariableGroup` - variable groups across an organization: how many variables
  and how many of those are secret, whether the group is backed by a Key Vault, how many projects
  it is shared with, and whether ANY pipeline in the project may reference it.

  THE COMBINATION IS THE FINDING, not the presence of secrets. Secrets in a group, open to every
  pipeline, in a project whose repositories require no reviewer, means anyone who can push can
  author a pipeline that reads them. Measured against a live organization: 114 groups, 77 holding
  secrets, 13 open to all pipelines, and 11 that are both - several with 18 to 21 secrets each.

  VALUES ARE NEVER EMITTED. Secret values are not returned by the API at all; NON-secret values
  are, and are dropped deliberately - this output goes into mailboxes and spreadsheets, and
  pipeline variables carry connection strings often enough that copying them into a report is a
  poor default. Variable and secret NAMES are kept, because knowing a group holds
  `AZURE_CLIENT_SECRET` is the point.

  A Key Vault-backed group counts as holding secrets under `-WithSecrets` even though it declares
  none of its own: everything it exposes is one, fetched from the vault at run time.

- `Get-MsecAzureDevOpsAgentPool` - agent pools, whether they are Microsoft-hosted or run on your
  own machines, whether every new project gets them automatically, and what the agents in them
  are. A self-hosted agent executes pipeline code on a machine you own and keeps its disk between
  jobs, so anyone who can queue against the pool can run code there and leave things behind.

  AGENT VERSIONS AND OPERATING SYSTEMS ARE DISTINCT LISTS, not summarised. A live pool held
  agent versions 2.213.2, 3.244.1 and 4.264.2 at once, on Windows builds 14393, 19044 and 19045 -
  an average or a maximum would have hidden the agent two majors behind, which is the one worth
  finding.

  AN OFFLINE AGENT THAT IS STILL ENABLED IS COUNTED SEPARATELY from a disabled one: it will
  rejoin and start taking jobs when it comes back, which is not the same as decommissioned.

  `LongestOfflineDays` says how long the most absent ENABLED agent has been gone. Measured live:
  731 days in one pool and 2261 - over six years - in another, both still enabled. A count of
  offline agents does not convey that; the age does. Disabled agents are excluded, because they
  will not come back.

  `-IncludeExposure` maps which projects can queue work on each pool today, and which of them let
  ANY pipeline do so without approval - the same "grant access to all pipelines" trap service
  connections have. `AutoProvision` answers the question for FUTURE projects; this answers it for
  the ones that already have it. Measured live: three self-hosted pools reachable from all 36
  projects, one of them open to every pipeline in a project.

  A hosted pool reports 0 agents without being asked - it has none to enumerate - while a pool
  whose agents could not be read reports `$null`. `-IncludeSecurity` adds the pool role counts
  and needs `View` on the `DistributedTask` namespace; without it those columns are `$null`.
  Both switches are opt-in because each costs calls: exposure is one per project plus one per
  queue.

- `Get-MsecAzureDevOpsExtension` - marketplace extensions installed in an organization and the
  access each one holds. An extension is third-party code running inside the organization with
  delegated access to it; the scopes granted at install are permanent until someone uninstalls
  it, apply organization-wide, and nothing prompts a review afterwards.

  `Access` groups the scopes - Manage (`*_manage`), Write (`*_write`, `*_execute`), Read, None -
  and that grouping is the command's JUDGEMENT, not something the API states, so the raw `Scopes`
  are always returned beside it. A scope this module has never seen still appears there.

  A disabled extension is kept: disabling does not revoke its scopes, and re-enabling asks nobody
  to consent again. `IsMicrosoftPublisher` is a column rather than a filter - Microsoft-published
  is not the same as safe, and judging the publisher is the reader's job.

  Verified against a live organization: 50 extensions, 7 third-party, and two holding manage
  scopes - `vso.code_manage` and `vso.serviceendpoint_manage`.

- `Get-MsecAzureDevOpsRepository` - every Git repository with the protections on its default
  branch: minimum reviewers, whether the author's own vote counts, build validation, merge
  strategy, secret push protection, and Advanced Security state. Verified against a live
  organization: 215 repositories across 31 projects, 116 of them requiring no reviewer at all.

  A POLICY ONLY COUNTS IF IT IS ENABLED AND BLOCKING. Azure DevOps allows enabled-but-advisory
  policies that appear in a pull request and stop nothing; counting those as protection would
  overstate the posture.

  `-Unprotected` means NO REVIEWER REQUIREMENT, not "no blocking policy". On a real organization
  every repository had at least one blocking policy, because a single project-wide
  secrets-scanning rule applied to all of them - by that measure nothing was ever unprotected,
  which is true and useless. The reviewer requirement is what decides whether a human sees the
  change.

  EVERY CONTROL THE POLICY API EXPOSES IS REPORTED, not only the ones a given tenant happens to
  use. Alongside the minimum reviewer count: named required reviewers, whether the last pusher
  may approve, whether votes and rejections survive a push, whether approval must be on the final
  iteration, downvotes, comment resolution, work item linking, merge strategy, file size limit,
  and the Advanced Security features. A tenant where a control is uniformly set is not a reason
  to drop the column - the module is not written for one tenant.

  `OtherPolicies` NAMES ANY BLOCKING POLICY TYPE WITHOUT A COLUMN. Azure DevOps adds policy types
  and organizations write custom ones, so a report with a column per known type silently drops
  the rest. This surfaced `Reserved names restriction` and `Path Length restriction` on the first
  run against a live organization - neither had appeared in a twelve-project sample.

  Policies are read once per PROJECT rather than once per repository, and a project whose
  policies cannot be read reports `$null` rather than 0 - a 403 must not make its repositories
  look unprotected.

- `Get-MsecAzureDevOpsAlert` - Advanced Security alerts across an organization: secret,
  dependency and code scanning findings, one row per alert with severity, state, confidence,
  file path and how long it has been sitting there. Verified against a live organization: 172
  active critical secret alerts across 45 repositories, the oldest 41 days old.

  THERE IS NO ORGANIZATION-WIDE ALERTS ENDPOINT - established by enumerating the Advanced
  Security service's own routes. Every alerts route is project- and repository-scoped, and the
  portal's org view aggregates client-side, so this makes one call per enabled repository.

  THE WORK LIST COMES FROM `_apis/management/enablement`, NOT from the git repository list.
  `_apis/git/repositories` returns only what the caller can see, with a 200 - measured live, the
  app saw 95 repositories where a person with a PAT saw 220 - so driving off it would skip
  repositories silently. Enablement is organization-scoped and authoritative about what has
  scanning switched on; the git list is used only to put names to ids.

  A REPOSITORY THAT REFUSES ITS ALERTS IS COUNTED AND NAMED. Alerts return 403, never an empty
  list, so unreadable repositories cannot pass as clean - 42 of 87 did refuse, because the app
  holds organization membership but not Advanced Security alert read.

  `truncatedSecret` IS NEVER EMITTED. The API returns a fragment of the credential it found, and
  this output ends up in mailboxes and spreadsheets. `Title` carries the secret TYPE, which is
  what triage needs.

### Changed
- `Get-MsecAzureDevOpsServiceConnection -IncludeSecurity` reports who can administer or use each
  connection, and which pipelines may reference it: `Administrators`, `AdministratorCount`,
  `UserCount`, `ReaderCount`, `OpenInProjects`, `AuthorizedPipelineCount`.

  OPT-IN, because it costs two extra calls per connection - 243 connections on the organization
  it was built against. Without the switch those columns are `$null`, which reads as "not
  collected" rather than "nobody has access".

  `OpenInProjects` is the setting worth finding: any pipeline in the project may
  authenticate through the connection without a further approval. The API OMITS the field when
  the setting is off, so absence is reported as false - but a failed call stays `$null`, which is
  a different claim.

- `Get-MsecAzureDevOpsServiceConnection` now reports what it could not see. Service connections
  are permissioned per connection, and the endpoints API answers 200 with an empty list for
  connections the caller cannot read - never a 403 - so an inventory can miss whole projects
  while looking complete. Measured on a live organization: an app in `[Project]\Readers` on 36
  projects saw 70 connections in 1 project where a person saw 155 across 14.

  Every project that returns nothing is now counted and named, and the warning says plainly that
  this is not proof they have none. What governs the visibility is NOT established: it is not the
  endpoint Reader role - an endpoint carrying `[Project]\Readers -> Reader` by inheritance was
  hidden from that app while one with no Readers entry was visible - and not the endpoint type.
  The shortfall is reported rather than explained, and no remedy is asserted that has not been
  demonstrated.

  Project names are URL-encoded now: 17 of 36 contained spaces, so `-Project 'Viedoc eTMF'` had
  been building a malformed URL.

- **Fixed on Linux:** the module folder and its manifest are lowercase - `msec/msec.psd1`,
  `msec.psm1`, `msec.format.ps1xml` - matching the PowerShell Gallery id.

  The id was set by the first publish and a Gallery id keeps the casing it was first published
  with, so `Install-Module` created `.../Modules/msec/<version>/Msec.psd1`: a lowercase directory
  holding a capitalised manifest. PowerShell resolves a module as
  `<directory>/<version>/<directory>.psd1`, and on Linux that lookup is CASE-SENSITIVE - so
  `Import-Module Msec` failed there with "no valid module file was found in any module
  directory", which reads as a module that was never installed. macOS and Windows never showed
  it. Every Linux consumer was affected, not only CI.

  The internal folders are lowercase too (`public/`, `private/`, `tests/`, `kql/`, `scripts/`).
  Folders whose names are user-facing parameter values are NOT: `kql/Graph/VM/` still backs
  `-ResourceType VM`, and `scripts/VM/Windows/` still backs `-Os Windows`. Lowercasing those
  would have changed what callers type, and broken them on Linux only.

  Command names, the `-Msec` noun prefix and the `Msec*` type names are unchanged.

- **Breaking:** the Azure DevOps commands are named `*AzureDevOps*` rather than `*Ado*`.
  `Get-MsecAdoServiceConnection`, which shipped in 0.2.0, is now
  `Get-MsecAzureDevOpsServiceConnection`. No alias is kept: an abbreviation that appears in one
  command family and nowhere else in the module is worse than a one-line fix at the call site.

### Added
- `Connect-MsecTeams` / `Get-MsecTeamsPolicy` - the Teams settings that decide who can reach
  your people: external access and federation, guest access, meeting lobby and anonymous join,
  recording, which apps users may install, and file sharing in chats with external users.

  Teams admin policy is NOT in Graph, so this goes through the MicrosoftTeams module - the
  third workload msec reaches that way, after Exchange and SharePoint. It has a wrinkle the
  others do not: `Connect-MicrosoftTeams -AccessTokens` takes an ARRAY of TWO tokens, for
  Microsoft Graph and for the 'Skype and Teams Tenant Admin API'. Separate audiences, separate
  app roles, and passing only the Graph one fails in a way that reads as a permission problem.
  Teams also needs a DIRECTORY ROLE on top of app permissions, exactly as Exchange does.

  `Get-MsecTeamsPolicy` signs in to Teams itself, so it is one call after `Connect-Msec` like
  everything else here.

  `Connect-MsecTeams -AsCurrentUser` connects as the signed-in Azure user instead of the app,
  reusing the tokens from `Connect-AzAccount`. This exists because the Teams module cannot sign
  in interactively off Windows at all - its browser flow calls into `kernel32.dll` and dies with
  a dlopen error - and device code flow, the documented workaround, is refused by any
  Conditional Access policy requiring a compliant device. Borrowing the Az session avoids both,
  since that session already cleared CA. It is also the one place msec hands over an identity
  that can WRITE: msec has no `Set-*` commands, but the connection it leaves behind carries your
  rights, so `Set-Cs*` works afterwards. `Get-MsecTeamsPolicy` will not silently replace such a
  session with the app's.

  There is deliberately NO SharePoint equivalent. Teams accepts a token whose audience is the
  service; SharePoint validates the audience against the HOST, and `Get-AzAccessToken` normalises
  every sharepoint.com URL to the service GUID. The token is issued and then refused by every
  site with a bare 401. Verified on a live tenant against both the root and the admin host, and
  written up in `Connect-MsecSharePointOnline`'s notes so nobody adds the switch back.

  ONE ROW PER SETTING, NOT PER POLICY. A meeting policy object carries roughly eighty
  properties, most about layout and captions; returning whole objects makes the handful that
  matter impossible to see and impossible to diff between two policies or two tenants. Only the
  security-relevant settings are projected - which ones is a judgement the command makes, so it
  is written out in the source and `-All` returns everything for checking it.

  `IsGlobal` marks the tenant-wide policy, because that is what a user gets unless assigned
  another: a permissive Global is a tenant-wide finding where a permissive custom policy may
  apply to nobody. A policy area that cannot be read emits an `Unreadable` row rather than
  being skipped - a missing federation configuration would otherwise read as a tenant with no
  external access, the opposite of the truth.
- `Get-MsecAzureRoleAssignment` + `Kql/Graph/Authorization/RoleAssignments.kql` - Azure RBAC
  assignments across every subscription, with role and principal names resolved.

  THE LOOKUPS ARE DELIBERATELY SPLIT ACROSS TWO IDENTITIES. `Get-AzRoleAssignment` resolves
  principal names by calling Graph ITSELF, using whatever identity holds the Az context. That
  works for a person - who has directory read by default - and silently returns BLANK names for
  a service principal without Graph permissions. A pipeline running the same code as a laptop
  therefore produces a report full of GUIDs and no error. Here assignments and role names come
  from ARM, principals from the msec Graph session, so the ARM identity needs no directory
  access at all and the answer is the same in both places.

  Principals resolve in BULK through `/directoryObjects/getByIds`, up to 1000 per call - one
  call per assignment would be 2415 round trips on a real tenant. Role names come from ARM REST
  rather than `Get-AzRoleDefinition`, which lives in Az.Resources and is NOT a msec dependency:
  using it works on a developer machine and fails on a clean agent.

  An assignment whose principal no longer exists is KEPT, with `IsResolved = $false`. On a live
  tenant that was 94 of 233 subscription-scope assignments, 85 of them deleted service
  principals whose Azure rights outlived them - the finding, not an error.

  One Resource Graph query covers the estate: 2415 assignments against the 400
  `Get-AzRoleAssignment` returns for the current subscription, and without mutating the
  caller's Az context.

### Changed
- `Get-MsecAzureDevOpsUser` - every user in an Azure DevOps organization and the groups they belong to,
  one row per membership. Replaces the hand-rolled PAT-authenticated helpers in the Reporting
  repo, and fixes three things they got wrong.

  IT PAGES. The ADO graph APIs return one page and put the cursor in the X-MS-ContinuationToken
  RESPONSE HEADER, not in the body. Reading `$response.value` gives page one with no error and
  no sign more existed - and in an access review the users that go missing look exactly like
  users who do not exist.

  Group names are resolved from ONE fetch rather than a call per membership: the direct
  translation is thousands of round trips on a few hundred users for a few dozen distinct
  groups. A user in no group still gets a row (`(none)`), because emitting nothing drops the
  account from the review; a user whose memberships could not be read gets `(unreadable)`, which
  is a different claim. `Origin` separates Entra-backed accounts from `vsts` accounts that exist
  only inside Azure DevOps, with no Conditional Access and no leaver process behind them.

- `Get-MsecAzureDevOpsOrganizationPolicy` - the policies from Organization Settings > Policies:
  third-party OAuth access, SSH, PAT creation restrictions, guest access, public projects, audit
  logging, IP Conditional Access validation. Verified against a live organization: 13 policies in
  4 groups.

  THERE IS NO REST API FOR THESE. `_apis/organizationpolicy/policies` 404s on every api-version
  and on both hosts; the only source is the data provider behind the portal's own settings page
  (`_settings/organizationPolicy?__rt=fps&__ver=2`). That route is INTERNAL and can change
  without notice, so an empty response warns rather than reporting an organization with no
  policies. Categories and labels come from the payload itself, so there is no table here to
  drift out of date.

  `Value` is the raw stored value. Four policies are named for what they FORBID
  (`DisallowOAuthAuthentication` and friends), so the settings page renders them inverted -
  `IsInverted` says which. `IsExplicit` separates a policy someone configured from one still on
  its default; the provider signals that by OMITTING `isValueUndefined`, so absence means set.

- `Get-MsecSharePointTenantSetting` - the tenant-wide SharePoint and OneDrive settings, one row
  per setting grouped into a Category, the same shape as `Get-MsecTeamsPolicy`.

  THESE ARE THE CEILING EVERY SITE SITS UNDER. A site can be locked down and still live in a
  tenant where anyone-links are on; reviewing sites one at a time never surfaces that. Covers
  the sharing capability and domain lists, external resharing, legacy auth protocols (which
  bypass Conditional Access entirely), unmanaged-device sync, and site/Loop creation.

  AN EMPTY LIST READS AS `(none)` AND A MISSING VALUE AS `(not set)`, never blank. With
  `SharingDomainRestrictionMode` set to `allowList`, an EMPTY `SharingAllowedDomainList` means
  nobody outside can be invited at all - the opposite of what a blank cell suggests.

- `New-MsecApp -Workload SharePoint` also grants `SharePointTenantSettings.Read.All` on Graph,
  which is what `/admin/sharepoint/settings` needs - the tenant-wide sharing posture:
  `SharingCapability`, the domain allow/block-list and the restriction mode. `Sites.Read.All`
  does not cover it, those being site properties rather than tenant settings, and the call
  returns a bare 403 naming no permission. It is also the only route msec has to those
  settings: the PnP equivalent needs an admin-host token that `Get-AzAccessToken` cannot mint.

- `New-MsecApp -Workload Teams` grants `application_access` on the Skype and Teams Tenant
  Admin API and assigns the directory role. Without this `Connect-MsecTeams` could not get a
  token for that audience at all, so the Teams commands shipped unusable until the app was
  configured by hand.

- `-ExchangeDirectoryRole` is now `-DirectoryRole`, because Teams needs the same role for the
  same reason and the old name said otherwise. The old name still works as an alias, so
  nothing that passed it in 0.2.0 breaks.

## [0.2.0] - 2026-09-07

### Added
- `Get-MsecSharePointSite` - every site in the tenant, classified. Completes the SharePoint
  access review: enumerate with this, then read each site's owners and members with
  `Get-MsecSharePointSiteUser -Url`.

  ENUMERATED THROUGH GRAPH, NOT THE TENANT-ADMIN API, and the reason is privilege.
  `Get-PnPTenantSite` talks to the SharePoint tenant-admin endpoint, which accepts nothing less
  than `Sites.FullControl.All` - full read, WRITE and DELETE over every site in the tenant. For
  a list of site names, in a read-only module, that is a bad trade. Graph answers the same
  question with `Sites.Read.All`.

  MOST OF WHAT GRAPH CALLS A SITE IS NOT ONE. On a live tenant `/sites?search=*` returned 432
  results of which 286 were app containers - the backing storage for Loop workspaces, Designer
  files and similar, one per artefact. Running a site access review across those is noise and
  hundreds of wasted calls, so `SiteType` classifies them (SiteCollection / AppContainer /
  Personal / Root) and the default excludes all but real sites: 146 instead of 432. `-All`
  returns everything classified, because "146 of 432" is a finding and "146" is not.

- `New-MsecApp -Workload SharePoint` now also grants `Sites.Read.All` on MICROSOFT GRAPH,
  alongside the SharePoint one it already granted. Despite the identical name these are
  separate permissions on separate resources, and both are needed: Graph's enumerates sites,
  SharePoint's lets PnP read what is inside one. Having either alone fails in a way that looks
  like the other is missing.
- Exchange Online and SharePoint support, reached the same way everything else is - a token
  signed inside Key Vault, so no certificate reaches the machine:
  - `Connect-MsecExchangeOnline` / `Get-MsecExchangeMailboxPermission` - who can open which
    shared mailbox. Standing delegated access that appears in NO Entra-side review: not in
    group membership, not in a directory role, not in Conditional Access.
  - `Connect-MsecSharePointOnline` / `Get-MsecSharePointSiteUser` - site Owners and Members,
    with security groups expanded to the people inside them.

  THESE ARE THREE DIFFERENT TOKENS, NOT ONE. Entra issues a token FOR a resource, carrying only
  the app roles granted on that resource's service principal - so Graph's `User.Read.All` buys
  nothing in Exchange or SharePoint, and a Graph token presented to either is rejected outright.
  Only the signing key is shared.

  | Command | Audience | Roles come from |
  |---|---|---|
  | `Connect-MsecGraphSdk` | `graph.microsoft.com` | Microsoft Graph SP |
  | `Connect-MsecExchangeOnline` | `outlook.office365.com` | Office 365 Exchange Online SP |
  | `Connect-MsecSharePointOnline` | the site HOST | Office 365 SharePoint Online SP |

  A SharePoint token's audience is the site HOST, so `contoso.sharepoint.com` and
  `contoso-admin.sharepoint.com` need separate tokens - which matters because tenant cmdlets
  like `Get-PnPTenantSite` only work against the admin host.

  Both modules take `-AccessToken` as a plain STRING; `Connect-MgGraph` is the odd one out in
  wanting a SecureString. Verified against ExchangeOnlineManagement 3.10.1 and PnP.PowerShell
  3.4.1. Neither is an msec dependency - both are imported only when their command is called.

  Neither workload could reach Graph anyway: mailbox permissions have no Graph endpoint at all,
  and a site's own SharePoint groups - the permission model for classic sites - are not exposed
  there either.

- `New-MsecApp -Workload Exchange, SharePoint` configures the permissions those need. OPT-IN,
  because each needs fresh admin consent and Exchange needs more than a permission.

  EXCHANGE NEEDS A DIRECTORY ROLE, NOT JUST AN APP ROLE, and this is the step that is missed.
  With `Exchange.ManageAsApp` granted and consented but no directory role, the connection
  SUCCEEDS and then every `Get-EXO*` call fails with a plain authorisation error naming no
  missing permission - from Exchange's point of view the app authenticated and has no rights.
  `-Workload Exchange` assigns one (`Global Reader` by default, the least-privilege option that
  can read mailbox permissions).

  That is a real tenant-wide privilege grant rather than an API permission, which is why the
  workloads are opt-in, why it is announced before being made, and why it is idempotent. It
  needs Privileged Role Administrator - a higher bar than the rest of the command - and a
  caller without it still gets everything else configured plus a warning saying exactly what to
  assign by hand.

  `Sites.Read.All` is granted on the SHAREPOINT service principal, not the Graph one. The two
  permissions share a name and are not the same: PnP presents a SharePoint-audience token, so
  granting the Graph one looks right in the portal and still fails.

  A resource whose service principal does not exist in the tenant - no Exchange Online, a
  sovereign cloud without SharePoint - is now skipped with a warning rather than aborting the
  bootstrap, matching how unavailable app roles were already handled.
- `Kql/Graph/Resource/NetworkExposure.kql`, reached as
  `Search-MsecAzureResourceGraph -ResourceType Resource -Name NetworkExposure` - one row per
  resource that has a network exposure setting, across twelve types: what is reachable from the
  public internet and what restricts by IP.

  It complements rather than duplicates `KeyVault/NetworkRules.kql` and
  `Storage/NetworkRules.kql`. Those answer the question per RULE for one type - which addresses
  are allowed in, and whether each rule is actually enforcing. This answers it per RESOURCE
  across the estate, so finding where to look no longer needs one query per type.

  EVERY TYPE STORES IT SOMEWHERE DIFFERENT, verified against ~1300 live resources. MySQL
  flexible servers carry `publicNetworkAccess` at `properties.network.publicNetworkAccess` and
  nothing at the top level, so the paths are coalesced nested-first; the other order reports
  every one of them as unset, which then defaults to Enabled and looks like an answer.
  Container registries use `networkRuleSet.defaultAction` where vaults and storage use
  `networkAcls.defaultAction`.

  An absent `publicNetworkAccess` means ENABLED, not unknown - defaulting it the safe-looking
  way would under-report exposure on every resource that never had it explicitly set.

  App Service IP restrictions are reported as `IpRuleCount = $null` rather than 0: they live in
  `siteConfig.ipSecurityRestrictions`, which the ARM GET returns trimmed (empty on 315 of 315
  sites), so a site that IS restricted would otherwise read as having no rules.

  `ReachableFromAnyIp` is deliberately a separate column from `NetworkExposure`. A resource with
  a Deny default and no rules at all is restricted to nobody, which is a different finding from
  one that lets anyone in - and the practical question behind a build agent, a home connection
  or anything else without a fixed address is the former.
- Three commands that between them replace the ViedocAz module the Reporting repo depended on:

  `Kql/Graph/Resource/Unused.kql`, reached as
  `Search-MsecAzureResourceGraph -ResourceType Resource -Name Unused` - unattached public IPs,
  disks, NICs, NSGs, deallocated VMs, stopped app services and empty app service plans, in ONE
  Resource Graph query rather than a Set-AzContext loop running seven Get-Az* per subscription.
  Never mutates the caller's Az context, which such a loop does and has to remember to undo.

  Two predicates in the Az-based original were wrong or missing and are fixed here. Disks: the
  attachment marker is `managedBy` at the TOP level of the resource, not under `properties`,
  and reading the latter reports every disk in the estate as unused - verified 53 of 53 against
  a live tenant where the answer is 21. NICs: a private endpoint's NIC has no virtual machine
  and is very much in use, so excluding them takes the same tenant from 58 unused NICs to 1.

  The query returns the tag bag and applies NO deferral policy. An ArchivedUntil convention is
  organisational rather than an Azure fact, so it belongs to the caller - and Resource Graph is
  the wrong place for it anyway: `todynamic()` re-parses tag JSON and infers types, so a tag
  stored as '2026-06-15' read back through a lowercased copy of the bag arrives as
  '6/15/2026 12:00:00 AM'. Verified against a real tag in a live tenant. In PowerShell the same
  filter is a case-insensitive dictionary and a TryParseExact, with no round-trip to corrupt
  the value.

  `Get-MsecKeyVaultCertificate` - certificate expiry across the accessible vaults. Certificates
  are DATA-PLANE, so Resource Graph cannot see them (`microsoft.keyvault/vaults/certificates`
  returns no rows) and this walks the vaults with Az.KeyVault instead.

  A vault that can be LISTED but not READ INTO emits an `Unreadable` row rather than
  contributing nothing. Listing vaults is control-plane (Reader); listing certificates inside
  one is data-plane, granted separately - and having the first without the second is the normal
  state for an auditor's account. On a live tenant 185 of 258 vaults were unreadable, so
  without that row the inventory would have read as "18 certificates" with nothing to say that
  71% of the estate was never examined.

  `Get-MsecAzureCost` - actual pre-tax spend per subscription or resource group, from Cost
  Management.

  THE CURRENCY IS RETURNED AND THE FIGURE IS NOT ROUNDED. The API answers with both; dropping
  the currency is how a report adds SEK to EUR, and a run spanning two warns rather than
  summing. Rounding in the collector loses the difference between 0.4 and 0, and 0 reads as
  free.

  It goes through `Invoke-AzRestMethod` rather than building the call by hand, which fixes two
  faults in the original: the ARM endpoint had to be branched on per cloud, and since
  Az.Accounts 5 `Get-AzAccessToken` returns a SecureString - so
  `"Bearer $($t.Token)"` interpolates to the literal 'Bearer System.Security.SecureString' and
  every call 401s. Verified against Az.Accounts 5.4.0.

  Cost Management throttles aggressively and the natural use - a loop over every resource group
  - is the shape that trips it. 429s are retried honouring Retry-After, and a scope still lost
  after five attempts warns that the total is short by its cost rather than contributing a
  fabricated 0.
- `Connect-MsecGraphSdk` - signs the Microsoft.Graph PowerShell SDK in with the msec session's
  token, so `Get-Mg*` commands run as the msec app while the certificate's private key stays
  in Key Vault.

  THE USUAL CERTIFICATE ROUTE CANNOT PRESERVE THAT.
  `Connect-MgGraph -CertificateThumbprint` needs the private key present on the machine, so
  anything shipping a PFX or a base64 certificate to a build agent is putting the key
  somewhere it can be copied. The token handoff is the only form that does not.

  The cloud comes from the session and is matched on the Graph ENDPOINT, not by name - the SDK
  calls the Chinese cloud `China` where Azure calls it `AzureChinaCloud`, and an endpoint no
  environment matches warns rather than silently signing in to the wrong cloud.

  The SDK is handed a STATIC token and cannot renew it, unlike msec's own commands.
  `-MinimumMinutes` is how a long report asserts it has the time it needs before starting,
  rather than working for twenty minutes and then failing partway through.

  Microsoft.Graph.Authentication is NOT a module dependency - it is imported only when this
  command is called, so msec still installs and runs on a machine without the Graph SDK.
- `Scripts/Intune/` now also holds the two hand-written scripts that used to live at
  `windows/intune/` and `macos/intune/`, moved verbatim:
  - `Windows/entra-local-admins/detect.ps1` - inventories the Entra principals in the local
    Administrators group. Detection-ONLY: Intune allows a remediation with no remediation
    script, which turns the detection output column into a fleet inventory report.
  - `macOS/local-admins/custom-attribute.sh` - the same question for Macs, as a macOS Custom
    Attribute (macOS has no Remediations feature).

  Their techniques were folded back into `remove-local-admin`, and one of them fixed a real
  bug there - see below.
- `Scripts/Intune/Windows/remove-local-admin` - the first bundled Intune Remediation: a
  detection half that reports whether a named account is in the local Administrators group,
  and a remediation half that removes it.

  A NEW SCRIPT CHANNEL, AND THE FIRST THAT WRITES. Everything under `Scripts/VM/` is read-only
  and safe to run blindly across a fleet; these change a security group on every device the
  Intune assignment covers. `Scripts/README.md` now says so explicitly - an undocumented
  exception is how someone assigns a destructive script fleet-wide expecting a report. It is
  also the one channel msec does not execute: Intune runs it, and
  `Get-MsecIntuneScriptResult -Source Remediation` reads back what happened.

  THE GROUP IS RESOLVED BY SID (`S-1-5-32-544`), NEVER BY NAME. 'Administrators' is localised -
  Administratoren, Administradores - so a script hard-coding the English name finds no group at
  all on those builds and reports every one of them as clean, which is the most dangerous way
  for this to fail.

  MEMBERS ARE ENUMERATED THROUGH ADSI, not `Get-LocalGroupMember`, which throws
  "Failed to compare two elements in the array" whenever the group holds a SID it cannot
  resolve - an orphaned domain account, an Entra principal on some builds. It throws rather
  than skipping, so one stale member makes the whole group unreadable.

  Two safety rails, both checked BEFORE anything is removed so a refusal leaves the group
  untouched: the built-in Administrator (SID ending -500, whatever it has been renamed to) is
  protected, and the group is never emptied - a device with no local administrator cannot be
  recovered locally, and a fleet-wide assignment would do it everywhere at once. After removing,
  the group is RE-READ rather than the call being trusted: the WinNT provider reports success
  for a removal that policy quietly undid, and "fixed" while the account is still an
  administrator is worse than "failed".

  MATCHING AN ENTRA ACCOUNT BY UPN NOW WORKS, AND DID NOT BEFORE. ADSI and LSA give an Entra
  member its SAM-COMPATIBLE name - 'AzureAD\JaneDoe' - never the UPN, so a `$TargetAccount`
  written as 'AzureAD\jane@contoso.com' could never match: the account stayed an administrator
  and the device reported clean. The UPN is recovered from the two IdentityStore caches, and
  the lookup is UNCONDITIONAL rather than skipped when the name already contains an '@' - the
  20-character SAM truncation can cut mid-domain and leave 'anton@examp', which looks like a
  UPN and is not one.
  Detection throws rather than exiting non-zero when the group cannot be read. Intune treats any
  non-zero exit as "issue found, run the remediation", so a machine that could not be read would
  otherwise have its administrators edited on the strength of a failed check.

  `msec/tests/IntuneRemediationScripts.Tests.ps1` guards what is testable off-Windows: both
  halves present and parsing, the group resolved by SID, the safety rails still there, and -
  the hazard the scripts warn about - `$TargetAccount` identical across the pair, since they are
  separate uploads and nothing in Intune enforces that they agree.
- `Export-MsecPostureReport` now measures the device estate itself, on two new sheets fed by
  the Intune device list it already collects - no extra API call:
  - `DevicePlatform` - one column per OS family (Windows, macOS, iOS, Android), device counts.
  - `DeviceOsVersion` - one column per OS RELEASE (Windows 11, Windows 10, iOS 17, macOS 14).

  COUNTS, NOT PERCENTAGES. The question is "how many are still on the old one", and a
  percentage hides an estate that is growing or shrinking underneath it. `TotalDevices` is on
  both sheets so the columns can be checked against it, and a device Intune reported no OS for
  lands in an `Unknown` column rather than being dropped and quietly shrinking the total.

  THE RELEASE, NOT THE RAW VERSION. `10.0.22631.3155` would be a different column on every
  patch Tuesday - the sheet would reshape every run and the chart would become a hundred
  one-point series. `ConvertTo-MsecDeviceOsRelease` collapses builds into their release.

  WINDOWS 11 REPORTS ITSELF AS 10.0, so the build is the only thing separating it from
  Windows 10 - 22000 and above is 11. Splitting on the version string, which is the obvious
  implementation, files every Windows 11 device as Windows 10: exactly backwards for the
  question this exists to answer. Windows Server is NOT guessed at and is documented as such:
  Server 2019 and Windows 10 1809 are both build 17763, and Intune calls both 'Windows'.
- `Export-MsecEntraGroupMemberReport` - the evidence shape applied to group membership: one
  worksheet per group holding its members, a Summary with one row per group, and a chart.

  THE CHART COMPARES GROUPS, not membership types within one. Groups are the x axis, so the
  question it answers is "which of these is the outlier" - the access group that grew, the one
  that is all guests, the one with a service principal in it. A chart per group would be a
  dozen tiny pictures of a number already readable in a cell.

  The Summary is the sheet a reviewer reads first: members per group, how much of that is
  standing versus PIM-eligible, and how much is guests, service principals, nested groups or
  disabled accounts. An empty group still gets a worksheet and a row - "nobody is in it" is a
  finding that disappears if empty groups are skipped - and a group whose membership could not
  be read is marked `Unreadable` rather than counted as a clean zero.

  Sheets are keyed on the group ID, not its name: Entra display names are not unique, and
  keying on the name would put two different groups' members on one sheet under one heading. A
  group actually called 'Summary' or 'Dashboard' is suffixed rather than overwriting the
  report's own sheets.

  The overwrite prompt asks ONCE for the whole run rather than once per group - a wildcard can
  match forty groups, and forty prompts is a prompt nobody reads. It comes after the collection
  here, unlike the VM reports: which worksheets are at stake is not knowable until the names
  have resolved, and reading group membership has no side effects.
- `Get-MsecEntraGroupMember` - the members of one or more Entra groups as flat rows, one per
  (group, member). Takes a list of names, wildcards included, and puts the group name on every
  row so several groups come back as a single table rather than needing a call each.

  PIM-ELIGIBLE MEMBERS ARE INCLUDED, marked `MembershipType 'Eligible'`. Where a group is
  governed by PIM for Groups, people are eligible members rather than actual ones - they appear
  on no `/members` endpoint at all, so a group whose whole membership is eligible reads as
  EMPTY. The group looks unused while a queue of people is one activation away, which is the
  most dangerous direction to be wrong in. Group OWNERS are deliberately excluded: an owner can
  add themselves and then hold what the group grants, which is a real escalation path but a
  different finding, and counting them would overstate the membership.

  MEMBERS ARE NOT ONLY USERS. `MemberType` carries user / group / servicePrincipal / device,
  because filtering to users here would quietly drop the service principal somebody added to an
  access group. A member whose type Graph did not return reads `unknown` rather than being
  assumed to be a user.

  An empty group emits a row with `MemberType 'None'`, and one whose membership could not be
  read emits `'Unreadable'` plus a warning - "the group is empty", "the group does not exist"
  and "I could not look" are three different answers and only the first is good news. A name
  matching nothing is named in a warning; a name matching SEVERAL groups returns all of them,
  since Entra display names are not unique.

  Direct members by default, matching what the portal shows - a nested group is one row.
  `-Recurse` (aliased `-Transitive`) EXPANDS nested groups instead of listing them: the people
  inside come back as members in their own right and the nested group itself does not appear,
  because the question being asked is "who is in here" and a group is not a who. Graph's
  /transitiveMembers returns the nested groups alongside their members, so listing it verbatim
  would show a group as a member AND again as everyone in it.

  Recursion reads PIM-eligible membership for every NESTED group too, not only the ones named.
  Flattening follows actual membership only, so a nested group governed by PIM contributes
  nobody - and the recursion would otherwise be quietly less complete than not recursing.
  A person reachable through two nested groups is one row; Active and Eligible are kept apart,
  since standing membership plus an eligible assignment is a real state worth seeing.- `Export-MsecDefenderDeviceReport` - the evidence shape applied to the Defender estate: one
  row per onboarded device, a worksheet named after the tenant, and a chart per tenant.

  THE CHART IS A DISTRIBUTION, NOT A TOTAL. Devices are banded by discovered-vulnerability
  count (None / 1 to 10 / 11 to 25 / 26 to 50 / 51 to 100 / Over 100), so the chart shows how
  the estate is spread rather than a tenant-wide sum. A long tail of clean machines with three
  disasters and a broad middle where everything is equally behind produce the SAME total and
  need completely different responses.

  It counts twice per band: devices, and how many of those carry at least one CRITICAL
  vulnerability. Critical is a subset of each band rather than its own band, because the two
  do not share an axis - a device with 200 vulnerabilities might have three criticals, so
  plotting them as peers would flatten one into the floor. As a subset it stays readable and
  answers what decides the work order: are the criticals concentrated in the worst machines or
  spread through ones that otherwise look fine?

  'Not assessed' is a band in its own right and sorts to the TOP. It means the vulnerability
  export could not be read at all - no Defender Vulnerability Management licence, or a missing
  permission - so the count is unknown rather than zero, and a warning says how many. Folding
  those into 'None' would report an unmeasured estate as a clean one.
- `Get-MsecDefenderDevice` - the Assets > Devices view from the Defender portal as flat rows:
  one per onboarded device, with its exposure level, risk score and how many vulnerabilities
  have been discovered on it, broken down by severity.

  TWO BULK CALLS, NOT ONE PER DEVICE. The inventory comes from `/api/machines` and the counts
  from `/api/vulnerabilities/machinesVulnerabilities`, the assessment export that returns every
  (device, software, CVE) finding in one paged stream. Per-device
  `/api/machines/{id}/vulnerabilities` would be one round trip per machine - a few thousand
  requests and a throttling wall on a real estate.

  COUNTED AS DISTINCT CVEs, which is what the portal shows. The export is one row per
  (software, CVE), so one CVE affecting three installed versions of a product is three rows and
  one vulnerability; counting rows would inflate every device by a factor that varies with how
  much software it has. `FindingCount` carries the raw row count alongside - the gap between
  the two is the remediation workload.

  A FAILED VULNERABILITY READ GIVES NULL COUNTS, NOT ZERO. Defender Vulnerability Management is
  a separate licence and answers 403 without it; reporting 0 would read as "no device has any
  vulnerability", the most dangerous wrong answer here. The device rows still come back, every
  count is null, and a warning names the permission. A device absent from a SUCCESSFUL export
  reports 0 - which for an inactive device means nobody has looked rather than that it is
  clean, so `HealthStatus` and `LastSeen` are on every row to separate the two.

  The id and severity fields are read under BOTH names Defender uses for them - `machineId` /
  `severity` from `/api/vulnerabilities/machinesVulnerabilities`, and `deviceId` /
  `vulnerabilitySeverityLevel` from `/api/machines/SoftwareVulnerabilitiesByMachine`. Reading
  only one pair is how this first shipped, and against a live tenant it produced a full device
  list with every count reading 0: the call succeeded, every row streamed in, and every row was
  discarded for carrying no id under the name being looked for. A second guard backs it up - if
  rows arrive and NONE can be attributed to a device, the counts are reported as null with a
  warning, because "a response shape this code does not understand" and "an estate with no
  vulnerabilities" are indistinguishable in the output unless one of them says so.
  `Invoke-MsecDefenderRequest` gained `-All`, following `@odata.nextLink`. Reading only the
  first page of an assessment export would silently under-report, which on a vulnerability
  report looks exactly like a clean answer.

  `New-MsecApp` now also requests the WindowsDefenderATP roles `Machine.Read.All` and
  `Vulnerability.Read.All`. An app created before this needs a re-run to pick them up.
- App Service KQL: `Kql/Graph/AppService/All.kql` (one row per site - TLS enforcement, public
  network access, client certificates, vnet integration, managed identity, plan SKU) and
  `Kql/Graph/AppService/StackSettings.kql` (the runtime stack, for the end-of-life question).
  Reached as `Search-MsecAzureResourceGraph -ResourceType AppService [-Name StackSettings]`.

  BOTH QUERIES DELIBERATELY OMIT MOST OF siteConfig. Resource Graph indexes the trimmed
  siteConfig returned by the ARM GET on a site, not the sites/config child resource, which it
  does not index at all - `microsoft.web/sites/config` returns zero rows. The keys are present
  in the property bag holding null, so projecting them yields a column of blanks that reads as
  "not configured" when it means "not visible from here". Verified against a live tenant:
  `minTlsVersion`, `ftpsState`, `ipSecurityRestrictions`, `netFrameworkVersion`, `phpVersion`,
  `nodeVersion`, `javaVersion`, `appCommandLine`, `managedPipelineMode`, `use32BitWorkerProcess`
  and `healthCheckPath` were empty on 61 of 61 sites. Only `linuxFxVersion`, `alwaysOn`,
  `http20Enabled` and `numberOfWorkers` are populated, and only those are used.

  StackSettings therefore carries a `StackSource` column - `LinuxFxVersion` when Resource Graph
  knows, `Unavailable` when it does not - and Windows sites, whose stack lives entirely in the
  fields above, sort to the TOP as `Unknown (Windows)` rather than appearing as sites with no
  stack. A container reports `DOCKER` with its image reference, because what runs inside the
  image is not something Azure knows either; `MutableTag` flags the images pinned to `latest`,
  `trunk` or a branch name, where what ran last week cannot be reconstructed from the row.
- `Get-MsecEntraAppCredential` - every client secret and certificate on the tenant's app
  registrations, one row per CREDENTIAL rather than per app: rolling up per app would have to
  pick a single expiry, which hides the secret lapsing on Friday behind the two good for a
  year. Carries `DaysUntilExpiry`, `IsExpired` and `LifetimeDays`, so it answers both halves of
  the question - the outage (a credential expiring at 3am on the integration nobody owns) and
  the security posture (a secret minted with a two-year lifetime is two years of standing
  access if it leaks).

  `-ExpiringWithinDays` always keeps ALREADY-EXPIRED credentials, whatever the window: expired
  is not less urgent than expiring, and a filter that dropped them would report the opposite of
  the truth.

  App registrations are inventoried completely, including those with NO credentials
  (`CredentialType 'None'`) - that is usually the good state, an app on federated credentials,
  and a report that omitted them could not tell "no credentials" from "not returned". Service
  principals are opt-in via `-IncludeServicePrincipal` and only appear when they actually hold
  one, because a tenant carries hundreds of Microsoft-owned ones with none. Asking for them is
  how a SAML token-signing certificate - whose expiry is a sign-in outage for every user of
  that app - shows up at all.
- `Export-MsecPostureReport` now measures privileged access, on a `PrivilegedAccess` sheet fed
  by `Get-MsecEntraRoleHolder`: standing versus PIM-eligible admins, plus the holders no MFA or
  PIM policy reaches - service principals, guests, and accounts that are disabled and privileged
  at the same time.

  Counted in PEOPLE, not assignments. Someone holding Global Administrator, Security
  Administrator and Exchange Administrator is one administrator; counting rows would report
  three and would move whenever the same faces swapped roles. Holders are counted, so a role
  reaching someone through a role-assignable group counts the person rather than the group.
  `PrivilegedAssignments` and `AllRoleAssignments` are carried alongside, so the ratio between
  people and assignments stays checkable.

  `GlobalAdminHolders` here can exceed `GlobalAdministratorCount` on the TenantSettings sheet.
  They are not in conflict: this one counts effective holders, including group-inherited and
  PIM-eligible ones; the other counts the assignment side.

- The posture report Dashboard now PACKS CHARTS DENSELY instead of reserving a slot for every
  measurement in the canonical list. A measurement that has never produced a row cost a blank
  page before, so a workbook holding only one measurement put its single chart several pages
  down with nothing in between. The canonical list still fixes the ORDER charts appear in; it
  no longer fixes their spacing.

  The trade, taken deliberately: the first time a new measurement lands, every chart below it
  moves down one page. That is a one-way, one-off move - a data sheet never loses its rows, so
  a chart that exists keeps existing and the layout only ever settles further - and position
  was already reasserted on every run, so it adds no new instability. A permanent blank page
  per uncollected measurement was the worse cost.- The Dashboard now repositions a chart whose columns are DISCOVERED from the data - one per
  subscription, per initiative, per Secure Score category - on a run that did not collect that
  measurement. Such a spec carries an empty series list on a partial run, which previously made
  the whole spec be skipped: the chart kept the row it was drawn at while the slots around it
  moved, so the next chart could be drawn straight on top of it. This is what made adding
  `PrivilegedAccess` mid-list safe to pick up with `-Measurement PrivilegedAccess` alone.- `Export-MsecEntraDisabledUserReport` - the evidence shape applied to the directory: one row
  per disabled account, a worksheet named after the tenant, and a chart counting accounts per
  age bucket with a second series for how many of those still hold licences. Graph rather than
  Az, so `Connect-Msec` and no subscription dimension.

  `Unknown` is a bucket in its own right. Entra stores no `disabledDateTime`, so the date comes
  from the audit log and anything past its retention carries a bracket instead. The bracket
  still places an account when both ends fall inside one bucket - "at least 30, at most 60" is
  squarely 30-to-90 - but where it straddles a boundary the answer is Unknown rather than a
  guess. What it is never allowed to be is "under 30 days": anything the audit log cannot see
  is OLDER than the window, never newer.

  The writing half of all three evidence reports now lives in one `Write-MsecEvidenceWorkbook` -
  worksheet naming and collision handling, replace-not-append, the Summary block, per-block
  timestamps and the dashboard. Reports supply their rows, their categories, and an ordered map
  of count columns (one entry gives one bar per category, two give two). That map is what lets
  this report chart accounts and licensed accounts side by side while the VM reports chart a
  single count.
- `Export-MsecVMNtpReport` - the same evidence shape for time synchronisation, via the bundled
  `ntp-status` script. Both the Windows and Linux versions compute the same A.8.17 rule
  (synchronised AND naming a real upstream source), so the verdict means the same thing on
  both platforms.

  `No time source` is its own verdict rather than being folded into `Not synchronised`: a
  Windows machine fallen back to Local CMOS Clock reports itself perfectly synchronised - to
  its own drifting hardware clock. It is not a machine whose daemon stalled, it is one pointed
  at nothing, and the fix is different.

  Both VM reports are now thin wrappers over a shared `Write-MsecVMEvidenceWorkbook`, which
  owns everything they had in common - discovery, running the script, worksheet naming and
  collision handling, snapshot-replace semantics, the shared Summary sheet, per-block
  timestamps and the dashboard. A report supplies only the script to run, a projection from one
  VM's answer to a row, and its ordered list of verdicts. Duplicating that machinery would have
  meant fixing every bug in it twice.

  Rows now sort worst-first by verdict, so the machines nobody could assess are at the TOP of
  the table rather than buried under the healthy ones. That was the other way round while the
  chart plotted a number per VM and a null must not lead; the chart counts per verdict now, so
  the constraint is gone.
- `Export-MsecVMUpdateReport` - an EVIDENCE document of VM patch state: one row per VM,
  showing what that machine itself reported, on a worksheet named after the subscription. A
  fresh file per run rather than a growing one, so nothing is appended and a sheet written
  twice is replaced. Re-run against the same path after `Select-MsecAzureContext` and the next
  subscription gets its own sheet and its own chart in the same document.

  In-guest via the bundled `update-status` Run-Command script rather than
  `Kql/Graph/VM/LastUpdated.kql`, which sees only what Azure Update Manager installed - a VM
  patching itself through Windows Automatic Updates or unattended-upgrades contributes nothing
  there and reads as never updated. The price is a Run-Command per VM: minutes for a fleet, and
  the machines have to be running.

  EVERY VM gets a row, including ones that could not be reached - a stopped machine, a wedged
  agent or a timeout appears with the reason in Error rather than being left out, because
  evidence that quietly omits what it failed on is not evidence. The `Assessment` column keeps
  four states distinct, since they need different follow-up: Up to date, Stale, No update
  history, No answer. Unparseable output (Azure truncates stdout at 4096 bytes) is No answer,
  never a clean machine.

  Rows are ordered worst-first, so the evidence table reads from the most overdue machine down.

  The charts count VMs per assessment rather than plotting days per machine. Days per machine
  left the VMs that could not be assessed with NO BAR - they have no number - so a reviewer
  reading the chart alone saw only the machines that answered and no sign of the ones that did
  not, which on an evidence document is the wrong emphasis entirely. Counts are also readable
  at any fleet size. They come from a shared Summary sheet in long format, one five-row block
  per subscription, and each chart reads only its own block.

  Collection time is on every sheet: `CollectedUtc` per VM row, and per subscription block on
  the Summary sheet. Subscriptions are scanned in separate runs, so one timestamp for the file
  would date every sheet by whichever ran last - claiming a subscription scanned on Monday was
  collected on Friday. The Dashboard heading reports the span rather than a single clock when
  the blocks disagree.
  Worksheet names follow Excel's rules (31 characters, no `: \ / ? * [ ]`), and two
  subscriptions truncating to the same name are told apart by the SubscriptionId on the sheet
  rather than one overwriting the other's evidence.
- `Export-MsecPostureReport` - collects the tenant's posture with the read-only Get-Msec*
  commands and appends one row per measurement to an Excel workbook (via ImportExcel), so
  repeated runs build a time series. One sheet per measurement, each written as an Excel
  TABLE - including Azure Secure Score with one column per subscription, and Intune device
  compliance aggregated from `Get-MsecIntuneDevice`.

  Every chart is on a Dashboard sheet, first in the workbook, stacked one per row and set up
  to print one chart per page - A4 landscape, fit to one page wide, a page break above each
  chart and a print area covering them (charts are drawings anchored to cells, so without a
  print area a PDF export is blank pages).

  Charts are sized for pasting into Word rather than for filling Excel's page, because Word
  pastes at true pixel size with no scaling: A4 portrait at standard margins gives about
  602 px of printable width and landscape about 930, so a chart sized to Excel's own
  landscape page (~1045 px) had to be dragged smaller on every paste. `-ChartWidth` defaults
  to 600 and fits either orientation; `-ChartHeight` defaults to 370 and also sets the row
  band, and therefore where the page breaks fall. Excel printing does not suffer: the print
  area is derived from the chart width, so fit-to-one-page-wide scales the narrow band back
  up to fill the sheet. `-ResetDashboard` rebuilds the sheet, which is how a size change
  reaches charts that already exist - they are otherwise created once and only
  range-refreshed.
  Chart series use ordinary cell ranges. Structured table references were tried first, on
  the theory that Excel would grow the series with the table - EPPlus stores and reads those
  back happily, so it tested green, and Excel rendered every chart BLANK. Ordinary ranges
  are pinned to the row count they were written with, so the ranges are refreshed in place
  as rows are appended; the chart itself is never rebuilt, and its title, position, size,
  colours and any series added by hand all survive.

  No series colours are set: Excel's own theme palette applies, so the charts match the
  workbook and follow it if the theme changes.

  `-TableStyle` sets the Excel table style on every data sheet, default `Medium2`. It is
  applied on the append path as well as on create, so changing it restyles sheets that
  already exist rather than leaving them on the old style.
  `-Target` puts goals on the charts: `@{ MfaCoverage = 95; PolicyCompliance = 80 }` writes a
  Target column holding that number on every row, which Excel draws as a flat line across the
  chart. Only the sheets named get one, so charts without a target are untouched, and the
  series is added last so it takes the final theme colour and reads as an annotation rather
  than as another measurement. The value is in the chart's own units, so a count works too -
  `@{ Incidents = 0 }` draws a zero line under the severity counts. Because it is stored per
  row, raising a target later shows as a step in the line instead of silently restating the
  earlier months at the new number.
  Chart POSITION on the Dashboard is now reasserted on every run rather than set once. Slots
  come from the index in the canonical chart list, so adding a measurement anywhere but the
  end shifts every later slot - and a chart left where it was got the newcomer drawn straight
  on top of it, invisible, with nothing to say so. Everything else about a chart is still left
  alone: title, size, colours and hand-added series.
  A `PolicyCompliance` sheet and chart, one column per Azure Policy initiative, fed by
  `Kql/Graph/Policy/Compliance.kql`. Where an initiative is assigned to several subscriptions
  the figure is recomputed from the resource counts - total compliant over total graded - and
  NOT averaged from the per-subscription percentages, which would give a four-resource sandbox
  the same weight as a four-hundred-resource production subscription. Columns are ordered by
  how much of the estate each initiative grades, so the first chart series is the broadest;
  initiatives grading nothing are left out entirely, and `-PolicyInitiative` takes wildcards
  for narrowing. Past eight initiatives it warns that the chart will be hard to read rather
  than quietly drawing it.

  This is the one measurement needing an Az context rather than just the msec session, so it
  fails on its own and lands in RunLog if `Connect-AzAccount` has not been run. It is also
  SKIPPED when the Az context is on a different tenant than the session: `Connect-Msec` does
  not move the Az context, so a per-tenant export loop would otherwise write tenant A's policy
  compliance into tenant B's workbook - a plausible number, in the wrong file, in a compliance
  report. The skip and its reason are recorded in RunLog.
  Azure Secure Score is per-subscription rather than a tenant-wide average - averaging a
  well-run production subscription with a neglected sandbox describes neither.
  `-Subscription` filters which ones appear, taking names or ids.

  Rows accumulate and are never deduped. Secure Score is trimmed to its newest snapshot,
  because `Get-MsecSecureScore` returns ~90 days on every call and appending all of it would
  add ~90 near-duplicate rows per run.

  Collection degrades rather than fails: a tenant missing a Defender or Entra P1 licence
  gets a 403 on some measurements, and those are recorded in a RunLog sheet while every
  other measurement still lands. A failed measurement contributes no row, leaving a visible
  gap rather than a fabricated zero.
- `Kql/Graph/Policy/Compliance.kql` - compliance score per initiative assignment per
  subscription, run with
  `Search-MsecAzureResourceGraph -ResourceType Policy -Name Compliance`. `-Subscription`
  scopes it server-side; the result aggregates to a few dozen rows, so picking initiatives is
  a `Where-Object` away.

  The score is per RESOURCE, matching the portal. `policystates` holds one row per resource
  per policy, so an initiative with 200 policies over 50 resources is 10,000 rows - counting
  those compliant-vs-total answers "what share of checks passed", a much flatter number where
  one bad resource failing twenty rules barely registers. The query rolls up to the resource
  first (non-compliant if ANY policy in the initiative says so), then counts resources.
  `NonCompliantChecks` is kept alongside for the size of the remediation job.
- `Get-MsecEntraDisabledUser` - every account with `accountEnabled = false`, how long it has
  been disabled, and how many licences it still holds.

  Entra records no `disabledDateTime`, so the duration comes from the directory audit log -
  an `Update user` event whose `modifiedProperties` show `AccountEnabled` going `[true]` ->
  `[false]`. Those logs retain 30 days on P1/P2 and 7 on the free tier, so an account
  disabled inside that window gets an exact `DisabledSince`, `DisabledDays` and `DisabledBy`,
  and one disabled before it gets a BRACKET instead: `DisabledAtLeastDays` (nothing found in
  the window searched) and `DisabledAtMostDays` (days since its last successful sign-in,
  since a disabled account cannot sign in). `DisabledSource` says which of the two you have
  rather than leaving it to be inferred from a null.

  The upper bound comes from `signInActivity`, which Entra persists on the user object rather
  than serving from a log - so unlike `DisabledSince` it is not capped at the audit retention
  window and reaches back years (it does need Entra ID P1). It rests specifically on
  `lastSuccessfulSignInDateTime`: `lastSignInDateTime` records the last interactive ATTEMPT,
  and a disabled account still gets attempted, so bounding on it would report "disabled at
  most 7 days" for an account switched off three years ago. Where no successful sign-in is
  recorded the bound is left blank rather than guessed. All four timestamps are surfaced -
  `LastSignIn` (newest of any kind), `LastSuccessfulSignIn`, `LastInteractiveSignIn` and
  `LastNonInteractiveSignIn`, the last being how a service account looks dead interactively
  while being busy every hour.
  "Last updated" is three columns, because Graph exposes no `lastModifiedDateTime` on a user
  and the three real signals answer different questions: `LastDirectoryChange` (+ `...What`,
  naming which properties moved) is the newest audit event against the object and is bounded
  by the same retention, so null means "not in the window" rather than "never";
  `LastPasswordChange` is unbounded and usually the best marker of when a disabled account
  was genuinely last in use; `OnPremisesLastSync` catches the orphan case, where sync is
  still enabled but the on-premises source object is gone.
  Degrades rather than fails: a tenant without Entra ID P1 rejects `signInActivity`, so the
  call is retried without it; an unreadable audit log costs the dates but not the user list.
  Needs `User.Read.All` and `AuditLog.Read.All`, both already granted by `New-MsecApp`.
- `Get-MsecIntuneScriptResult` - per-device results from all five Intune script collections:
  remediations (deviceHealthScripts), platform scripts (deviceManagementScripts and
  deviceShellScripts), macOS custom attributes and custom compliance discovery scripts.
  The data behind the portal's Excel export. Reads deviceRunStates only - per-user results
  from user-context scripts are not covered.

### Removed
- `Set-MsecDefenderAlert -Comment`, and the `Invoke-MsecAdminDefenderRequest` helper behind it.

  IT PUT TWO DIFFERENT USER IDENTITIES INSIDE ONE COMMAND. Status and classification went through
  the Connect-MsecAdmin delegated session; the comment went to the Defender for Endpoint API on a
  separate Az-context token, because that host will not accept a Graph token. Nothing stopped those
  being two different people - an alert could be resolved by one and commented by another - and
  nothing in the output said which was which.

  It bought very little. The Defender API only knows ENDPOINT alerts: measured, 29 of 569 on one
  tenant, and none of the alerts anyone there actually triaged, which are Defender for Cloud and
  report `serviceSource` `unknownFutureValue`. Five per cent coverage did not justify a second
  authentication path.

  Notes belong on the incident - `Set-MsecDefenderIncident -ResolvingComment` - which Microsoft
  describes as explaining the resolution and the classification choice and which works for every
  incident whatever raised it. `Get-MsecDefenderAlert` keeps `ProviderAlertId`: it is the alert's
  id in the product that raised it and is useful for cross-referencing the portal, independently of
  the removed feature.

  A test now asserts the command reaches only the delegated Graph session, so a second transport
  reappearing is a failure whatever it authenticates with.
- `Export-MsecWordReport`. It was the module's only optional-dependency command, requiring
  PSWriteOffice to be installed separately, and its tests skipped entirely when that module
  was absent - so on CI and on most machines it was shipped but never exercised. Pipe to
  `Export-Csv`, or to `Export-Excel` from the ImportExcel module, for the same evidence.

### Changed
- `Get-MsecSharePointSiteUser -Url <site>` now CONNECTS ITSELF. Every other command in the
  module is one call after `Connect-Msec`; requiring a separate `Connect-MsecSharePointOnline`
  first made SharePoint the exception for no good reason.

  It does so WITHOUT moving the caller's session. PnP keeps a single ambient connection, so a
  command that simply called `Connect-PnPOnline` would leave the caller pointed at a different
  site than they were on - a side effect nobody asked for that only shows up later. The
  connection is created with `Connect-MsecSharePointOnline -PassThru` (new switch, wrapping
  PnP's `-ReturnConnection`) and threaded through each PnP call explicitly. Verified live:
  reading site B left `Get-PnPConnection` pointing at site A.

  Omitting `-Url` still uses the ambient connection, so existing scripts are unaffected.- `Select-MsecAzureContext` now RECONNECTS THE MSEC APP SESSION to the tenant it switches to,
  when that tenant has been connected before. `Connect-Msec` remembers the vault name, client
  id and certificate name per tenant on a successful connection; switching context replays
  them.

  msec runs on two identities - the Az context is you, the msec session is the app
  registration - and switching one left the other pointing at the tenant you just left, so
  Graph and Defender calls kept answering for the wrong tenant. That was already detected; it
  was a warning telling you to run Connect-Msec again. Now it is fixed where it can be, and the
  warning remains for the cases it cannot (no saved profile, or -NoConnect).

  NO SECRET IS STORED, and none is needed: msec signs its client assertion inside Key Vault and
  the private key never leaves it. The profile holds what you would type on the command line,
  under the tenant's own folder beside the completion caches, so two tenants can never overwrite
  each other. `-NoSave` on Connect-Msec skips writing one; `-NoConnect` on
  Select-MsecAzureContext skips replaying one.

  Written only AFTER the tokens are obtained, so a saved profile always describes a connection
  that worked rather than one that was merely typed. A missing, malformed or incomplete profile
  is treated as no profile rather than as an error mid-switch, and a reconnect that fails warns
  without failing the context switch - the switch is what was asked for and it stands.
- The four snapshot reports (`Export-MsecVMUpdateReport`, `Export-MsecVMNtpReport`,
  `Export-MsecEntraDisabledUserReport`, `Export-MsecDefenderDeviceReport`) now ASK before
  replacing a worksheet that already holds evidence, and take `-Force` to skip the question.
  They replace rather than append - that is the point of a snapshot - which also means a
  mistyped path silently destroyed last month's evidence.

  Asked only when something would actually be lost. A new file, or a new tenant or subscription
  inside an existing file, is not a question worth interrupting for; a sheet already holding
  THIS subject's rows is. Two owners whose names truncate to the same 31 characters are a
  collision rather than an overwrite - the newcomer gets its own suffixed sheet - so that does
  not prompt either. The prompt names the sheet, its row count and when it was collected, so
  the answer can be given on the facts.

  ASKED BEFORE THE COLLECTION, NOT AFTER, so declining costs nothing: no directory enumeration,
  and on the VM reports no Run Command invocations against live machines.

  `Resolve-MsecEvidenceSheet` is shared by the prompt and by the writer, so the sheet the
  caller was asked about is necessarily the sheet that gets written - asking the question in
  two places is how a confirmation ends up guarding the wrong one.

  Unattended runs need `-Force`: a scheduled task has no one to answer, and `ShouldContinue` in
  a non-interactive host is an error rather than a default.

  `Confirm-MsecEvidenceOverwrite` also takes a SET of subjects, so a report writing many sheets
  in one run asks a single question naming all of them.

### Fixed
- `Get-MsecSharePointSiteUser` read no groups at all. `Get-PnPGroup @($spec.Param)` is an ARRAY
  SUBEXPRESSION, not splatting - it passed a one-element array that bound positionally to
  `-Identity`, so every call failed. Found on the first real run against a live site.

  The symptom was the more instructive half: the catch block reported "this site has no
  associated Owner group", asserting a cause it had not checked, so a code defect read as a
  property of the tenant. The message now says what happened before what might have caused it.
- `PrincipalType` was inconsistent between the two paths that produce it - SharePoint types a
  direct member 'User', Graph types an expanded group member '#microsoft.graph.user'. The same
  person therefore read as 'User' or 'user' depending on how they got access, and a filter on
  either silently missed the other. Both are normalised to Graph's lowercase form now.
- A missing msec session no longer degrades silently. Expanding a security group needs a Graph
  session as well as the PnP one; without it every group came back `IsResolved = $false`, which
  is exactly what a DELETED group looks like - so the output read as a tenant full of orphaned
  groups rather than as a missing connection. It now warns up front, and every unresolved row
  carries an `UnresolvedReason` distinguishing "no session" from "group could not be read".- `Search-MsecAzureResourceGraph` now fingerprints the QUERY into its cache key. The key was the
  resource type, the name and the subscription scope - none of which change when the .kql does -
  so editing a bundled query kept serving rows in the old shape, and the author reasonably
  concluded the edit had not applied. Found the hard way while editing `Resource/Unused.kql`.

  A cached result written before this has no fingerprint and is treated as a miss rather than
  trusted, since it may have been written by a different query.- An OS release or device platform that EMPTIES OUT now reports 0 rather than blank. Those
  columns are discovered from the data, so the run where the last device leaves iOS 26 simply
  stops producing that column - and `Export-Excel -Append` maps by name, leaving the cell
  empty. Excel plots a blank as a GAP, so the line stopped dead exactly where it should have
  descended to zero: "we stopped measuring" instead of "nobody is on it any more", which is the
  good news the sheet exists to show.

  It also stops the sheet being rewritten every time the release set shrinks - a column going
  missing is schema drift as much as a column appearing, and a rewrite is the one operation
  that discards manual formatting.

  Deliberately NOT done generally: this is right for counts and wrong for scores. A
  subscription that drops out of AzureSecureScore was not measured, and writing 0 there would
  report a perfect-zero score rather than an absence. History is left alone too - a release that
  did not exist yet keeps its blank, which is different from nobody being on it.
- A DAMAGED WORKBOOK COULD BE SILENTLY REPLACED BY A FRESH ONE, losing every sheet in it rather
  than just one. Export-Excel can CREATE the file, so it treats "cannot read this" and "nothing
  here yet" identically - and a zero-byte file is indistinguishable from a new one. A OneDrive
  placeholder that never downloaded, or a run killed mid-save, therefore got replaced by a
  workbook holding one sheet and one row, and the write reported success. Reproduced.

  `Assert-MsecExcelWorkbook` now runs before either writer touches the path: a file that exists
  but is empty, unopenable, or holds no worksheets is refused, and left exactly as found so
  version history can still restore it. A path that does not exist is still a normal first run.
- A SHEET REWRITE COULD SILENTLY DISCARD EVERY ROW EVER COLLECTED. `Write-MsecExcelSheet`
  rewrites with `-ClearSheet`, so whatever it reads back first is the entire surviving record -
  and it caught every failure of that read and carried on with an empty history, reporting the
  loss only through `Write-Verbose`. Any transient failure to read the workbook (open in Excel,
  a sync client mid-write) therefore reduced a posture sheet to the single row from that run.
  Reproduced at five rows in, one row out.

  It now reads the sheet's row count from the package BEFORE reading its contents, which is
  what makes "there is nothing to preserve" distinguishable from "I could not read what is
  there". Only the first proceeds; the second throws, and the file is left untouched. Reading
  back FEWER rows than the sheet holds is refused on the same grounds - a truncated history is
  not recoverable, a refusal is.

  This only ever fired on a RESHAPE (a measurement changing its column set); ordinary appends
  go through `Export-Excel -Append` and never took this path.
- A sheet that cannot be written now costs only its own row rather than the whole run, matching
  how the collect half already degraded. The refusal above would otherwise throw away nine
  successfully collected measurements to protect one, and the failure is recorded in RunLog.
- A column that appeared AFTER a posture-report chart was first drawn now gets a series on it.
  The sheets with dynamic columns - one per Azure subscription, per Secure Score category, per
  policy initiative - grow a column whenever the estate does, and the dashboard only ever
  refreshed the ranges of series the chart already carried. So a new subscription landed on the
  AzureSecureScore sheet, appeared in the schema-drift warning, and was then absent from the
  chart indefinitely: the report quietly under-reported the estate while looking complete.
  Series are only ever ADDED, so one added by hand in Excel still survives.
- A series whose column is still on the sheet but which this run did not collect now keeps
  growing with the sheet. A subscription that drops out of the Az context keeps its column
  (`Write-MsecExcelSheet` takes the UNION of old and new columns, so history is never dropped)
  but its chart range stopped at the row count it had when last collected - so the line ended
  early, reading as the data stopping rather than the subscription leaving.
- `New-MsecApp` now requests `DeviceManagementScripts.Read.All`. Intune scripts are a
  separate scope from `DeviceManagementConfiguration.Read.All`, which does not cover
  deviceHealthScripts or deviceCustomAttributeShellScripts even though both sit under
  /deviceManagement beside the configuration policies - they answer 403 without it.
- `New-MsecApp` reported its permission grants only through `Write-Verbose`, so a re-run
  that added a dozen app roles printed one line about finding the app and nothing about the
  grants - indistinguishable from having done nothing. It now prints a summary, returns
  `GrantedNow` / `AlreadyGranted` / `UnavailableRoles`, and says to reconnect: consent does
  not apply to a token that was already issued, so re-running to fix a 403 and retrying in
  the same session hits the same 403.

## [0.1.0] - 2026-08-20

First release.

### Added
- **Secure Score** - `Get-MsecSecureScore` (overall and per category, over time),
  `Get-MsecAzureSecureScore` (Defender for Cloud, per subscription),
  `Get-MsecDefenderScoreExposure`, `Get-MsecDefenderScoreDeviceConfiguration`.
- **Defender XDR** - `Get-MsecDefenderIncidentStats`, `Get-MsecDefenderEmailStats`.
- **Entra ID** - `Get-MsecEntraTenantSecuritySetting`, `Get-MsecEntraLicense`,
  `Get-MsecEntraRoleHolder`, `Get-MsecEntraConditionalAccessPolicy`,
  `Get-MsecEntraConditionalAccessStats`, `Get-MsecEntraConditionalAccessSignInLog`,
  `Get-MsecEntraMfaRegistration`, `Get-MsecEntraMfaRegistrationStats`,
  `Get-MsecEntraMfaEvidence`, `Convert-MsecEntraSid`.
- **Intune** - `Get-MsecIntuneConfigurationProfile`, `Get-MsecIntuneCompliancePolicy`,
  `Get-MsecIntuneDevice`, `Get-MsecIntuneScriptResult`.
- **Azure** - `Search-MsecAzureResourceGraph`, `Search-MsecLogAnalytics`,
  `Invoke-MsecAzureVMScript`, `Select-MsecAzureContext`.
- **Azure DevOps** - `Get-MsecAzureDevOpsServiceConnection`.
- **Session** - `New-MsecApp`, `Connect-Msec`, `Disconnect-Msec`. The private key stays
  in Azure Key Vault; tokens are JWT client assertions signed there.
- **Reporting** - `Export-MsecWordReport`.

### Notes on the output shape

These are the decisions most likely to surprise, and the reasoning is in each command's
help under `.NOTES`:

- **Directory roles are matched by `roleTemplateId`, never by display name.** Graph
  returns Global Administrator as *Company Administrator* on many tenants, display names
  are localisable, and a tenant can rename a role - so a name comparison silently reports
  zero. `Get-MsecEntraRoleHolder -Role 'Global Administrator'` resolves through the
  canonical map and matches either way.
- **`Get-MsecEntraRoleHolder` separates the assignee from the holder.** A role assigned to
  a group reports the group in `Principal*` and each member in `Effective*`, so counting
  administrators and counting grants are different questions that no longer contaminate
  each other. PIM-eligible assignments are included.
- **Intune assignment targets are typed columns, not a summary string.** `AssignmentType`,
  `AssignmentGroup` and `AssignmentExcludedGroup` are arrays, so `-contains` is exact;
  `msec.format.ps1xml` flattens them for display only. An assignment count cannot tell
  *All Users plus an exclusion group* from *two unrelated groups*.
- **Unmeasured is `$null`, measured-and-zero is `0`.** A failed read never reports the same
  value as a successful one that found nothing; where a command can say why, it does.
