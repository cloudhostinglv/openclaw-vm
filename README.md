# OpenClaw — per-client single-tenant VM

A turnkey **personal AI agent in the client's messaging apps** that can run
tools/commands, backed by **avots.ai** as the LLM gateway. One VM = one client.
The VM itself is the isolation boundary.

- Upstream: <https://github.com/openclaw/openclaw> · Docs: <https://docs.openclaw.ai>
- License: **MIT** (OpenClaw Foundation)
- Backend: avots.ai, OpenAI-compatible. Each client uses **their own avots key**.

> [!CAUTION]
> **OpenClaw is remote-code-execution by design.** The agent runs shell commands and
> code on this VM. It also has a serious CVE history (**CVE-2026-25253**, a 1-click RCE
> via auth-token theft, plus the "Claw-Chain" origin-validation flaws). Treat every VM
> as fully compromisable by its agent and by anyone who can talk to it. The hardening
> below is **not optional**.

---

## What the client gets

- A bot in one messaging app (Telegram by default; any OpenClaw outbound channel works).
- The agent answers **only the owner** (`allowFrom` / `toolsBySender` lock), runs in a
  **tool sandbox**, and uses avots `anthropic/claude-opus-4.8` for reasoning + tool use.
- No web UI is exposed. The gateway API is **loopback-only**; reach it via SSH tunnel.

## Files in this dir

| File | Purpose |
|---|---|
| `docker-compose.yml` | Pinned image (by digest), loopback-only publish, hardening. Two services: `openclaw-gateway` (long-running) and `openclaw` (CLI sidecar, on-demand). |
| `openclaw.json` | Templated gateway config: avots provider + allowlist + **sandbox** + tool policy + channel. Strict JSON. |
| `.env.example` | Secret template (`AVOTS_API_KEY`, gateway token, messaging tokens). Copy to `~/.openclaw/.env`. |
| `autoinstall-snippet.yaml` | cloud-init `write_files` + `runcmd` for first-boot provisioning. |

---

## Run steps (manual, mirrors what cloud-init does)

```bash
# 0) Host config dir that gets bind-mounted as ~/.openclaw inside the container.
#    Owned by uid/gid 1000 (the in-image 'node' user).
sudo mkdir -p /srv/avots-vm/openclaw/state/workspace
sudo cp openclaw.json /srv/avots-vm/openclaw/state/openclaw.json
sudo cp .env.example   /srv/avots-vm/openclaw/state/.env   # then edit real values
sudo chown -R 1000:1000 /srv/avots-vm/openclaw/state
sudo chmod 600 /srv/avots-vm/openclaw/state/.env

# 1) Point compose at that host dir and bring up the loopback-only gateway.
cat > .compose.env <<'EOF'
OPENCLAW_CONFIG_DIR=/srv/avots-vm/openclaw/state
OPENCLAW_WORKSPACE_DIR=/srv/avots-vm/openclaw/state/workspace
OPENCLAW_AUTH_PROFILE_SECRET_DIR=/srv/avots-vm/openclaw/state/auth-profile-secrets
EOF
docker compose --env-file .compose.env up -d openclaw-gateway

# 2) Finalize local mode + token (ref mode) and check health.
docker compose --env-file .compose.env run --rm --no-deps --entrypoint node openclaw \
  dist/index.js onboard --non-interactive --mode local --auth-choice skip \
  --secret-input-mode ref --gateway-auth token \
  --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN --skip-bootstrap --accept-risk

# 3) Verify config resolves (provider, allowlist, sandbox).
docker compose --env-file .compose.env run --rm --no-deps --entrypoint node openclaw \
  dist/index.js doctor
docker compose --env-file .compose.env run --rm --no-deps --entrypoint node openclaw \
  dist/index.js models list   # expect: avots/anthropic/claude-opus-4.8 present + default
```

Then DM the bot from the owner account and confirm it replies **and that it actually
invokes a tool** (see "Tool-calling — live test" below).

---

## avots wiring — EXACT

avots is added as a **custom `openai-completions` provider**. This is a deliberate
**two-step** registration; doing only one half silently fails.

### Step 1 — register the provider + model (`models.providers.avots`)

```json
"models": {
  "mode": "merge",
  "providers": {
    "avots": {
      "baseUrl": "https://api.avots.ai/openai/v1",
      "apiKey": "${AVOTS_API_KEY}",
      "api": "openai-completions",
      "models": [
        {
          "id": "anthropic/claude-opus-4.8",
          "name": "avots Claude Opus 4.8",
          "input": ["text", "image"],
          "contextWindow": 200000,
          "maxTokens": 32000,
          "reasoning": true,
          "compat": { "supportsTools": true, "supportsDeveloperRole": false }
        }
      ]
    }
  }
}
```

- `mode: "merge"` keeps OpenClaw's bundled catalogs and *adds* avots.
- `apiKey: "${AVOTS_API_KEY}"` is an **env secret ref**, resolved from `~/.openclaw/.env`.
  The key never sits in the JSON in plaintext.
- `api: "openai-completions"` is correct for avots `/v1/chat/completions` (verified
  tool-calling, stream + non-stream).

### Step 2 — allowlist the model in `agents.defaults` (REQUIRED)

`models.providers.*` registers the runtime model but does **not** make agents use it.
You must also add the **fully-qualified `<provider-id>/<model-id>`** key to the agent
allowlist and set it primary:

```json
"agents": {
  "defaults": {
    "model": { "primary": "avots/anthropic/claude-opus-4.8" },
    "models": { "avots/anthropic/claude-opus-4.8": { "alias": "Claude Opus 4.8 (avots)" } }
  }
}
```

Note the **doubled slash**: provider id is `avots`, the model id is literally
`anthropic/claude-opus-4.8`, so the fully-qualified ref is
`avots/anthropic/claude-opus-4.8`. (avots' lazy alias `claude` also works upstream, but
we pin the explicit id for reproducibility.)

### Tool-calling — what's actually true, and the live test

> [!IMPORTANT]
> The historical bug where OpenClaw withheld the `tools` parameter from custom
> `openai-completions` providers (GitHub issue #8923) is **resolved** in current
> OpenClaw. Verified against source (`src/agents/model-tool-support.ts`): capability is
> now **opt-out** — OpenClaw sends `tools` for any catalog model **unless**
> `compat.supportsTools === false`. `src/llm/providers/openai-completions.ts` sets
> `params.tools = convertTools(...)` whenever `context.tools` is non-empty.
>
> We still set **`compat.supportsTools: true` explicitly** so the intent is recorded and
> nobody disables it by accident. **Do not** set it to `false` for the avots model.
>
> avots itself passes `tools` fine; the only gap was ever OpenClaw-side metadata. Because
> the exact behavior is version-sensitive and your pinned image matters, **you must
> live-test an actual tool invocation before baking the golden image** — do not trust the
> config alone:

```bash
# Host-level smoke test of avots first (run from the repo root, one dir up):
AVOTS_API_KEY=av_mcp_... bash ../00-avots-smoke.sh   # expects tool_calls PASS

# Then test OpenClaw end-to-end: DM the bot something that REQUIRES a tool,
# e.g. "run `uname -a` and tell me the kernel". Confirm in the gateway logs that a
# tool call fired (exec) and the result came back — not just a chatty text reply.
docker compose --env-file .compose.env logs -f openclaw-gateway
```

If OpenClaw answers as text without calling the tool, recheck: model present in
`models list`, model allowlisted, `compat.supportsTools` not false, and the pinned
image version.

`compat.supportsDeveloperRole: false` is also set — OpenClaw **forces** this to false at
runtime for non-native `openai-completions` base URLs anyway (avoids provider 400s); we
match it explicitly. `input: ["text","image"]` marks the model vision-capable so image
attachments are passed natively.

---

## Network — outbound-only

- Messaging is **long-polling / outbound**. No inbound webhook, **no TLS, no reverse
  proxy** needed or wanted.
- The gateway HTTP API binds **loopback** (`--bind loopback`) and is published only on
  `127.0.0.1:18789`. The bridge (18790) and MS Teams (3978) ports from upstream compose
  are **not published**.
- To reach the gateway/admin from your laptop: `ssh -L 18789:localhost:18789 <vm>`.
- Restrict the VM's **egress** where practical (allow only avots.ai + the messaging
  platform). The agent can run arbitrary commands; outbound is its exfiltration path.

---

## 🔒 Security hardening checklist (do all of these)

- [ ] **Pin a patched version.** Image pinned by digest to `2026.6.1`
      (`sha256:b12f76a7947e4cdd328bf3ea1045d41a5494b33852c911e9bc4fdd03dde469d5`).
      CVE-2026-25253 was fixed in `2026.1.29`; never run below that. **Never use
      `:latest` or `:main`.**
- [ ] **Sandbox ON.** `agents.defaults.sandbox.mode: "all"` (every session sandboxed) +
      `workspaceAccess: "none"`. Default (in-gateway) backend — **no docker.sock**.
- [ ] **Gateway loopback-only.** `--bind loopback`, published on `127.0.0.1` only.
- [ ] **Gateway token set.** `gateway.auth.mode: "token"` with a unique
      `OPENCLAW_GATEWAY_TOKEN` (defense-in-depth even on loopback).
- [ ] **Answer only the owner.** Set the channel's `allowFrom` to the owner's id, AND
      keep `tools.toolsBySender["*"]` denying `exec/process/code_execution/write/edit/
      apply_patch` so any non-owner / untrusted sender is read-only.
- [ ] **High-risk tools denied for untrusted input.** `browser`/`canvas` denied globally;
      `tools.elevated.enabled: false` (elevated exec BYPASSES the sandbox — keep off).
- [ ] **No docker.sock, never privileged.** Compose mounts no socket, drops ALL caps,
      `no-new-privileges`, pids + memory + cpu limits.
- [ ] **Egress restricted** to avots.ai + the messaging platform where the host allows.
- [ ] **Secrets only in `~/.openclaw/.env`** (`0600`), referenced as `${VAR}` in config;
      never commit a real `.env`.
- [ ] **Patch SLA / re-bake pipeline.** OpenClaw ships CVEs/fixes frequently. Subscribe to
      releases, and re-bake the golden image on every security patch — target **same-day
      for RCE/critical**, weekly for the rest. Re-verify the digest comment in
      `docker-compose.yml` before each bake.

### Sandbox backend note (read before changing it)

The shipped config uses the **default sandbox backend** (isolation inside the gateway),
which needs nothing extra. OpenClaw also supports a **Docker backend** for stronger
isolation — but that requires the Docker CLI in the image *and* a reachable Docker
daemon. **Do not** satisfy that by mounting the host `/var/run/docker.sock`: that hands
the agent host-root-equivalent and defeats the whole point. If you want the docker
backend, give the gateway a **dedicated, throwaway Docker context** (rootless or a nested
daemon), never the host socket. The relevant compose lines are left **commented** on
purpose.

---

## Version-pin / re-verify before baking

- `docker-compose.yml` pins `ghcr.io/openclaw/openclaw:2026.6.1@sha256:b12f…469d5`
  (latest **stable** as of 2026-06-05; newer tags were alpha/beta). The pin comment marks
  it to re-verify.
- Before each bake: confirm the latest **patched stable** on
  <https://github.com/openclaw/openclaw/releases>, re-resolve the digest
  (`docker buildx imagetools inspect ghcr.io/openclaw/openclaw:<tag>`), update the tag +
  digest in both services, and re-run the doctor + live tool test.

## Caveats / verify on a live VM

- **Channel block is a template.** The `channels.telegram` block in `openclaw.json` is an
  example. Confirm the exact key names for the client's chosen channel against
  <https://docs.openclaw.ai> (channel config keys vary per platform) and set `allowFrom`.
- **`openclaw.json` is strict JSON here.** Upstream docs show JSON5/JSONC (comments,
  trailing commas). We ship strict JSON with `$comment` string keys so it parses
  everywhere; if you prefer authored JSON5, OpenClaw accepts it too — just keep the keys.
- **Onboard flags.** The non-interactive `onboard` flags (`--auth-choice skip`,
  `--secret-input-mode ref`, `--gateway-token-ref-env`, `--skip-bootstrap`,
  `--accept-risk`) are from the current `openclaw onboard` CLI reference. Run once on a
  scratch VM and read `openclaw onboard --help` for your pinned version to confirm none
  were renamed before baking.
- **uid/gid 1000.** The image's `node` user is assumed to be uid/gid 1000 for the
  bind-mount ownership. Verify with `docker run --rm <image> id` and adjust the
  `chown 1000:1000` if it differs.
- **Tool-calling is version-sensitive.** As above, always run the live tool-invocation
  test against the exact pinned image before baking.
