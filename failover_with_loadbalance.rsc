/system script run global_definitions;

# return = 0 - nenhum link foi alterado; 1 - no mínimo 1 link foi alterado; 2 - links insuficientes para failover;
:global runFailover do={
    :global defaultLinkPattern;
    :global getLinkNameFromComment;
    :global failoverIpList;
    :global failoverMinPercentSuccessfulPings;
    :global failoverPingAttempts;
    :global failoverAllRoutesFailed; # 0 - algum link está ativo na execução atual; 1 - todos os links falharam na execução atual;
    :global sendTelegramMessage;

    :local pingInterval .5;
    :local pingTotalAttempts ($failoverPingAttempts * [:len $failoverIpList]);

    :local routesIds [/ip/route/find dst-address=0.0.0.0/0 routing-table=main comment~$defaultLinkPattern];
    :local routesFailIds [];

    :if ([:len $routesIds] <= 1) do={
        /ip/route/enable [find dst-address=0.0.0.0/0 routing-table=main comment~$defaultLinkPattern];
        :log error "[Failover] Não foram encontradas rotas suficientes para o failover automático. Verifique as configurações ou desabilite esse script.";
        :return 2;
    }

    # necessário para inicializar as tabelas de VRF
    ping 127.0.0.1 count=1;
    :delay 1;

    :foreach routeId in=$routesIds do={
        :local successfulPingCount 0;
        :local routeName [$getLinkNameFromComment [/ip/route/get $routeId comment]];
        :local failoverRouteTable "vrf-failover-$routeName";

        :foreach ip in=$failoverIpList do={
            :set successfulPingCount ($successfulPingCount + [ping address=$ip vrf=$failoverRouteTable interval=$pingInterval count=$failoverPingAttempts]);
        }

        :local successRatio (($successfulPingCount * 100) / $pingTotalAttempts);

        :if ($successRatio < $failoverMinPercentSuccessfulPings) do={
            :set routesFailIds ($routesFailIds, $routeId);
            :log warning ("[Failover] A rota \"$routeName\" falhou com " . (100 - $successRatio) . "% de perda de pacotes");
        }
    }

    :local allRoutesFailed ([:len $routesFailIds] = [:len $routesIds]);

    :if ($allRoutesFailed) do={
        /ip/route/enable [find dst-address=0.0.0.0/0 comment~$defaultLinkPattern];
        :log error "[Failover] Todas as rotas falharam. Verifique a conectividade da rede";
        $sendTelegramMessage "%E2%9D%97%E2%9D%97[Failover] Todas as rotas falharam.%0A%0AVerifique a conectividade da rede.";

        :if ($failoverAllRoutesFailed = 0) do={
            :set failoverAllRoutesFailed 1;
            :return 1; # pelo menos uma rota foi alterada
        }

        :return 0; # nenhuma rota foi alterada
    } else={
        :local wasAnyRouteChanged false;

        :foreach routeId in=$routesIds do={
            :local routeFaield false;
            :local routeName [$getLinkNameFromComment [/ip/route/get $routeId comment]];
            :local routeIsDisabled [/ip/route/get $routeId disabled];
            :local failoverRouteTable "vrf-failover-$routeName";

            :foreach failRouteId in=$routesFailIds do={
                :if ($routeId = $failRouteId) do={
                    :set routeFaield true;
                }
            }

            :if ($routeFaield && !$routeIsDisabled) do={
                /ip/route/disable [find routing-table!=$failoverRouteTable comment~"^Link:.*$routeName" dst-address=0.0.0.0/0];
                :log warning "[Failover] Rota com falha desabilitada: $routeName";
                $sendTelegramMessage ("%E2%9D%97[Failover] A rota \"" . $routeName ."\" foi desabilitada com falha.%0A%0AVerifique a conectividade da rede.");
                :set wasAnyRouteChanged true;
            } else={
                :if (!$routeFaield && $routeIsDisabled) do={
                    /ip/route/enable [find comment~"^Link:.*$routeName" dst-address=0.0.0.0/0];
                    :log info "[Failover] Rota reabilitada: $routeName";
                    $sendTelegramMessage ("%E2%9C%85[Failover] A rota \"" . $routeName ."\" foi reabilitada.");
                    :set wasAnyRouteChanged true;
                }
            }
        }

        :set failoverAllRoutesFailed 0;
        :if ($wasAnyRouteChanged) do={
            :return 1; # pelo menos uma rota foi alterada
        } else={
            :return 0; # nenhuma rota foi alterada
        }
    }
}

:global runLoadbalance do={
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
                action=mark-connection new-connection-mark="loadbalance-conn-out-$routeName" passthrough=no \
                comment="[Loadbalance] PCC: $routeName ($mangleQtdTotal/$mangleIndex) #script-generated";
            
            :set mangleIndex ($mangleIndex + 1);
        }
    }
};

:global loadbalanceWasExecuted;
:local result [$runFailover];

:if ($result >= 1 || $loadbalanceWasExecuted = nil) do={
    :set loadbalanceWasExecuted true;
    $runLoadbalance;
}