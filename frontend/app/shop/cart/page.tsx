"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import toast from "react-hot-toast";
import { addOrder, getCustomers } from "../../api";
import { CustomersType } from "../../types/CustomersType";
import { useShop } from "../ShopProvider";

export default function ShopCartPage() {
  const {
    cartItems,
    session,
    selectedCustomerId,
    setSelectedCustomerId,
    updateCartQuantity,
    removeFromCart,
    clearCart,
    cartTotal,
  } = useShop();

  const [customers, setCustomers] = useState<CustomersType[]>([]);
  const [isCheckingOut, setIsCheckingOut] = useState(false);

  useEffect(() => {
    const loadCustomers = async () => {
      try {
        const response = await getCustomers();
        const customerList = Array.isArray(response?.data)
          ? response.data
          : Array.isArray(response)
          ? response
          : [];
        setCustomers(customerList);

        if (!selectedCustomerId && customerList.length > 0) {
          setSelectedCustomerId(customerList[0].id);
        }
      } catch {
        toast.error("Unable to load customers for checkout.");
      }
    };

    loadCustomers();
  }, [selectedCustomerId, setSelectedCustomerId]);

  const selectedCustomer = useMemo(
    () => customers.find((customer) => customer.id === selectedCustomerId),
    [customers, selectedCustomerId]
  );

  const onCheckout = async () => {
    if (cartItems.length === 0) {
      toast.error("Your cart is empty.");
      return;
    }

    if (!session?.sessionId) {
      toast.error("Agent session is not initialized. Please refresh.");
      return;
    }

    setIsCheckingOut(true);

    try {
      // Call the Express service to initiate Pesapal payment
      const { checkoutCartApi } = await import("../../api");
      const checkoutResponse = await checkoutCartApi(session.sessionId);

      if (checkoutResponse.redirectUrl) {
        // Redirect browser to the Pesapal iframe/hosted page
        window.location.href = checkoutResponse.redirectUrl;
      } else {
        toast.error("No redirect URL returned from payment service.");
        setIsCheckingOut(false);
      }
    } catch (error: any) {
      toast.error(error?.response?.data?.message || "Checkout failed. Could not connect to payment service.");
      setIsCheckingOut(false);
    }
  };

  return (
    <section className="space-y-6">
      <div>
        <h1 className="text-3xl font-bold tracking-tight">Cart</h1>
        <p className="mt-2 text-sm text-slate-600">
          Review your selected items and run a checkout.
        </p>
      </div>

      {cartItems.length === 0 ? (
        <div className="rounded-2xl border border-slate-200 bg-white p-8 text-center shadow-sm">
          <p className="text-slate-600">Your cart is empty.</p>
          <Link
            href="/shop/products"
            className="mt-4 inline-block rounded-full bg-slate-900 px-5 py-2 text-sm font-semibold text-white transition hover:bg-slate-700"
          >
            Continue Shopping
          </Link>
        </div>
      ) : (
        <div className="grid gap-6 lg:grid-cols-[1.5fr_1fr]">
          <div className="space-y-3">
            {cartItems.map((item) => (
              <article
                key={item.id}
                className="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"
              >
                <div className="flex flex-wrap items-center justify-between gap-2">
                  <h2 className="text-lg font-bold text-slate-900">{item.name}</h2>
                  <button
                    type="button"
                    onClick={() => removeFromCart(item.id)}
                    className="text-sm font-semibold text-rose-600 hover:text-rose-500"
                  >
                    Remove
                  </button>
                </div>

                <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
                  <p className="text-sm text-slate-600">
                    KES {Number(item.unitCost).toLocaleString()} each
                  </p>

                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => updateCartQuantity(item.id, item.cartQuantity - 1)}
                      className="h-8 w-8 rounded-full border border-slate-300 text-sm font-bold text-slate-700"
                    >
                      -
                    </button>
                    <span className="min-w-8 text-center text-sm font-semibold">
                      {item.cartQuantity}
                    </span>
                    <button
                      type="button"
                      onClick={() => updateCartQuantity(item.id, item.cartQuantity + 1)}
                      className="h-8 w-8 rounded-full border border-slate-300 text-sm font-bold text-slate-700"
                    >
                      +
                    </button>
                  </div>
                </div>
              </article>
            ))}
          </div>

          <aside className="h-fit rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
            <h2 className="text-lg font-bold text-slate-900">Checkout Summary</h2>

            <div className="mt-4 rounded-xl bg-slate-50 p-4 text-sm text-slate-700">
              <p className="mt-2 text-lg font-bold text-slate-900">
                Total: KES {cartTotal.toLocaleString()}
              </p>
            </div>

            <button
              type="button"
              disabled={isCheckingOut}
              onClick={onCheckout}
              className="mt-4 w-full rounded-xl bg-emerald-500 px-4 py-3 text-sm font-bold text-white transition hover:bg-emerald-600 disabled:cursor-not-allowed disabled:bg-emerald-300"
            >
              {isCheckingOut ? "Processing..." : "Checkout via Pesapal"}
            </button>
          </aside>
        </div>
      )}
    </section>
  );
}
