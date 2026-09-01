#!/usr/bin/env python3
import datetime
import io
import json
import os
import sys
import urllib.request
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, "/app")

EXPECTED_PERMISSIONS = {
    "HANDLE_PAYMENTS", "HANDLE_CHECKOUTS", "MANAGE_CHECKOUTS", "MANAGE_ORDERS",
}
PRODUCT_SLUG = "terrahorse-e2e-test-product"
SKU = "TH-E2E-TEST-001"
WEBHOOK_NAME = "TerraHorse transaction initialize"


def required(name):
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name}-required")
    return value


def payment_subscription():
    source = Path(required("E2E_PAYMENT_OPERATION")).read_text()
    start = source.index("fragment SaleorTransactionInitializeSessionEvent")
    end = source.index("mutation SaleorPaymentOwnershipPrivateMetadataUpdate")
    return source[start:end].strip()


def write_runtime(values):
    target = Path(required("E2E_RUN_STATE_DIR")) / "runtime.env"
    temporary = target.with_suffix(".tmp")
    temporary.write_text("".join(f"{key}={value}\n" for key, value in values.items()))
    temporary.chmod(0o600)
    temporary.replace(target)


def seed():
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", "saleor.settings")
    import django

    django.setup()
    import graphene
    from django.core.management import call_command
    from django.db import transaction
    from django.utils import timezone
    from measurement.measures import Weight
    from saleor.account.models import Address
    from saleor.app.models import App
    from saleor.channel.models import Channel
    from saleor.product import ProductTypeKind
    from saleor.product.models import (
        Category,
        Product,
        ProductChannelListing,
        ProductType,
        ProductVariant,
        ProductVariantChannelListing,
    )
    from saleor.shipping.models import ShippingMethod, ShippingMethodChannelListing, ShippingZone
    from saleor.shipping.models import ShippingMethodType
    from saleor.tax.models import TaxConfiguration
    from saleor.warehouse.models import Stock, Warehouse
    from saleor.webhook.event_types import WebhookEventSyncType
    from saleor.webhook.models import Webhook, WebhookEvent

    with transaction.atomic():
        migration_defaults = [
            (Channel, {"name": "Default Channel", "slug": "default-channel"}),
            (Warehouse, {"name": "Default Warehouse", "slug": "default-warehouse"}),
            (ShippingZone, {"name": "Default"}),
            (Category, {"name": "Default Category", "slug": "default-category"}),
            (ProductType, {"name": "Default Type", "slug": "default-type"}),
        ]
        if Product.objects.exists() or App.objects.exists():
            raise RuntimeError("saleor-database-not-empty")
        for model, identity in migration_defaults:
            matches = model.objects.filter(**identity)
            if model.objects.count() != 1 or matches.count() != 1:
                raise RuntimeError("unexpected-saleor-migration-defaults")
        for model, identity in reversed(migration_defaults):
            model.objects.get(**identity).delete()

        channel = Channel.objects.create(
            name="TerraHorse E2E", slug="terrahorse-e2e", currency_code="EUR",
            default_country="LT", is_active=True, release_funds_for_expired_checkouts=True,
        )
        TaxConfiguration.objects.create(channel=channel, charge_taxes=False)
        address = Address.objects.create(
            company_name="TerraHorse E2E", street_address_1="Disposable fixture",
            city="Kaunas", postal_code="44248", country="LT", validation_skipped=True,
        )
        warehouse = Warehouse.objects.create(
            name="TerraHorse E2E Warehouse", slug="terrahorse-e2e",
            email="e2e@terrahorse.invalid", address=address,
        )
        warehouse.channels.add(channel)
        zone = ShippingZone.objects.create(name="TerraHorse E2E LT", countries=["LT"])
        zone.channels.add(channel)
        zone.warehouses.add(warehouse)

        shipping = []
        for name, amount in [
            ("TerraHorse E2E Venipak Parcel Locker", Decimal("3.49")),
            ("TerraHorse E2E Venipak Courier", Decimal("6.99")),
        ]:
            method = ShippingMethod.objects.create(
                name=name, type=ShippingMethodType.PRICE_BASED, shipping_zone=zone,
            )
            ShippingMethodChannelListing.objects.create(
                shipping_method=method, channel=channel, currency="EUR",
                minimum_order_price_amount=Decimal("0"), price_amount=amount,
            )
            shipping.append(method)

        category = Category.objects.create(
            name="TerraHorse Contract Test", slug="terrahorse-contract-test",
            metadata={"terrahorse.homepage.visible": "false"},
        )
        product_type = ProductType.objects.create(
            name="TerraHorse E2E Product", slug="terrahorse-e2e",
            kind=ProductTypeKind.NORMAL, has_variants=True, is_shipping_required=True,
        )
        product = Product.objects.create(
            name="TerraHorse E2E Test Product", slug=PRODUCT_SLUG,
            product_type=product_type, category=category,
        )
        ProductChannelListing.objects.create(
            product=product, channel=channel, currency="EUR", is_published=True,
            published_at=timezone.now(), visible_in_listings=True,
            available_for_purchase_at=timezone.now(), discounted_price_amount=Decimal("10.00"),
        )
        variant = ProductVariant.objects.create(
            product=product, name="1 kg", sku=SKU, weight=Weight(kg=1),
            metadata={
                "terrahorse.shipping.length_cm": "20",
                "terrahorse.shipping.width_cm": "15",
                "terrahorse.shipping.height_cm": "10",
            },
        )
        product.default_variant = variant
        product.save(update_fields=["default_variant"])
        ProductVariantChannelListing.objects.create(
            variant=variant, channel=channel, currency="EUR", price_amount=Decimal("10.00"),
            discounted_price_amount=Decimal("10.00"),
        )
        Stock.objects.create(product_variant=variant, warehouse=warehouse, quantity=10)

        output = io.StringIO()
        call_command(
            "create_app", "TerraHorse E2E Runtime", identifier="terrahorse-e2e",
            permissions=sorted(EXPECTED_PERMISSIONS), activate=True, stdout=output,
        )
        token = json.loads(output.getvalue())["auth_token"]
        app = App.objects.get(identifier="terrahorse-e2e")
        webhook = Webhook.objects.create(
            app=app, name=WEBHOOK_NAME, is_active=True,
            target_url="https://e2e.terrahorse.lt/api/payments/saleor/initialize",
            secret_key=required("SALEOR_PAYMENT_WEBHOOK_SECRET"),
            subscription_query=payment_subscription(), custom_headers={},
        )
        WebhookEvent.objects.create(
            webhook=webhook, event_type=WebhookEventSyncType.TRANSACTION_INITIALIZE_SESSION,
        )

    write_runtime({
        "SALEOR_API_URL": "http://saleor-api:8000/graphql/",
        "SALEOR_COMMERCE_APP_TOKEN": token,
        "SALEOR_PAYMENT_APP_ID": graphene.Node.to_global_id("App", app.pk),
        "SALEOR_PAYMENT_GATEWAY_ID": app.identifier,
        "SALEOR_VENIPAK_PARCEL_LOCKER_METHOD_ID": graphene.Node.to_global_id("ShippingMethod", shipping[0].pk),
        "SALEOR_VENIPAK_COURIER_METHOD_ID": graphene.Node.to_global_id("ShippingMethod", shipping[1].pk),
    })
    print("Disposable Saleor fixture seeded.")


def graphql(query, variables=None):
    runtime = {}
    for line in Path(required("E2E_RUNTIME_ENV_FILE")).read_text().splitlines():
        key, value = line.split("=", 1)
        runtime[key] = value
    request = urllib.request.Request(
        required("SALEOR_E2E_API_URL"),
        data=json.dumps({"query": query, "variables": variables or {}}).encode(),
        headers={
            "content-type": "application/json",
            "authorization": f"Bearer {runtime['SALEOR_COMMERCE_APP_TOKEN']}",
        },
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        body = json.load(response)
    if body.get("errors"):
        error = body["errors"][0]
        raise RuntimeError(f"saleor-graphql-failure:{error['message']}:{error.get('path')}")
    return body["data"], runtime


def mutation_result(data, key):
    result = data[key]
    if result.get("errors"):
        raise RuntimeError(f"{key}-failed:{result['errors'][0]['code']}")
    return result


def verify():
    subscription = " ".join(payment_subscription().split())
    data, runtime = graphql("""query($slug:String!,$channel:String!){
      shop{version} app{id identifier name isActive permissions{code} webhooks{
        name isActive targetUrl customHeaders subscriptionQuery syncEvents{eventType} asyncEvents{eventType}}}
      product(slug:$slug,channel:$channel){slug category{slug metadata{key value}}
        productType{slug hasVariants isShippingRequired} productVariants(first:2){edges{node{
          id sku weight{unit value} metadata{key value} quantityAvailable pricing{price{gross{amount currency}}}}}}}
    }""", {"slug": PRODUCT_SLUG, "channel": "terrahorse-e2e"})
    if not data["shop"]["version"].startswith("3.23."):
        raise RuntimeError("unexpected-saleor-version")
    app = data["app"]
    if (
        app["id"] != runtime["SALEOR_PAYMENT_APP_ID"]
        or app["identifier"] != "terrahorse-e2e"
        or app["name"] != "TerraHorse E2E Runtime"
        or not app["isActive"]
        or {item["code"] for item in app["permissions"]} != EXPECTED_PERMISSIONS
    ):
        raise RuntimeError("runtime-app-identity-mismatch")
    if len(app["webhooks"]) != 1:
        raise RuntimeError("runtime-webhook-count-mismatch")
    webhook = app["webhooks"][0]
    if webhook["name"] != WEBHOOK_NAME or not webhook["isActive"]:
        raise RuntimeError("runtime-webhook-state-mismatch")
    if webhook["targetUrl"] != "https://e2e.terrahorse.lt/api/payments/saleor/initialize":
        raise RuntimeError("runtime-webhook-target-mismatch")
    if webhook["customHeaders"] not in ({}, "{}", None):
        raise RuntimeError("runtime-webhook-headers-mismatch")
    if " ".join(webhook["subscriptionQuery"].split()) != subscription:
        raise RuntimeError("runtime-webhook-subscription-mismatch")
    if [event["eventType"] for event in webhook["syncEvents"]] != ["TRANSACTION_INITIALIZE_SESSION"]:
        raise RuntimeError("runtime-webhook-sync-events-mismatch")
    if webhook["asyncEvents"]:
        raise RuntimeError("runtime-webhook-async-events-mismatch")
    product = data["product"]
    variant = product["productVariants"]["edges"][0]["node"]
    metadata = {item["key"]: item["value"] for item in variant["metadata"]}
    category_metadata = {item["key"]: item["value"] for item in product["category"]["metadata"]}
    if product["slug"] != PRODUCT_SLUG or product["category"]["slug"] != "terrahorse-contract-test":
        raise RuntimeError("fixture-product-identity-mismatch")
    if category_metadata.get("terrahorse.homepage.visible") != "false":
        raise RuntimeError("fixture-hidden-category-mismatch")
    if product["productType"] != {"slug": "terrahorse-e2e", "hasVariants": True, "isShippingRequired": True}:
        raise RuntimeError("fixture-product-type-mismatch")
    if variant["sku"] != SKU or variant["weight"] != {"unit": "KG", "value": 1.0}:
        raise RuntimeError("fixture-variant-identity-mismatch")
    if variant["quantityAvailable"] != 10:
        raise RuntimeError("fixture-stock-mismatch")
    if variant["pricing"]["price"]["gross"] != {"amount": 10.0, "currency": "EUR"}:
        raise RuntimeError("fixture-price-mismatch")
    if metadata != {
        "terrahorse.shipping.length_cm": "20", "terrahorse.shipping.width_cm": "15",
        "terrahorse.shipping.height_cm": "10",
    }:
        raise RuntimeError("fixture-dimensions-mismatch")

    checkout_id = None
    try:
        created, _ = graphql("""mutation($input:CheckoutCreateInput!){checkoutCreate(input:$input){
          checkout{id} errors{code}}}""", {"input": {"channel": "terrahorse-e2e", "lines": [{"variantId": variant["id"], "quantity": 1}]}})
        checkout_id = mutation_result(created, "checkoutCreate")["checkout"]["id"]
        addressed, _ = graphql("""mutation($id:ID!,$address:AddressInput!){checkoutShippingAddressUpdate(
          id:$id,shippingAddress:$address){checkout{shippingMethods{id name price{amount currency}}} errors{code}}}""",
          {"id": checkout_id, "address": {"firstName": "E2E", "lastName": "Test", "streetAddress1": "E2E Test", "city": "Kaunas", "postalCode": "44248", "country": "LT"}})
        methods = mutation_result(addressed, "checkoutShippingAddressUpdate")["checkout"]["shippingMethods"]
        expected = {
            runtime["SALEOR_VENIPAK_PARCEL_LOCKER_METHOD_ID"]: ("TerraHorse E2E Venipak Parcel Locker", 3.49),
            runtime["SALEOR_VENIPAK_COURIER_METHOD_ID"]: ("TerraHorse E2E Venipak Courier", 6.99),
        }
        actual = {item["id"]: (item["name"], item["price"]["amount"]) for item in methods}
        if actual != expected or any(item["price"]["currency"] != "EUR" for item in methods):
            raise RuntimeError("checkout-delivery-methods-mismatch")
    finally:
        if checkout_id:
            deleted, _ = graphql("mutation($id:ID!){checkoutDelete(id:$id){errors{code}}}", {"id": checkout_id})
            mutation_result(deleted, "checkoutDelete")
            reread, _ = graphql("query($id:ID!){checkout(id:$id){id}}", {"id": checkout_id})
            if reread["checkout"] is not None:
                raise RuntimeError("checkout-cleanup-reread-failed")
    print("Private Saleor fixture, app, webhook and disposable checkout verified.")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in {"seed", "verify"}:
        raise SystemExit("usage: saleor-e2e.py seed|verify")
    seed() if sys.argv[1] == "seed" else verify()
