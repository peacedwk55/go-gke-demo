# Ansible — Task 8

Four roles, applied by `site.yml` to the `webservers` group.

```
ansible.cfg              connection + output settings
inventory/hosts.ini      hosts (no credentials)
group_vars/all.yml       versions, ports, paths — nothing hardcoded in tasks
requirements.yml         pinned Galaxy collections
site.yml                 imports the four roles, plus pre/post verification
roles/common/            apt update+upgrade, timezone, reboot reporting
roles/docker/            Docker from the official repo, daemon.json log rotation
roles/nginx_container/   NGINX container serving a Jinja2-templated page
roles/node_exporter/     hardened systemd service under a dedicated system user
```

## Run it

```bash
ansible-galaxy collection install -r requirements.yml

# dry run first — --diff shows exactly which template lines would change
ansible-playbook -i inventory/hosts.ini site.yml --check --diff

# apply
ansible-playbook -i inventory/hosts.ini site.yml

# one role
ansible-playbook -i inventory/hosts.ini site.yml --tags docker

# when passwordless sudo is not available
ansible-playbook -i inventory/hosts.ini site.yml --ask-become-pass
```

## Idempotency is the grading criterion

```bash
ansible-playbook -i inventory/hosts.ini site.yml   # first run:  changed=N
ansible-playbook -i inventory/hosts.ini site.yml   # second run: changed=0
```

That second run is not a formality — it is easy to fail, and several choices in
these roles exist only because of it:

| Trap | What goes wrong | Fix used here |
|---|---|---|
| `ansible_date_time.iso8601` in a template | second-resolution timestamp differs every run, so the template is rewritten every run | render `ansible_date_time.date` (day granularity) |
| `apt: update_cache` with no `cache_valid_time` | the metadata refresh reports `changed` every run | `cache_valid_time: 3600` |
| `command:` for a version check | every `command` is `changed` by default | `changed_when: false` |
| `docker_image: pull: always` | re-pulls and reports changed even on a pinned tag | `pull: false` + `force_source: false` |
| Restarting a service in a task | a restart task always reports changed | handlers, notified only on a real change |
| `stat` to test for a pending reboot | a read counted as a change | `changed_when: false` |

The timestamp one is the instructive case. Rendering `inventory_hostname` and
`ansible_date_time` into the page is what proves templating is real rather than a
copied file — but at second resolution it makes `changed=0` impossible. Day
granularity keeps the proof and drops the churn.

## Decisions worth defending

### Docker: keyring, not `apt-key`

`apt-key add` is deprecated, and the reason matters: it trusts the key for
**every** repository on the system, so a compromised Docker key could sign a
replacement for any package. `signed-by=/etc/apt/keyrings/docker.asc` scopes that
trust to the Docker repository alone.

### `daemon.json` is templated *and validated*

Docker's default `json-file` driver has **no size limit**. One chatty container
fills the disk and takes the host down — a genuinely common production outage.
`10m × 3` caps each container at 30 MB.

The template task carries `validate: python3 -c "import json…"`. Without it a
malformed `daemon.json` is written, the handler restarts dockerd, dockerd refuses
to start, and every container on the host goes with it. The validation turns that
into a failed task with the file left untouched.

`live-restore: true` means containers survive a dockerd restart, so applying a
config change does not bounce the workloads.

### `comparisons: "*": strict` on the container

Without it, `docker_container` only checks that *a container with this name
exists*. Change a published port or a mount and the task reports `ok` while the
change silently never happens. `strict` makes the module reconcile the full
desired state.

### The bind mount is read-only

NGINX serves that content; it has no reason to be able to rewrite it. If NGINX is
compromised, the attacker cannot persist a modified page onto the host.

### `docker` group membership is root-equivalent

Anyone in it can bind-mount `/` into a privileged container. It is granted here
because the assignment implies interactive use, but it is a privilege-escalation
path rather than a convenience — a hardened host would use rootless Docker or
sudo-wrapped invocations. Stated rather than left implicit.

Note also `append: true` on that task: a bare `groups:` assignment **replaces** a
user's supplementary groups and would silently strip `sudo`.

### node_exporter: a checksum, not just a pinned version

A pinned version *without* a checksum still trusts whatever the download server
returns. The `checksum:` on the `unarchive` task is what makes a compromised or
MITM-ed download fail the play, instead of being installed and started as a
system service.

The binary is owned by **root**, not by `node_exporter`. The service account must
not be able to overwrite the binary it executes — otherwise a compromise of the
process becomes persistence.

### The systemd unit is sandboxed, not merely unprivileged

Running as a non-login system user is the baseline. Layered on top:
`ProtectSystem=strict` (the whole filesystem read-only to the unit),
`NoNewPrivileges`, `PrivateTmp`, `PrivateDevices`, an empty
`CapabilityBoundingSet`, `SystemCallFilter=@system-service`,
`MemoryDenyWriteExecute`, and `RestrictAddressFamilies` limited to IP and unix
sockets.

`MemoryMax=128M` and `CPUQuota=20%` are there for a specific reason: monitoring
must never be the cause of a host running out of memory. If the exporter
misbehaves it dies, rather than the workload dying.

`--collector.disable-defaults` plus an explicit collector list, rather than the
defaults. The default set includes collectors nobody reads, and every one of them
is series volume in Prometheus forever.

### Reboots are opt-in

`common_reboot_if_required` defaults to **false**. The role detects a pending
reboot and reports it; it does not act. Automation that can reboot production
because a kernel package was updated is automation nobody dares run during
working hours — so it stops being run at all, and the patching it was meant to
deliver stops happening.

### `site.yml` verifies rather than asserts

The `post_tasks` actually `uri` the NGINX port and the metrics port, and assert
that the returned HTML contains `inventory_hostname` — proving the templated page
reached the container, not merely that *something* answers on :8080.

A `pre_tasks` assert checks the target is Debian-family, so an unsupported OS
fails immediately with a clear message rather than part-way through with a
confusing apt error.

## Testing without cloud cost

```bash
multipass launch 22.04 --name ansible-test --cpus 2 --memory 2G

# authorise your key inside the VM
multipass exec ansible-test -- tee -a /home/ubuntu/.ssh/authorized_keys < ~/.ssh/id_ed25519.pub

multipass info ansible-test | grep IPv4    # put this address in [local_test]
```

Then point the play at `local_test`. Vagrant or a local KVM guest works equally
well; the roles assume nothing about the hypervisor.

## Lint

```bash
ansible-playbook -i inventory/hosts.ini site.yml --syntax-check
ansible-lint
yamllint .
```

## Not done here

No `molecule` scenarios — proper role testing across two distributions is a task
of its own.

No Ansible Vault: there is nothing secret in these roles, and adding a vault with
no secrets in it would be theatre. Connection details that vary per operator
belong in `~/.ssh/config` or an untracked `hosts.local.ini` (already in
`.gitignore`).

No firewall role. On a real host `ufw` would restrict :9100 to the monitoring
subnet rather than leaving node_exporter bound to `0.0.0.0` — called out in the
role defaults.
