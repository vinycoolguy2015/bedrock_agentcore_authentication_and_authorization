"""
Activity 4: Inventory Lambda (Trust Domain 2)
Exposed via Amazon API Gateway with JWT Authorizer.
Auth: OAuth 2.0 token
"""

import json

INVENTORY = {
    "PROD-001": {"product_id": "PROD-001", "name": "Wireless Noise-Canceling Headphones", "warehouse": "WH-East-01", "quantity": 342, "reorder_threshold": 50, "status": "IN_STOCK"},
    "PROD-002": {"product_id": "PROD-002", "name": "Organic Cotton T-Shirt", "warehouse": "WH-West-01", "quantity": 1205, "reorder_threshold": 200, "status": "IN_STOCK"},
    "PROD-003": {"product_id": "PROD-003", "name": "Stainless Steel Water Bottle", "warehouse": "WH-East-01", "quantity": 89, "reorder_threshold": 100, "status": "LOW_STOCK"},
    "PROD-004": {"product_id": "PROD-004", "name": "Mechanical Keyboard", "warehouse": "WH-Central-01", "quantity": 0, "reorder_threshold": 75, "status": "OUT_OF_STOCK"},
    "PROD-005": {"product_id": "PROD-005", "name": "Running Shoes - CloudStride", "warehouse": "WH-West-01", "quantity": 567, "reorder_threshold": 100, "status": "IN_STOCK"},
}


def handler(event, context):
    http_method = event.get("httpMethod", event.get("requestContext", {}).get("http", {}).get("method", "GET"))
    path = event.get("path", event.get("rawPath", "/"))
    query = event.get("queryStringParameters") or {}

    if http_method == "GET":
        product_id = query.get("product_id")

        if product_id:
            item = INVENTORY.get(product_id)
            if not item:
                return _response(404, {"error": f"No inventory record for {product_id}"})
            return _response(200, {"inventory": item})

        status_filter = query.get("status")
        items = list(INVENTORY.values())
        if status_filter:
            items = [i for i in items if i["status"] == status_filter.upper()]

        return _response(200, {"inventory": items, "count": len(items)})

    if http_method == "PUT":
        body = json.loads(event.get("body", "{}"))
        product_id = body.get("product_id")
        quantity_change = body.get("quantity_change", 0)

        if not product_id or product_id not in INVENTORY:
            return _response(404, {"error": f"Product {product_id} not found in inventory"})

        item = INVENTORY[product_id]
        new_qty = item["quantity"] + quantity_change
        if new_qty < 0:
            return _response(400, {"error": "Insufficient inventory"})

        item["quantity"] = new_qty
        if new_qty == 0:
            item["status"] = "OUT_OF_STOCK"
        elif new_qty < item["reorder_threshold"]:
            item["status"] = "LOW_STOCK"
        else:
            item["status"] = "IN_STOCK"

        return _response(200, {"message": "Inventory updated", "inventory": item})

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
