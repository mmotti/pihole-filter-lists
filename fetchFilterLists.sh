#!/usr/bin/env bash

# Variables
dir_dnsmasq='/etc/dnsmasq.d'
file_output="$dir_dnsmasq/filter_lists.conf"
file_regex='/etc/pihole/regex.list'
file_whitelist='/etc/pihole/whitelist.txt'
file_setupVars='/etc/pihole/setupVars.conf'
file_ftl='/etc/pihole/pihole-FTL.conf'

# Fetch domains
echo '[i] Fetching domains'
filter_domains=$(curl -s https://raw.githubusercontent.com/justdomains/blocklists/master/lists/{adguarddns,easylist,easyprivacy,nocoin}-justdomains.txt |
	sort -u)

# Conditional exit in the event that no domains are fetched
[ -z "$filter_domains" ] && echo '[i] An error occured when fetching the filter domains' && exit

# Identify existing local wildcards
echo '[i] Parsing existing wildcard config (DNSMASQ)'
existing_wildcards=$(find $dir_dnsmasq -type f -name '*.conf' -not -name 'filter_lists.conf' -print0 |
	xargs -r0 grep -hE '^address=\/.+\/(([0-9]{1,3}\.){3}[0-9]{1,3}|::|#)?$' |
		cut -d '/' -f2 |
			sort -u)

# Remove subdomains where root domains are also present
echo '[i] Cleaning domains'
cleaned_filter_domains=$(echo "$filter_domains" | rev | LC_ALL=C sort |
	 awk -F'.' 'index($0,prev FS)!=1{ print; prev=$0 }' | rev | sort)
cleaned_existing_wildcards=$(echo "$existing_wildcards" | rev | LC_ALL=C sort |
	awk -F'.' 'index($0,prev FS)!=1{ print; prev=$0 }' | rev | sort)

# Regex remove unnecessary domains
if [ -s $file_regex ]; then
	echo '[i] Removing regex.list conflicts'
	file_regex=$(grep '^[^#]' $file_regex)
	cleaned_filter_domains=$(grep -vEf <(echo "$file_regex") <<<"$cleaned_filter_domains")
	# Conditional exit if no hosts remain after cleanup
	[ -z "$cleaned_filter_domains" ] && echo '[i] There are no domains to process after regex removals.' && exit
fi

# Process conflicts between filter domains and existing wildcards
if [ -n "$cleaned_existing_wildcards" ]; then
	echo '[i] Checking for local wildcard conflicts'
	# Add filterList domains to awk array
	# Check whether the exact wildcard entry is in filterList
	# For each wildcard, iterate through each filterList domain and check whether it's a subdomain of the current wildcard.
	# Existing Wildcards <--> filterList
	cleaned_filter_domains=$(awk 'NR==FNR{cleaned_filter_domains[$0];next}$0 in cleaned_filter_domains{badDoms[$0];next}{for (d in cleaned_filter_domains)if(index(d, $0".")||index($0, d".")){badDoms[d];continue}}END{for (d in cleaned_filter_domains)if(!(d in badDoms))print d}' <(rev <<< "$cleaned_filter_domains" | sort) <(rev <<< "$cleaned_existing_wildcards" | sort) | rev | sort)
	[ -z "$cleaned_filter_domains" ] && echo '[i] There are no domains to process after conflict removals.' && exit
fi

# Process whitelist matches
if [ -s $file_whitelist ]; then
	echo '[i] Checking whitelist conflicts'
	# Whitelist <--> filterList
	cleaned_filter_domains=$(awk 'NR==FNR{cleaned_filter_domains[$0];next}$0 in cleaned_filter_domains{badDoms[$0];next}{for (d in cleaned_filter_domains)if(index(d, $0".")||index($0, d".")){badDoms[d];continue}}END{for (d in cleaned_filter_domains)if(!(d in badDoms))print d}' <(rev <<< "$cleaned_filter_domains" | sort) <(rev $file_whitelist | sort) | rev | sort)
	[ -z "$cleaned_filter_domains" ] && echo '[i] There are no domains to process after conflict removals.' && exit
fi

# Start determining output format
echo "[i] Determining output format"
# Check for IPv6 Address
IPv6_enabled=$(grep -F "IPV6_ADDRESS=" $file_setupVars | cut -d'=' -f2 | cut -d'/' -f1)
# Check for IPv4 Address
IPv4_enabled=$(grep -F "IPV4_ADDRESS=" $file_setupVars |cut -d'=' -f2 | cut -d'/' -f1)
# Check for blocking mode
blockingMode=$(grep -F "BLOCKINGMODE=" $file_ftl | cut -d'=' -f2)
# Revert to NULL blocking if it is not specificed
[ -z "$blockingMode" ] && blockingMode="NULL"

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
                [ -n "$IPv6_enabled" ] && blockingMode+=' '$IPv6_enabled
        ;;
esac

# Construct output
echo '[i] Constructing output'
echo "$cleaned_filter_domains" |
	awk -v mode="$blockingMode" 'BEGIN{n=split(mode, modearr, " ")}n>0{for(m in modearr)print "address=/"$0"/"modearr[m]; next} {print "address=/"$0"/"}' |
sudo tee $file_output > /dev/null

# Some stats
echo '[i]' $(wc -l <<< "$cleaned_filter_domains") 'domains added to' $file_output

# Restart FTL
echo '[i] Restarting FTL'
sudo service pihole-FTL restart