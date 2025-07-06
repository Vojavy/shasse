````markdown
# OpenWrt × eduroam – “Wired-Enterprise” router in 8 MB  
Connect a small TP-Link Archer C6 v2 (Ath79) to **eduroam** over Ethernet (IEEE 802.1X) and still keep Wi-Fi + LAN for your own devices – without LuCI and inside the 8 MB flash limit.

---

## 0 · Why this guide exists

I wanted a **personal subnet** behind my university’s eduroam uplink.  
Sounds easy – just plug a router into a wall port, right?  
Wrong:

* The wired port is authenticated with **802.1X (EAP-TTLS / PEAP)**.  
* Stock OpenWrt images for this router ship only *wpad-basic-mbedtls* (no EAP-TTLS).  
* Adding `wpad-openssl` or `wpad-wolfssl` pushes the firmware **over 8 MB** – OpenWrt refuses to generate the factory/sysupgrade images.

So I had to craft a **custom, minimal image** that still contains:

| Must-have | Why |
|-----------|-----|
| **`wpad-openssl`** | full EAP-TTLS / PEAP support |
| **`openssl` / `ca-bundle`** | certificate validation |
| **`dropbear`** only | SSH (no SFTP → use `scp -O`) |
| basic network, Wi-Fi & switch kmods | router still works as AP |
| ***nothing else*** | stay \< 8 MB |

3 days later – it works.  
Below is the exact recipe so you don’t have to repeat the pain.

---

## 1 · Prerequisites

| Item | Notes |
|------|-------|
| Archer C6 v2 (EU/RU/JP) | 8 MB flash, ath79 |
| A Linux build host **or Docker** | Windows users → see Docker section |
| University **CA certificate** (`*.pem`) | e.g. `chain_geant_ov_rsa_ca_4.pem` |
| Your eduroam credentials | *identity / password* (or anonymous ID) |
| One free eduroam **wired** port | **check that it actually uses 802.1X** |

---

## 2 · Building the firmware

### 2.1  Using Docker (recommended on Windows)

```Dockerfile
# Dockerfile (save next to README)
FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      git build-essential libncurses5-dev gawk gettext \
      libssl-dev xsltproc unzip python3-distutils gcc-multilib \
      rsync zstd ca-certificates && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /openwrt-src
# Official stable branch (24.10)
RUN git clone --depth 1 --branch v24.10.2 \
      https://git.openwrt.org/openwrt/openwrt.git .
RUN ./scripts/feeds update -a && ./scripts/feeds install -a
CMD ["bash"]
````

```bash
# build & enter
docker build -t openwrt-eduroam .
docker run --name owrt -it -v %cd%/bin:/openwrt-src/bin openwrt-eduroam
```

#### 2.2  Minimal `.config`

Inside the container:

```bash
make menuconfig
```

* Target → your router, in my example it will be **Atheros ath79 → TP-Link Archer C6 v2 (EU/RU/JP)** 
* Drop **LuCI**, PPPoE, IPv6 extras, etc.
* **Network → WirelessAPD → `wpad-openssl` \[\*]**
  (`<space>` toggles, `y` = built-in)
* **Libraries → SSL → libopenssl** keep defaults but **disable DTLS**, IDEA, Camellia, … (saves \~300 kB)
* Target Images → keep **squashfs**, **1004 MiB rootfs size**, disable ext4
* Save and exit.

```bash
make -j$(nproc)           # full world build, ~30-60 min first time
ls bin/targets/ath79/generic
```

If `openwrt-ath79-generic-tplink_archer-c6-v2-squashfs-factory.bin` and `openwrt-*-squashfs-sysupdate.bin` exists and is **< 7995392 bytes** – you’re good.
If it’s still **too big**, go back and un-select more packages.

---

## 3 · Flashing

1. TP-Link stock web UI → **System Tools → Firmware Upgrade** → upload the *factory* .bin
2. Router reboots into OpenWrt.
3. `ssh root@192.168.1.1` (*no password yet*)
   Set a root password (`passwd`) **immediately**.
   
Already installed OpenWRT?

1. Somehow send new *.bin to router (scp cought help)
2. `ssh root@192.168.1.1`
3. In directory, where you saved it, use 
```bash
sysupgrade -v /tmp/openwrt-15.05-ar71xx-generic-tl-wr1043nd-v1-squashfs-sysupgrade.bin
```
---

## 4 · Network configuration

### 4.1  `/etc/config/network`

```uci
config device
        option name 'br-lan'
        option type 'bridge'
        list ports 'eth0.1'

config interface 'lan'
        option device 'br-lan'
        option proto 'static'
        option ipaddr '192.168.1.1'
        option netmask '255.255.255.0'

config interface 'wan'
        option device 'eth0.2'
        option proto 'dhcp'          # IP via eduroam after EAP success
```

VLAN 1 = LAN ports, VLAN 2 = WAN port.

### 4.2  Wi-Fi AP (optional)

```uci
config wifi-device 'radio0'
        option type 'mac80211'
        option channel '1'

config wifi-iface
        option device 'radio0'
        option mode 'ap'
        option ssid 'MyHomeNet'
        option encryption 'psk2'
        option key 'SuperSecret'
        option network 'lan'
```

### 4.3  `wpa_supplicant.conf` for wired 802.1X

```ini
ctrl_interface=/var/run/wpa_supplicant
ap_scan=0
eapol_version=2

network={
    key_mgmt=IEEE8021X
    eap=TTLS
    identity="yourid@domain.cz"
    anonymous_identity="anonymous@domain.cz"
    password="********"
    phase2="auth=PAP"
    ca_cert="/etc/certs/pardubice-ca.pem"
}
```

> *Use TTLS + PAP because that’s what UPCE states for Linux (“TUNNELED-TLS”).*
> **PEAP/MSCHAPv2** also works if the radius accepts it – just swap `eap=` & `phase2=`.

Copy the CA file:

```bash
mkdir -p /etc/certs
scp -O chain_geant_ov_rsa_ca_4.pem root@192.168.1.1:/etc/certs/pardubice-ca.pem
```

(`-O` forces legacy SCP compatible with Dropbear)

### 4.4  Auto-start the supplicant

Create `/etc/rc.local` (before the final `exit 0`):

```sh
# start wired EAP on WAN vlan
/usr/sbin/wpa_supplicant -B -D wired -i eth0.2 -c /etc/wpa_supplicant.conf
```

Reboot → check logs:

```bash
logread -e wpa_supplicant
```

You should see `CTRL-EVENT-CONNECTED` then DHCP leasing.

---

## 5 · Troubleshooting

| Symptom                                    | Check                                                   |
| ------------------------------------------ | ------------------------------------------------------- |
| **“Image too big”** during build           | Remove LuCI, IPv6 extras, PPP, nftables, …              |
| `ash: /usr/libexec/sftp-server: not found` | Use `scp -O` or `cat > /path` trick                     |
| `EAP-FAILURE`                              | wrong credentials, wrong EAP method, CA file unreadable |
| No 802.1X at all                           | The wall port may be open – try plain DHCP first        |

---

## 6 · Docker quick-start for Windows users

```powershell
# inside project folder
docker build -t openwrt-eduroam .
docker run --name owrt -it -v "${PWD}\bin:/openwrt-src/bin" openwrt-eduroam
# compiled images appear in .\bin after 'make'
```

---

## 7 · Result

* Router boots < 8 MB firmware with `wpad-openssl`
* Authenticates over Ethernet to eduroam (EAP-TTLS)
* Provides own Wi-Fi + LAN switching
* No LuCI, just pure SSH & UCI

> **Mission accomplished** – personal subnet on top of eduroam without extra login pop-ups for each device.

if you got some other configs - i`m open to MR!

Hope it will help!
*— Andrii (2025-07)*

```
```
