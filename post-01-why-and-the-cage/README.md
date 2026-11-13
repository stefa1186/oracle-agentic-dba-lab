# Post 01 – Why, and the cage

Builds and destroys the isolated lab on a Linux server (tested on CentOS 10;
other distributions need small changes, starting with the package manager).
The server doesn't have to be dedicated, but nothing else of value should run on it:

- a dedicated Linux user, **`oralab`**, with no password, owning everything in the lab
- an outbound network policy for that user: loopback, DNS and HTTPS to the
  internet only; nothing on the local network. HTTPS is open to any host, on
  purpose: later posts download from many sites, and an allow list of HTTPS
  addresses would grow with every post
- Oracle AI Database 26ai Free in a rootless Podman container, with its
  listener on `127.0.0.1` only and the password passed as a Podman secret

**Only one step runs as root** (`00_root_setup.sh`). Everything else, in this
folder and in the rest of the repository, runs as `oralab`.
Oracle analogy: `root.sh` after an installation. A short, fixed list of root
actions, then everything is done as the software owner.

## Scripts

| Script | Runs as | Purpose |
|---|---|---|
| `00_root_setup.sh` | **root** | Packages, the `oralab` user, linger, outbound policy, sudoers entry, and a read-only copy of this repository for `oralab`. `--remove` undoes all of it. |
| `env.example` | — | Settings with defaults. To change one, copy to `.env` and edit (`.env` is never committed). |
| `lib.sh` | — | Helpers shared by the scripts (not run directly) |
| `01_prereqs.sh` | oralab | Checks the root setup, the tools and the resources. Changes nothing. |
| `02_build.sh` | oralab | Password, network, datafile volume and database; waits until FREEPDB1 is open |
| `03_verify.sh` | oralab | PASS/FAIL checks: database up, unreachable from outside, outbound limited |
| `04_test_policy.sh [setup script]` | oralab | The outbound policy's rules, tested in a throwaway network namespace (no root, nothing on the host changes): online and offline, for the lab user and for another user |
| `99_destroy.sh --db-only` | oralab | Deletes the database and its datafiles; keeps everything else |
| `99_destroy.sh --all` | oralab | Deletes everything `02_build.sh` created |

## Step by step

**1. Root setup** (as root, once). The repository is public, so root clones
it without credentials:

```bash
dnf install -y git
git clone https://github.com/stefa1186/oracle-agentic-dba-lab.git /root/oracle-agentic-dba-lab
/root/oracle-agentic-dba-lab/post-01-why-and-the-cage/00_root_setup.sh
```

The last step of the script gives `oralab` its own clone of the repository,
in `/home/oralab/oracle-agentic-dba-lab`. `oralab` never needs the network
or GitHub credentials to update it (see "The repository copy" below).

**2. Everything else, as `oralab`:**

```bash
machinectl shell oralab@               # log in as the lab user
cd ~/oracle-agentic-dba-lab/post-01-why-and-the-cage
./01_prereqs.sh
./02_build.sh                           # first run: image download + database creation, about 5 min on the lab server
./03_verify.sh
```

Any way of becoming `oralab` works (`machinectl shell oralab@`, `su - oralab`,
...): the scripts set the runtime directory rootless Podman needs
(`/run/user/<uid>`, kept in place by linger) themselves. For interactive
`podman` commands outside the scripts, `machinectl shell oralab@` sets it
for you; after `su - oralab`, run `export XDG_RUNTIME_DIR=/run/user/$(id -u)`.

## The repository copy

`oralab` must never hold GitHub credentials: later in the series an AI agent
runs as `oralab` and could read them. And it must be able to update its
scripts without the network: in offline mode (post 12) it has none. So `00_root_setup.sh` publishes root's clone as a **read-only mirror**
in `/srv/oralab/repo.git`, and `oralab` clones and pulls from that mirror:
no network, no secrets. `oralab` can read the mirror but cannot change it.
Oracle analogy: a read-only copy of a schema instead of the production password.

**Updating to the latest scripts:**

```bash
# as root: fetch from GitHub, then republish the mirror (the rerun is safe)
git -C /root/oracle-agentic-dba-lab pull
/root/oracle-agentic-dba-lab/post-01-why-and-the-cage/00_root_setup.sh

# as oralab: pull from the mirror
git -C ~/oracle-agentic-dba-lab pull
```

## The lab user: what the root setup does

`00_root_setup.sh` does exactly this. The manual equivalent, if you prefer to
type it yourself (as root):

```bash
# 1. Create the user. No password is set, so password logins are impossible;
#    the comment marks it as the lab user (the removal step checks it).
useradd --create-home --shell /bin/bash --comment "oracle-agentic-dba-lab lab user" oralab

# 2. Check it got subordinate ID ranges (needed by rootless containers).
grep '^oralab:' /etc/subuid /etc/subgid

# 3. Keep its containers running without an open login session.
loginctl enable-linger oralab

# 4. Allow two read-only commands used by 03_verify.sh. Always via visudo,
#    which validates the syntax before saving.
visudo -f /etc/sudoers.d/oralab
#    with this single line:
#    oralab ALL=(root) NOPASSWD: /usr/sbin/nft list table inet oralab_egress, /usr/bin/firewall-cmd --list-all-zones
```

The script additionally installs the packages and the outbound policy
(`/etc/oralab/egress.nft`, loaded at boot by `oralab-egress.service`).

**Why the sudoers entry is so small.** The lab user must not be able to
loosen its own cage, so the policy is written and loaded by root only. The
two allowed commands only *read* the firewall; each one runs with exactly
these arguments and nothing else. Oracle analogy: a GRANT of SELECT on two
dictionary views, not the DBA role.

`03_verify.sh` checks that these two commands are **all** the lab user can
run with sudo. Any wider grant (`dnf`, `systemctl`, `install`, ...) is root
in disguise, so the check fails and lists the extra rights. Oracle analogy:
GRANT ANY PRIVILEGE, the one grant that contains all the others.

## How it behaves

- **Deterministic.** Every run of `02_build.sh` produces the same database
  from the same settings: the container is recreated, and only the datafiles
  and the password are kept. Oracle analogy: the instance is recreated from a
  fixed spfile every time; the datafiles persist.
- **Safe to rerun.** Every script can run any number of times.
- **After a reboot** the outbound policy comes back automatically; start the
  database again with `./02_build.sh`.
- **Fresh database in minutes:** `./99_destroy.sh --db-only` then
  `./02_build.sh`. Use this after experiments that damage the database.
- **The image is pinned by digest** in `env.example`, so every clone and
  every rebuild uses exactly the same image. Upgrading is a deliberate step:
  pull the new `latest`, read its digest, update `DB_IMAGE` in
  `env.example`, commit, rerun `./02_build.sh`.
- **Changing the outbound ports** is a root action: edit
  `EGRESS_ALLOWED_TCP_PORTS` and rerun `sudo ./00_root_setup.sh`.
- **Offline mode (post 12):** `sudo ./00_root_setup.sh --offline` cuts the lab
  user to loopback only: no DNS, no internet, no LAN. The database and local
  models keep working. Rerun without `--offline` to go back online. The mode
  is whatever the last run wrote, and it survives a reboot.

## Working in the lab

```bash
podman exec -it oralab-db sqlplus / as sysdba      # SQL*Plus inside the container
cat ~/.config/oralab/oracle_pwd                    # SYS / SYSTEM / PDBADMIN password
```

Connect string from the server: `127.0.0.1:1521/FREEPDB1`.

## Removing everything

```bash
./99_destroy.sh --all                  # as oralab: database, image, password
sudo ./00_root_setup.sh --remove       # as administrator: user, sudoers, policy
```

## Why the isolation works

Rootless containers have no network of their own on the host: everything
they send leaves through a user-space process running as `oralab`. So one
nftables rule set on "traffic created by `oralab`" covers the lab user's
shell, the agent harness and every container. `03_verify.sh` proves it, from
inside the database container too.

Only `oralab`'s packets are checked: the rule set sends them to a chain of
their own (`meta skuid <uid> jump lab_user`) and lets everything else pass.
The first version started with "accept every other user" instead
(`meta skuid != <uid> accept`). It looks the same, but it isn't: the
kernel's own packets (IPv6 neighbour discovery, TCP resets, ICMP errors)
belong to no user, so that rule didn't match them and the final drop took
them. On this dual-stack server, IPv6 stopped working for the whole host,
root included. Post 12 found it (its model downloads went over IPv6);
`03_verify.sh` now tests HTTPS over IPv6 too, when the host has IPv6, and
`04_test_policy.sh` tests the rules themselves, in a throwaway network: the
current rules pass. The first version failed it; it is no longer in the
repository history.
