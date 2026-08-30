# Self-Hosting Frappe Press (Your Own Frappe Cloud) — Complete Beginner's Guide
### Ubuntu 24.04 + AWS Free Tier + DuckDNS (no paid domain needed)
##
This guide walks a complete beginner through building your own private "Frappe Cloud" — a platform where you (or your users) can spin up Frappe/ERPNext sites with one click, just like frappecloud.com.

It merges three sources into one working path:
- The official community guide, *[Guide] Installing Press and get it up and running - Part 1*
- Frappe's official *Local Development Environment Setup* doc (concepts only — that guide targets internal Frappe contributors on Docker/Hetzner, so it isn't directly followable for our case, but its explanations of server roles are accurate and included below)
- Every real fix required to make this actually work on **Ubuntu 24.04** with **DuckDNS** instead of a paid domain + Route 53 — discovered by really doing it, documented so you don't hit the same walls

Expect this to take a full day if you're new to Linux/AWS. Every command is written out — you don't need prior DevOps experience, just patience and the ability to copy-paste carefully.

---

## Part 0 — Understand What You're Building

You need **4 servers**, each with one job:

| Server | Nickname | Job |
|---|---|---|
| `press` | — | Runs the Press application itself — the dashboard you and your users interact with |
| `n1` | Proxy (Nginx) | The "front door." Every visitor request lands here first, and it routes traffic to the right site |
| `m1` | Database (MariaDB) | Stores the actual data for every site hosted on your platform |
| `f1` | App/Build server | Builds the Docker images (the actual Frappe/ERPNext code) that sites run on |

Once everything's working, a user visits your dashboard, clicks "New Site," and Press automatically: tells `f1` to build the right code image, tells `m1` to create a database, and tells `n1` to route the new subdomain to that site — all without you touching a terminal.

---

## Part 1 — AWS Account Preparation

### 1.1 Create an IAM user for container registry access

1. Log into AWS with your **root** account.
2. Go to **IAM → Users → Create user**.
3. Name it `press-user`. Check "Provide user access to AWS Management Console" if you want, but it's not required for this user's actual purpose.
4. Click **Attach policies directly** → search `AmazonElasticContainerRegistryPublicFullAccess` → select it → **Next** → **Create user**.

### 1.2 Create an access key for this user

1. Open the `press-user` you just made → **Security credentials** tab.
2. Scroll to **Access keys** → **Create access key**.
3. Choose the option matching "application running outside AWS" only if your Press server will NOT be on AWS. Since it will be on AWS, pick the general/CLI option offered.
4. **Download the CSV immediately** — the secret key is shown only once. Save it somewhere safe; you'll need it later for the Docker registry.

---

## Part 2 — Launch 4 EC2 Instances

1. **EC2 → Launch instances.**
2. **AMI:** Ubuntu Server **24.04 LTS**.
3. **Instance type:** anything with at least 2 vCPU / 4GB RAM (e.g. `t3.medium` or `m7i-flex.large`). More RAM comfortably avoids out-of-memory issues during dependency builds.
4. **Key pair:** click **Create new key pair**, name it e.g. `key_press`, download the `.pem` file. **This one key will unlock all 4 servers.**
5. **Storage:** at least 30GB. The build server (`f1`) does Docker builds that can eat disk fast — if you can spare it, give `f1` more (40GB+).
6. **Number of instances:** 4.
7. Click **Launch instance**.

Once running, rename them in the EC2 console (click the pencil next to the instance name):
- Instance 1 → `press`
- Instance 2 → `n1`
- Instance 3 → `m1`
- Instance 4 → `f1`

### 2.1 Allocate Elastic IPs (do this now — don't skip)

⚠️ **Important lesson learned the hard way:** if you don't attach an Elastic IP, AWS can assign your instance a *new* public IP after any stop/start cycle. If that happens, your DNS records, SSH config, and Press's saved server IPs all silently point to the wrong address — and nothing self-heals. Fix this before doing anything else.

Note: since Feb 2024, AWS charges a small hourly fee (~$3.65/month per address) for *any* public IPv4 address in continuous use — Elastic or not — beyond a small free allowance. This is unavoidable with 4 always-on servers, regardless of which IP type you use, so there's no cost reason to skip Elastic IPs.

1. **EC2 → Network & Security → Elastic IPs → Allocate Elastic IP address** → repeat 4 times.
2. For each one, **Actions → Associate Elastic IP address** → pick one of your 4 instances.
3. Note down all 4 public IPs — you'll need them constantly going forward.

---

## Part 3 — DNS Setup with DuckDNS (Free, No Domain Purchase Needed)

The official guide uses AWS Route 53 with a paid domain. If you don't want to buy a domain, DuckDNS gives you free subdomains that work just as well for testing and small production use.

### 3.1 Register your DuckDNS names

1. Go to [duckdns.org](https://www.duckdns.org) and sign in (GitHub/Google, etc).
2. Note your **token** shown at the top of the page — you'll reuse it for every subdomain.
3. In the "add domain" box, register **5 separate names**, one at a time, each pointing at the matching IP:

| DuckDNS name | Points to | Purpose |
|---|---|---|
| `yourproject` | press server's IP | Main dashboard |
| `yourproject-n1` | n1's IP | Proxy server |
| `yourproject-m1` | m1's IP | Database server |
| `yourproject-f1` | f1's IP | App/build server |
| `yourproject-sites` | n1's IP (same as n1) | Wildcard base — every future customer site lives under this |

Replace `yourproject` with whatever unique name you claim (DuckDNS names are global, so pick something unlikely to be taken).

⚠️ **Why 5 separate names, not one with subdomains:** DuckDNS gives one A record per registered name — it doesn't support giving different IPs to different "sub-subdomains" of one name. Each server needs its own top-level DuckDNS registration.

4. Verify DNS propagated correctly from your local terminal:
```bash
nslookup yourproject.duckdns.org
nslookup yourproject-n1.duckdns.org
nslookup yourproject-m1.duckdns.org
nslookup yourproject-f1.duckdns.org
nslookup yourproject-sites.duckdns.org
```
Each should return the correct matching IP within a minute or two.

---

## Part 4 — SSH Access Setup (the fiddly but critical part)

Get this exactly right — it's the single most common source of "Broken" statuses later.

### 4.1 Prepare your key on your local machine

```bash
mkdir -p ~/.ssh
cp /path/to/key_press.pem ~/.ssh/
chmod 400 ~/.ssh/key_press.pem
```

### 4.2 Create the `press` Linux user on the press server

```bash
ssh -i ~/.ssh/key_press.pem ubuntu@yourproject.duckdns.org
sudo passwd ubuntu
sudo adduser press
sudo usermod -aG sudo press
sudo su press
cd /home/press
mkdir .ssh
chmod 700 ~/.ssh
sudo cp /home/ubuntu/.ssh/authorized_keys /home/press/.ssh/authorized_keys
sudo chmod 600 ~/.ssh/authorized_keys
sudo chown press:press ~/.ssh/authorized_keys
exit
exit
```

### 4.3 Set up your local SSH shortcut

On your local machine:
```bash
nano ~/.ssh/config
```
Add:
```
Host press
    HostName yourproject.duckdns.org
    User press
    IdentityFile ~/.ssh/key_press.pem
```
Test: `ssh press` should log you in instantly.

### 4.4 Copy the key onto the press server itself

The press server needs its own copy of the key, because *it* will be the one connecting to n1/m1/f1 (not your laptop directly).

```bash
scp -i ~/.ssh/key_press.pem ~/.ssh/key_press.pem press@yourproject.duckdns.org:~/.ssh/
ssh press
chmod 400 ~/.ssh/key_press.pem
```

### 4.5 Enable root SSH login on n1, m1, and f1

Repeat this **entire block three times** — once for each server (swap the hostname each time):

```bash
ssh -i ~/.ssh/key_press.pem ubuntu@yourproject-n1.duckdns.org
sudo -i
nano /etc/ssh/sshd_config
```
Ensure these two lines exist and are uncommented:
```
PermitRootLogin yes
PasswordAuthentication no
```
Save (Ctrl+O, Enter, Ctrl+X), then:
```bash
cp /home/ubuntu/.ssh/authorized_keys /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
systemctl daemon-reload
systemctl restart ssh
```
⚠️ **Ubuntu-specific fix:** the guide's original instructions say `systemctl restart sshd` — on Ubuntu the service is named **`ssh`**, not `sshd` (that naming is a RHEL/CentOS convention). Using `sshd` here will fail with "Unit not found."

Exit back out:
```bash
exit
exit
```

### 4.6 Fix the UID 1000 conflict (do this now, on n1, m1, and f1)

Later, Press will try to create a new Linux user with UID 1000 on each server — but AWS's default `ubuntu` user already owns UID 1000, which will cause a silent failure. Fix it preemptively, from a **fresh** root connection (don't do this from a session you're still logged into as `ubuntu`, or the running session itself will block the change):

```bash
ssh -i ~/.ssh/key_press.pem root@yourproject-n1.duckdns.org
usermod -u 1001 ubuntu
find /home/ubuntu -uid 1000 -exec chown ubuntu {} +
exit
```
Repeat for `yourproject-m1.duckdns.org` and `yourproject-f1.duckdns.org`.

If `usermod` complains "user ubuntu is currently used by process NNNN," it means a lingering per-user systemd session is holding the UID. Fix with:
```bash
loginctl terminate-user ubuntu
pkill -9 -u ubuntu
```
This will disconnect any other open session as `ubuntu` — reconnect fresh as root afterward and retry `usermod`.

### 4.7 Verify access from inside the press server, and add SSH aliases there too

```bash
ssh press
ssh root@yourproject-n1.duckdns.org
whoami   # should print "root", no password prompt
exit
ssh root@yourproject-m1.duckdns.org
exit
ssh root@yourproject-f1.duckdns.org
exit
```

While still inside `press`, add SSH aliases so Press's own automation can find the right key easily:
```bash
nano ~/.ssh/config
```
```
Host yourproject-n1.duckdns.org
    HostName yourproject-n1.duckdns.org
    User root
    IdentityFile ~/.ssh/key_press.pem

Host yourproject-m1.duckdns.org
    HostName yourproject-m1.duckdns.org
    User root
    IdentityFile ~/.ssh/key_press.pem

Host yourproject-f1.duckdns.org
    HostName yourproject-f1.duckdns.org
    User root
    IdentityFile ~/.ssh/key_press.pem
```

⚠️ **Critical extra step, learned the hard way:** Press's internal automation (Ansible) connects to your servers by **raw IP address**, not by the hostname. An SSH config keyed only by hostname won't apply when Ansible connects by IP — the connection will silently fail with "Unreachable" even though manual `ssh root@yourproject-n1.duckdns.org` works perfectly. Add a **second entry per server, keyed by its IP**:
```
Host 52.200.82.254
    User root
    IdentityFile ~/.ssh/key_press.pem
    StrictHostKeyChecking no
```
Repeat for every server's actual public IP. Skipping this step is one of the most confusing failures you can hit, because manual SSH tests will all pass while Press's automation still fails.

Also fix the file permissions on the key while you're at it — SSH silently rejects keys that are readable by others:
```bash
chmod 400 ~/.ssh/key_press.pem
chmod 700 ~/.ssh
```

### 4.8 Create folders Press expects

Still on the press server:
```bash
cd ~
mkdir -p .certbot/.webroot
```
(You'll create `.clones` and `.docker-builds` inside the bench folder once it exists, in Part 5.)

---

## Part 5 — Install Frappe + Press on the Press Server

The official guide points to a separate ERPNext install guide, written for Ubuntu 22.04 with Python 3.10. On Ubuntu 24.04 (Python 3.12 by default), use the steps below instead — they account for every package/version difference.

### 5.1 Install system packages

```bash
ssh press
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install git -y
sudo apt-get install python3-dev python3-pip python3-setuptools python3-venv -y
sudo apt-get install software-properties-common -y
sudo apt-get install mariadb-server mariadb-client -y
sudo apt-get install redis-server -y
sudo apt-get install xvfb libfontconfig libmysqlclient-dev pkg-config -y
```

Install wkhtmltopdf:
```bash
wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
sudo apt install ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb -y
```

### 5.2 Configure MariaDB

```bash
sudo mysql_secure_installation
```
Answer: switch to unix_socket auth = **Y**; set a root password = **Y** (choose and remember one — you'll need it in a moment); remove anonymous users = **Y**; disallow remote root = **N**; remove test database = **Y**; reload privileges = **Y**.

```bash
sudo nano /etc/mysql/my.cnf
```
Add at the end:
```ini
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

[mysql]
default-character-set = utf8mb4
```
```bash
sudo service mysql restart
```

### 5.3 Install Node.js and Yarn

```bash
cd ~
curl https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
source ~/.profile
nvm install 18
nvm use 18
sudo apt-get install npm -y
sudo npm install -g yarn
```

### 5.4 Install Bench and create the site

⚠️ **Ubuntu 24.04 note:** system-wide `pip install` is blocked without an override flag. Use `--break-system-packages`.

```bash
sudo pip3 install frappe-bench --break-system-packages
cd ~
bench init --frappe-branch version-15 frappe-bench
cd frappe-bench/
mkdir -p .clones .docker-builds
sudo chmod -R o+rx /home/press/
bench new-site yourproject.duckdns.org
```
When prompted for the MySQL root password, enter the one you set in step 5.2. Then set an Administrator password for the site — remember this, it's your Press login.

### 5.5 Install Press — and fix its Ubuntu-24.04 dependency problems

```bash
bench get-app press
```

At this point, running `bench --site yourproject.duckdns.org install-app press` directly will fail with a chain of dependency errors, because several packages Press pins are too old for Python 3.12. Fix all of them **before** running install-app, by editing `apps/press/pyproject.toml`:

```bash
cd ~/frappe-bench/apps/press
cp pyproject.toml pyproject.toml.bak
sed -i 's/"ansible==3.4.0",/"ansible>=9,<12",/' pyproject.toml
sed -i 's/"stripe~=2.56.0",/"stripe>=7,<8",/' pyproject.toml
```

Reinstall with the fixed versions:
```bash
cd ~/frappe-bench
./env/bin/pip install -e apps/press
```

Fix `sqlparse` (Frappe's own dependency, sometimes gets downgraded by other installs):
```bash
./env/bin/pip install --force-reinstall "sqlparse~=0.5.4"
```

Patch python-telegram-bot's broken legacy import (it references a `urllib3.contrib.appengine` module that no longer exists in modern urllib3, and this package is too old to safely upgrade without breaking Press's other code):
```bash
cd ~/frappe-bench
perl -i -pe 's/^(\s*)import telegram\.vendor\.ptb_urllib3\.urllib3\.contrib\.appengine as appengine$/$1try:\n$1    import telegram.vendor.ptb_urllib3.urllib3.contrib.appengine as appengine\n$1except ImportError:\n$1    appengine = None/' env/lib/python3.12/site-packages/telegram/utils/request.py
perl -i -pe 's/^(\s*)import urllib3\.contrib\.appengine as appengine(\s*#.*)?$/$1try:\n$1    import urllib3.contrib.appengine as appengine$2\n$1except ImportError:\n$1    appengine = None/' env/lib/python3.12/site-packages/telegram/utils/request.py
sed -i 's/appengine\.AppEngineManager,/type(None),/' env/lib/python3.12/site-packages/telegram/utils/request.py
sed -i "s/if appengine\.is_appengine_sandbox():/if appengine and appengine.is_appengine_sandbox():/" env/lib/python3.12/site-packages/telegram/utils/request.py
```

Now install Press:
```bash
bench --site yourproject.duckdns.org install-app press
```
This should now complete without errors, ending with something like "Updating Dashboard for press."

### 5.6 Production setup

```bash
bench --site yourproject.duckdns.org enable-scheduler
bench --site yourproject.duckdns.org set-maintenance-mode off
sudo env "PATH=$PATH" bench setup production press
bench setup nginx
```

⚠️ If `sudo supervisorctl status` shows nothing at all, bench generated its config file but didn't link it into supervisor's active config folder. Fix:
```bash
sudo ln -sf /home/press/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart all
sudo supervisorctl status
```
All ~7 processes should show `RUNNING` within a few seconds.

### 5.7 Firewall and HTTPS for the dashboard itself

```bash
sudo ufw allow 22,25,143,80,443,3306,3022,8000/tcp
sudo ufw enable
```

```bash
sudo snap install core
sudo snap refresh core
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo certbot --nginx
```
Follow the prompts (email, terms, select your domain when listed).

### 5.8 First login

Go to `https://yourproject.duckdns.org/app` (not `/dashboard` — that's the customer-facing signup flow, not the admin login). Log in as:
- **Username:** `Administrator`
- **Password:** the one you set in step 5.4

If you land on the Frappe desk with no errors, Press is fully installed and running.

---

## Part 6 — Pre-Setup Server Fixes (do these BEFORE clicking "Setup Server" on any server)

These four fixes address environment gaps in Press's Ansible automation on Ubuntu 24.04. Doing them now, in one pass, saves you from discovering each one individually mid-provisioning.

### 6.1 Ansible collection-loader initialization

Recent Ansible versions need an explicit call to register the built-in plugin loader when driven from raw Python (which is how Press calls it) rather than the `ansible-playbook` CLI.

```bash
cd ~/frappe-bench/apps/press/press
cp runner.py runner.py.bak
```
Open `runner.py` and add near the top, with the other imports:
```python
from ansible.plugins.loader import init_plugin_loader
```
Then find where the Ansible runner class is defined/instantiated and add a call to `init_plugin_loader()` once, before any Playbook object is constructed.

### 6.2 Align cryptography and pyOpenSSL versions

Press's own dependency pin for `pyOpenSSL` is older than what your installed Frappe version actually needs, causing an `AttributeError: module 'lib' has no attribute 'GEN_EMAIL'` crash.

```bash
cd ~/frappe-bench
./env/bin/pip install "cryptography~=50.0.0" "pyOpenSSL~=26.4.0" --break-system-packages
```

### 6.3 Fix the MariaDB Ansible role for Ubuntu 24.04

Press's built-in MariaDB role points at MariaDB 10.6, which has no official build for Ubuntu 24.04 (Noble) at all.

```bash
cd ~/frappe-bench/apps/press/press/playbooks/roles/mariadb/tasks
cp main.yml main.yml.bak
nano main.yml
```
Remove the tasks that add the Rackspace MariaDB 10.6 apt repository entirely (the `Add MariaDB Repository Key` and `Add MariaDB Repository` tasks at the top), so `apt install mariadb-server` falls back to Ubuntu 24.04's own built-in MariaDB 10.11 packages instead. Also change any reference to `libmariadbclient18` to `libmariadb3` (the old package name doesn't exist in Noble). Finally, add a task that ensures the systemd override folder exists before anything tries to write into it:
```yaml
- name: Create MariaDB systemd override directory
  file:
    path: /etc/systemd/system/mariadb.service.d
    state: directory
    owner: root
    group: root
    mode: '0755'
```

### 6.4 sshd service name alias

Several of Press's Ansible roles reference the SSH service as `sshd`, but Ubuntu names the systemd unit `ssh`. Rather than patching every role individually, create a compatibility symlink on **each** of n1, m1, and f1:

```bash
ssh root@yourproject-n1.duckdns.org
ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/sshd.service
systemctl daemon-reload
exit
```
Repeat for m1 and f1.

---

## Part 7 — Root Domain and TLS Certificate

### 7.1 Create the Root Domain

In the dashboard (`/app`), go to `https://yourproject.duckdns.org/app/root-domain/new`:
- **Name:** `yourproject-sites.duckdns.org`
- **DNS Provider:** select **Generic** (not "AWS Route 53" — that option requires an AWS-hosted domain, which DuckDNS isn't)
- Save.

### 7.2 Why the automated certificate flow won't work here — and the manual fix

Press's automated wildcard-certificate flow is built specifically around the Route 53 API. With "Generic" as the provider, Press can only validate domain ownership via HTTP-01 challenge — and **HTTP-01 cannot issue wildcard certificates at all**, regardless of setup order. Every site under your platform needs one shared wildcard cert (`*.yourproject-sites.duckdns.org`), so we get it manually instead, using DuckDNS's own certbot plugin.

Install the plugin as a **snap** (not pip — a pip-installed plugin is invisible to a snap-confined certbot):
```bash
sudo snap install certbot-dns-duckdns
sudo snap set certbot trust-plugin-with-root=ok
sudo snap connect certbot:plugin certbot-dns-duckdns
```

Request the wildcard certificate (pass your token directly on the command line — a credentials file can fail inside the snap sandbox):
```bash
sudo certbot certonly \
  --non-interactive \
  --authenticator dns-duckdns \
  --dns-duckdns-token YOUR_DUCKDNS_TOKEN \
  --dns-duckdns-propagation-seconds 60 \
  -d "*.yourproject-sites.duckdns.org" \
  --agree-tos \
  --email you@example.com \
  --config-dir /home/press/.certbot \
  --work-dir /home/press/.certbot/work \
  --logs-dir /home/press/.certbot/logs
```
⚠️ Request the wildcard and the bare domain **separately** if you need both — DuckDNS's API only supports one TXT value at a time under a given name, so requesting both in the same command causes a validation failure.

Fix ownership (certbot ran as root, but Press's console runs as `press`):
```bash
sudo chown -R press:press /home/press/.certbot
```

### 7.3 Manually register the certificate in Press

The automated flow that would normally create this record never ran, so create it directly via the bench console:
```bash
bench --site yourproject.duckdns.org console
```
```python
import frappe
with open("/home/press/.certbot/live/yourproject-sites.duckdns.org/cert.pem") as f:
    cert = f.read()
with open("/home/press/.certbot/live/yourproject-sites.duckdns.org/chain.pem") as f:
    chain = f.read()
with open("/home/press/.certbot/live/yourproject-sites.duckdns.org/fullchain.pem") as f:
    fullchain = f.read()
with open("/home/press/.certbot/live/yourproject-sites.duckdns.org/privkey.pem") as f:
    privkey = f.read()

frappe.get_all("Team", fields=["name", "user"])  # find your real team name first
```
Use the team name from that last line's output, then:
```python
doc = frappe.get_doc({
    "doctype": "TLS Certificate",
    "domain": "yourproject-sites.duckdns.org",
    "wildcard": 1,
    "status": "Active",
    "provider": "Let's Encrypt",
    "team": "<team-name-from-above>",
    "certificate": cert,
    "intermediate_chain": chain,
    "full_chain": fullchain,
    "private_key": privkey,
})
doc.insert(ignore_permissions=True)
frappe.db.commit()
exit()
```

⚠️ **Never click "Obtain Certificate" in the UI after this** — it will try to run the Route53-based flow, fail, and can overwrite your manually-set `Active` status back to `Failure`. If that ever happens, fix it directly:
```python
frappe.db.sql(
    "UPDATE `tabTLS Certificate` SET status = %s WHERE name = %s",
    ("Active", "*.yourproject-sites.duckdns.org")
)
frappe.db.commit()
```

### 7.4 Certificate renewal — don't skip this

Let's Encrypt certificates expire every 90 days, and since you bypassed Press's automated renewal, **nothing will renew this certificate on its own**. Set up a cron job now so this doesn't silently break your platform months from now:

```bash
sudo crontab -e
```
Add a monthly renewal line (adjust paths/token):
```
0 3 1 * * certbot certonly --non-interactive --authenticator dns-duckdns --dns-duckdns-token YOUR_TOKEN --dns-duckdns-propagation-seconds 60 -d "*.yourproject-sites.duckdns.org" --agree-tos --email you@example.com --config-dir /home/press/.certbot --work-dir /home/press/.certbot/work --logs-dir /home/press/.certbot/logs && chown -R press:press /home/press/.certbot
```
You'll still need to re-run the "manually register in Press" step (7.3) after each renewal, since the cert content changes — consider wrapping steps 7.2's renewal command and 7.3's Python snippet into a single shell script you run every ~60 days.

---

## Part 8 — Create Your Servers in Press (Proxy, Database, App)

⚠️ **Critical: use SHORT hostnames, not full DuckDNS names.** The "Hostname" field combines with "Domain" to form the server's permanent internal name (`<hostname>.<domain>`), and this field **cannot be changed after creation** (it's locked, `set_only_once`). If you type the full FQDN here, you'll get an ugly, broken-looking name like `yourproject-n1.duckdns.org.yourproject-sites.duckdns.org` and will have to delete and recreate the whole server record to fix it. Use just `n1`, `m1`, `f1`.

### 8.1 Proxy Server (n1)

From the Root Domain page → Connections → Servers → **Proxy Server +**. Fill in:
- **Hostname:** `n1` (short label only)
- **Domain:** `yourproject-sites.duckdns.org` (should be pre-filled)
- **Provider:** Generic
- **Is Primary:** ✅ checked (since this is your only proxy, not a replica)
- **Networking → IP:** n1's public IP
- **Networking → Private IP:** n1's private IP (find it in the EC2 console — looks like `172.31.x.x`)
- **Nginx → Domains:** Add Row → `n1.yourproject-sites.duckdns.org`

Save.

### 8.2 Database Server (m1) and App Server (f1)

Same pattern via their respective **+** buttons in Root Domain's Connections panel, using hostname `m1` and `f1` respectively, and each server's own public/private IP.

---

## Part 9 — Run Setup Server (and Fix What Comes Up)

Click **Actions → Setup Server** on the Proxy Server (n1) first. Status will show "Installing." Click **Ansible Play** (in the Connections panel) to watch progress and diagnose any failure — this is the same debugging path the official guide recommends.

Expect these issues, once each, in this rough order — all are environment-level (Ubuntu 24.04 + fresh install), not mistakes on your part:

### 9.1 `pkg_resources` missing in the agent's Python environment
Newer `setuptools` releases removed `pkg_resources`, which Press's per-server agent needs (via Jinja2).
```bash
ssh root@yourproject-n1.duckdns.org
/home/frappe/agent/env/bin/pip install "setuptools<81" --break-system-packages
exit
```

### 9.2 nginx fails to start: config file symlink missing
Press's agent role manages `/etc/nginx/nginx.conf` as a symlink into its own directory — if that target doesn't exist yet when nginx first tries to start, it fails outright.
```bash
ssh root@yourproject-n1.duckdns.org
rm -f /etc/nginx/nginx.conf
apt-get install --reinstall --yes -o Dpkg::Options::="--force-confmiss" nginx-common
mkdir -p /home/frappe/agent
touch /home/frappe/agent/nginx.conf
chown -R frappe:frappe /home/frappe
ln -sf /home/frappe/agent/nginx.conf /etc/nginx/conf.d/agent.conf
nginx -t
systemctl start nginx
exit
```

If either of these appears again on m1 or f1 when you set those up next, apply the same fix there (same root cause, same commands, different server).

Re-run **Setup Server** after each fix. Once status shows **Active**, that server is genuinely done.

Repeat Part 8.2 + Part 9's fixes for **Database Server (m1)** and then **App Server (f1)**.

---

## Part 10 — Docker Registry, Apps, and Your First Deploy

Once n1, m1, and f1 all show **Active**:

1. On the **f1** Server doc → SSH section → check **Use for Build**.
2. **AWS ECR** → create a **public** registry.
3. **Press Settings → Docker tab:** set Build server to `f1.yourproject-sites.duckdns.org`, Registry URL to your ECR URL, and Username/Password to `press-user`'s access key/secret from Part 1.2.
4. Create an **App** named `frappe` → add an **App Source** (branch `version-15`) → approve the auto-created App Release.
5. Create a **Release Group** (e.g. "V-15"): Version 15, Servers = f1, Build server = f1, add the `frappe` app.
6. **Actions → Create Deploy Candidate** → open it → **Deploy → Schedule Build and Deploy**.

If the build gets stuck because `build` isn't recognized as a valid queue, add this to `sites/common_site_config.json` on the press server:
```json
"workers": {
  "sync": { "timeout": 300 },
  "build": { "timeout": 2400 }
}
```
⚠️ **Validate the JSON after editing this file, every time** — a missing comma here won't error immediately, but will silently crash every background process the next time the server restarts (which could be days later, looking like an unrelated outage):
```bash
python3 -c "import json; json.load(open('sites/common_site_config.json')); print('JSON OK')"
```

Also fix Docker socket permissions on the build server:
```bash
ssh root@yourproject-f1.duckdns.org
chmod 666 /var/run/docker.sock
exit
```

---

## Part 11 — Verify Everything Actually Works

Before calling this done, confirm all of the following:

- [ ] `https://yourproject.duckdns.org/app` loads and logs in as Administrator with no errors
- [ ] `https://yourproject.duckdns.org/dashboard` shows the Frappe Cloud–style signup page
- [ ] n1, m1, f1 all show **Active** status in Press (not Installing/Broken)
- [ ] A test site created through the dashboard successfully deploys and is reachable at its `*.yourproject-sites.duckdns.org` subdomain over HTTPS with no certificate warning
- [ ] `sudo supervisorctl status` on the press server shows all processes `RUNNING`
- [ ] The Elastic IPs from Part 2.1 are genuinely attached (check EC2 console) — not just ephemeral public IPs

---

## Appendix — AWS Security Group Checklist

Make sure your EC2 Security Group(s) allow this inbound traffic, or servers will fail to communicate even with everything else correctly configured:

| Server | Port | From |
|---|---|---|
| press | 22 (SSH) | Your IP |
| press | 80, 443 | Anywhere |
| n1 | 22 (SSH) | press's IP |
| n1 | 80, 443 | Anywhere |
| m1 | 22 (SSH) | press's IP |
| m1 | 3306 (MySQL) | n1 and f1's IPs only |
| f1 | 22 (SSH) | press's IP |
| f1 | agent port (check Press docs for current default) | n1's IP |

---

## Appendix — If You Get a Real Domain Later

Everything in Parts 4 onward transfers directly if you later move from DuckDNS to a real domain — just swap every `yourproject*.duckdns.org` reference for your real subdomains, and re-do Parts 7-9 for the new domain (the server-level fixes in Part 6 don't need repeating; they're one-time environment fixes, not domain-specific).

If your real domain's DNS is hosted on **AWS Route 53**, you can skip the entire manual certificate process in Part 7 — select "AWS Route 53" as the DNS Provider instead of "Generic," and Press's built-in automation (wildcard cert issuance and renewal) will work as originally designed by Frappe.
