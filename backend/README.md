# VeriCall Backend

Secure caller verification and WebRTC signaling API.

## Quick Start

### Local Development

1. Install dependencies:
```bash
pip install -r requirements.txt
```

2. Set up PostgreSQL (or use Docker):
```bash
docker run -d --name vericall-db \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=vericall \
  -p 5432:5432 \
  postgres:15
```

3. Run the server:
```bash
uvicorn app.main:app --reload
```

4. API docs available at: http://localhost:8000/docs

### Deployment

#### Fly.io
```bash
fly deploy
```

## API Endpoints

### Authentication
- `POST /auth/request-otp` - Request OTP
- `POST /auth/verify-otp` - Verify OTP and get tokens
- `POST /auth/refresh` - Refresh access token

### Contacts
- `POST /contacts/sync` - Sync contacts

### Calls
- `POST /calls/initiate` - Initiate verified call
- `POST /calls/{id}/answer` - Answer call
- `POST /calls/{id}/end` - End call

### WebSocket
- `WS /ws?token=<jwt>` - Real-time signaling
- `GET /health` - Includes current websocket connection stats

## WebSocket Events

**Client → Server:**
- `call:initiate` - Initiate call
- `call:answer` - Answer call
- `call:end` - End call

**Server → Client:**
- `call:incoming` - Incoming call notification
- `call:answered` - Call was answered
- `call:ended` - Call was ended

## Voiceprint Signaling Notes

- `voip:initiate` and `voip:answer` can include `voiceThumbprint`.
- Backend sanitizes `voiceThumbprint` and only relays valid 192-dim float vectors.
- VoIP relay now forwards an allowlist of fields only (`callId`, ports, device info, `voiceThumbprint`, etc.).

## 500-User Scale Validation

### Capacity assumptions

- Target: 500 concurrent websocket users (roughly 250 simultaneous calls).
- Signaling now supports multi-machine routing when `REDIS_URL` is configured.
- If only Upstash REST-style secrets are present (`UPSTASH_REDIS_URL` + `UPSTASH_REDIS_TOKEN`), backend now auto-converts them to a TLS Redis URL.
- Without Redis, signaling is single-instance only.

### Production prerequisites

1. Configure Redis for cross-instance signaling:
```bash
fly secrets set REDIS_URL=redis://<user>:<pass>@<host>:<port>/0
```
If `UPSTASH_REDIS_URL` + `UPSTASH_REDIS_TOKEN` are already set in Fly secrets, no additional secret is required.

2. Deploy:
```bash
fly deploy
```

3. Verify health reports Redis enabled:
```bash
curl -s https://vericall-api.fly.dev/health | jq .websocket
```

Expected:
- `redis_enabled: true`
- `instance_id` present
- relay counters (`relay_messages_published`, `relay_messages_received`, `relay_errors`)

### Run websocket load test

1. Prepare a token file:
```bash
# one JWT per line
cat tokens.txt
```

2. Run Python version:
```bash
python scripts/ws_load_test.py \
  --url wss://vericall-api.fly.dev/ws \
  --token-file ./tokens.txt \
  --connections 500 \
  --duration 60 \
  --ramp-seconds 20
```

3. Or run Node version (no external packages needed on Node 20+):
```bash
node scripts/ws_load_test_node.mjs \
  --url wss://vericall-api.fly.dev/ws \
  --token-file ./tokens.txt \
  --connections 500 \
  --duration 60 \
  --ramp-seconds 20 \
  --auth-mode query
```

If your deployed backend expects an explicit auth payload after socket open, use:
```bash
--auth-mode message
```

4. Success criteria (recommended):
- connection success rate >= 99%
- stable p95 connect latency under your target
- no sustained websocket error spikes in logs

5. During test, monitor backend in parallel:
```bash
fly logs -a vericall-api
curl -s https://vericall-api.fly.dev/health | jq .websocket
```
