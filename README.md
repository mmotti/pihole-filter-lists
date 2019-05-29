# AdGuard, Easylist, EasyPrivacy and NoCoin wildcard support for Pi-Hole

Filter lists are not supported by Pi-hole as they require a more advanced format than standard DNS entries. It is, however, possible (and beneficial) to make use of the extracted wildcard domains from these filter lists.

Extraction source: https://github.com/justdomains/blocklists

**Notes**

It is recommended to run [gravityOptimise.sh](https://github.com/mmotti/pihole-gravity-optimise) after each run of this script.

All commands will need to be entered via Terminal (PuTTY or your SSH client of choice) after logging in.

### Installation
```
sudo bash
wget -qO /usr/local/bin/fetchFilterLists.sh https://raw.githubusercontent.com/mmotti/pihole-filter-lists/master/fetchFilterLists.sh
chmod +x /usr/local/bin/fetchFilterLists.sh
exit
```

### Uninstall
```
sudo bash
rm -f /usr/local/bin/fetchFilterLists.sh
rm -f /etc/cron.d/fetchFilterLists
service pihole-FTL restart
exit
```

### Running the script
Enter `fetchFilterLists.sh`

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

### What does the script do?
1. Downloads domains to wildcard block from the JustDomains extraction source.
2. References existing .conf files (to exclude conflicts)
3. Determines .conf output format (NULL, NXDOMAIN, IP-NODATA-AAAA or IP)
4. Removes unnecessary wildcard domains by checking against regex.list
5. Removes wildcards that conflict with whitelist
6. Restarts Pi-hole FTL service.
