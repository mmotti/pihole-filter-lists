#!/usr/bin/env bash

# Define output file
file_name="filter-lists.conf"
file_out="/etc/dnsmasq.d/$file_name"

# Define regex input
file_regex="/etc/pihole/regex.list"

# Define pihole conf files
file_setupVars="/etc/pihole/setupVars.conf"
file_ftl="/etc/pihole/pihole-FTL.conf"
file_whitelist="/etc/pihole/whitelist.txt"

#### Functions ####

invertMatchConflicts () {

	# Conditional exit
	# Return supplied match criteria (all domains)
	if [ -z "$1" ] || [ -z "$2" ]; then
		echo "$2"
		return 1
	fi

	# Convert target - something.com -> ^something.com$
        match_target=$(sed 's/^/\^/;s/$/\$/' <<< "$2")
        # Convert exact domains (pattern source) - something.com -> ^something.com$
        exact_domains=$(sed 's/^/\^/;s/$/\$/' <<< "$1")
        # Convert wildcard domains (pattern source) - something.com - .something.com$
        wildcard_domains=$(sed 's/^/\./;s/$/\$/' <<< "$1")
	# Combine exact and wildcard matches
        match_patterns=$(printf '%s\n' "$exact_domains" "$wildcard_domains")

	# Invert match wildcards
        # Invert match exact domains
        # Remove start / end markers
        grep -vFf <(echo "$match_patterns") <<< "$match_target" |
			sed 's/[\^$]//g'
}

#### Fetch hosts #####

echo "[i] Fetching hosts"

# Fetch the hosts
# Remove duplicates
# Remove whitelisted items
filtered=$(curl -s https://raw.githubusercontent.com/justdomains/blocklists/master/lists/{adguarddns,easylist,easyprivacy}-justdomains.txt |
         sort -u)

# Exit if there are no domains
# Or an issue occured with downloading
if [[ -z "$filtered" ]]; then
        echo "[i] An error occured whilst trying to fetch filter lists"
        exit
fi

# Output the current host count
echo "[i] $(wc -l <<< "$filtered") hosts fetched"

#### Capture existing domains ####

# Extract domains for existing .conf files (except for filter-lists.conf)
echo "[i] Parsing existing dnsmasq configs"
existing_domains=$(find /etc/dnsmasq.d -type f -name "*.conf" -not -name $file_name -print0 |
        xargs -r0 grep -hE '^address=\/.+\/(([0-9]+\.){3}[0-9]+|::|#)?$' |
                cut -d'/' -f2 |
                        sort -u)

###### Output format checks ######

echo "[i] Determining output format"

# Check for IPv6 Address
IPv6_enabled=$(grep -F "IPV6_ADDRESS=" $file_setupVars |
	cut -d'=' -f2 |
		cut -d'/' -f1)

# Check for IPv4 Address
IPv4_enabled=$(grep -F "IPV4_ADDRESS=" $file_setupVars |
	cut -d'=' -f2 |
		cut -d'/' -f1)

# Check for blocking mode
blockingMode=$(grep -F "BLOCKINGMODE=" $file_ftl |
	cut -d'=' -f2)

# Revert to NULL blocking if it is not specificed
if [ -z "$blockingMode" ]; then
        blockingMode="NULL"
fi

# Switch statement for blocking mode
case "$blockingMode" in

        "NULL")
                blockingMode="#"
        ;;

        "NXDOMAIN")
                blockingMode=""
        ;;

        "IP-NODATA-AAAA")
                blockingMode=$IPv4_enabled
        ;;

        "IP")
                blockingMode=$IPv4_enabled

                if [ -n "$IPv6_enabled" ]; then
                        blockingMode+=" "$IPv6_enabled
                fi
        ;;
esac

#### Remove subdomains from fetched hosts and existing domains ####

echo "[i] Removing unnecessary subdomains"

# Remove unnecessary subdomains
# Reverse, sort, awk, rev, sort, convert to dnsmasq
cleaned_hosts=$(echo "$filtered" | rev | LC_ALL=C sort |
	 awk -F'.' 'index($0,prev FS)!=1{ print; prev=$0 }' | rev | sort)

existing_domains=$(echo "$existing_domains" | rev | LC_ALL=C sort |
         awk -F'.' 'index($0,prev FS)!=1{ print; prev=$0 }' | rev | sort)

#### Regex remove unnecessary domains ####

# If there is a regex.list, process it
if [ -s $file_regex ]; then
	# Status update
	echo "[i] Running regex removals from $file_regex"
	# Grab the pre-removal count
	count_pre_regex=$(wc -l <<< "$cleaned_hosts")
	# Remove comments from regex.list
	regex_stripped=$(grep '^[^#]' $file_regex)
	# Invert match against regex.list
	cleaned_hosts=$(grep -vEf <(echo "$regex_stripped") <<< "$cleaned_hosts")

	# Conditional exit
	if [ -n "$cleaned_hosts" ]; then
		# Count the regex removals
        	count_regex_removals=$(($count_pre_regex-$(wc -l <<< "$cleaned_hosts")))
		# Status update
        	echo "[i] $count_regex_removals hosts regex removed"
	else
        	echo "[i] 0 hosts remain after regex removals"
        	exit
	fi
fi

#### Process conflicts between new and existing hosts ####

# Remove hosts that appear in other dnsmasq files
if [ -n "$existing_domains" ]; then
	# Status update
	echo "[i] Checking for conflicts against existing config"
	# Grab the current count of cleaned_hosts
	count_cleaned_hosts=$(wc -l <<< "$cleaned_hosts")
	# Invert match existing hosts -> cleaned hosts
	# Example:
	# Remove *.something.com from $cleaned_hosts
	cleaned_hosts=$(invertMatchConflicts "$existing_domains" "$cleaned_hosts")

	# Conditional exit
	if [ -z "$cleaned_hosts" ]; then
		echo "[i] 0 hosts remain after removing conflicts"
		exit
	fi

	# Remove conflicting root domains (existing domains as priority)
	# Example:
	# Existing - test.something.com
	# New      - something.com
	# Decision: Remove something.com
	cleaned_hosts=$(awk 'NR==FNR{cleaned_hosts[$0];next}{for(i in cleaned_hosts)if(index($0, i".")){badDoms[i];break}}END{for(d in cleaned_hosts)if(!(d in badDoms))print d}' <(rev <<< "$cleaned_hosts" | LC_ALL=C sort)  <(rev <<< "$existing_domains" | LC_ALL=C sort) | rev)

	# Conditional exit
	if [ -z "$cleaned_hosts" ]; then
		echo "[i] 0 hosts remain after removing conflicts"
		exit
	fi

       	# Grab the removal count
	count_post_exist=$(($count_cleaned_hosts-$(wc -l <<< "$cleaned_hosts")))
	# Status update (how many hosts did we identify as unnecessary)
	echo "[i] $count_post_exist hosts matched against existing conf entries"
fi

#### Remove whitelist conflicts ####

if [ -s $file_whitelist ]; then
        echo "[i] Processing whitelist"
        # Grab the current domain count
        count_pre_whitelist_rm=$(wc -l <<< "$cleaned_hosts")
	# Reverse and sort the Pihole whitelist
	whitelist_domains=$(rev $file_whitelist | LC_ALL=C sort)
        # Check for exact matches or domains that conflict with whitelist entries
        cleaned_hosts=$(awk 'NR==FNR{cleaned_hosts[$0];next}$0 in cleaned_hosts{badDoms[$0];next}{for(i in cleaned_hosts)if(index($0, i".")){badDoms[i];break}}END{for(d in cleaned_hosts)if(!(d in badDoms))print d}' <(rev <<< "$cleaned_hosts" | LC_ALL=C sort)  <(echo "$whitelist_domains") | rev)^

        # Conditional status update / exit
        if [ -n "$cleaned_hosts" ]; then
                # Status update
                echo "[i] $((($count_pre_whitelist_rm-$(wc -l <<< "$cleaned_hosts")))) conflicts with whitelist"
        else
                echo "[i] 0 domains remain after processing whitelist conflicts"
                exit
        fi
fi

echo "[i] Outputting $(wc -l <<< "$cleaned_hosts") hosts to $file_out"

echo "$cleaned_hosts" |
	awk -v mode="$blockingMode" 'BEGIN{n=split(mode, modearr, " ")}n>0{for(m in modearr)print "address=/"$0"/"modearr[m]; next} {print "address=/"$0"/"}' |
		sudo tee $file_out > /dev/null

# Restart FTL service
echo "[i] Restarting Pihole service"
sudo service pihole-FTL restart

exit
