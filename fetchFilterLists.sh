#!/usr/bin/env bash

# Variables
dir_dnsmasq='/etc/dnsmasq.d'
file_output="$dir_dnsmasq/filter_lists.conf"
file_regex='/etc/pihole/regex.list'
file_whitelist='/etc/pihole/whitelist.txt'
file_setupVars='/etc/pihole/setupVars.conf'
file_ftl='/etc/pihole/pihole-FTL.conf'

# Create an array to hold the filter sources
declare -a filterSourceArray

# Filter include options
# Remove or change to false to exclude
include_adguarddns=true
include_easylist=true
include_easyprivacy=true
include_nocoin=true

# Functions
function convertToFMatchPatterns() {
	# Conditional exit
	[ -z "$1" ] && (>&2 echo '[i] Failed to supply string for conversion') && return 1
	# Convert exact domains (pattern source) - something.com -> ^something.com$
	match_exact=$(sed 's/^/\^/;s/$/\$/' <<< "$1")
	# Convert wildcard domains (pattern source) - something.com - .something.com$
	match_wildcard=$(sed 's/^/\./;s/$/\$/' <<< "$1")
	# Output combined match patterns
	printf '%s\n' "$match_exact" "$match_wildcard"

	return 0
}
function convertToFMatchTarget() {
	# Conditional exit
	[ -z "$1" ] && (>&2 echo '[i] Failed to supply string for conversion') && return 1
	# Convert target - something.com -> ^something.com$
	sed 's/^/\^/;s/$/\$/' <<< "$1"

	return 0
}
function removeWildcardConflicts() {
	# Conditional exit if the required arguments aren't available
	[ -z "$1" ] && (>&2 echo '[i] Failed to supply match pattern string') && return 1
	[ -z "$2" ] && (>&2 echo '[i] Failed to supply match target string') && return 1
	# Gather F match strings for LTR match
	ltr_match_patterns=$(convertToFMatchPatterns "$1")
	ltr_match_target=$(convertToFMatchTarget "$2")
	# Invert LTR match
	ltr_result=$(grep -vFf <(echo "$ltr_match_patterns") <<< "$ltr_match_target" | sed 's/[\^$]//g')
	# Conditional exit if no domains remain after match inversion
	[ -z "$ltr_result" ] && return 0
	# Gather F match strings for RTL match
	rtl_match_patterns=$(convertToFMatchPatterns "$ltr_result")
	rtl_match_target=$(convertToFMatchTarget "$1")
	# Find conflicting wildcards
	rtl_conflicts=$(grep -Ff <(echo "$rtl_match_patterns") <<< "$rtl_match_target" | sed 's/[\^$]//g')
	# Identify source of match conflicts and remove
	[ -n "$rtl_conflicts" ] && awk 'NR==FNR{Domains[$0];next}$0 in Domains{badDoms[$0]}{for(d in Domains)if(index($0, d".")==1)badDoms[d]}END{for(d in Domains)if(!(d in badDoms))print d}' <(rev <<< "$ltr_result") <(rev <<< "$rtl_conflicts") | rev | sort || echo "$ltr_result"

	return 0
}

# Conditionally add each source to the array
[ "$include_adguarddns" = true ] && filterSourceArray+=('adguarddns')
[ "$include_easylist" = true ] && filterSourceArray+=('easylist')
[ "$include_easyprivacy" = true ] && filterSourceArray+=('easyprivacy')
[ "$include_nocoin" = true ] && filterSourceArray+=('nocoin')

# Conditional exit
[ "${#filterSourceArray[@]}" -eq 0 ] && echo '[i] You have not selected an input source' && exit

# Construct filter source string
filterSources=$(IFS=','; echo "${filterSourceArray[*]}")
echo "[i] Selected filter sources: $filterSources"

# Construct filter url
filterURL="https://raw.githubusercontent.com/justdomains/blocklists/master/lists/{$filterSources}-justdomains.txt"

# Fetch domains
echo '[i] Fetching domains'
filter_domains=$(curl -s "$filterURL" | sort -u)

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
	# Remove conflicts with existing wildcards
	cleaned_filter_domains=$(removeWildcardConflicts "$cleaned_existing_wildcards" "$cleaned_filter_domains")
	[ -z "$cleaned_filter_domains" ] && echo '[i] There are no domains to process after conflict removals.' && exit
fi

# Process whitelist matches
if [ -s $file_whitelist ]; then
	echo '[i] Checking whitelist conflicts'
	# Store whitelist in string
	str_whitelist=$(cat "$file_whitelist")
	# Remove conflicts with wildcards
	cleaned_filter_domains=$(removeWildcardConflicts "$str_whitelist" "$cleaned_filter_domains")
	[ -z "$cleaned_filter_domains" ] && echo '[i] There are no domains to process after conflict removals.' && exit
fi

# Start determining output format
echo '[i] Determining output format'
# Check for IPv6 Address
IPv6_enabled=$(grep -F 'IPV6_ADDRESS=' $file_setupVars | cut -d'=' -f2 | cut -d'/' -f1)
# Check for IPv4 Address
IPv4_enabled=$(grep -F 'IPV4_ADDRESS=' $file_setupVars |cut -d'=' -f2 | cut -d'/' -f1)
# Check for blocking mode
blockingMode=$(grep -F 'BLOCKINGMODE=' $file_ftl | cut -d'=' -f2)

# Switch statement for blocking mode
# Note: There doesn't seem to be a way to force DNSMASQ to return NODATA at this time.
case "$blockingMode" in

	NULL)
		blockingMode='#'
	;;

	NXDOMAIN)
		blockingMode=''
	;;

	IP-NODATA-AAAA)
		blockingMode=$IPv4_enabled
	;;

	IP)
		blockingMode=$IPv4_enabled
		[ -n "$IPv6_enabled" ] && blockingMode+=' '$IPv6_enabled
	;;

	*)
		blockingMode='#'
	;;

esac

# Construct output
echo '[i] Constructing output'
echo "$cleaned_filter_domains" |
	awk -v mode="$blockingMode" 'BEGIN{n=split(mode, modearr, " ")}n>0{for(m in modearr)print "address=/"$0"/"modearr[m]; next} {print "address=/"$0"/"}' |
sudo tee $file_output > /dev/null

# Some stats
echo "[i] $(wc -l <<< "$cleaned_filter_domains") domains added to $file_output"

# Restart FTL
echo '[i] Restarting FTL'
sudo service pihole-FTL restart
