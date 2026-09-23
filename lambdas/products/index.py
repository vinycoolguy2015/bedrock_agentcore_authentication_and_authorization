"""
Activity 3: Products Lambda
Exposed via Amazon API Gateway.
Auth: OAuth 2.0 token (JWT Authorizer)
"""

import json

PRODUCTS = [
    {
        "product_id": "PROD-001",
        "name": "Wireless Noise-Canceling Headphones",
        "category": "Electronics",
        "price": 249.99,
        "description": "Premium over-ear headphones with active noise cancellation and 30-hour battery life.",
        "in_stock": True
    },
    {
        "product_id": "PROD-002",
        "name": "Organic Cotton T-Shirt",
        "category": "Apparel",
        "price": 34.99,
        "description": "Sustainably sourced 100% organic cotton crew neck t-shirt.",
        "in_stock": True
    },
    {
        "product_id": "PROD-003",
        "name": "Stainless Steel Water Bottle",
        "category": "Home & Kitchen",
        "price": 29.99,
        "description": "Double-walled vacuum insulated 32oz water bottle. Keeps drinks cold for 24 hours.",
        "in_stock": True
    },
    {
        "product_id": "PROD-004",
        "name": "Mechanical Keyboard",
        "category": "Electronics",
        "price": 149.99,
        "description": "Full-size mechanical keyboard with Cherry MX Blue switches and RGB backlighting.",
        "in_stock": False
    },
    {
        "product_id": "PROD-005",
        "name": "Running Shoes - CloudStride",
        "category": "Footwear",
        "price": 129.99,
        "description": "Lightweight running shoes with responsive cushioning and breathable mesh upper.",
        "in_stock": True
    }
]


def handler(event, context):
    http_method = event.get("httpMethod", event.get("requestContext", {}).get("http", {}).get("method", "GET"))
    path = event.get("path", event.get("rawPath", "/"))
    query = event.get("queryStringParameters") or {}

    if http_method == "GET":
        product_id = query.get("product_id")
        category = query.get("category")

        if product_id:
            product = next((p for p in PRODUCTS if p["product_id"] == product_id), None)
            if not product:
                return _response(404, {"error": f"Product {product_id} not found"})
            return _response(200, {"product": product})

        results = PRODUCTS
        if category:
            results = [p for p in results if p["category"].lower() == category.lower()]

        return _response(200, {"products": results, "count": len(results)})

    return _response(400, {"error": "Invalid request"})


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps(body)
    }
