```sh
##############################################################################
# 1. Init script /etc/init.d/wpa_wired (procd, no PID files)
##############################################################################
cat > /etc/init.d/wpa_wired <<'EOF'
#!/bin/sh /etc/rc.common
START=19
USE_PROCD=1

start_service() {
    # Exact command line you asked for
    procd_open_instance
    procd_set_param command /usr/sbin/wpa_supplicant \
        -D wired -i eth0.2 -c /etc/wpa_supplicant.conf -dd
    # Uncomment the next line if you prefer to log to a file:
    # procd_append_param command -f /var/log/wpa_wired.log
    procd_set_param respawn          # auto-restart if it crashes
    procd_close_instance
}
EOF
chmod +x /etc/init.d/wpa_wired
/etc/init.d/wpa_wired enable          # enable autostart at boot

##############################################################################
# 2. Start the daemon right away and watch live output
##############################################################################
/etc/init.d/wpa_wired restart
logread -f | grep wpa_supplicant
```

**What it does**

1. Writes an init script that launches

   ```
   wpa_supplicant -D wired -i eth0.2 -c /etc/wpa_supplicant.conf -dd
   ```

   under procd supervision (so it respawns automatically).

2. Makes the script executable and adds it to the startup sequence.

3. Immediately restarts the service and tails `logread` so you can see
   verbose `-dd` debug output in real time.
