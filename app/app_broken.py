"""
Deliberately broken version — simulates a bad deploy where a shared helper
function referenced by both /login and /forgot-password has a typo'd
variable name. /health and /api/v1/user/me are untouched and keep working,
which is exactly why this one won't show up as a Target Group problem.
"""
from flask import Flask, jsonify, request

app = Flask(__name__)

FAKE_USER = {"id": 1, "email": "demo@georgekoufie.xyz", "name": "Demo User"}


def _log_auth_event(event_type, request_body):
    # Real bug: references `event_typo` instead of `event_type` — the kind
    # of typo that slips through a quick deploy and only fires on the
    # specific code path that calls this helper.
    print(f"[auth] {event_typo}: {request_body}")


@app.route("/health")
def health():
    return jsonify({"status": "ok"}), 200


@app.route("/api/v1/user/me")
def user_me():
    return jsonify(FAKE_USER), 200


@app.route("/login", methods=["POST"])
def login():
    body = request.get_json(silent=True) or {}
    _log_auth_event("login_attempt", body)
    if body.get("email") == FAKE_USER["email"]:
        return jsonify({"token": "fake-demo-token"}), 200
    return jsonify({"error": "invalid credentials"}), 401


@app.route("/forgot-password", methods=["POST"])
def forgot_password():
    body = request.get_json(silent=True) or {}
    _log_auth_event("forgot_password", body)
    if not body.get("email"):
        return jsonify({"error": "email required"}), 400
    return jsonify({"message": "reset link sent"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
