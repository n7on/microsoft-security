# Live Response scripts

Uploaded to the **Defender XDR Live Response library** and run against ONE device, by an
analyst, during an investigation. Nothing in msec executes them.

Defender portal → Settings → Endpoints → Live response library.

```
LiveResponse/
└── Windows/
    └── *.ps1     one script = one library entry, invoked as: run <file> -parameters "..."
```

## This is a different blast radius from Intune/, and that is the point

A script here runs on a **single device somebody chose**, now, while they are looking at it.
An Intune Remediation runs on **every device in its assignment**, on a schedule, whether
anyone is watching or not.

The same file can do either, which is why the channels are separate top-level folders. A
Live Response script uploaded as a remediation turns one investigative action into a
fleet-wide configuration change - `Start-WindowsService -Name DiagTrack -StartupType
Automatic` is a reasonable thing to do to a machine under investigation and quite another
thing to do to all of them.

## These WRITE

Like `Intune/` and unlike `VM/`, scripts here change the machine. They are held to the same
rule as any other write in this repo: **report the observed state, not the call's success.**
Print what the thing was before, what was changed, and what it is afterwards, re-read from
the system rather than assumed - `Set-Service` returning without error does not mean the
service is running, and "fixed" while it is still stopped is worse than "failed".

## Requirements

- Live response enabled (Defender portal → Settings → Endpoints → Advanced features).
- **Live response unsigned script execution** enabled, unless the script is signed.
- The analyst needs the live response role; running a script is a higher permission than
  starting a session.
- Scripts run as SYSTEM.

## Parameters

Live Response passes everything as one string:

```
run Start-WindowsService.ps1 -parameters "-Name DiagTrack -StartupType Automatic"
```

so a `param()` block with real types and `[ValidateSet]` is worth having - it is the only
validation between the console and SYSTEM on someone's machine.
