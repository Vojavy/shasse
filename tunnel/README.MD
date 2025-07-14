# Reverse-SSH Tunnel – safe self-hosting from a locked-down network

**Use-case**  
You are on a eduroam / campus network that only lets you initiate **outgoing** connections.  
With OpenSSH you can still expose a service that is running on your server to the public Internet.  
This repository documents a **minimal, security-minded** configuration I run in production. If you spot anything that could be hardened further – please open an issue or PR 🙏.

```

client (inside EDUROAM)
└── ssh -R \*:8080:127.0.0.1:80 … tunneluser\@VPS
│
▼
┌───────────────────────────────────────────────┐
│  Oracle Cloud VPS  (Ubuntu 22.04 x86-64)      │
│  DNAT 80→8080  443→8443  26656→26656          │
│  sshd (only *tunneluser* may forward)         │
│  fail2ban + UFW                               │
└───────────────────────────────────────────────┘
▲
│
Internet / your IP or domain (e.g. `115.14.11.1` || `notes.example.dev`)

````

---

## 0.  VPS choice & Security List

| item | value |
|------|-------|
| Cloud     | Oracle Cloud “Always Free” Ampere A1 🛈 <br>*(**failed**: OEM “Oracle Linux” image gave mysterious port-bind errors – switched to stock **Ubuntu 22.04 LTS**, everything works)* |
| Shape | 1 vCPU / 1 GB RAM / 60 MB/s |
| Open ports in *Security List* | `22, 80, 443, 26656  tcp  0.0.0.0/0` |

*(I cannot white-list CIDRs because my university hands out dynamic addresses; later we will rate-limit & ban offenders on the VM itself.)*

---

## 1.  Server hardening (`/etc/ssh/sshd_config.d/00-hardening.conf`)

```text
Protocol                2
PasswordAuthentication   no
ChallengeResponseAuthentication no
PermitRootLogin          prohibit-password   # root only via key, never by pwd
AllowAgentForwarding     no
AllowTcpForwarding       no                 # disabled globally – re-enabled per user
GatewayPorts             no
ClientAliveInterval      120                # keep-alive every 2 min
ClientAliveCountMax      2                  # drop after 2 missed probes
````

### Per-user override (`Match User tunneluser`)

```text
Match User tunneluser
    AllowTcpForwarding   yes
    GatewayPorts         clientspecified    # allow *:PORT
    # restrict WHAT may be opened
    PermitOpen 127.0.0.1:80 127.0.0.1:443 127.0.0.1:26656
    # no shell – even if attacker gains key
    ForceCommand echo '🔒  tunneluser: shell disabled'
```

`sudo systemctl reload sshd`
*(logs show one line and session closes – that is expected).*

---

## 2.  Create service account & authorised key

```bash
# on the VPS (as root/ubuntu)
adduser --disabled-password --gecos "" tunneluser
install -d -m700 -o tunneluser -g tunneluser /home/tunneluser/.ssh
# paste your client public key
echo "ssh-ed25519 AAAA… tunnel" \
    | tee /home/tunneluser/.ssh/authorized_keys
chown tunneluser:tunneluser /home/tunneluser/.ssh/authorized_keys
chmod 600 /home/tunneluser/.ssh/authorized_keys
```

Why a separate user?

* if the key leaks, attacker **cannot** open arbitrary ports (`PermitOpen`)
* `ForceCommand` kills any interactive shell
* rest of the system (root / ubuntu) keeps TCP-forwarding disabled

---

## 3.  Fail2Ban (SSH brute-force & re-cidive)

`apt install fail2ban`
`/etc/fail2ban/jail.d/sshd.conf`

```ini
[sshd]
enabled   = true
port      = ssh
maxretry  = 5
findtime  = 10m
bantime   = 1h
```

`/etc/fail2ban/jail.d/recidive.conf`

```ini
[recidive]
enabled  = true
logpath  = /var/log/fail2ban.log
findtime = 1d
bantime  = 26w
maxretry = 3
```

Restart: `systemctl restart fail2ban`

---

## 4.  DNAT + firewall (leave ports privileged but run as user)

```bash
# preroute 80/443 to high ports listened by sshd
iptables -t nat -A PREROUTING -p tcp --dport 80  -j REDIRECT --to-port 8080
iptables -t nat -A PREROUTING -p tcp --dport 443 -j REDIRECT --to-port 8443
# open high ports & rpc
ufw default deny incoming
ufw allow 22/tcp 80/tcp 443/tcp 26656/tcp
ufw allow 8080/tcp 8443/tcp
ufw enable
```

*(hashlimit / ufw limit are optional; you can add later).*

---

## 5.  Client (Server inside eduroam)

```bash
# generate key
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

### Quick manual test

```bash
ssh -i ~/.ssh/id_ed25519 \
    -R *:8080:127.0.0.1:80  \
    -R *:8443:127.0.0.1:443 \
    -R *:26656:127.0.0.1:26656 \
    tunneluser@141.147.28.19
```

You should see just the 🔒 message and the connection stays open.

### Auto-restart with systemd + autossh

`apt install autossh`
`/etc/systemd/system/ssh-tunnel.service`

```ini
[Unit]
Description=Persistent reverse SSH tunnel to OCI
After=network-online.target

[Service]
User=tunneluser             # ← *local* user that owns the key
Group=tunneluser
Environment=AUTOSSH_GATETIME=0
ExecStart=/usr/bin/autossh -M 0 -N \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes \
  -i /home/tunneluser/.ssh/id_ed25519 \
  -R *:8080:127.0.0.1:80  \
  -R *:8443:127.0.0.1:443 \
  -R *:26656:127.0.0.1:26656 \
  tunneluser@141.147.28.19
Restart=always
RestartSec=10
```

```bash
systemctl daemon-reload
systemctl enable --now ssh-tunnel.service
systemctl status ssh-tunnel.service
```

---

## 6.  Smoke-test with Python HTTP server

On the client (Server):

```bash
sudo python3 -m http.server 80 --bind 127.0.0.1
echo '<h1>Hello via tunnel!</h1>' | sudo tee index.html
```

### Expect:

| where   | command                         | expected            |
| ------- | ------------------------------- | ------------------- |
| VPS     | `curl -I http://127.0.0.1:8080` | `HTTP/1.0 200 OK`   |
| world   | `curl -I http://141.147.28.19/` | same headers        |
| browser | `http://<your-domain>`          | “Hello via tunnel!” |

*(later swap Python for Joplin Server, Caddy, etc.)*

---

## 7.  Why this is reasonably safe

* **SSH**: key-only, root login disabled, per-user forwarding whitelist.
* **tunneluser**: no shell, no agent-forward, only 3 ports allowed.
* **Fail2Ban**: bruteforce blocked after 5 tries; repeat offenders = 26-week ban.
* **iptables DNAT**: privileged 80/443 stay protected by sshd’s unprivileged listener.
* **autossh watchdog**: tunnel recreates itself after Wi-Fi drop.
* **Everything else closed** by UFW default-deny.

If you see a gap – open an issue!

---

## 8.  Known limitations / TODO

* No Geo-IP / CIDR filtering (university gives dynamic IP).
* TLS termination is up to you (Caddy on client or Nginx on VPS).
* For heavy/production load add rate-limiting (`hashlimit`) to UFW.

---

Happy tunneling! 🚀

```
— Andrii (2025-07)

```