/system script run global_definitions;

:local setupEnviroment do={
    :global defaultLinkPattern;
    :global getLinkNameFromComment;

    :local setupMangle do={
        :local mangleComment "[Loadbalance] Envia pacotes de saída para a chain de Loadbalance #script-generated";
        :local loadbalanceMangleExists ([/ip/firewall/mangle/print count-only where comment=$mangleComment] >= 1);

        :if (!$loadbalanceMangleExists) do={
            :local totalMangleCount [/ip/firewall/mangle/print count-only];
            :local defaultMangleCount [/ip/firewall/mangle/print count-only where comment="special dummy rule to show fasttrack counters"];

            :if ($totalMangleCount = 0 || $totalMangleCount = $defaultMangleCount) do={ 
                /ip/firewall/mangle/add \
                    chain=prerouting connection-mark=no-mark connection-state=new src-address-list=loadbalance-local-networks dst-address-list=!loadbalance-local-networks \
                    action=jump jump-target=loadbalance comment=$mangleComment;
            } else={
                /ip/firewall/mangle/add \
                    chain=prerouting connection-mark=no-mark connection-state=new src-address-list=loadbalance-local-networks dst-address-list=!loadbalance-local-networks \
                    action=jump jump-target=loadbalance comment=$mangleComment \
                    place-before=$defaultMangleCount;
            }

            :log info "[Loadbalance] Chain de Loadbalance criada com sucesso";
        }
    };
    $setupMangle;

    :foreach routeId in=[/ip/route/find dst-address=0.0.0.0/0 routing-table=main comment~$defaultLinkPattern] do={
        :local routeName [$getLinkNameFromComment [/ip/route/get $routeId comment]];
        :local routeDistance 30;
        :local routeGateway [/ip/route/get $routeId gateway];
        :local routeComment [/ip/route/get $routeId comment];
        :local loadbalanceRouteTable "vrf-loadbalance-$routeName";
        :local mangleComment "[Loadbalance] Marca rotas para $routeName #script-generated";

        :if ($routeName = "" || $routeGateway = "") do={
            :log error ("[Loadbalance] Rota sem nome encontrada: $routeId");
            continue;
        }

        :local vrfExists ([/ip/vrf/print count-only where name=$loadbalanceRouteTable] >= 1);
        :local routeExists ([/ip/route/print count-only where routing-table=$loadbalanceRouteTable dst-address=0.0.0.0/0] >= 1);
        :local mangleExists ([/ip/firewall/mangle/print count-only where comment=$mangleComment] >= 1);

        :if (!$vrfExists) do={
            /ip/vrf/add interfaces=none name=$loadbalanceRouteTable comment="[Loadbalance] VRF: $routeName #script-generated";
            :delay 2;
            :log info "[Loadbalance] Criada VRF \"$loadbalanceRouteTable\" para o gateway \"$routeGateway\" via \"$routeName\"";
        }

        :if (!$routeExists) do={
            /ip/route/add gateway=$routeGateway routing-table=$loadbalanceRouteTable dst-address=0.0.0.0/0 distance=$routeDistance comment=$routeComment;
            :log info "[Loadbalance] Adicionada rota \"$loadbalanceRouteTable\" para gateway \"$routeGateway\" via \"$routeName\"";
        }

        :if (!$mangleExists) do={
            /ip/firewall/mangle/add \ 
                chain=prerouting connection-mark="loadbalance-conn-out-$routeName" src-address-list=loadbalance-local-networks dst-address-list=!loadbalance-local-networks \
                action=mark-routing new-routing-mark=$loadbalanceRouteTable passthrough=no \
                comment=$mangleComment;
            
            :log info "[Loadbalance] Mangle criado para o gateway \"$routeGateway\" via \"$routeName\"";
        }
    }
}

$setupEnviroment;