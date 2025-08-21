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
    :global failoverLinkFailsCount;
    :global failoverLinkSuccessCount;
    
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
    :local pingMaxResponseTime .250;
    :local pingTotalAttempts ($pingAttempts * [:len $ipList]);
    :local pingMinPercentSuccess 75;

    :local routeMinPercentSuccess 51;
    :local routesFailedCount 0;
    :local routesThatStateChanged [];

    :foreach routeId in=$routesIds do={
        :local routeName [$getLinkNameFromComment [/ip/route/get $routeId comment]];
        :local routeIsDisabled [/ip/route/get $routeId disabled];
        :local failoverRouteTable "vrf-failover-$routeName";

        :local successfulTestCount 0;
        :local successfulPingCount 0;

        # necessário para inicializar as tabelas de VRF
        ping 127.0.0.1 count=1;

        :foreach ip in=$ipList do={
            :local successfulPingCountLocal [ping address=$ip vrf=$failoverRouteTable interval=$pingMaxResponseTime count=$pingAttempts];
            :local successPingRatio (($successfulPingCountLocal * 100) / $pingAttempts);

            :set successfulPingCount ($successfulPingCount + $successfulPingCountLocal);

            :if ($successPingRatio >= $pingMinPercentSuccess) do={
                :set successfulTestCount ($successfulTestCount + 1);
            }
        }

        :local successRatio (($successfulTestCount * 100) / [:len $ipList]);
        :local successPingRatio (($successfulPingCount * 100) / $pingTotalAttempts);

        :if ($successRatio >= $routeMinPercentSuccess && $routeIsDisabled) do={
            :set routesThatStateChanged ($routesThatStateChanged, {{"successRatio"=$successRatio;"newState"=true;name=$routeName;"pingSuccessRatio"=$successPingRatio}});
        } 
        
        :if ($successRatio < $routeMinPercentSuccess && !$routeIsDisabled) do={
            :set routesThatStateChanged ($routesThatStateChanged, {{"successRatio"=$successRatio;"newState"=false;name=$routeName;"pingSuccessRatio"=$successPingRatio}});
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

        # necessário para rastrear comportamentos consecutivos entre execuções
        :local linkFailsCount;
        :local linkSuccessCount;
        :local minConsecutiveFail 3;
        :local minConsecutiveSuccess 2;

        :foreach v in=$routesThatStateChanged do={
            :local routeName ($v->"name");
            :local routeIsToEnable ($v->"newState");
            :local routeSuccessRatio ($v->"successRatio");
            :local routePingSuccessRatio ($v->"pingSuccessRatio");

            :if ($routeIsToEnable) do={
                :set ($linkSuccessCount->$routeName) ($failoverLinkSuccessCount->$routeName + 1);

                :log warning ("[Failover] A rota \"$routeName\" está com " . ($linkSuccessCount->$routeName) . " tentativa(s) consecutiva(s) de sucesso registrada. O último teste teve $routeSuccessRatio% de sucesso e $routePingSuccessRatio% de entrega de pacotes");

                :if (($linkSuccessCount->$routeName) >= $minConsecutiveSuccess) do={
                    /ip/route/enable [find comment~"^Link:.*$routeName" dst-address=0.0.0.0/0];

                    :local message ("[Failover] A rota \"$routeName\" foi reabilitada após $minConsecutiveSuccess tentativas consecutivas de sucesso registrada. O último teste teve $routeSuccessRatio% de sucesso e $routePingSuccessRatio% de entrega de pacotes");
                    :log warning $message;
                    $sendTelegramMessage ("%E2%9C%85" . $message . ".");
                }
            } else={
                :set ($linkFailsCount->$routeName) ($failoverLinkFailsCount->$routeName + 1);

                :log error ("[Failover] A rota \"$routeName\" está com " . ($linkFailsCount->$routeName) . " tentativa(s) consecutiva(s) de falha registrada. O último teste teve $routeSuccessRatio% de sucesso e " . (100 - $routePingSuccessRatio) . "% de perda de pacotes");

                :if (($linkFailsCount->$routeName) >= $minConsecutiveFail) do={
                    /ip/route/disable [find (routing-table~"failover")=false comment~"^Link:.*$routeName" dst-address=0.0.0.0/0];

                    :local message ("[Failover] A rota \"$routeName\" foi desabilitada após $minConsecutiveFail tentativas consecutivas de falha registrada. O último teste teve $routeSuccessRatio% de sucesso e " . (100 - $routePingSuccessRatio) . "% de perda de pacotes");
                    :log error $message;
                    $sendTelegramMessage ("%E2%9D%97" . $message . ".%0A%0AVerifique a conectividade da rede.");
                }
            }
        }

        # transfere para o global apenas links que tiveram o mesmo comportamento entre a execução anterior e a atual.
        # dessa forma, conseguimos rastrear sucessos/falhas consecutivos(as), onde se no teste atual uma rota anterior tiver o mesmo comportamento, ela será contada.
        :set failoverLinkFailsCount $linkFailsCount;
        :set failoverLinkSuccessCount $linkSuccessCount;

        $runLoadbalance;
        :return 0;
    }

    # limpa caso não tenha registrado nenhuma alteração
    :set failoverLinkFailsCount;
    :set failoverLinkSuccessCount;
    :set failoverPreviousState "sem-alteracoes";
}

:global failoverIsRunning;

:if ($failoverIsRunning = true) do={
    :log info "[Failover] O script de failover já está em execução. Abortando nova execução.";
} else={
    :set failoverIsRunning true;
    $runFailover $runLoadbalance;
    :set failoverIsRunning false;
}
