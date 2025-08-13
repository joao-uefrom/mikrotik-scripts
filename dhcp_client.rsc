# Use apenas quando o link do provedor for configurado via DHCP

:local routeDistance 10;
:local routeBandwidth 10; # Em Mbps (Mbps / 8 = MBps)

:local gatewayAddress (($"gateway-address") . "%" . $interface);
:local routeName [:pick $interface ([:find $interface "-"] + 1) [:len $interface]];
:local routeTable main;
:local routeComment "Link: $routeName; Bandwidth: $routeBandwidth Mbps #script-generated";

:local searchPattern ("^Link: $routeName;.*#script-generated\$");
:local routeExists ([/ip/route/print count-only where routing-table=$routeTable && comment~$searchPattern] >= 1);

:if ($bound=1) do={
    :if ($routeExists) do={
        /ip/route/set [find routing-table=$routeTable && comment~$searchParttern] gateway=$gatewayAddress comment=$routeComment;
        :log info "[DHCP-Rota] Atualizada \"$routeName\" para gateway \"$gatewayAddress\" via \"$interface\"";
    } else={
        /ip/route/add gateway=$gatewayAddress distance=$routeDistance dst-address=0.0.0.0/0 routing-table=$routeTable comment=$routeComment;
        :log info "[DHCP-Rota] Adicionada \"$routeName\" para gateway \"$gatewayAddress\" via \"$interface\"";
    }
} else={
    :if ($routeExists) do={
        /ip/route/remove [find routing-table=$routeTable && comment~$searchPattern];
        :log warning "[DHCP-Rota] Removida \"$routeName\" por falta de concessão DHCP na interface \"$interface\"";
    }
}
