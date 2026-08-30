	# Self-Hosting Frappe Press on AWS Free Tier with DuckDNS
### A field guide from a real installation — every problem we hit, and how we fixed it

This guide documents a complete, real-world installation of [Frappe Press](https://github.com/frappe/press) (self-hosted Frappe Cloud) on 4 AWS EC2 instances, using **DuckDNS** instead of a paid domain + Route 53, on the **AWS Free Tier**. It is based on the official community guide:

> [\[Guide\] Installing Press and get it up and running - Part 1](https://discuss.frappe.io/t/guide-installing-press-and-get-it-up-and-running-part-1/152576)

That guide assumes AWS Route 53 and a paid domain. This document captures **every deviation, every error, and every fix** we needed to get a working Press installation using DuckDNS + Ubuntu 24.04 (Noble) instead. If you're following the same path, this should save you the multi-day debugging session it took us.

---

## 1. Architecture / What We Were Building

Same 4-server layout as the official guide:

| Server | Role | Hostname (final) |
|---|---|---|
| `press` | Runs Press app itself (the dashboard) | `presstest.duckdns.org` |
| `n1` | Proxy Server (nginx reverse proxy + TLS termination) | `n1.presstest-sites.duckdns.org` |
| `m1` | Database Server (MariaDB) | `m1.presstest-sites.duckdns.org` |
| `f1` | App Server (runs benches/sites, builds Docker images) | `f1.presstest-sites.duckdns.org` |

Key deviations from the official guide:
- **DNS provider:** DuckDNS (free) instead of AWS Route 53 (paid domain required)
- **OS:** Ubuntu 24.04 LTS (Noble) — the official guide uses 22.04 (Jammy)
- **AWS tier:** Free tier (no Elastic IPs by default — see [Section 10](#10-the-elastic-ip-warning))

---

## 2. Phase 0 — Installing Frappe + Press on the `press` Server (Ubuntu 24.04)

This is the very first real milestone — getting `bench --site <domain> install-app press` to succeed at all — and it turned out to be the single longest phase of the whole project. None of these problems are DuckDNS-specific; they hit **any** fresh Press install on Ubuntu 24.04 / Python 3.12, because Press's own dependency list still targets an older Python.

### 2.1 Root cause of the first entire wasted attempt: wrong Linux user

**Symptom:** After apparently following every step, `sudo bench setup production press` "succeeded" but nginx/supervisor never served anything correctly, and things generally behaved as if configured for a different user than expected.

**Cause:** On AWS EC2 Ubuntu images, the default login user is `ubuntu`. The original guide has you create a dedicated `press` user for cleanliness. It's easy to `ssh` in as `ubuntu`, run `sudo apt-get install ...` (fine, system-wide), but then **not actually switch to the `press` user** before running `bench init`, `bench new-site`, `bench setup production`, etc. Since `sudo bench setup production press` was run from *inside* the `ubuntu` user's shell, all the generated configs, file ownership, and the entire `frappe-bench` directory ended up under `/home/ubuntu/frappe-bench` — pointing nginx/supervisor at paths owned by the wrong user, and creating a permissions/path mismatch that's very confusing to debug after the fact because most individual commands don't error.

**Fix — verify the user before every install step, and clean up any partial state under the wrong user:**
```bash
ssh press
whoami        # must print "press" — if it prints "ubuntu", exit and re-login as press
```
Cleanup of the wrong-user attempt:
```bash
sudo rm -rf /home/ubuntu/frappe-bench
sudo rm -rf /home/press/frappe-bench

# drop any half-created MariaDB database/user from the failed site
sudo mysql -e "SHOW DATABASES;"
sudo mysql -e "DROP DATABASE IF EXISTS <the_hash_named_db_you_found>;"
sudo mysql -e "SELECT User FROM mysql.user;"
sudo mysql -e "DROP USER IF EXISTS '<matching_user>'@'localhost';"

# remove any nginx/supervisor config generated under the wrong user
sudo rm -f /etc/nginx/conf.d/frappe-bench.conf
sudo rm -f /etc/supervisor/conf.d/frappe-bench.conf
sudo systemctl restart nginx
sudo systemctl restart supervisor
```
Then confirm `cd ~ && pwd` prints `/home/press` before starting the install sequence in Section 2.2 below.

> **Lesson:** `sudo <command>` does **not** change which user's home directory `bench` operates in — it only elevates privileges while keeping your current shell's user context (`$HOME`, `cwd`, etc. — unless you also `sudo -u otheruser`). Always confirm `whoami` and `pwd` immediately before any `bench` command during initial setup.

### 2.2 Should you use the newer ERPNext v16 guide (Python 3.14 / `uv`) instead?

At one point we seriously considered abandoning the `pip`/`venv`-based v15 install (which was producing a long chain of dependency errors — Section 2.4 below) in favor of a newer community guide for ERPNext v16 on Ubuntu 24.04, which uses Python 3.14 and the `uv` package manager.

**We did not switch, and would recommend against it for a Press install specifically:**
- Press is a different thing from plain ERPNext — it's the *hosting/orchestration platform* (why this project needs 4 servers at all), not just the ERP application.
- At the time, a comment on that v16 guide's own thread reported **Press specifically breaking** on the Python 3.14 / `uv` toolchain, with no posted resolution.
- Nobody in that thread had confirmed getting **Press** (as opposed to plain ERPNext) working on v16.
- The dependency errors we were hitting on v15/Python 3.12 (Section 2.4) were all fixable, just tedious — not a dead end.

**Recommendation:** for a Press install specifically, stay on Frappe version-15 with the standard `pip`/`venv` bench install, even on Ubuntu 24.04. Ubuntu 24.04 ships Python 3.12 by default, which works fine with Frappe version-15 once the dependency pins below are corrected.

### 2.3 Base OS package installation (Ubuntu 24.04-specific deviations)

Followed the [community ERPNext v15-on-Ubuntu guide](https://discuss.frappe.io/t/guide-how-to-install-erpnext-v15-on-linux-ubuntu-step-by-step-instructions/111706) with the following 24.04-specific corrections:

```bash
timedatectl set-timezone "Africa/Cairo"   # or your timezone

sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install git -y
sudo apt-get install python3-dev python3-pip python3-setuptools python3-venv -y
sudo apt-get install software-properties-common -y
sudo apt-get install mariadb-server mariadb-client -y
sudo apt-get install redis-server -y
sudo apt-get install xvfb libfontconfig libmysqlclient-dev pkg-config -y
```

**wkhtmltopdf** — install the patched-Qt build explicitly for x86_64 (Intel/AMD instance types):
```bash
wget https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb
sudo apt install ./wkhtmltox_0.12.6.1-2.jammy_amd64.deb -y
wkhtmltopdf --version   # should report "(with patched qt)"
```

**MariaDB charset config** — same as the original guide, add to `/etc/mysql/my.cnf`:
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

**Node / npm / yarn** — via `nvm`, pinned to Node 18 (Frappe version-15's supported major):
```bash
cd ~
curl https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
source ~/.profile
nvm install 18
nvm use 18
sudo apt-get install npm -y
sudo npm install -g yarn
node --version   # should show v18.x
```

**Frappe Bench itself — Ubuntu 24.04 blocks a plain system-wide `pip3 install`:**
```bash
sudo pip3 install frappe-bench --break-system-packages
bench --version
```
> **24.04-specific gotcha:** Ubuntu 24.04 ships [PEP 668](https://peps.python.org/pep-0668/) "externally managed environment" protection, which the original guide (written for 22.04) doesn't need to account for. Every system-wide `pip install` needs `--break-system-packages` on 24.04, or you'll get an `error: externally-managed-environment` refusal.

**Initialize the bench, as the `press` user, under `/home/press`:**
```bash
cd ~
bench init --frappe-branch version-15 frappe-bench
cd frappe-bench/
sudo chmod -R o+rx /home/press/
```

### 2.4 Create the site and install Press

```bash
bench new-site presstest.duckdns.org
# prompts for the MariaDB root password (set in 2.3), then an Administrator password (your future Press login)

bench get-app press
bench --site presstest.duckdns.org install-app press
```

This is where the real work started — `install-app press` failed repeatedly with a chain of `ModuleNotFoundError`/`AttributeError` exceptions, one after another. **All of them share one root cause:** Press's `pyproject.toml` pins several dependencies to old, specific versions that predate Python 3.12 (they were fine on the Python 3.10/3.11 environments most guides assume), and those old packages use import machinery Python 3.12 removed outright.

#### 2.4.1 `ModuleNotFoundError: No module named 'urllib3.contrib.appengine'`

**Cause:** Press depends on the old `python-telegram-bot==13.15` package (for its Telegram notification feature), which vendors/falls back to `urllib3.contrib.appengine` — a module that was **removed in `urllib3` 2.x**. A newer `urllib3` had been installed as a transitive dependency of something else.

First-pass fix (temporary — see 2.4.5 for why this alone doesn't stick):
```bash
cd ~/frappe-bench
./env/bin/pip install "urllib3<2"
./env/bin/pip show urllib3   # should show 1.26.x
bench --site presstest.duckdns.org install-app press
```

#### 2.4.2 `ModuleNotFoundError: No module named 'stripe.six.moves'`

**Cause:** Press pins `stripe~=2.56.0`, an old Stripe SDK that vendors its own copy of `six` (the Python 2/3 compatibility shim) for legacy support — a mechanism that breaks under Python 3.12.

First-pass fix:
```bash
cd ~/frappe-bench
./env/bin/pip install --upgrade stripe
./env/bin/pip show stripe
bench --site presstest.duckdns.org install-app press
```

#### 2.4.3 `AttributeError: module 'sqlparse.engine.grouping' has no attribute 'MAX_GROUPING_TOKENS'`

**Cause:** This is the opposite direction from the other two — Frappe's own query-builder code (`frappe/model/dbquery.py`) expects `MAX_GROUPING_TOKENS`, a constant that only exists in `sqlparse` **0.5.4 or later** (added in a Feb 2026 security fix). Whatever `sqlparse` version was installed was older than that.

Fix — upgrade, don't downgrade:
```bash
cd ~/frappe-bench
./env/bin/pip install --upgrade "sqlparse>=0.5.4"
./env/bin/pip show sqlparse   # should show 0.5.4+
bench --site presstest.duckdns.org install-app press
```

#### 2.4.4 `ModuleNotFoundError: No module named 'ansible.module_utils.six.moves'`

**Cause:** Press pins `ansible==3.4.0`, which bundles `ansible-base` 2.10 — built for Python 2/early Python 3, using a legacy internal `ansible.module_utils.six` shim that Python 3.12 breaks entirely.

First-pass fix:
```bash
cd ~/frappe-bench
./env/bin/pip install --upgrade ansible
./env/bin/pip show ansible   # should now show a 9.x/10.x ansible, bundling a modern ansible-core
bench --site presstest.duckdns.org install-app press
```

#### 2.4.5 Why the fixes kept "reverting" — and the permanent solution

After fixing Ansible, the **exact same `urllib3.contrib.appengine` error came back**, as if the Section 2.4.1 fix had never happened. Same thing happened to the Stripe and sqlparse fixes on subsequent retries.

**Root cause:** `bench --site ... install-app` automatically reinstalls the app's declared dependencies from its `pyproject.toml` **every time it's run** — silently undoing any manual `pip install --upgrade` fix made in between attempts. Chasing these fixes one `pip install` at a time was never going to stick; the fix has to live in the dependency declaration itself.

**Permanent fix — edit `apps/press/press/pyproject.toml` directly:**
```bash
cp ~/frappe-bench/apps/press/pyproject.toml ~/frappe-bench/apps/press/pyproject.toml.bak
cd ~/frappe-bench/apps/press
sed -i 's/"ansible==3.4.0",/"ansible>=9,<12",/' pyproject.toml
sed -i 's/"stripe~=2.56.0",/"stripe>=7,<8",/' pyproject.toml
```
Then reinstall the app in editable mode so pip picks up the new pins:
```bash
cd ~/frappe-bench
./env/bin/pip install -e apps/press
```

#### 2.4.6 New conflict surfaced by the fix: `oci` needs `urllib3>=2.6.3`, contradicting the `urllib3<2` pin

Adding an explicit `"urllib3<2"` pin (to keep the old `python-telegram-bot` happy) into `pyproject.toml` produced a **genuine, unresolvable conflict** with another Press dependency, Oracle's `oci` SDK, which requires `urllib3>=2.6.3`:
```
ERROR: Cannot install oci==2.180.0 and press==0.7.0 because these package versions have conflicting dependencies.
The conflict is caused by:
    press 0.7.0 depends on urllib3<2
    oci 2.180.0 depends on urllib3>=2.6.3; python_version >= "3.10.0"
```
A single global `urllib3` pin cannot satisfy both packages at once — so the fix has to happen at the actual point of breakage instead: patch the one broken import inside the installed `python-telegram-bot` package. Its `urllib3.contrib.appengine` import is only used for Google App Engine sandbox detection — irrelevant here — so it's safe to make optional.

1. Remove the conflicting pin:
   ```bash
   cd ~/frappe-bench/apps/press
   sed -i '/"urllib3<2",/d' pyproject.toml
   ```
2. Patch `env/lib/python3.12/site-packages/telegram/utils/request.py` — wrap **both** `appengine` import attempts (the vendored one and the fallback one) in `try/except ImportError`:
   ```bash
   cd ~/frappe-bench
   perl -i -pe 's/^(\s+)import telegram\.vendor\.ptb_urllib3\.urllib3\.contrib\.appengine as appengine$/$1try:\n$1    import telegram.vendor.ptb_urllib3.urllib3.contrib.appengine as appengine\n$1except ImportError:\n$1    appengine = None/' env/lib/python3.12/site-packages/telegram/utils/request.py

   perl -i -pe 's/^(\s+)import urllib3\.contrib\.appengine as appengine(\s+#.*)?$/$1try:\n$1    import urllib3.contrib.appengine as appengine$2\n$1except ImportError:\n$1    appengine = None/' env/lib/python3.12/site-packages/telegram/utils/request.py
   ```
3. `appengine` is also *used* later in the same file (not just imported) — those usages need null-guards too, or it'll crash at runtime instead of import time:
   ```bash
   # the type-hint reference (evaluated at runtime in Python) — swap for a harmless placeholder
   sed -i 's/appengine\.AppEngineManager,/type(None),/' env/lib/python3.12/site-packages/telegram/utils/request.py

   # the actual usage — guard with a None-check
   sed -i "s/if appengine\.is_appengine_sandbox():/if appengine and appengine.is_appengine_sandbox():/" env/lib/python3.12/site-packages/telegram/utils/request.py
   ```
4. Verify both patched blocks look correct:
   ```bash
   grep -n -B1 -A2 "appengine" env/lib/python3.12/site-packages/telegram/utils/request.py
   ```

> **Why patch the library instead of the pin:** when two *legitimate* dependencies genuinely need incompatible major versions of a shared transitive dependency, there is no single version pin that satisfies both. The only durable fix is neutralizing the specific unused code path that assumes the old version, in the package that doesn't actually need it (Telegram's App Engine support is dead code in this deployment).

#### 2.4.7 sqlparse regressed too — fix belongs in `frappe`'s own `pyproject.toml`, not Press's

After resolving the `urllib3`/`oci` conflict and re-running `pip install -e apps/press`, the `stripe.six.moves` error reappeared once more (stale install state from the earlier failed `pip install -e` attempt — resolved simply by re-running it now that the conflict was gone), and then the `sqlparse` `MAX_GROUPING_TOKENS` error came back too.

This one wasn't Press's pin — checking confirmed Frappe's own `pyproject.toml` already correctly requires `sqlparse~=0.5.4`:
```bash
grep -n "sqlparse" apps/frappe/pyproject.toml
# 74:    "sqlparse~=0.5.4",
```
The constraint was correct; the **installed** package just didn't match it yet (downgraded again as a side effect of the `oci`/dependency resolution churn above). Force it back in line:
```bash
cd ~/frappe-bench
./env/bin/pip install --force-reinstall "sqlparse~=0.5.4"
./env/bin/pip show sqlparse
bench --site presstest.duckdns.org install-app press
```

At this point, `install-app` finally completed cleanly:
```
Installing press...
Updating DocTypes for press : [========================================] 100%
Updating customizations for Country
Updating customizations for Address
Updating Dashboard for press
```

> **Order of the four real problem dependencies, from easiest to hardest:** sqlparse (pure version bump) → Stripe (pure version bump) → Ansible (version bump, but needed the permanent `pyproject.toml` fix to stick) → python-telegram-bot/urllib3 (no version bump possible — needed direct source patching due to a genuine cross-dependency conflict).

### 2.5 Production setup — two more gotchas after `install-app` succeeds

```bash
bench --site presstest.duckdns.org list-apps   # confirm both "frappe" and "press" are listed
bench --site presstest.duckdns.org enable-scheduler
bench --site presstest.duckdns.org set-maintenance-mode off
```

**Gotcha — use `sudo env "PATH=$PATH"`, not plain `sudo`, for the production setup command:**
```bash
sudo env "PATH=$PATH" bench setup production press
bench setup nginx
```
Plain `sudo bench setup production press` re-resolves `bench`/`python` through `root`'s own `$PATH`, which may not point at the same virtualenv where all the dependency fixes above were applied — `sudo env "PATH=$PATH"` preserves the *current* shell's `$PATH` while still elevating privileges.

**Gotcha — `bench setup production` generates the supervisor config, but doesn't automatically link it into supervisor's active config directory.** After running it, `sudo supervisorctl status` came back completely empty (no processes listed at all, not even `FATAL`/`BACKOFF`) — not the "some services not RUNNING" failure mode, but *nothing registered whatsoever*. The supervisor daemon's own log confirmed why:
```
WARN No file matches via include "/etc/supervisor/conf.d/*.conf"
```
Diagnosis:
```bash
ls -l /etc/supervisor/conf.d/                       # empty — nothing linked in
sudo systemctl status supervisor --no-pager          # supervisor daemon itself is fine and running
ls -l ~/frappe-bench/config/supervisor.conf          # bench DID generate the config file — just never linked it
```
Fix — link it manually:
```bash
sudo ln -sf /home/press/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart all
sleep 10
sudo supervisorctl status
```
All 7 processes (`redis-cache`, `redis-queue`, `frappe-web`, `node-socketio`, `frappe-long-worker-0`, `frappe-schedule`, `frappe-short-worker-0`) should now show `RUNNING`.

### 2.6 Firewall and SSL for the `press` dashboard itself

```bash
sudo ufw allow 22,25,143,80,443,3306,3022,8000/tcp
sudo ufw enable   # type 'y' if it warns about disrupting the current SSH session — port 22 is included above
```

This certificate is for the **single** `press` dashboard domain (not a wildcard, so the DuckDNS DNS-01 dance from Section 3 isn't needed here) — plain HTTP-01 via nginx works fine:
```bash
sudo snap install core
sudo snap refresh core
sudo snap install --classic certbot
sudo ln -s /snap/bin/certbot /usr/bin/certbot
sudo certbot --nginx
# enter an email, agree to ToS, select the one domain listed (presstest.duckdns.org) when prompted
```
Then confirm `https://presstest.duckdns.org/dashboard` loads the Press login page (`Administrator` / the password set during `bench new-site`).

---

## 3. Phase 1 — DNS & TLS Certificate (DuckDNS instead of Route 53)

### 3.1 Problem: Press's "Generic" DNS provider can't issue wildcard certificates

The official guide uses Route 53 because Press's certificate flow needs a **wildcard TLS certificate** (`*.presstest-sites.duckdns.org`) for the sites domain, so every tenant site gets HTTPS automatically.

- **Wildcard certificates require a DNS-01 ACME challenge** (proving you control the DNS zone via a TXT record).
- Press's **"Generic" DNS provider only does HTTP-01** (webroot) validation — which **cannot issue wildcard certs at all**, regardless of step ordering.
- This is why Route 53 isn't just "convenient" in the original guide — it's structurally required, because DNS-01 needs an API to create TXT records, and only Route 53 is wired into Press's "Generic vs Route53" logic.

**Symptom:** `TLS Certificate None not found` error on the Proxy Server, tracing back to `proxy_server.py` expecting a `certificate_name` that was never set.

### 3.2 Solution: Bypass Press's automated TLS flow — get the cert manually via `certbot-dns-duckdns`

1. Install the DuckDNS certbot plugin **as a snap** (not pip — see gotcha below):
   ```bash
   sudo snap install certbot-dns-duckdns
   sudo snap set certbot trust-plugin-with-root=ok
   sudo snap connect certbot:plugin certbot-dns-duckdns
   ```

   > **Gotcha:** If `certbot` itself is installed as a **classic-confinement snap** (`which certbot` → `/usr/local/bin/certbot`, but `snap list | grep certbot` shows it), a plugin installed via `pip3 install certbot-dns-duckdns` will be **invisible to it** — snap confinement isolates it from the system Python's `site-packages`. You must install the plugin as a snap too, then explicitly connect it (with the `trust-plugin-with-root=ok` acknowledgment, since the plugin needs root).

2. Create the DuckDNS token file:
   ```bash
   sudo nano /home/press/.certbot/duckdns.ini
   ```
   ```ini
   dns_duckdns_token = <your-duckdns-token>
   ```
   ```bash
   sudo chmod 600 /home/press/.certbot/duckdns.ini
   ```

3. **Request the wildcard and base domain SEPARATELY, not in the same command.**

   > **Gotcha:** DuckDNS's API only supports **one TXT value** under `_acme-challenge.<domain>` at a time. If you request `example.com` and `*.example.com` in the same `certbot certonly` call, Let's Encrypt needs two *different* TXT values under the same name simultaneously — but DuckDNS overwrites the first with the second, so validation fails with `Incorrect TXT record`.

   Run wildcard-only:
   ```bash
   sudo certbot certonly \
     --non-interactive \
     --authenticator dns-duckdns \
     --dns-duckdns-token <your-token> \
     --dns-duckdns-propagation-seconds 60 \
     -d "*.presstest-sites.duckdns.org" \
     --agree-tos \
     --email you@example.com \
     --config-dir /home/press/.certbot \
     --work-dir /home/press/.certbot/work \
     --logs-dir /home/press/.certbot/logs
   ```

   > **Gotcha:** Using the token from a config file (`--dns-duckdns-credentials file.ini`) inside the certbot **snap sandbox** failed with `No DuckDNS token found` even though the file was correctly formatted and readable — a snap confinement / sandboxed-file-access issue. Passing the token directly via `--dns-duckdns-token <token>` on the command line worked around it.

4. Fix file ownership (certbot ran as root, but Press's bench console runs as the `press` user):
   ```bash
   sudo chown -R press:press /home/press/.certbot
   ```

5. Manually create the `TLS Certificate` doc in Press since the automated flow never ran. In `bench console`:
   ```python
   import frappe
   with open("/home/press/.certbot/live/presstest-sites.duckdns.org/cert.pem") as f:
       cert = f.read()
   with open("/home/press/.certbot/live/presstest-sites.duckdns.org/chain.pem") as f:
       chain = f.read()
   with open("/home/press/.certbot/live/presstest-sites.duckdns.org/fullchain.pem") as f:
       fullchain = f.read()
   with open("/home/press/.certbot/live/presstest-sites.duckdns.org/privkey.pem") as f:
       privkey = f.read()

   doc = frappe.get_doc({
       "doctype": "TLS Certificate",
       "domain": "presstest-sites.duckdns.org",
       "wildcard": 1,
       "status": "Active",
       "provider": "Let's Encrypt",
       "team": "<your-team-id>",   # e.g. from frappe.get_all("Team", fields=["name","user"])
       "certificate": cert,
       "intermediate_chain": chain,
       "full_chain": fullchain,
       "private_key": privkey,
   })
   doc.insert(ignore_permissions=True)
   frappe.db.commit()
   ```

   > **Gotcha:** `team` is a Link field to the `Team` doctype (not the string `"Administrator"`). Look up the real team name first:
   > ```python
   > frappe.get_all("Team", fields=["name", "user"])
   > ```

6. **Never click "Obtain Certificate" or "Trigger Server Setup Callback" in the UI after this** — those buttons run Press's built-in Route53-based automation, which will fail and can overwrite your manually-set `status` back to `Failure` (the certificate data itself survives, but you'll need to flip `status` back to `Active` — see below).

### 3.3 Recurring gotcha: a background job kept resetting the certificate to "Failure"

Press has an hourly scheduled job, `retrigger_failed_wildcard_tls_callbacks`, that retries certs belonging to servers with `status = "Active"`. As long as your Proxy Server doc is still `Installing`/`Broken` (not yet `Active`), this job won't touch your certificate. Once your Proxy Server becomes `Active`, this stops being a concern (the callback only fires for *failed* renewals, and a valid, non-expired manually-issued cert won't trigger a renewal attempt).

If your `TLS Certificate` doc's `status` ever gets stuck on `Failure` despite the cert/key still being present, fix it directly via SQL (the ORM's `doc.save()` can throw `TimestampMismatchError` if the doc was touched elsewhere):
```python
frappe.db.sql(
    "UPDATE `tabTLS Certificate` SET status = %s WHERE name = %s",
    ("Active", "*.presstest-sites.duckdns.org")
)
frappe.db.commit()
```

---

## 4. Phase 2 — Proxy Server (n1) Setup Issues

Running **Actions → Setup Server** on the Proxy Server (`n1`) surfaced a long chain of environment problems. Fix them **in this order** — each one blocks discovery of the next.

### 4.1 `ModuleNotFoundError: No module named 'ansible_collections.ansible.builtin'`

**Cause:** Press's `runner.py` calls Ansible's `Playbook`/`PlaybookExecutor` classes directly from Python (not via the `ansible-playbook` CLI). Recent Ansible-core versions (2.18+) require an explicit call to register the built-in collection loader — something the `ansible-playbook` CLI does automatically, but a raw Python import does not. Older `ansible-core` versions (~2.9–2.10, which is what the original guide assumed) didn't need this.

**Fix:** Edit `apps/press/press/runner.py`:
```python
# add to the imports
from ansible.plugins.loader import init_plugin_loader

# add once at module load time, before Ansible/Playbook objects are constructed
init_plugin_loader()
```

Verify with:
```bash
./env/bin/python3 -c "
from ansible.plugins.loader import init_plugin_loader
init_plugin_loader()
import ansible_collections.ansible.builtin
print('OK')
"
```

### 4.2 `AttributeError: module 'lib' has no attribute 'GEN_EMAIL'` (pyOpenSSL / cryptography mismatch)

**Cause:** `press/pyproject.toml` pins `pyOpenSSL~=23.2.0` with a comment capping `cryptography` below version 46 ("drops the GEN_EMAIL binding pyOpenSSL reads at import"). But the frappe framework version in use required `cryptography~=50.0.0` and `pyOpenSSL~=26.4.0` — a newer pair. Installing an old `pyOpenSSL` against the newer `cryptography` (or vice versa) breaks certificate parsing at import time.

**Fix — don't follow the old `press` pin; match what `frappe` actually needs:**
```bash
./env/bin/pip install "cryptography~=50.0.0" "pyOpenSSL~=26.4.0" --break-system-packages
```
Verify:
```bash
./env/bin/python3 -c "
from ansible.plugins.loader import init_plugin_loader
init_plugin_loader()
import ansible_collections.ansible.builtin
import OpenSSL
from OpenSSL import SSL, crypto
print('ALL OK')
"
```

> **Lesson:** when a library's own pinned dependency comment is stale relative to a newer sibling package (here, `frappe` had moved ahead of what `press`'s pin assumed), trust the newest working combination over the older pin's stated intent. This is the exact same pattern as the `install-app` dependency chase in Section 2.4 — Press's pinned versions across the board assume an older Python/Frappe pairing than what Ubuntu 24.04 + current Frappe actually gives you.

### 4.3 SSH `Unreachable` — Ansible connects by IP, not by the `~/.ssh/config` hostname alias

**Symptom:** `ssh root@presstest-n1.duckdns.org` works fine manually, but the Ansible play reports the host as `Unreachable`.

**Cause:** In `runner.py`:
```python
self.host = server.ip if server.ip else server.private_ip
```
Press connects using the **raw IP address**, not the domain name. If your `~/.ssh/config` only has a `Host` entry keyed by the domain name (as the original guide sets up), SSH's pattern matching won't apply your `IdentityFile` when connecting by IP, and the connection silently falls back to failing auth.

**Fix:** Add a **second** `Host` entry per server, keyed by IP:
```
Host 52.200.82.254
    User root
    IdentityFile ~/.ssh/key_test_erp.pem
    StrictHostKeyChecking no
```
Repeat for every server's IP (not just its hostname). Verify with `ssh root@<ip>` directly before re-running Setup Server.

### 4.4 `pkg_resources` missing (agent Python environment)

**Symptom:**
```
File ".../jinja2/loaders.py", line 222, in __init__
    from pkg_resources import DefaultProvider, ResourceManager, ...
ModuleNotFoundError: No module named 'pkg_resources'
```

**Cause:** `pkg_resources` ships inside `setuptools`, but recent `setuptools` releases (v81+) **removed it entirely** since it's deprecated. Press's `agent` package (a separate venv per server, at `/home/frappe/agent/env`) depends on it transitively via Jinja2's `PackageLoader`.

**Fix — pin to a `setuptools` version that still ships it:**
```bash
/home/frappe/agent/env/bin/pip install "setuptools<81" --break-system-packages
```
Verify: `/home/frappe/agent/env/bin/python3 -c "import pkg_resources; print('OK')"` (a deprecation warning is expected and harmless).

> This happens on **every server** (n1, m1, f1) because each runs its own isolated `agent` venv — you'll hit this once per server.

### 4.5 `sshd` service name mismatch (`Could not find the requested service sshd: host`)

**Cause:** Press's Ansible roles (`sshd_hardening`, `user_ssh_certificate`, `warning_banners`, and others) all reference the SSH daemon service as `sshd`. On **Ubuntu**, the systemd unit is named `ssh.service`, not `sshd.service` (unlike RHEL/CentOS-family distros, which this playbook set was apparently also written for).

**Fix — create a systemd alias so both names resolve to the same unit** (safer than patching every `service: name=sshd` task across 6+ playbook files):
```bash
sudo ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/sshd.service
sudo systemctl daemon-reload
systemctl status sshd   # should now report the real ssh.service state
```

### 4.6 MariaDB repository 404 (`mirror.rackspace.com/mariadb/repo/10.6/ubuntu noble ... does not have a Release file`)

**Cause:** The `mariadb` Ansible role hardcodes:
```yaml
repo: deb https://mirror.rackspace.com/mariadb/repo/10.6/ubuntu {{ ansible_distribution_release }} main
```
**MariaDB 10.6 has no official build for Ubuntu 24.04 (Noble)** — 10.6 predates Noble's release by years. This isn't a mirror outage; it's a genuine absence of packages for that OS/version combination. Confirmed by testing multiple mirrors (`mirror.rackspace.com`, `mirror.mariadb.org`, `archive.mariadb.org`) — all 404 for `10.6/ubuntu/dists/noble`, while `10.11` and `11.4` both resolve fine (302 redirects to a working mirror).

**Fix — use Ubuntu Noble's own built-in MariaDB (10.11), not an external MariaDB.org repo:**
- Remove/skip the `apt_repository` task adding the Rackspace 10.6 repo.
- Let `apt install mariadb-server mariadb-client` pull Noble's native 10.11 packages instead.
- Fix the package name: `libmariadbclient18` (the old dev package name Press's role expects) doesn't exist in Noble either — the correct package is **`libmariadb3`**.
- Ensure `/etc/systemd/system/mariadb.service.d/` exists before any override file is written to it (a `mkdir -p` guard was added, since a from-scratch install may not have created it yet by the time the role tries to write into it).

### 4.7 nginx: `open() "/etc/nginx/nginx.conf" failed (2: No such file or directory)`

**Root cause:** Press's `agent` role deliberately manages `/etc/nginx/nginx.conf` as a **symlink** into the agent's own directory:
```yaml
- name: Create NGINX Root Configuration File
  file:
    path: /home/frappe/agent/nginx/nginx.conf
    state: touch
- name: Symlink NGINX Root Configuration File
  file:
    src: /home/frappe/agent/nginx/nginx.conf
    dest: /etc/nginx/nginx.conf
    state: link
    force: yes
```
Similarly, `/etc/nginx/conf.d/agent.conf` is symlinked to `/home/frappe/agent/nginx.conf`.

**This only breaks if `/home/frappe` gets deleted** (e.g. during a manual cleanup/reset) while the dangling symlinks are left behind in `/etc/nginx/`. On a genuinely first-time install this never happens, because the `agent` role runs and creates the real files before anything tries to (re)start nginx *within the same play* — except that the **`nginx` role's own "Restart NGINX and Enable at Boot" task runs earlier in the playbook than the `agent` role**, so on a *fresh* install nginx starts against the **stock config that came with `apt install nginx`**, succeeds, and only gets re-pointed to the agent's symlinked config afterward. If a stale/broken symlink already occupies `/etc/nginx/nginx.conf` before that first start attempt, it fails immediately.

**Fix, step by step:**
1. Remove the dangling symlink and reinstall the package's own default config file (a conffile, so a plain `--reinstall` is refused unless forced):
   ```bash
   rm -f /etc/nginx/nginx.conf
   apt-get install --reinstall --yes -o Dpkg::Options::="--force-confmiss" nginx-common
   ```
2. The default `nginx.conf` includes `/etc/nginx/conf.d/*.conf` — if `agent.conf` is *also* a dangling symlink, `nginx -t` will now fail on that instead:
   ```
   open() "/etc/nginx/conf.d/agent.conf" failed (2: No such file or directory)
   ```
   Pre-create an empty placeholder so the include succeeds (the `agent` role will overwrite it with real content later in the same run):
   ```bash
   mkdir -p /home/frappe/agent
   touch /home/frappe/agent/nginx.conf
   chown -R frappe:frappe /home/frappe
   ln -sf /home/frappe/agent/nginx.conf /etc/nginx/conf.d/agent.conf
   ```
3. Confirm and start:
   ```bash
   nginx -t
   systemctl start nginx
   systemctl status nginx --no-pager
   ```

> **Order matters.** Do **not** symlink `/etc/nginx/nginx.conf` itself to an empty placeholder file — nginx needs a real, non-empty top-level config (with an `events {}` block) to start at all. Only `conf.d/agent.conf` (an *include target*) is safe to pre-create as an empty placeholder.

---

## 5. Phase 3 — Database Server (m1) Setup Issues

m1 hit the **exact same** issues as n1, since it's provisioned by the same underlying Press/Ansible/agent machinery:
- Same `pkg_resources` fix (separate `agent` venv on m1) — [4.4](#44-pkg_resources-missing-agent-python-environment)
- Same `sshd`/`ssh` systemd alias — [4.5](#45-sshd-service-name-mismatch-could-not-find-the-requested-service-sshd-host)
- Same MariaDB 10.6→10.11 fix — [4.6](#46-mariadb-repository-404-mirrorrackspacecommariadbrepo106ubuntu-noble--does-not-have-a-release-file)
- Same nginx symlink fix — [4.7](#47-nginx-open-etcnginxnginxconf-failed-2-no-such-file-or-directory)

No new problem classes appeared here — this is expected once you understand these are **environment-level** issues (Ubuntu 24.04 + fresh installs), not server-role-specific ones.

---

## 6. Phase 4 — App Server (f1) Setup Issues

Same pattern again:
- `pkg_resources` fix — [4.4](#44-pkg_resources-missing-agent-python-environment)
- nginx symlink fix — [4.7](#47-nginx-open-etcnginxnginxconf-failed-2-no-such-file-or-directory)

No MariaDB involved here (f1 doesn't run a database), so that class of problem doesn't apply.

---

## 7. Phase 5 — The Hostname Problem (and why we rebuilt from scratch)

### 7.1 The problem

When creating each server (Proxy/Database/App) in the Press UI, the **Hostname** field was filled with the *full DuckDNS FQDN* (e.g. `presstest-n1.duckdns.org`) instead of a short label (e.g. `n1`), because that felt like the "real" hostname to enter.

Press builds each server document's **name** (its primary key, which is also used to build nginx vhost names, DNS records for tenant sites, etc.) as:
```
<hostname>.<domain>
```
So this produced ugly, doubled names like:
```
presstest-n1.duckdns.org.presstest-sites.duckdns.org
```
instead of the clean form the official guide expects:
```
n1.presstest-sites.duckdns.org
```

### 7.2 Why it couldn't be fixed in place

The `hostname` field on `Proxy Server` / `Database Server` / `Server` doctypes is marked `set_only_once: 1` in the doctype JSON — Frappe blocks any `.save()` that changes it after creation. Confirmed via:
```python
print(f1.meta.get_field("hostname").set_only_once)  # → 1
print(f1.meta.get_field("hostname").read_only)       # → 0 (blocked by validation, not the form)
```
There's a `rename_server()` / `_rename_server()` method on the `Server` doctype, but inspecting its implementation showed it does **not** accept or set a new hostname — it re-runs a `rename.yml` Ansible playbook against the server's *existing* `self.name`/`self.private_ip`, presumably to reconcile nginx/monitoring config **after** some other, undiscovered renaming mechanism already changed the doc's underlying name. We could not find that mechanism confidently, and didn't want to risk a partial, unsupported rename against servers that were otherwise healthy and `Active`.

### 7.3 The decision: full rebuild

Given:
- Three servers already fully provisioned and validated (all fixes above applied and working)
- No safe, documented way to rename in place
- All root causes now understood and fixable in minutes, not hours

**We chose to delete and recreate all three server docs with the correct short hostnames**, rather than risk data/config corruption from an unsupported rename path. This took under an hour end-to-end, versus days on the first pass (because every failure mode was now known in advance).

### 7.4 What survives a server-doc deletion (and what doesn't)

| Artifact | Survives deletion from Press UI? | Notes |
|---|---|---|
| The **TLS Certificate** doc (`*.domain`) | ✅ Yes | Keyed to the *domain*, not the server hostname. No need to re-issue. |
| DuckDNS A-records | ✅ Yes | Still point at the same EC2 IPs; nothing to change. |
| `~/.ssh/config` entries on `press` | ✅ Yes | Keyed by IP/hostname, unrelated to Press's DB records. |
| The `Team` record | ✅ Yes | Independent of servers. |
| MariaDB install + data on the DB server | ❌ No — must be manually purged | Deleting the Press doc does **not** touch the actual EC2 instance. Old data/config left in place will conflict with a fresh Setup Server run. |
| nginx configs / `/home/frappe/agent` on Proxy & App servers | ❌ No — must be manually purged | Same reasoning. |

### 7.5 Manual server cleanup procedure (before recreating)

**On the Database Server (m1):**
```bash
systemctl stop mariadb 2>/dev/null
apt purge -y mariadb-server mariadb-client mariadb-common libmariadb3 mysql-common
apt autoremove -y
rm -rf /var/lib/mysql /etc/mysql /etc/systemd/system/mariadb.service.d
rm -rf /home/frappe
```

**On the Proxy Server (n1):**
```bash
systemctl stop nginx 2>/dev/null
rm -rf /etc/nginx/conf.d/*
rm -rf /home/frappe
```

**On the App Server (f1):**
```bash
supervisorctl stop all 2>/dev/null
rm -rf /home/frappe
```

**In the Press UI / console — delete the doctype records themselves**, children first (nothing else references them), parents (Proxy Server) last:
```python
frappe.delete_doc("Server", "<f1-old-name>", force=True, ignore_permissions=True)
frappe.delete_doc("Database Server", "<m1-old-name>", force=True, ignore_permissions=True)
frappe.delete_doc("Proxy Server", "<n1-old-name>", force=True, ignore_permissions=True)
frappe.db.commit()
```

### 7.6 Recreating with correct short hostnames

Same forms as before, but with **`Hostname = n1` / `m1` / `f1`** (short label only — the `Domain` field still holds the full sites domain, and Press concatenates them). Result: clean names like `n1.presstest-sites.duckdns.org`.

Re-running **Setup Server** on each rebuilt server hit the *same* environment-level issues as the first pass (Sections 4.4–4.7) — expected, since those are fresh-install issues, not hostname-related. Each was fixed using the same procedures already documented above, this time in minutes rather than hours since the causes were already known.

---

## 8. Phase 6 — Post-Server-Setup Steps (Docker / Apps / Release Groups)

Once all three servers show `Active` with correct short hostnames, the official guide's remaining steps applied without modification:

1. On the App Server (f1) doc → SSH section → enable **"Use for Build"**.
2. **Press Settings → Docker tab:**
   - Clone Directory / Build Directory (create if missing, e.g. inside `frappe-bench`)
   - Build Server → `f1.<sites-domain>`
   - Docker Registry URL / Namespace / Username / Password from an **AWS ECR** registry + the `press-user` IAM access key/secret
3. Create an **App** (Frappe first, always), an **App Source** pointing at a git repo/branch, and approve the auto-created **App Release**.
4. Create a **Release Group** (e.g. "V-15"), assign the app server + build server, add the app + source, save, then **Actions → Create Deploy Candidate**.
5. Open the Deploy Candidate → **Deploy → Schedule Build and Deploy**.

### 8.1 `common_site_config.json` build-queue fix

If the Deploy Candidate Build gets stuck because `build` isn't a recognized queue type, add the following to `sites/common_site_config.json` on the `press` server:
```json
"workers": {
  "sync": { "timeout": 300 },
  "build": { "timeout": 2400 }
}
```
> **Watch your commas.** See [Section 9](#9-json-syntax-error-after-manual-config-edits) — a missing trailing comma here caused a much bigger outage later.

### 8.2 Docker socket permissions on the build server
```bash
ssh root@f1.<sites-domain>
chmod 666 /var/run/docker.sock
```

---

## 9. JSON Syntax Error After Manual Config Edits

**Symptom (days later, after stopping/starting the `press` EC2 instance):** The dashboard became completely inaccessible with:
```
redis.exceptions.ConnectionError: Error 111 connecting to 127.0.0.1:13311. Connection refused.
...
frappe.exceptions.SessionBootFailed
```
and `supervisorctl status` showed several processes stuck in `BACKOFF` / "Exited too quickly".

**Root cause — not the instance restart itself.** Investigating the error logs of the crash-looping processes revealed:
```
json.decoder.JSONDecodeError: Expecting ',' delimiter: line 18 column 2 (char 489)
```
in `sites/common_site_config.json`. The manual edit from [Section 8.1](#81-common_site_configjson-build-queue-fix) had been appended without a trailing comma after the preceding key:
```json
 "webserver_port": 8000
 "workers": {                 ← missing comma above broke the whole file
```
This had been silently broken since the edit — it only surfaced once every process was forced to **re-read the file from scratch** at supervisor startup (which happens on every instance boot). Redis itself started fine (it doesn't read this file); it was `bench`/frappe processes trying to load `bench_config` that failed, cascading into Redis-connection-refused errors because the worker/socketio processes that would normally hold those connections open never started.

**Fix:**
```bash
sed -i 's/"webserver_port": 8000$/"webserver_port": 8000,/' sites/common_site_config.json
python3 -c "import json; json.load(open('sites/common_site_config.json')); print('JSON OK')"
sudo supervisorctl restart all
```

**Lesson:** always validate JSON immediately after any manual edit to `common_site_config.json` — a syntax error here doesn't fail loudly until the next full process restart, which could be days later and look like an unrelated outage.

---

## 10. The Elastic IP Warning

None of the 4 EC2 instances in this setup had an **Elastic IP** allocated — they were using the default, ephemeral public IPs assigned by AWS. In this particular run the IP happened to survive a stop/start cycle, but **that is not guaranteed** — AWS may reassign a new public IP to an instance after it's stopped and restarted, unless an Elastic IP is attached.

If that happens, **everything breaks at once**: DuckDNS A-records point at the old IP, `~/.ssh/config` entries on the `press` server reference the old IP, and Press's server docs still have the old IP saved — none of it self-heals.

**Recommendation:** allocate and associate an Elastic IP to all 4 instances (`press`, `n1`, `m1`, `f1`) before doing any further stop/start cycles, especially if this is meant to run continuously rather than purely as a one-off test.

---

## 11. Summary — Full List of Dependency / Ansible / Playbook Customizations Made

| File / Location | Change | Why |
|---|---|---|
| `apps/press/press/pyproject.toml` | `"ansible==3.4.0"` → `"ansible>=9,<12"`; `"stripe~=2.56.0"` → `"stripe>=7,<8"` | Old pins used Python-2-era import machinery Python 3.12 removed; `bench install-app` reinstalls from this file every run, so fixes must live here, not just in the live venv |
| `env/lib/python3.12/site-packages/telegram/utils/request.py` (installed package, patched directly) | Wrapped both `urllib3.contrib.appengine` imports in `try/except ImportError`, plus null-guarded the two runtime usages (`appengine.AppEngineManager` type hint → `type(None)`, `appengine.is_appengine_sandbox()` → `appengine and appengine.is_appengine_sandbox()`) | `python-telegram-bot==13.15` needs old `urllib3` for this dead code path, but another Press dependency (`oci`) needs modern `urllib3` — no single pin satisfies both, so the unused path was neutralized instead |
| System Python env (`env/bin/pip`) — sqlparse | `pip install --force-reinstall "sqlparse~=0.5.4"` (matching `apps/frappe/pyproject.toml`'s own correct pin) | Frappe's query builder needs `MAX_GROUPING_TOKENS`, only present from sqlparse 0.5.4+; installed version had drifted below it during dependency churn |
| `/etc/supervisor/conf.d/frappe-bench.conf` (symlink) | `ln -sf ~/frappe-bench/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf` | `bench setup production` generates the supervisor config but doesn't link it into supervisor's active config directory automatically |
| `apps/press/press/runner.py` | Added `from ansible.plugins.loader import init_plugin_loader` + call `init_plugin_loader()` at module load | Ansible-core 2.18+ needs explicit collection-loader init when driven via raw Python API instead of the CLI |
| System Python env (`env/bin/pip`) — TLS libs | `pip install "cryptography~=50.0.0" "pyOpenSSL~=26.4.0" --break-system-packages` | `press`'s own `pyOpenSSL~=23.2.0` / `cryptography<46` pin was stale relative to the `frappe` version actually in use |
| `~/.ssh/config` (on `press` server) | Added a `Host <ip>` entry per server, in addition to the hostname entry | Press's `runner.py` connects by raw IP (`server.ip`), not hostname |
| Each server's `agent` venv (`/home/frappe/agent/env`) | `pip install "setuptools<81" --break-system-packages` | Newer `setuptools` dropped `pkg_resources`, which `agent`'s Jinja2 loader needs |
| Each server (systemd) | `ln -sf /lib/systemd/system/ssh.service /etc/systemd/system/sshd.service` | Playbooks reference `sshd`; Ubuntu's unit is named `ssh` |
| `apps/press/press/playbooks/roles/mariadb/tasks/main.yml` | Removed/bypassed the hardcoded Rackspace MariaDB 10.6 `apt_repository`; used Ubuntu Noble's native 10.11 packages instead; fixed `libmariadbclient18` → `libmariadb3` | MariaDB 10.6 has no Ubuntu 24.04 (Noble) build at all |
| n1 / m1 / f1 (manual, one-time) | Pre-created `/home/frappe/agent/nginx/nginx.conf` and `/home/frappe/agent/nginx.conf` (empty placeholders) and re-pointed the `/etc/nginx/nginx.conf` / `conf.d/agent.conf` symlinks before the first Setup Server attempt (or after a manual `/home/frappe` cleanup) | The `agent` Ansible role's symlink targets don't exist until that role runs, but the `nginx` role (which starts the service) runs *before* it in `proxy.yml` — a genuine ordering gap that's normally masked by the OS's default nginx config still being in place |
| `sites/common_site_config.json` (on `press`) | Added `"workers": {"sync": {...}, "build": {...}}` block | Required for the Deploy Candidate Build's `build` queue to be recognized |

---

## 12. If You're Doing This Yourself — Recommended Order

Knowing everything above in advance, here's the order we'd do it in next time:

1. Provision 4 EC2 instances (Ubuntu 24.04), **allocate Elastic IPs immediately**.
2. Set up DuckDNS records for all 4 subdomains + the wildcard.
3. Set up SSH: copy the `.pem` key to the `press` server, add **both** hostname-keyed and IP-keyed entries to `~/.ssh/config` from the start.
4. Set root SSH login + fix default user UID (1000→1001) on n1/m1/f1, as in the original guide.
5. **Before installing Frappe/Press:** double- and triple-check you are logged in as the dedicated `press` user (`whoami`, `pwd`), not `ubuntu` — this single mistake cost an entire wasted first attempt.
6. Install base OS packages per Section 2.3 (remembering `--break-system-packages` everywhere on 24.04).
7. `bench init` → `bench new-site` → `bench get-app press`, then **before** running `install-app press`, pre-apply the known-good dependency pins directly in `apps/press/press/pyproject.toml` (Section 2.4.5/2.4.6: `ansible>=9,<12`, `stripe>=7,<8`, and the `telegram/utils/request.py` patch) — this alone would have skipped roughly two-thirds of the install-time debugging.
8. Run `install-app press`; if `sqlparse` complains, force-reinstall to match `apps/frappe/pyproject.toml`'s own pin.
9. Complete production setup with `sudo env "PATH=$PATH" bench setup production press`, and manually verify/link `/etc/supervisor/conf.d/frappe-bench.conf` if `supervisorctl status` comes back empty.
10. **Before** touching any TLS/server setup: patch `runner.py` with `init_plugin_loader()`, and align `cryptography`/`pyOpenSSL` versions — this avoids two entire rounds of confusing Ansible failures later.
11. Get the wildcard cert manually via `certbot-dns-duckdns` (snap-based), and manually insert the `TLS Certificate` doc.
12. Patch the `mariadb` role (10.6→10.11 / `libmariadb3`) **before** first running Setup Server on the DB server.
13. Create each server doc with a **short hostname** (`n1`, `m1`, `f1`) from the very first attempt — don't use the full DuckDNS FQDN as the hostname field.
14. Run Setup Server on each. Expect (and quickly fix) the `pkg_resources`, `sshd` alias, and nginx-symlink issues once per server — they're fast to resolve once you know the cause.
15. Proceed with Docker/ECR registry, App/App Source/Release, and Release Group + Deploy Candidate exactly as the official guide describes.
16. Validate `common_site_config.json` with `python3 -c "import json; json.load(open(...))"` after **every** manual edit.
