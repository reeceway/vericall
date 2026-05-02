#!/usr/bin/env python3
from __future__ import annotations

import os
import re
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

TEMP_DIR = Path(tempfile.mkdtemp(prefix="vicall-voice-context-"))
os.environ["VICALL_CONTROL_DB_PATH"] = str(TEMP_DIR / "control.db")
os.environ["DEVICE_BINDINGS_PATH"] = str(TEMP_DIR / "device_bindings.json")
os.environ.setdefault("TWILIO_AI_AUDIO_MIRROR_ENABLED", "false")

from fastapi.testclient import TestClient  # noqa: E402

import app as service_app  # noqa: E402
from control_plane import ControlPlaneStore, month_start  # noqa: E402


def seed_membership(
    store: ControlPlaneStore,
    *,
    msp_name: str,
    org_name: str,
    phone_number: str,
    user_id: str,
    code: str,
) -> dict[str, str]:
    msp = store.create_msp(
        name=msp_name,
        billing_email=f"{msp_name.lower().replace(' ', '-')}@example.com",
        seat_price_cents=2000,
    )
    org = store.create_organization(msp_id=msp["id"], name=org_name)
    access_code = store.create_access_code(
        organization_id=org["id"],
        code=code,
        label=f"{org_name} test code",
    )
    context = store.organization_context(
        organization_id=org["id"],
        access_code_id=access_code["id"],
    )
    membership = store.activate_membership(
        context=context,
        phone_number=phone_number,
        user_id=user_id,
    )
    return {
        "msp_id": msp["id"],
        "organization_id": org["id"],
        "membership_id": membership["membership_id"],
        "phone_number": membership["phone_number"],
    }


def identity_for(phone_number: str) -> str:
    digits = "".join(ch for ch in phone_number if ch.isdigit())
    return f"user_{digits}_prod1"


def main() -> None:
    store = service_app.control_plane
    assert isinstance(store, ControlPlaneStore)
    client = TestClient(service_app.app)

    shared_phone = "+15550001111"
    callee_phone = "+15550002222"
    first = seed_membership(
        store,
        msp_name="Context MSP One",
        org_name="Context Company One",
        phone_number=shared_phone,
        user_id="shared-user-first",
        code="VOICE-CONTEXT-ONE",
    )
    second = seed_membership(
        store,
        msp_name="Context MSP Two",
        org_name="Context Company Two",
        phone_number=shared_phone,
        user_id="shared-user-second",
        code="VOICE-CONTEXT-TWO",
    )
    callee = seed_membership(
        store,
        msp_name="Context Callee MSP",
        org_name="Context Callee Company",
        phone_number=callee_phone,
        user_id="callee-user",
        code="VOICE-CONTEXT-CALLEE",
    )

    caller_identity = identity_for(shared_phone)
    callee_identity = identity_for(callee_phone)

    ambiguous_binding = client.post(
        "/calls/device-binding",
        json={
            "identity": caller_identity,
            "voip_token": "a" * 64,
            "platform": "ios",
            "context": "missing_account_context",
        },
    )
    assert ambiguous_binding.status_code == 409, ambiguous_binding.text
    detail = ambiguous_binding.json()["detail"]
    assert len(detail["memberships"]) == 2, detail

    selected_binding = client.post(
        "/calls/device-binding",
        json={
            "identity": caller_identity,
            "voip_token": "b" * 64,
            "platform": "ios",
            "context": "selected_account_context",
            "membership_id": first["membership_id"],
            "organization_id": first["organization_id"],
            "msp_id": first["msp_id"],
        },
    )
    assert selected_binding.status_code == 200, selected_binding.text

    callee_binding = client.post(
        "/calls/device-binding",
        json={
            "identity": callee_identity,
            "voip_token": "c" * 64,
            "platform": "ios",
            "context": "callee_account_context",
            "membership_id": callee["membership_id"],
            "organization_id": callee["organization_id"],
            "msp_id": callee["msp_id"],
        },
    )
    assert callee_binding.status_code == 200, callee_binding.text

    webhook = client.post(
        "/calls/twilio-voice",
        data={
            "From": caller_identity,
            "To": callee_identity,
            "CallSid": "CA-context-parent",
            "Session": "context-session",
            "FromMembershipId": first["membership_id"],
            "FromOrganizationId": first["organization_id"],
            "FromMspId": first["msp_id"],
        },
    )
    assert webhook.status_code == 200, webhook.text
    assert first["membership_id"] in webhook.text, webhook.text
    assert callee["membership_id"] in webhook.text, webhook.text

    status_match = re.search(r'statusCallback="([^"]+)"', webhook.text)
    assert status_match, webhook.text
    status_url = status_match.group(1).replace("&amp;", "&")
    assert f"from_membership_id={first['membership_id']}" in status_url, status_url
    assert f"to_membership_id={callee['membership_id']}" in status_url, status_url

    status = client.post(
        status_url.removeprefix("http://testserver"),
        data={
            "CallSid": "CA-context-child",
            "ParentCallSid": "CA-context-parent",
            "CallStatus": "completed",
            "CallbackEvent": "completed",
            "CallDuration": "61",
            "From": caller_identity,
            "To": callee_identity,
        },
    )
    assert status.status_code == 200, status.text

    first_snapshot = store.billing_snapshot(
        msp_id=first["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    second_snapshot = store.billing_snapshot(
        msp_id=second["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    assert first_snapshot["total_call_count"] == 1, first_snapshot
    assert first_snapshot["total_billable_minutes"] == 2, first_snapshot
    assert second_snapshot["total_call_count"] == 0, second_snapshot
    assert second_snapshot["total_billable_minutes"] == 0, second_snapshot

    with store._connect() as conn:
        participant = conn.execute(
            """
            SELECT membership_id, organization_id, msp_id
            FROM call_participants
            WHERE identity = ? AND phone_number = ?
            ORDER BY updated_at DESC
            LIMIT 1
            """,
            (caller_identity, shared_phone),
        ).fetchone()
    assert dict(participant) == {
        "membership_id": first["membership_id"],
        "organization_id": first["organization_id"],
        "msp_id": first["msp_id"],
    }, dict(participant)

    direct_second = store.record_call_event(
        canonical_key="context-direct-second",
        caller_identity=caller_identity,
        caller_membership_id=second["membership_id"],
        caller_organization_id=second["organization_id"],
        caller_msp_id=second["msp_id"],
        twilio_call_sid="CA-context-second",
        leg_role="caller",
        status="completed",
        callback_event="completed",
        duration_seconds=60,
    )
    assert direct_second is not None
    second_after_direct = store.billing_snapshot(
        msp_id=second["msp_id"],
        period_start_value=month_start(datetime.now(timezone.utc)),
    )
    assert second_after_direct["total_call_count"] == 1, second_after_direct
    assert second_after_direct["total_billable_minutes"] == 1, second_after_direct

    print("PASS: duplicate phone voice calls are attributed by explicit MSP/org/membership context")


if __name__ == "__main__":
    main()
