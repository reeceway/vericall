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

## WebSocket Events

**Client → Server:**
- `call:initiate` - Initiate call
- `call:answer` - Answer call
- `call:end` - End call

**Server → Client:**
- `call:incoming` - Incoming call notification
- `call:answered` - Call was answered
- `call:ended` - Call was ended
