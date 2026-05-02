#!/usr/bin/env python3
from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

from fastapi.testclient import TestClient


ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

BOOTSTRAP_DIR = Path(tempfile.mkdtemp(prefix="vicall-delete-bootstrap-"))
os.environ.setdefault("VICALL_CONTROL_DB_PATH", str(BOOTSTRAP_DIR / "control.db"))
os.environ.setdefault("DEVICE_BINDINGS_PATH", str(BOOTSTRAP_DIR / "device_bindings.json"))

import app as service_app  # noqa: E402
from control_plane import ControlPlaneStore  # noqa: E402


async def _fake_forward_main_api_request(*args, **kwargs):
    return {}


def _seed_membership(store: ControlPlaneStore, *, suffix: str) -> dict[str, str]:
    msp = store.create_msp(
        name=f"Deletion Test MSP {suffix}",
        billing_email=f"billing-{suffix}@example.com",
        seat_price_cents=2000,
    )
    org = store.create_organization(
        msp_id=msp["id"],
        name=f"Deletion Test Org {suffix}",
    )
    access_code = store.create_access_code(
        organization_id=org["id"],
        code=f"DELETE-{suffix}",
        label="Primary",
    )
    context = store.organization_context(
        organization_id=org["id"],
        access_code_id=access_code["id"],
    )
    phone_number = f"+1555123{suffix.zfill(4)}"
    user_id = f"user_{suffix}"
    identity = f"user_1555123{suffix.zfill(4)}_prod1"
    store.activate_membership(
        context=context,
        phone_number=phone_number,
        user_id=user_id,
    )
    return {
        "phone_number": phone_number,
        "user_id": user_id,
        "identity": identity,
    }


def main() -> None:
    original_mode = os.environ.get("ACCOUNT_DELETION_FLOW_MODE")
    original_control_plane = service_app.control_plane
    original_forward = service_app.forward_main_api_request
    original_bindings = dict(service_app.device_bindings)
    original_save_device_bindings = service_app.save_device_bindings

    try:
        tempdir = Path(tempfile.mkdtemp(prefix="vicall-delete-flow-"))
        service_app.control_plane = ControlPlaneStore(tempdir / "control.db")
        service_app.forward_main_api_request = _fake_forward_main_api_request
        service_app.save_device_bindings = lambda bindings: None
        service_app.device_bindings = {}

        client = TestClient(service_app.app)
        headers = {"Authorization": "Bearer demo-token"}

        api_subject = _seed_membership(service_app.control_plane, suffix="1001")
        service_app.device_bindings[api_subject["identity"]] = {"voip_token": "tok_api"}

        os.environ["ACCOUNT_DELETION_FLOW_MODE"] = "api"
        prepare = client.post(
            "/account/delete/prepare",
            headers=headers,
            json=api_subject,
        )
        assert prepare.status_code == 200, prepare.text
        prepare_body = prepare.json()
        assert prepare_body["mode"] == "api", prepare_body
        assert prepare_body["deletion_token"].startswith("vdel_"), prepare_body
        manage_path = urlparse(prepare_body["manage_url"]).path + "?" + urlparse(prepare_body["manage_url"]).query
        manage_view = client.get(manage_path)
        assert manage_view.status_code == 200, manage_view.text

        execute = client.post(
            "/account/delete/execute",
            json={"deletion_token": prepare_body["deletion_token"]},
        )
        assert execute.status_code == 200, execute.text
        execute_body = execute.json()
        assert execute_body["status"] == "deleted", execute_body
        assert execute_body["deactivated_memberships"] == 1, execute_body
        assert execute_body["device_binding_removed"] is True, execute_body

        reused = client.post(
            "/account/delete/execute",
            json={"deletion_token": prepare_body["deletion_token"]},
        )
        assert reused.status_code == 410, reused.text

        legacy_subject = _seed_membership(service_app.control_plane, suffix="1002")
        service_app.device_bindings[legacy_subject["identity"]] = {"voip_token": "tok_legacy"}
        legacy = client.post(
            "/account/delete",
            headers=headers,
            json=legacy_subject,
        )
        assert legacy.status_code == 200, legacy.text
        legacy_body = legacy.json()
        assert legacy_body["deactivated_memberships"] == 1, legacy_body
        assert legacy_body["device_binding_removed"] is True, legacy_body

        web_subject = _seed_membership(service_app.control_plane, suffix="1003")
        service_app.device_bindings[web_subject["identity"]] = {"voip_token": "tok_web"}
        os.environ["ACCOUNT_DELETION_FLOW_MODE"] = "web"
        prepare_web = client.post(
            "/account/delete/prepare",
            headers=headers,
            json=web_subject,
        )
        assert prepare_web.status_code == 200, prepare_web.text
        prepare_web_body = prepare_web.json()
        assert prepare_web_body["mode"] == "web", prepare_web_body
        manage_web = urlparse(prepare_web_body["manage_url"]).path + "?" + urlparse(prepare_web_body["manage_url"]).query
        manage_web_view = client.get(manage_web)
        assert manage_web_view.status_code == 200, manage_web_view.text
        manage_submit = client.post(
            "/account/delete/manage",
            data={"token": prepare_web_body["deletion_token"]},
        )
        assert manage_submit.status_code == 200, manage_submit.text
        assert "Vicall Account Deleted" in manage_submit.text, manage_submit.text
        invalidated = client.get(manage_web)
        assert invalidated.status_code == 410, invalidated.text

        print("PASS: account deletion prepare/manage/execute flow works in api and web modes")
    finally:
        if original_mode is None:
            os.environ.pop("ACCOUNT_DELETION_FLOW_MODE", None)
        else:
            os.environ["ACCOUNT_DELETION_FLOW_MODE"] = original_mode
        service_app.control_plane = original_control_plane
        service_app.forward_main_api_request = original_forward
        service_app.device_bindings = original_bindings
        service_app.save_device_bindings = original_save_device_bindings


if __name__ == "__main__":
    main()
