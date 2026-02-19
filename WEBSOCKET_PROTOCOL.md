# VeriCall WebSocket Protocol

The WebSocket endpoint handles all real-time call signaling. Audio is transported directly peer-to-peer (QUIC/MoQ) and never passes through the WebSocket server.

---

## Connection

```
WS /ws?token=<jwt-access-token>
```

The JWT access token is passed as a query parameter. The connection is rejected with close code `4001` if the token is missing or invalid.

On successful connection the server immediately sends:

```json
{
  "type": "connected",
  "user_id": "uuid",
  "device_id": "uuid"
}
```

All subsequent messages are JSON objects with a `"type"` field.

---

## Event Namespaces

| Prefix | Purpose |
|--------|---------|
| _(none)_ | Utility (ping/pong, errors) |
| `call:` | Standard VoIP call signaling |
| `voip:` | P2P QUIC call signaling (preferred) |
| `native_call:` | Native carrier call verification and matching |

---

## Utility

### Ping / Pong

Keep the connection alive.

**Client → Server**
```json
{ "type": "ping" }
```

**Server → Client**
```json
{ "type": "pong" }
```

### Error

Sent by the server when a message cannot be processed.

```json
{
  "type": "error",
  "message": "Human-readable error description"
}
```

---

## `call:` — Standard Call Signaling

Used for WebRTC offer/answer exchange. Both peers must be online (connected to WebSocket).

### `call:initiate` — Caller starts a call

**Client → Server**
```json
{
  "type": "call:initiate",
  "recipient_id": "uuid",
  "call_id": "uuid",
  "offer": { /* WebRTC SDP offer */ }
}
```

**Server → Recipient** (if online)
```json
{
  "type": "call:incoming",
  "call_id": "uuid",
  "caller_id": "uuid",
  "offer": { /* WebRTC SDP offer */ }
}
```

**Server → Caller** (if recipient offline)
```json
{
  "type": "call:unavailable",
  "recipient_id": "uuid",
  "message": "Recipient is offline"
}
```

---

### `call:answer` — Recipient answers

**Client → Server**
```json
{
  "type": "call:answer",
  "call_id": "uuid",
  "caller_id": "uuid",
  "answer": { /* WebRTC SDP answer */ }
}
```

**Server → Caller**
```json
{
  "type": "call:answered",
  "call_id": "uuid",
  "answer": { /* WebRTC SDP answer */ }
}
```

---

### `call:end` — Either party ends the call

**Client → Server**
```json
{
  "type": "call:end",
  "call_id": "uuid",
  "other_party_id": "uuid",
  "reason": "ended"
}
```

**Server → Other party**
```json
{
  "type": "call:ended",
  "call_id": "uuid",
  "reason": "ended"
}
```

---

## `voip:` — P2P QUIC Call Signaling

Used for the preferred QUIC/MoQ transport path. The server forwards these messages to the recipient and injects the caller's public IP so the recipient can attempt a direct connection.

### `voip:initiate` — Caller opens a VoIP call

**Client → Server**
```json
{
  "type": "voip:initiate",
  "toUserId": "uuid-or-omit",
  "toPhone": "+15550001234",
  "callId": "uuid",
  "port": 12345,
  "device": "Alice's iPhone"
}
```

`toUserId` and `toPhone` are both optional but at least one is required. The server tries `toUserId` first (verifying the user is currently online), then falls back to phone number lookup.

**Server → Recipient** (forwarded, fields injected/removed)
```json
{
  "type": "voip:initiate",
  "callId": "uuid",
  "port": 12345,
  "device": "Alice's iPhone",
  "fromUserId": "uuid",
  "callerName": "Alice",
  "senderIp": "203.0.113.42"
}
```

The server injects `fromUserId`, `callerName`, and `senderIp` (the caller's public IP as seen by the server). `toUserId` and `toPhone` are removed.

**Server → Caller** (delivery confirmation)
```json
{
  "type": "voip:delivered",
  "callId": "uuid",
  "toUserId": "uuid"
}
```

**Server → Caller** (recipient offline)
```json
{
  "type": "voip:offline",
  "message": "Recipient is offline"
}
```

**Server → Caller** (delivery failure)
```json
{
  "type": "voip:error",
  "message": "Could not find recipient user"
}
```

---

### `voip:answer` — Recipient answers

Same forwarding behaviour as `voip:initiate`. The server injects the recipient's public IP so the caller can attempt a direct connection back.

**Client → Server**
```json
{
  "type": "voip:answer",
  "toUserId": "uuid",
  "callId": "uuid",
  "port": 54321,
  "device": "Bob's iPhone"
}
```

**Server → Caller** (forwarded)
```json
{
  "type": "voip:answer",
  "callId": "uuid",
  "port": 54321,
  "device": "Bob's iPhone",
  "fromUserId": "uuid",
  "callerName": "Bob",
  "senderIp": "203.0.113.99"
}
```

---

### `voip:reject` — Recipient declines

**Client → Server**
```json
{
  "type": "voip:reject",
  "toUserId": "uuid",
  "callId": "uuid"
}
```

**Server → Caller** (forwarded)
```json
{
  "type": "voip:reject",
  "callId": "uuid",
  "fromUserId": "uuid",
  "callerName": "Bob",
  "senderIp": "203.0.113.99"
}
```

---

### `voip:end` — Either party ends the call

**Client → Server**
```json
{
  "type": "voip:end",
  "toUserId": "uuid",
  "callId": "uuid"
}
```

**Server → Other party** (forwarded)
```json
{
  "type": "voip:end",
  "callId": "uuid",
  "fromUserId": "uuid",
  "callerName": "Alice",
  "senderIp": "203.0.113.42"
}
```

---

## `native_call:` — Native Carrier Call Verification

These events support VeriCall operating alongside the device's native phone app: when a user answers a carrier call, the app announces itself to the backend and gets matched with the other VeriCall user on the same call.

### `native_call:in_call` — Announce entering a call

Sent when the user picks up a carrier call. The backend attempts to match this user with another VeriCall user who sent this event around the same time (within 30 seconds).

**Client → Server**
```json
{
  "type": "native_call:in_call",
  "direction": "incoming",
  "timestamp": 1739000000000
}
```

`direction` is `"incoming"` or `"outgoing"`.

**Server → Client** — Match found
```json
{
  "type": "native_call:matched",
  "matched_user_id": "uuid",
  "matched_name": "Alice"
}
```

Both matched users also receive a `native_call:handshake` (see below).

**Server → Client** — Waiting for match
```json
{
  "type": "native_call:waiting",
  "message": "Waiting for other party..."
}
```

---

### `native_call:handshake` — Identity handshake

Sent automatically by the server when two users are matched. Also sent directly by clients to a specific recipient (by phone or user ID) to initiate verification.

**Server → Client** (auto-sent on match)
```json
{
  "type": "native_call:handshake",
  "fromUserId": "uuid",
  "displayName": "Alice",
  "phoneNumber": "+15550001234",
  "timestamp": 1739000000000
}
```

**Client → Server** (direct handshake, forwarded to recipient)
```json
{
  "type": "native_call:handshake",
  "phoneNumber": "+15550001234",
  "recipientId": "uuid-or-omit",
  "timestamp": 1739000000000
}
```

The server resolves the recipient by `recipientId` first, then `phoneNumber`. It injects `fromUserId`, `displayName`, and `phoneNumber` (caller's) before forwarding.

---

### `native_call:request_thumbprint` — Request device proof

Sent by the recipient to ask the caller to prove device ownership.

**Client → Server** (forwarded to recipient)
```json
{
  "type": "native_call:request_thumbprint",
  "phoneNumber": "+15550001234",
  "timestamp": 1739000000000
}
```

**Server → Recipient** (forwarded)
```json
{
  "type": "native_call:request_thumbprint",
  "fromUserId": "uuid",
  "displayName": "Bob",
  "phoneNumber": "+15550005678",
  "timestamp": 1739000000000
}
```

---

### `native_call:handshake_response` — Device proof response

**Client → Server** (forwarded to requester)
```json
{
  "type": "native_call:handshake_response",
  "phoneNumber": "+15550005678",
  "verified": true,
  "timestamp": 1739000000000
}
```

---

### `native_call:call_ended` — Remove from matching pool

Sent when the native call ends to remove the user from the matching pool.

**Client → Server**
```json
{
  "type": "native_call:call_ended"
}
```

**Server → Client**
```json
{
  "type": "native_call:pool_cleared"
}
```

---

### Delivery status events (server → sender)

| Type | Meaning |
|------|---------|
| `native_call:delivered` | Message forwarded to online recipient |
| `native_call:push_sent` | Recipient offline — VoIP push sent to wake app |
| `native_call:offline` | Recipient offline and no push token available |
| `native_call:error` | Recipient not found or forwarding failed |

```json
{
  "type": "native_call:delivered",
  "original_type": "native_call:handshake",
  "to_user_id": "uuid"
}
```

```json
{
  "type": "native_call:push_sent",
  "original_type": "native_call:handshake",
  "to_user_id": "uuid",
  "message": "VoIP push sent to wake recipient app"
}
```

```json
{
  "type": "native_call:offline",
  "original_type": "native_call:handshake",
  "to_user_id": "uuid",
  "message": "Recipient is offline (no push token)"
}
```

---

## Recipient Routing

For all `voip:` and `native_call:` events the server resolves the recipient using this priority:

1. `toUserId` / `recipientId` — if provided and the user is currently connected
2. `toPhone` / `phoneNumber` — normalized phone number lookup in the database

Phone numbers are normalized before comparison (strips spaces, dashes, parens) and multiple formats are tried:
- E.164 with country code (e.g., `+15550001234`)
- Without leading `+` (`15550001234`)
- AU local format (`04xx` ↔ `+614xx`)
- US 10-digit without country code

---

## Swift Usage Example

```swift
// Connect
let url = URL(string: "wss://vericall-api.fly.dev/ws?token=\(accessToken)")!
let socket = URLSessionWebSocketTask(with: url)

// Initiate a VoIP call
let message = [
    "type": "voip:initiate",
    "toPhone": "+15550001234",
    "callId": UUID().uuidString,
    "port": 12345,
    "device": UIDevice.current.name
]
socket.send(.string(try! JSONSerialization.string(message)))

// Receive
socket.receive { result in
    if case .success(.string(let text)) = result,
       let data = text.data(using: .utf8),
       let json = try? JSONDecoder().decode([String: Any].self, from: data) {
        let type = json["type"] as? String
        // handle event...
    }
}
```

---

## Implementation Reference

All WebSocket logic is in [backend/app/websocket.py](backend/app/websocket.py).

The iOS client is in [ios/VeriCall/Services/CallWebSocketService.swift](ios/VeriCall/Services/CallWebSocketService.swift).
