"""
Minimal SaaS-style backend, deliberately simple so any 503 that shows up
is coming from infrastructure (ALB / Target Group / security groups),
not from application complexity.
"""
from flask import Flask, jsonify, request

app = Flask(__name__)

FAKE_USER = {"id": 1, "email": "demo@georgekoufie.xyz", "name": "Demo User"}


@app.route("/health")
def health():
    # What the ALB's Target Group health check hits.
    return jsonify({"status": "ok"}), 200


@app.route("/api/v1/user/me")
def user_me():
    return jsonify(FAKE_USER), 200


@app.route("/login", methods=["POST"])
def login():
    body = request.get_json(silent=True) or {}
    if body.get("email") == FAKE_USER["email"]:
        return jsonify({"token": "fake-demo-token"}), 200
    return jsonify({"error": "invalid credentials"}), 401


@app.route("/forgot-password", methods=["POST"])
def forgot_password():
    body = request.get_json(silent=True) or {}
    if not body.get("email"):
        return jsonify({"error": "email required"}), 400
    return jsonify({"message": "reset link sent"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
