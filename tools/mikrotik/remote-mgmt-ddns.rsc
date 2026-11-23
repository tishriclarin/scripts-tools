# MikroTik RouterOS v7: TCC dynamic remote management
# Run in Safe Mode and inspect firewall policy before using on production.
# Does NOT create a deny/drop rule. A later input-chain drop rule is REQUIRED
# to prevent other sources from reaching SSH/WinBox when services use 0.0.0.0/0.
# Uses RouterOS built-in FQDN address-list refresh; no scheduler required.

:local ddnsHost "tcc.cloud-ip.cc"
:local listName "REMOTE-MGMT"
:local ruleComment "ALLOW REMOTE-MGMT SSH WINBOX"

# Add FQDN source only if it is not already configured.
:if ([:len [/ip firewall address-list find where list=$listName and address=$ddnsHost]] = 0) do={
    /ip firewall address-list add list=$listName address=$ddnsHost comment="TCC Dynamic Remote Management"
}

# Add management access rule only once, ahead of existing filter rules.
:if ([:len [/ip firewall filter find where chain=input and comment=$ruleComment]] = 0) do={
    :if ([:len [/ip firewall filter find]] > 0) do={
        /ip firewall filter add chain=input action=accept protocol=tcp dst-port=22,8291 src-address-list=$listName comment=$ruleComment place-before=0
    } else={
        /ip firewall filter add chain=input action=accept protocol=tcp dst-port=22,8291 src-address-list=$listName comment=$ruleComment
    }
}

# Permit all IPv4 at the service layer; firewall must restrict access.
/ip service set [find where name="winbox"] address=0.0.0.0/0 disabled=no
/ip service set [find where name="ssh"] address=0.0.0.0/0 disabled=no

:log info "REMOTE-MGMT: DDNS input allow rule and SSH/WinBox service settings installed"
