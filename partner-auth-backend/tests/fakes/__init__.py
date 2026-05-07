"""Fake fixtures for integration tests.

Provides ``httpx.MockTransport``-based stand-ins for the Ring consumer
API and the Node.js SIP bridge sidecar so tests can wire the real
adapter stack together without talking to live services.
"""
