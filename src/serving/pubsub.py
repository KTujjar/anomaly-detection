"""
Pub/Sub push endpoint.

Pub/Sub push delivery is an ordinary HTTPS POST, so this needs no google-cloud-pubsub
dependency -- which is why the serving image stays slim. The publisher side
(scripts/publish_sample.py) is the only thing that needs the client library, and it
never ships in the image.

Authentication is handled entirely outside this code. The push subscription is
configured with an OIDC token (terraform/pubsub.tf), the Cloud Run consumer service
is private, and only the push service account holds roles/run.invoker. Cloud Run
rejects unsigned requests at the edge, so there is no shared secret or auth
middleware here.

Envelope shape Pub/Sub sends:
    {
      "message": {
        "data": "<base64 of the JSON row>",
        "messageId": "...",
        "publishTime": "..."
      },
      "subscription": "projects/<p>/subscriptions/<s>"
    }
"""

import base64
import binascii
import json
import logging
import os
from typing import Optional

from fastapi import APIRouter, Request, Response, status

from src.ingestion.pipeline import MissingFieldsError, StreamingDetector, format_result

logger = logging.getLogger(__name__)

router = APIRouter(tags=["pubsub"])

# Log every scored row, or only the anomalies. Cloud Run charges for log volume at
# scale, and on a steady stream the anomalies are the interesting line.
LOG_ALL_RESULTS = os.environ.get("LOG_ALL_RESULTS", "false").lower() == "true"

_ACK = Response(status_code=status.HTTP_204_NO_CONTENT)


class PubSubEnvelopeError(ValueError):
    """The POST body was not a Pub/Sub push envelope we can read."""


def decode_envelope(body: dict) -> dict:
    """
    Pull the JSON row out of a Pub/Sub push envelope.

    Raises PubSubEnvelopeError for anything malformed, so the caller can make one
    decision about poison messages instead of many.
    """
    if not isinstance(body, dict):
        raise PubSubEnvelopeError("body is not an object")

    message = body.get("message")
    if not isinstance(message, dict):
        raise PubSubEnvelopeError("missing 'message' object")

    data = message.get("data")
    if not data:
        raise PubSubEnvelopeError("missing 'message.data'")

    try:
        raw = base64.b64decode(data, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise PubSubEnvelopeError(f"'message.data' is not valid base64: {exc}") from exc

    try:
        row = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PubSubEnvelopeError(f"'message.data' is not valid JSON: {exc}") from exc

    if not isinstance(row, dict):
        raise PubSubEnvelopeError("decoded payload is not a JSON object")

    return row


def _detector(request: Request) -> Optional[StreamingDetector]:
    """The StreamingDetector built during app startup, or None if artifacts are missing."""
    return getattr(request.app.state, "streaming_detector", None)


@router.post("/pubsub/push")
async def pubsub_push(request: Request) -> Response:
    """
    Score one streamed row.

    On status codes -- this endpoint returns 204 far more often than it looks like it
    should, and that is deliberate. Pub/Sub treats any non-2xx as a nack and redelivers,
    so returning 4xx for a message that can never parse means redelivering it until the
    retention window expires. Unparseable input is acked here and routed to the
    dead-letter topic by the subscription's own maxDeliveryAttempts. 5xx is reserved
    for transient failures that genuinely deserve a retry.
    """
    detector = _detector(request)
    if detector is None:
        # Artifacts never loaded. This IS transient from Pub/Sub's point of view --
        # a redelivery after the next revision boots should succeed.
        logger.error("pubsub push received but no detector is loaded")
        return Response(status_code=status.HTTP_503_SERVICE_UNAVAILABLE)

    try:
        body = await request.json()
    except json.JSONDecodeError:
        logger.warning("pubsub push body was not JSON; acking to dead-letter")
        return _ACK

    try:
        row = decode_envelope(body)
    except PubSubEnvelopeError as exc:
        logger.warning("malformed pubsub envelope, acking to dead-letter: %s", exc)
        return _ACK

    try:
        result = detector.handle(row)
    except MissingFieldsError as exc:
        logger.warning("unusable row, acking to dead-letter: %s", exc)
        return _ACK

    if result is None:
        # Still filling the rolling window. Nothing to report yet.
        return _ACK

    if result["is_anomaly"] or LOG_ALL_RESULTS:
        logger.info(format_result(result))

    return _ACK
