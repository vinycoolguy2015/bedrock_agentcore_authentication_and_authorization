"""
Agent Proxy Lambda — forwards browser requests to the AgentCore Runtime
as plain HTTP (no MCP wrapping).
"""

import json
import os
import boto3

RUNTIME_ARN = os.environ.get('AGENT_RUNTIME_ARN', '')
REGION = os.environ.get('AWS_DEFAULT_REGION', 'us-east-1')

client = boto3.client('bedrock-agentcore', region_name=REGION)


def handler(event, context):
    body = event.get('body', '{}')
    if event.get('isBase64Encoded'):
        import base64
        body = base64.b64decode(body).decode()

    try:
        req = json.loads(body)
    except Exception:
        return _response(400, {'error': 'Invalid JSON'})

    try:
        resp = client.invoke_agent_runtime(
            agentRuntimeArn=RUNTIME_ARN,
            payload=body.encode(),
            qualifier='DEFAULT',
            contentType='application/json',
            accept='application/json',
        )

        raw = resp['response'].read().decode()
        try:
            data = json.loads(raw)
        except Exception:
            data = {'response': raw}

        return _response(200, data)

    except Exception as e:
        print(f"Error: {e}")
        return _response(502, {'error': str(e)})


def _response(status, body):
    return {
        'statusCode': status,
        'headers': {
            'Content-Type': 'application/json',
            'Access-Control-Allow-Origin': '*',
            'Access-Control-Allow-Headers': 'Content-Type,Authorization',
            'Access-Control-Allow-Methods': 'POST,OPTIONS',
        },
        'body': json.dumps(body),
    }
