"use client";

import { useEffect, useState, Suspense } from "react";
import Link from "next/link";
import { useSearchParams } from "next/navigation";
import { useShop } from "../../ShopProvider";
import { addOrder, getCustomers } from "../../../api";

function SuccessContent() {
  const searchParams = useSearchParams();
  const orderTrackingId = searchParams.get("OrderTrackingId");
  const orderMerchantReference = searchParams.get("OrderMerchantReference");
  const { cartItems, cartTotal, selectedCustomerId, session, clearCart } = useShop();
  const [cleared, setCleared] = useState(false);

  useEffect(() => {
    if (!cleared && cartItems.length > 0) {
      const resolveCustomerId = async () => {
        if (selectedCustomerId) return selectedCustomerId;

        try {
          const response = await getCustomers();
          const customerList = Array.isArray(response?.data)
            ? response.data
            : Array.isArray(response)
              ? response
              : [];

          if (!customerList.length || !session?.phone) return "";

          const normalizePhone = (value: string) => value.replace(/\D/g, "");
          const sessionPhone = normalizePhone(session.phone);
          const matched = customerList.find((customer: any) => {
            return normalizePhone(customer.phone || "") === sessionPhone;
          });

          return matched?.id || "";
        } catch {
          return "";
        }
      };

      const saveOrder = async () => {
        const resolvedCustomerId = await resolveCustomerId();
        if (!resolvedCustomerId) {
          console.error("Failed to save order: missing customerId");
          clearCart();
          setCleared(true);
          return;
        }

        // Push the order to NestJS before clearing the cart
        addOrder({
          customerId: resolvedCustomerId,
          orderAmount: String(cartTotal),
          orderDate: new Date(),
          paymentMethod: "Pesapal",
          shippingAddress: "Default",
          status: "COMPLETED",
          items: cartItems.map((item) => ({
            productId: item.id,
            quantity: item.cartQuantity,
            unitCost: Number(item.unitCost),
          })),
        })
          .then(() => {
            clearCart();
            setCleared(true);
          })
          .catch((err) => {
            console.error("Failed to save order to database:", err);
            // Still clear the cart to avoid infinite loops on error
            clearCart();
            setCleared(true);
          });
      };

      saveOrder();
    } else if (!cleared && cartItems.length === 0) {
      // If landed with empty cart, just mark cleared
      setCleared(true);
    }
  }, [clearCart, cleared, cartItems, cartTotal, selectedCustomerId, session]);

  return (
    <div className="mx-auto max-w-2xl rounded-2xl border border-slate-200 bg-white p-8 text-center shadow-sm">
      <div className="mx-auto flex h-16 w-16 items-center justify-center rounded-full bg-emerald-100">
        <svg
          className="h-8 w-8 text-emerald-600"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth="2"
            d="M5 13l4 4L19 7"
          />
        </svg>
      </div>

      <h1 className="mt-6 text-3xl font-bold tracking-tight text-slate-900">
        Payment Confirmed!
      </h1>
      <p className="mt-2 text-slate-600">
        Thank you for your order. We are processing it and will update you shortly.
      </p>

      {(orderTrackingId || orderMerchantReference) && (
        <div className="mt-8 rounded-xl bg-slate-50 p-6 text-left">
          <h2 className="text-sm font-semibold uppercase tracking-wider text-slate-500">
            Order Details
          </h2>
          <div className="mt-4 space-y-3">
            {orderTrackingId && (
              <div className="flex justify-between">
                <span className="text-sm text-slate-600">Tracking ID</span>
                <span className="text-sm font-medium text-slate-900">
                  {orderTrackingId}
                </span>
              </div>
            )}
            {orderMerchantReference && (
              <div className="flex justify-between">
                <span className="text-sm text-slate-600">Reference</span>
                <span className="text-sm font-medium text-slate-900">
                  {orderMerchantReference}
                </span>
              </div>
            )}
          </div>
        </div>
      )}

      <div className="mt-8">
        <Link
          href="/shop/products"
          className="inline-block rounded-xl bg-slate-900 px-6 py-3 text-sm font-bold text-white transition hover:bg-slate-700"
        >
          Continue Shopping
        </Link>
      </div>
    </div>
  );
}

export default function CheckoutSuccessPage() {
  return (
    <section className="py-12">
      <Suspense fallback={
        <div className="text-center text-slate-600">Loading...</div>
      }>
        <SuccessContent />
      </Suspense>
    </section>
  );
}
