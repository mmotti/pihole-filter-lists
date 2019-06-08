# AdGuard, Easylist, EasyPrivacy and NoCoin wildcard support for Pi-Hole

Filter lists are not supported by Pi-hole as they require a more advanced format than standard DNS entries. It is, however, possible (and beneficial) to make use of the extracted wildcard domains from these filter lists.

Extraction source: https://github.com/justdomains/blocklists

**Notes**

DNSMASQ wildcards are completely independent to Pi-hole which means that you are unable to manage them through the Pi-hole interface. **If you update your whitelist**, for example, **you will need to run the script again** to make sure that any conflicting wildcards are removed.


It is recommended to run [gravityOptimise.sh](https://github.com/mmotti/pihole-gravity-optimise) after each run of this script.

All commands will need to be entered via Terminal (PuTTY or your SSH client of choice) after logging in.

### What does the script do?
1. Fetches domains from the [JustDomains](https://github.com/justdomains/blocklists) repo
2. Examines existing DNSMASQ .conf files (to exclude conflicts)
3. Determines .conf output format (NULL, NXDOMAIN, IP-NODATA-AAAA or IP)
4. Removes unnecessary wildcard domains by checking against your installed regexps
5. Removes wildcards that conflict with your whitelist
6. Restarts Pi-hole FTL service.

### Installation
Download the script to `/usr/local/bin/` and give it execution permissions:
```
sudo bash
wget -qO /usr/local/bin/fetchFilterLists.sh https://raw.githubusercontent.com/mmotti/pihole-filter-lists/master/fetchFilterLists.sh
chmod +x /usr/local/bin/fetchFilterLists.sh
exit
```

### Options
The script will download from the following sources: adguarddns, easylist, easyprivacy and nocoin.

If you would like to exclude one or more of these sources, simply open up the script and modify as follows:
```
include_adguarddns=true
include_easylist=true
include_easyprivacy=true
#include_nocoin=true
```
Commenting out a line with `#` will exclude that list. In this example, we will skip **nocoin**.

### Uninstall
Remove the script and cron file (if you created one), then restart Pi-hole.
```
sudo bash
rm -f /usr/local/bin/fetchFilterLists.sh
rm -f /etc/cron.d/fetchFilterLists
service pihole-FTL restart
exit
```

### Running the script
Enter `fetchFilterLists.sh` in Terminal

### Example output
```
[i] Pi-hole DB detected
[i] Selected filter sources: adguarddns,easylist,easyprivacy,nocoin
[i] Fetching domains
[i] Parsing existing wildcard config (DNSMASQ)
[i] Cleaning domains
[i] Removing regex.list conflicts
[i] Checking for local wildcard conflicts
[i] Checking whitelist conflicts
[i] Determining output format
[i] Constructing output
[i] 31438 domains added to /etc/dnsmasq.d/filter_lists.conf
[i] Restarting FTL
[i] Done


Don't forget to run this script again if you make changes to your whitelist!
```

### Updating automatically with cron.d
The instructions below will install a cron.d job to run each night at 3:40am
1. `sudo nano /etc/cron.d/fetchFilterLists`
2. Enter the following:
```
# Download filters and restart pihole service
40 3   * * *   root   PATH="$PATH:/usr/local/bin/" fetchFilterLists.sh
```
3. Press `CTRL + X`
4. Press `Y`
5. Press `Enter`
