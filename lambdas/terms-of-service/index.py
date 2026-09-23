"""
Activity 2: Terms of Service Lambda
Exposed as an AWS Lambda function via AgentCore Gateway MCP Server (AnyCompany-ToS-Tool).
Auth: AWS IAM Role

Retrieves service conditions by type: Delivery, Payment, or Refund.
"""

import json
from datetime import datetime

TERMS_BY_TYPE = {
    "Delivery": {
        "type": "Delivery",
        "version": "2.1",
        "effective_date": "2025-01-15",
        "last_updated": "2025-06-01",
        "conditions": [
            {
                "title": "Standard Shipping",
                "content": "Standard shipping takes 5-7 business days. Free for orders over $50."
            },
            {
                "title": "Express Shipping",
                "content": "Express shipping takes 2-3 business days. Flat rate of $12.99."
            },
            {
                "title": "Same-Day Delivery",
                "content": "Same-day delivery is available in select metropolitan areas for orders placed before 12 PM. Fee is $19.99."
            },
            {
                "title": "International Shipping",
                "content": "International shipping takes 10-15 business days. Rates vary by destination. Customs duties are the responsibility of the recipient."
            },
            {
                "title": "Shipping Restrictions",
                "content": "Hazardous materials, oversized items, and perishable goods may have shipping restrictions. Check product pages for details."
            }
        ]
    },
    "Payment": {
        "type": "Payment",
        "version": "2.1",
        "effective_date": "2025-01-15",
        "last_updated": "2025-06-01",
        "conditions": [
            {
                "title": "Accepted Payment Methods",
                "content": "We accept Visa, Mastercard, American Express, PayPal, and AnyCompany Gift Cards."
            },
            {
                "title": "Payment Processing",
                "content": "Payments are processed at the time of order placement. Your card is charged when the order is confirmed."
            },
            {
                "title": "Pricing",
                "content": "All prices are displayed in USD and include applicable taxes unless stated otherwise. Prices are subject to change without notice."
            },
            {
                "title": "Payment Security",
                "content": "All transactions are encrypted using TLS 1.3. We are PCI DSS Level 1 compliant and do not store full card numbers."
            },
            {
                "title": "Installment Plans",
                "content": "Orders over $200 are eligible for 4 interest-free installments via our Buy Now Pay Later partner."
            }
        ]
    },
    "Refund": {
        "type": "Refund",
        "version": "2.1",
        "effective_date": "2025-01-15",
        "last_updated": "2025-06-01",
        "conditions": [
            {
                "title": "Return Window",
                "content": "Items may be returned within 30 days of delivery. Items must be in original condition with tags attached."
            },
            {
                "title": "Refund Processing",
                "content": "Refunds are processed within 5-7 business days after the returned item is received and inspected."
            },
            {
                "title": "Refund Method",
                "content": "Refunds are issued to the original payment method. Gift card purchases are refunded as store credit."
            },
            {
                "title": "Non-Refundable Items",
                "content": "Final sale items, personalized products, and opened hygiene products are not eligible for refund."
            },
            {
                "title": "Exchanges",
                "content": "Exchanges for a different size or color are free. The replacement is shipped once the original item is received."
            }
        ]
    }
}

ACCEPTED_USERS = {}


def handler(event, context):
    action = event.get("action", "get_terms")
    tos_type = event.get("type", "").strip()

    if action == "get_terms":
        if tos_type and tos_type in TERMS_BY_TYPE:
            return _ok({"terms": TERMS_BY_TYPE[tos_type]})

        if tos_type and tos_type not in TERMS_BY_TYPE:
            return _ok({
                "error": f"Unknown type: {tos_type}",
                "available_types": list(TERMS_BY_TYPE.keys())
            })

        return _ok({
            "available_types": list(TERMS_BY_TYPE.keys()),
            "message": "Specify a type (Delivery, Payment, or Refund) to retrieve the corresponding Terms of Service."
        })

    elif action == "accept_terms":
        user_id = event.get("user_id")
        if not user_id:
            return _err("user_id is required")
        ACCEPTED_USERS[user_id] = {
            "accepted_at": datetime.utcnow().isoformat(),
            "version": "2.1"
        }
        return _ok({
            "message": f"User {user_id} accepted Terms of Service v2.1",
            "acceptance": ACCEPTED_USERS[user_id]
        })

    elif action == "check_acceptance":
        user_id = event.get("user_id")
        if not user_id:
            return _err("user_id is required")
        acceptance = ACCEPTED_USERS.get(user_id)
        return _ok({
            "user_id": user_id,
            "has_accepted": acceptance is not None,
            "acceptance": acceptance
        })

    return _err(f"Unknown action: {action}")


def _ok(body):
    return {"statusCode": 200, "body": json.dumps(body)}


def _err(msg):
    return {"statusCode": 400, "body": json.dumps({"error": msg})}
