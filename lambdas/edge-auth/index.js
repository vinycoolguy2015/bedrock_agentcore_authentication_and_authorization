/**
 * Lambda@Edge - Viewer Request
 * Validates Cognito JWT tokens on CloudFront requests.
 * Redirects unauthenticated users to the Cognito login page.
 */

'use strict';

const COGNITO_DOMAIN = '%%COGNITO_DOMAIN%%';
const CLIENT_ID = '%%CLIENT_ID%%';

exports.handler = async (event) => {
    const request = event.Records[0].cf.request;
    const headers = request.headers;
    const host = headers.host && headers.host[0] ? headers.host[0].value : '';
    const CALLBACK_URL = `https://${host}/callback`;

    if (request.uri === '/callback') {
        return request;
    }

    // Pass through static assets without auth — they must load before token exchange
    if (/\.(js|css|html|png|jpg|jpeg|gif|svg|ico|woff|woff2|ttf|map|json)(\?.*)?$/i.test(request.uri)) {
        return request;
    }

    if (request.uri === '/health') {
        return {
            status: '200',
            statusDescription: 'OK',
            body: JSON.stringify({ status: 'healthy' }),
            headers: { 'content-type': [{ value: 'application/json' }] }
        };
    }

    const cookies = parseCookies(headers);
    const idToken = cookies['id_token'];

    if (!idToken) {
        return redirectToLogin(CALLBACK_URL);
    }

    try {
        const payload = decodeJwt(idToken);
        const now = Math.floor(Date.now() / 1000);

        if (!payload.exp || payload.exp < now) {
            return redirectToLogin(CALLBACK_URL);
        }

        request.headers['x-user-sub'] = [{ value: payload.sub || '' }];
        request.headers['x-user-email'] = [{ value: payload.email || '' }];

        return request;
    } catch (err) {
        console.error('Token validation failed:', err.message);
        return redirectToLogin(CALLBACK_URL);
    }
};

function redirectToLogin(callbackUrl) {
    const loginUrl = `https://${COGNITO_DOMAIN}/login?response_type=code&client_id=${CLIENT_ID}&redirect_uri=${encodeURIComponent(callbackUrl)}`;
    return {
        status: '302',
        statusDescription: 'Found',
        headers: {
            location: [{ value: loginUrl }],
            'cache-control': [{ value: 'no-cache, no-store, must-revalidate' }]
        }
    };
}

function parseCookies(headers) {
    const cookies = {};
    if (headers.cookie) {
        headers.cookie[0].value.split(';').forEach(cookie => {
            const parts = cookie.trim().split('=');
            if (parts.length >= 2) {
                cookies[parts[0].trim()] = parts.slice(1).join('=').trim();
            }
        });
    }
    return cookies;
}

function decodeJwt(token) {
    const parts = token.split('.');
    if (parts.length !== 3) throw new Error('Invalid JWT');
    const payload = Buffer.from(parts[1], 'base64url').toString('utf8');
    return JSON.parse(payload);
}
