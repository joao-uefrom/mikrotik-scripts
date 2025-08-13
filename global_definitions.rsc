:global defaultLinkPattern "Link:.*; {0,}?Bandwidth: {0,}?[0-9]{1,}";

:global failoverIpList {1.1.1.1; 8.8.8.8; 200.160.0.8; 31.13.80.8};
:global failoverMinPercentSuccessfulPings 75;
:global failoverPingAttempts 4;

:global loadbalanceAddressList "loadbalance-local-networks";

:global getLinkNameFromComment do={
    :local searchStr "Link:";
    :local startIndex [:find $1 $searchStr];

    :if (!($startIndex >= 0)) do={
        :return "";
    }

    :local comment [:pick $1 ([:find $1 $searchStr] + [:len $searchStr]) [:len $1]]
    
    :local name "";
    :local index 0;
    :local nameIndex 0;
    :local exitLoop false;

    :do { 
        :local l [:pick $comment $index];
        :set index ($index + 1);

        :if ($l = " ") do={
            :set nameIndex ($nameIndex + 1);
        } else={
            :set exitLoop true;
        }
     } while (!$exitLoop);

    :set exitLoop false;

    :do { 
        :local l [:pick $comment $nameIndex];
        :set nameIndex ($nameIndex + 1);

        :if ($l = " " || $l = ";") do={
            :set exitLoop true;
        } else={
            :set name ($name . $l);
        }
     } while (!$exitLoop && $nameIndex < [:len $comment]);

    :return $name;
}

:global getLinkBandwidthFromComment do={
    :local searchStr "Bandwidth:";
    :local comment [:pick $1 ([:find $1 $searchStr] + [:len $searchStr]) [:len $1]]
    
    :local bandwidth "";
    :local index 0;
    :local exitLoop false;

    :do { 
        :local n [:pick $comment $index];
        :set index ($index + 1);

        :if ($n != " ") do={
            :if ($n ~ "[0-9]") do={
                :set bandwidth ($bandwidth . $n);
            } else={
                :set exitLoop true;
            }
        }
     } while (!$exitLoop);

    :return $bandwidth;
}

:global calculateGCD do={
    :if ([:typeof $1] != "array" || [:len $1] = 0) do={ 
        :error "O array de valores está vazio ou não é um array";
     }

    :if ([:len $1] = 1) do={
        :return ($1->0);
    }

    :local values $1;
    :local gcd ($values->0);
    
    :for i from=1 to=([:len $values] - 1) do={
        :local b [:pick $values $i]
        :while ($b != 0) do={
            :local temp $b
            :set b ($gcd % $b)
            :set gcd $temp
        }
    }

    :return $gcd;
};