/system/script/run global_definitions;

:local runLoadbalance do={
    :global getLinkNameFromComment;
    :global getLinkBandwidthFromComment;
    :global defaultLinkPattern;
    :global calculateGCD;

    :local gcd [];
    :local bandwidthTotal 0;
    :local routesEnabledCount [/ip/route/print count-only where dst-address=0.0.0.0/0 routing-table=main disabled=no comment~$defaultLinkPattern];
    :local addressListExists ([/ip/firewall/address-list/print count-only where list=loadbalance-local-networks] >= 1);

    /ip/firewall/mangle/remove [find comment~"\\[Loadbalance\\] PCC.*#script-generated"];

    :if (!$addressListExists) do={
        :error "[Loadbalance] A lista de endereços 'loadbalance-local-networks' não existe ou está vazia. Por favor, crie-a e/ou a preencha antes de executar este script";
    };
    
    :if ($routesEnabledCount = 0) do={
        :error "[Loadbalance] Não foram encontradas rotas suficientes ativas para o balanceamento de carga. Verifique as configurações";
    }

    foreach routeId in=[/ip/route/find dst-address=0.0.0.0/0 routing-table=main disabled=no comment~$defaultLinkPattern] do={
        :local bandwidth [$getLinkBandwidthFromComment [/ip/route/get $routeId comment]];
        :set bandwidthTotal ($bandwidthTotal + $bandwidth);
        :set gcd ($gcd, $bandwidth);
    }

    :set gcd [$calculateGCD $gcd];

    :local mangleIndex 0;
    :local mangleQtdTotal ($bandwidthTotal / $gcd);
    :foreach routeId in=[/ip/route/find dst-address=0.0.0.0/0 routing-table=main disabled=no comment~$defaultLinkPattern] do={
        :local routeBandwidth [$getLinkBandwidthFromComment [/ip/route/get $routeId comment]];
        :local routeName [$getLinkNameFromComment [/ip/route/get $routeId comment]];
        :local mangleQtd ($routeBandwidth / $gcd);

        :for i from=1 to=$mangleQtd do={
            /ip/firewall/mangle/add \
                chain=loadbalance \
                per-connection-classifier="both-addresses:$mangleQtdTotal/$mangleIndex" \
                action=mark-connection new-connection-mark="loadbalance-conn-out-$routeName" passthrough=yes \
                comment="[Loadbalance] PCC: $routeName ($mangleQtdTotal/$mangleIndex) #script-generated";
            
            :set mangleIndex ($mangleIndex + 1);
        }
    }
};

:local runFailover do={
    :global defaultLinkPattern;
    :global getLinkNameFromComment;
    :global failoverPreviousState;
    :global sendTelegramMessage;
    
    :local runLoadbalance $1;
    :local enableAllRoutes do={ :global defaultLinkPattern; /ip/route/enable [find dst-address=0.0.0.0/0 comment~$defaultLinkPattern]; };
    :local routesIds [/ip/route/find dst-address=0.0.0.0/0 routing-table=main comment~$defaultLinkPattern];

    :if ([:len $routesIds] <= 1) do={
        :if ($failoverPreviousState != "sem-rotas-suficientes") do={
            $enableAllRoutes;
            :set failoverPreviousState "sem-rotas-suficientes";

            :log error "[Failover] Não foram encontradas rotas suficientes para o failover automático. Verifique as configurações ou desabilite esse script.";
            $sendTelegramMessage "%E2%9D%97%E2%9D%97[Failover] Não foram encontradas rotas suficientes para o failover automático.%0A%0AVerifique as configurações ou desabilite esse script.";
        
            $runLoadbalance;
        }

        :return 0;
    }

    :local ipList {1.1.1.1; 8.8.8.8; 9.9.9.9; 76.76.19.19};

    :local pingAttempts 12;
    :local pingMaxResponseTime .280;
    :local pingTotalAttempts ($pingAttempts * [:len $ipList]);
    :local pingMinPercentSuccess 75;

    :local routeMinPercentSuccess 75;
    :local routesFailedCount 0;
    :local routesThatStateChanged [];

    :foreach routeId in=$routesIds do={
        :local routeName [$getLinkNameFromComment [/ip/route/get $routeId comment]];
        :local routeIsDisabled [/ip/route/get $routeId disabled];
        :local failoverRouteTable "vrf-failover-$routeName";

        :local successfulTestCount 0;

        # necessário para inicializar as tabelas de VRF
        ping 127.0.0.1 count=1;

        :foreach ip in=$ipList do={
            :local successfulPingCount [ping address=$ip vrf=$failoverRouteTable interval=$pingMaxResponseTime count=$pingAttempts];
            :local successPingRatio (($successfulPingCount * 100) / $pingAttempts);

            :if ($successPingRatio >= $pingMinPercentSuccess) do={
                :set successfulTestCount ($successfulTestCount + 1);
            }
        }

        :local successRatio (($successfulTestCount * 100) / [:len $ipList]);

        :if ($successRatio >= $routeMinPercentSuccess && $routeIsDisabled) do={
            :set routesThatStateChanged ($routesThatStateChanged, {{"successRatio"=$successRatio;"newState"=true;name=$routeName}});
        } 
        
        :if ($successRatio < $routeMinPercentSuccess && !$routeIsDisabled) do={
            :set routesThatStateChanged ($routesThatStateChanged, {{"successRatio"=$successRatio;"newState"=false;name=$routeName}});
            :set routesFailedCount ($routesFailedCount + 1);
        }
    }

    :local allRoutesFailed ($routesFailedCount = [:len $routesIds]);

    :if ($allRoutesFailed) do={
        :if ($failoverPreviousState != "todas-as-rotas-falharam") do={
            $enableAllRoutes;
            :set failoverPreviousState "todas-as-rotas-falharam";

            :log error "[Failover] Todas as rotas falharam. Verifique a conectividade da rede";
            $sendTelegramMessage "%E2%9D%97%E2%9D%97[Failover] Todas as rotas falharam.%0A%0AVerifique a conectividade da rede.";

            $runLoadbalance;
        }
        
        :return 0;
    } 

    if ([:len $routesThatStateChanged] > 0) do={
        :set failoverPreviousState "pelo-menos-uma-rota-foi-alterada";

        :foreach v in=$routesThatStateChanged do={
            :local routeName ($v->"name");
            :local routeIsToEnable ($v->"newState");
            :local routeFailRatio (100 - $v->"successRatio");

            :if ($routeIsToEnable) do={
                /ip/route/enable [find comment~"^Link:.*$routeName" dst-address=0.0.0.0/0];
                
                :log info "[Failover] Rota reabilitada: $routeName";
                $sendTelegramMessage ("%E2%9C%85[Failover] A rota \"" . $routeName ."\" foi reabilitada.");
            } else={
                /ip/route/disable [find (routing-table~"failover")=false comment~"^Link:.*$routeName" dst-address=0.0.0.0/0];

                :log warning ("[Failover] A rota \"$routeName\" foi desabilitada com " . $routeFailRatio . "% de perda de pacotes");
                $sendTelegramMessage ("%E2%9D%97[Failover] A rota \"$routeName\" foi desabilitada com " . $routeFailRatio . "% de perda de pacotes.%0A%0AVerifique a conectividade da rede.");
            }
        }

        $runLoadbalance;
        :return 0;
    }

    :set failoverPreviousState "sem-alteracoes";
}

$runFailover $runLoadbalance;
