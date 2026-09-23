// =============================================================================
// AVP Policies — tool names use target name prefixes, NOT gateway names
// =============================================================================
// Tool naming: <TargetName>___<operationId>
//   ToS:       ToS-Lambda___get_terms_of_service, ToS-Lambda___accept_terms_of_service, etc.
//   Products:  Products-API-Gateway___getProducts
//   Sales:     Sales-API-Gateway___getSalesRecords, getSalesSummary, getSalesByProduct, getSalesByRegion
//   Reviews:   dynamodb-target___Query, dynamodb-target___Scan, dynamodb-target___GetItem, dynamodb-target___DescribeTable
//   Inventory: Inventory-MCP-Target___Inventory-API___getInventory

// Policy 1: Everyone — ToS + Products
permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    (resource.gateway == "ToS-Lambda" || resource.gateway == "Products-API-Gateway")
    && resource has gateway
};

// Policy 2: Admin — full access
permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    principal.role == "admin"
};

// Policy 3: Managers — Sales tools
permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    principal.role == "manager" &&
    resource.gateway == "Sales-API-Gateway" &&
    resource has gateway
};

// Policy 4: Managers — Customer Reviews (DynamoDB) tools
permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    principal.role == "manager" &&
    resource.gateway == "dynamodb-target" &&
    resource has gateway
};

// Policy 5: Suppliers — Inventory tool
permit(
    principal,
    action == RetailAgent::Action::"InvokeTool",
    resource
) when {
    principal.role == "supplier" &&
    resource.gateway == "Inventory-MCP-Target" &&
    resource has gateway
};
