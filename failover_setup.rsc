/system script run global_definitions;

:local setupEnviroment do={
    :global getRouteNameFromComment;
    :global defaultLinkPattern;

    :foreach routeId in=[/ip/route/find dst-address=0.0.0.0/0 routing-table=main comment~$defaultLinkPattern] do={
        :local routeName [$getRouteNameFromComment [/ip/route/get $routeId comment]];
        :local routeDistance 20;
        :local routeGateway [/ip/route/get $routeId gateway];
        :local routeComment [/ip/route/get $routeId comment];
        :local failoverRouteTable "vrf-failover-$routeName";

        :local vrfExists ([/ip/vrf/print count-only where name=$failoverRouteTable] >= 1);
        :local routeExists ([/ip/route/print count-only where routing-table=$failoverRouteTable dst-address=0.0.0.0/0] >= 1);
        :local ruleExists ([/routing/rule/print count-only where routing-mark=$failoverRouteTable table=$failoverRouteTable] >= 1);

        :if (!$vrfExists) do={
            /ip/vrf/add interfaces=none name=$failoverRouteTable comment="[Failover] VRF: $routeName #script-generated";
            :log info ("[Failover] Criada VRF \"$failoverRouteTable\"");
            :delay 2;
        }

        :if (!$routeExists) do={
            /ip/route/add gateway=$routeGateway routing-table=$failoverRouteTable dst-address=0.0.0.0/0 distance=$routeDistance comment=$routeComment;
            :log info ("[Failover] Adicionada rota \"$failoverRouteTable\" para gateway \"$routeGateway\" via \"$routeName\"");
        }

        :if (!$ruleExists) do={
            /routing/rule/add action=lookup-only-in-table routing-mark=$failoverRouteTable table=$failoverRouteTable comment="Rule Failover: $routeName #script-generated";
            :log info ("[Failover] Adicionada regra de roteamento \"$failoverRouteTable\" para \"$routeName\"");
        }
    }
}

$setupEnviroment;