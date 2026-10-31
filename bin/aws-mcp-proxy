#!/usr/bin/env -S uv run --script --quiet
# /// script
# requires-python = ">=3.10,<3.15"
# dependencies = ["mcp-proxy-for-aws-cli==1.7.0"]
# ///
"""mcp-proxy-for-aws that starts even while the profile's credentials are expired.

Takes the same arguments as mcp-proxy-for-aws-cli; pass --skip-auth.

--skip-auth sends requests unsigned only when boto3 finds no credentials at
all. An SSO profile always yields deferred credentials, which raise on use
once the login expires (or before the first login), so initialize fails and
an MCP client or gateway never loads the server. This reports such
credentials as missing instead: requests go unsigned (initialize and
tools/list work; tools that need AWS access fail) until `aws sso login`,
and the next request is signed again, without a restart.

This replaces mcp_proxy_for_aws.sigv4_helper.create_aws_session, an
internal: re-test before bumping the pinned version (requires-python
follows the package's; uv would otherwise pick an unsupported Python).
"""

import sys

import botocore.exceptions
from mcp_proxy_for_aws import server, sigv4_helper

_create_aws_session = sigv4_helper.create_aws_session


def create_aws_session(profile=None):
    session = _create_aws_session(profile)
    get_credentials = session.get_credentials

    def usable_credentials():
        credentials = get_credentials()
        if credentials is None:
            return None
        try:
            credentials.get_frozen_credentials()
        except botocore.exceptions.BotoCoreError:
            return None
        return credentials

    session.get_credentials = usable_credentials
    return session


sigv4_helper.create_aws_session = create_aws_session
sys.exit(server.main())
