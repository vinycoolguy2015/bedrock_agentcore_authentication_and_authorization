"""
Activity 3: Sales Records Lambda
Exposed via Amazon API Gateway.
Auth: API Key
"""

import json
from datetime import datetime, timedelta
import random

SALES_RECORDS = [
    {"sale_id": "SALE-1001", "product_id": "PROD-001", "quantity": 2, "unit_price": 249.99, "total": 499.98, "date": "2025-06-01", "region": "US-East"},
    {"sale_id": "SALE-1002", "product_id": "PROD-002", "quantity": 5, "unit_price": 34.99, "total": 174.95, "date": "2025-06-01", "region": "US-West"},
    {"sale_id": "SALE-1003", "product_id": "PROD-003", "quantity": 3, "unit_price": 29.99, "total": 89.97, "date": "2025-06-02", "region": "EU-West"},
    {"sale_id": "SALE-1004", "product_id": "PROD-005", "quantity": 1, "unit_price": 129.99, "total": 129.99, "date": "2025-06-02", "region": "US-East"},
    {"sale_id": "SALE-1005", "product_id": "PROD-001", "quantity": 1, "unit_price": 249.99, "total": 249.99, "date": "2025-06-03", "region": "AP-Southeast"},
    {"sale_id": "SALE-1006", "product_id": "PROD-004", "quantity": 4, "unit_price": 149.99, "total": 599.96, "date": "2025-06-03", "region": "US-West"},
    {"sale_id": "SALE-1007", "product_id": "PROD-002", "quantity": 10, "unit_price": 34.99, "total": 349.90, "date": "2025-06-04", "region": "EU-West"},
    {"sale_id": "SALE-1008", "product_id": "PROD-003", "quantity": 2, "unit_price": 29.99, "total": 59.98, "date": "2025-06-04", "region": "US-East"},
]


def handler(event, context):
    http_method = event.get("httpMethod", event.get("requestContext", {}).get("http", {}).get("method", "GET"))
    path = event.get("path", event.get("rawPath", "/"))
    query = event.get("queryStringParameters") or {}

    if http_method == "GET":
        if "summary" in path:
            return _response(200, _get_summary())
        if "by-product" in path:
            return _response(200, _get_by_product(query.get("product_id")))
        if "by-region" in path:
            return _response(200, _get_by_region(query.get("region")))
        return _response(200, {"sales": SALES_RECORDS, "count": len(SALES_RECORDS)})

    return _response(400, {"error": "Invalid request"})


def _get_summary():
    total_revenue = sum(s["total"] for s in SALES_RECORDS)
    total_units = sum(s["quantity"] for s in SALES_RECORDS)
    return {
        "summary": {
            "total_revenue": round(total_revenue, 2),
            "total_units_sold": total_units,
            "total_transactions": len(SALES_RECORDS),
            "average_order_value": round(total_revenue / len(SALES_RECORDS), 2)
        }
    }


def _get_by_product(product_id=None):
    grouped = {}
    for s in SALES_RECORDS:
        pid = s["product_id"]
        if product_id and pid != product_id:
            continue
        if pid not in grouped:
            grouped[pid] = {"product_id": pid, "total_revenue": 0, "total_units": 0, "transactions": 0}
        grouped[pid]["total_revenue"] = round(grouped[pid]["total_revenue"] + s["total"], 2)
        grouped[pid]["total_units"] += s["quantity"]
        grouped[pid]["transactions"] += 1
    return {"sales_by_product": list(grouped.values())}


def _get_by_region(region=None):
    grouped = {}
    for s in SALES_RECORDS:
        r = s["region"]
        if region and r != region:
            continue
        if r not in grouped:
            grouped[r] = {"region": r, "total_revenue": 0, "total_units": 0, "transactions": 0}
        grouped[r]["total_revenue"] = round(grouped[r]["total_revenue"] + s["total"], 2)
        grouped[r]["total_units"] += s["quantity"]
        grouped[r]["transactions"] += 1
    return {"sales_by_region": list(grouped.values())}


def _response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Access-Control-Allow-Origin": "*"
        },
        "body": json.dumps(body)
    }
