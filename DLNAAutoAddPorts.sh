#!/bin/bash

## See README.md for a full description of this script.
## https://github.com/PartialVolume/DNLAAutoAddPorts for downloads and installation instructions
## 
## Summary
## This script will open and close TCP & UDP ports automatically for specified processes only.
## It was designed to open TCP/UDP ports as randomly used by DLNA/UPNP servers that need
## to be accessable on the local area network, while having most ports closed to to your LAN
## except those explicitly stated by UFW or IPTABLES etc. It was mainly written with bubbleupnpserver
## and minidlnad in mind but should work for other DLNA software & devices. Any existing rules you
## have in your firewall are not affected.
##

## TO DO
## [DONE in V2.0.2]Add -v (verbose) option
## [DONE in V2.0.4]Add Java/bubbleupnpserver crosscheck from netstat -anp to ps -ef, ie only allow BubbleUPnPServerLauncher.jar, not other Java processes.
## [DONE in V2.0.5]Add instance check. Only one instance of this script is allowed.
## Add Min Port number and port overide list
## Add more detail in verbose mode - identify which process is using which port.

## User Configuration ----------------
## Edit these based on which DLNA servers you are running, multiple DLNA servers are ok. Separate each server name by a space
## Note case is important, process names must match exactly what you see if you run ps -ef | grep -i bubbleupnpserver or
## ps -ef | grep -i minidlnad or ps -ef | grep -i rygel
processnames='minidlnad BubbleUPnPServer rygel'
## End of User Configuration  --------

# Set logfiles
version="DLNAAutoAddPorts V2.0.6"
logtcp="/tmp/ports.tcp"
logudp="/tmp/ports.udp"
currtcp="/tmp/curr.tcp"
currudp="/tmp/curr.udp"

## Only one instance of this script should ever be running and as its use is normally called via cron, if it's then run manually
## for test purposes it may intermittently update the ports.tcp & ports.udp files unnecessarily. So here we check no other instance
## is running. If another instance is running we pause for 3 seconds and then delete the PID anyway. Normally this script will run
## in under 150ms and via cron runs every 60 seconds, so if the PID file still exists after 3 seconds then it's a orphan PID file.
DNLAAutoAddPortsPID='/var/run/DNLAAutoAddPorts.sh.pid'
if [ -f $DNLAAutoAddPortsPID ]
then
	sleep 3 #if PID file exists wait 3 seconds and test again, if it still exists delete it and carry on
        rm -f -- $DNLAAutoAddPortsPID
fi		
trap "rm -f -- $DNLAAutoAddPortsPID" EXIT
echo $$ > $DNLAAutoAddPortsPID


## Check for arguments
if [ "$1" = -v ]; then verbose=1; else verbose=0;fi

## Get listening ports, multiple ports may be returned by each netstat command determined by process name, the results are sorted and duplicates deleted.
tcpports=""
udpports=""
if [ $verbose -eq '1' ]; then echo $version;fi
if [ $verbose -eq '1' ]; then echo "Ports are being checked/opened/closed for the following processes:";fi
for i in $processnames
do
    if [ $verbose -eq '1' ]; then echo $i;fi
    if [ $i = 'BubbleUPnPServer' ] #netstat calls any java program java so we have to dig deeper to find out if its BubbleUPnPServer, which is done by 'ps' a few lines down
    then
            i='java'
    fi

    tcpports_tmp=$(/bin/netstat -anp | grep $i | grep tcp | grep LISTEN | cut -d ':' -f 2 | cut -d ' ' -f 1)" "
    udpports_tmp=$(/bin/netstat -anp | grep $i | grep udp | grep 0.0.0.0 | grep -v ESTABLISHED | cut -d ':' -f 2 | cut -d ' ' -f 1)" "

    if [ $i = 'BubbleUPnPServer' ]
    then
            for port in tcpports_tmp
	    do
                ## The command below will validate a PID as a java process that has BubbleUPnPServer in the command line
	        ps -ef | awk '{ print substr($0, index($0,$2)) }' | grep "^$port" |  awk '{ print substr($0, index($0,$7)) }' | grep "^java" | grep "BubbleUPnPServer"
	        if [ $? eq '0' ];then tcpports=$tcpports$port;fi
	    done

            for port in udpports_tmp
            do
                ## The command below will validate a PID as a java process that has BubbleUPnPServer in the command line
                ps -ef | awk '{ print substr($0, index($0,$2)) }' | grep "^$port" |  awk '{ print substr($0, index($0,$7)) }' | grep "^java" | grep "BubbleUPnPServer" 
                if [ $? eq '0' ];then udpports=$udpports$port;fi
            done
    else
            tcpports=$tcpports$tcpports_tmp
            udpports=$udpports$udpports_tmp
    fi

done

## Sort ports removing duplicates and clean up
tcpports=$(echo $tcpports | xargs -n1 | sort -u | xargs)
udpports=$(echo $udpports | xargs -n1 | sort -u | xargs)

if [ $verbose -eq '1' ]; then echo "Ports identified as being used by the above processes..";fi
if [ ! -z "$tcpports" ] || [ "$tcpports" = ' ' ]
then
        if [ $verbose -eq '1' ]; then echo "TCP/"$tcpports;fi
else
        if [ $verbose -eq '1' ]; then echo "No process & associated TCP ports found";fi
fi
if [ ! -z "$udpports" ] || [ "$udpports" = ' ' ]
then
        if [ $verbose -eq '1' ]; then echo "UDP/"$udpports;fi
else
        if [ $verbose -eq '1' ]; then echo "No process & associated UDP ports found";fi
fi

## Compare previous and current ports, if no change exit, if change then update iptables
## Echo all the TCP ports to a file

## Create empty current port files, necessary in the situation
## where no process/ports are found else we get diff failing and
## create empty logtcp/udp files for the same reason
if [ -f $currtcp ]; then rm $currtcp; touch $currtcp;fi
if [ -f $currudp ]; then rm $currudp; touch $currudp;fi
if [ ! -f $logtcp ]; then touch $logtcp;fi
if [ ! -f $logudp ]; then touch $logudp;fi

## save the tcp/udp ports to files so we can diff them.
for tcpport in $tcpports
do
        echo $tcpport >> $currtcp
done
for udpport in $udpports
do
        echo $udpport >> $currudp
done

## TCP
if [ $verbose -eq '1' ]; then echo "diff output of previous and current port logs follows..";fi
if [ $verbose -eq '1' ]; then diff $currtcp $logtcp;status=$?;else diff $currtcp $logtcp > /dev/null 2>&1;status=$?;fi
if [ $status = '0' ]
then
        if [ $verbose -eq '1' ]; then echo "No change in TCP ports";fi
else
        if [ $verbose -eq '1' ]; then echo "TCP ports have changed, updating logs and iptables";fi
        
        ## Delete old TCP firewall rules
        if [ -f "$logtcp" ]
        then
                if [ $verbose -eq '1' ]; then echo "Deleting old TCP firewall rules ..";fi
                for tcpport in $(cat $logtcp)
                do
                        /sbin/iptables -D INPUT -p tcp --dport $tcpport -j ACCEPT
                        status=$?
                        if [ $status != 0 ]
                        then
                                echo "Error deleting old TCP firewall rules, code="$status
                        else
                                if [ $verbose -eq '1' ]; then echo "Deleted "$tcpport;fi
                        fi
                done
                rm $logtcp
        fi
        
        ## Add TCP Firewall rules
        if [ "$tcpports" != "" ]; then if [ $verbose -eq '1' ]; then echo "Adding TCP firewall rules..";fi;fi
        for tcpport in $tcpports
        do
                /sbin/iptables -A INPUT -p tcp --dport $tcpport -j ACCEPT
                status=$?
                if [ $status != 0 ]
                then
                        echo "Error adding TCP firewall rule $tcpport, code="$status
                else
                        if [ $verbose -eq '1' ]; then echo "Added "$tcpport;fi
                fi
        done

        ## Echo all the TCP ports to a file
        for tcpport in $tcpports
        do
                echo $tcpport >> $logtcp
        done

fi

# UDP
if [ $verbose -eq '1' ]; then echo "diff output of previous and current port logs follows..";fi
if [ $verbose -eq '1' ]; then diff $currudp $logudp;status=$?;else diff $currudp $logudp > /dev/null 2>&1;status=$?;fi
if [ $status = '0' ]
then
        if [ $verbose -eq '1' ]; then echo "No change in UDP ports";fi
else
        if [ $verbose -eq '1' ]; then echo "UDP ports have changed, updating logs and iptables";fi
        
        ## Delete old UDP firewall rules
        if [ -f "$logudp" ]
        then
                if [ $verbose -eq '1' ]; then echo "Deleting old UDP firewall rules ..";fi
                for udpport in $(cat $logudp)
                do
                        /sbin/iptables -D INPUT -p udp --dport $udpport -j ACCEPT
                        status=$?
                        if [ $status != 0 ]
                        then
                                echo "Error deleting old UDP firewall rules, code="$status
                        else
                                if [ $verbose -eq '1' ]; then echo "Deleted "$udpport;fi
                        fi

                done
                rm $logudp
        fi

        ## Add UDP Firewall Rules ..
        if [ "$udpports" != "" ]; then if [ $verbose -eq '1' ]; then echo "Adding UDP firewall rules..";fi;fi
        for udpport in $udpports
        do
                /sbin/iptables -A INPUT -p udp --dport $udpport -j ACCEPT
                status=$?
                if [ $status != 0 ]
                then
                        echo "Error adding UDP firewall rule $udpport, code="$status
                else
                        if [ $verbose -eq '1' ]; then echo "Added "$udpport;fi
                fi
        done

        ## Echo all UDP ports to a file
        for udpport in $udpports
        do
                echo $udpport >> $logudp
        done
fi
