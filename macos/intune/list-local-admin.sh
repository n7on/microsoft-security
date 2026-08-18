#!/bin/sh
#
# Intune > Devices > macOS > Custom attributes for macOS
#
#   Data type : String
#   Runs as   : root, every 8 hours, by the Intune management agent
#   Output    : comma-separated, qualified admin accounts, or "none"
#
#     AzureAD\anton.lindstrom@viedoc.com,Local\localadmin
#
# v2: output is now qualified per account source so it lines up with the
# Windows report, which shows Entra accounts as AzureAD\<name>.
#
#   AzureAD\<upn>       Platform SSO / Entra-linked account
#   <DOMAIN>\<name>     legacy Active Directory mobile account
#   Local\<name>        local-only account
#
# Note the asymmetry with Windows, which is unavoidable: Windows displays the
# *derived* name (AzureAD\FirstnameLastname), macOS gives you the real UPN.
# If you need the two reports to join on a key, join on UPN and normalise the
# Windows side by SID, not by the displayed name.

PATH=/usr/bin:/usr/sbin:/bin:/sbin
export PATH

admins=""

append() {
    if [ -z "$admins" ]; then
        admins="$1"
    else
        admins="$admins,$1"
    fi
}

# Real (non-service) accounts: UID >= 500 and shortname not starting with "_".
users=$(dscl . -list /Users UniqueID 2>/dev/null | awk '$2 >= 500 { print $1 }')

for user in $users; do
    case "$user" in
        _*|daemon|nobody|Guest) continue ;;
    esac

    # Admin membership via dseditgroup, NOT by reading GroupMembership directly:
    # that attribute misses members added by GeneratedUID or through nesting.
    if ! dseditgroup -o checkmember -m "$user" admin 2>/dev/null | grep -q '^yes'; then
        continue
    fi

    # --- Entra / Platform SSO ------------------------------------------------
    # PSSO writes the Entra UPN into AltSecurityIdentities as ...PlatformSSO:<upn>.
    # tr turns the value into one token per line, which tolerates dscl's habit of
    # wrapping long attribute values onto a continuation line.
    upn=$(dscl . -read "/Users/$user" dsAttrTypeStandard:AltSecurityIdentities 2>/dev/null \
          | tr ' ' '\n' \
          | grep -i 'PlatformSSO:' \
          | sed 's/.*[Ss][Ss][Oo]://' \
          | head -n 1)

    if [ -n "$upn" ]; then
        append "AzureAD\\$upn"
        continue
    fi

    # --- Legacy AD mobile account -------------------------------------------
    node=$(dscl . -read "/Users/$user" OriginalNodeName 2>/dev/null | tr '\n' ' ')
    case "$node" in
        *"Active Directory"*)
            domain=$(printf '%s' "$node" \
                     | sed -e 's|.*Active Directory/||' -e 's|/.*||' -e 's|[[:space:]]*$||')
            [ -z "$domain" ] && domain="AD"
            append "$domain\\$user"
            continue
            ;;
    esac

    # --- Local-only ----------------------------------------------------------
    append "Local\\$user"
done

# printf, not echo: /bin/sh interprets backslash escapes in echo, which would
# eat the separator in "AzureAD\anton..." (\a becomes a bell character).
if [ -z "$admins" ]; then
    printf 'none\n'
else
    printf '%s\n' "$admins"
fi

exit 0
