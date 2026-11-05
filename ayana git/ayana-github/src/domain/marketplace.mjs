// Pure domain rules for server-side checkout and dispatch. No framework/dependency required.
export const DAY_MS = 86_400_000;
export const SELLER_SUBSCRIPTION_XOF = 5_000;
export const SELLER_PERIOD_DAYS = 40;

export const SHIPMENT_TRANSITIONS = Object.freeze({
  unassigned: ['assigned', 'cancelled'],
  assigned: ['pickup_scheduled', 'cancelled'],
  pickup_scheduled: ['picked_up', 'delivery_failed', 'cancelled'],
  picked_up: ['in_transit', 'out_for_delivery', 'delivery_failed'],
  in_transit: ['out_for_delivery', 'delivery_failed', 'returned'],
  out_for_delivery: ['delivered', 'delivery_failed'],
  delivery_failed: ['pickup_scheduled', 'returned'],
  delivered: [],
  returned: [],
  cancelled: [],
});

export function assertValidSubscription(subscription, now = new Date()) {
  if (!subscription) throw new Error('Boutique sans abonnement valide.');
  const valid = subscription.status === 'active'
    ? new Date(subscription.current_period_end) > now
    : subscription.status === 'trialing' && new Date(subscription.trial_ends_at) > now;
  if (!valid) throw new Error('Abonnement boutique expiré ou inactif.');
  return true;
}

export function nextSubscriptionPeriod(start = new Date()) {
  const from = new Date(start);
  return {
    amount_xof: SELLER_SUBSCRIPTION_XOF,
    period_days: SELLER_PERIOD_DAYS,
    current_period_start: from.toISOString(),
    current_period_end: new Date(from.getTime() + SELLER_PERIOD_DAYS * DAY_MS).toISOString(),
  };
}

/** Split one customer basket into one seller shipment per store. Rates are server-sourced. */
export function splitCheckout({ items, address, zone, now = new Date() }) {
  if (!Array.isArray(items) || items.length === 0) throw new Error('Le panier est vide.');
  if (!address?.recipient_name || !address?.phone || !address?.city || !address?.region || !address?.address_line) {
    throw new Error('Adresse de livraison incomplète.');
  }
  if (!zone?.active || !Number.isSafeInteger(zone.fee_xof) || zone.fee_xof < 0) {
    throw new Error('Cette destination n’est pas desservie.');
  }
  const byStore = new Map();
  for (const line of items) {
    const { product, quantity, subscription } = line;
    if (!product || !Number.isInteger(quantity) || quantity < 1) throw new Error('Article ou quantité invalide.');
    if (!product.active || product.stock_qty < quantity) throw new Error(`Stock indisponible : ${product?.name ?? 'article'}.`);
    if (!product.store?.active) throw new Error('Une boutique est indisponible.');
    assertValidSubscription(subscription, now);
    const storeId = product.store.id;
    const bucket = byStore.get(storeId) ?? { store_id: storeId, items: [], subtotal_xof: 0 };
    const lineTotal = product.price_xof * quantity;
    if (!Number.isSafeInteger(lineTotal)) throw new Error('Montant article invalide.');
    bucket.items.push({ product_id: product.id, product_name_snapshot: product.name, unit_price_xof: product.price_xof, quantity, line_total_xof: lineTotal });
    bucket.subtotal_xof += lineTotal;
    byStore.set(storeId, bucket);
  }
  // Delivery pricing may vary by partner/destination; this starter uses the selected zone rate per parcel.
  const sellerOrders = [...byStore.values()].map((bucket) => ({
    ...bucket,
    delivery_fee_xof: zone.fee_xof,
    seller_amount_xof: bucket.subtotal_xof, // Ayana takes no sales commission.
    shipment: { status: 'unassigned', zone_id: zone.id, fee_xof: zone.fee_xof },
  }));
  const subtotal_xof = sellerOrders.reduce((sum, order) => sum + order.subtotal_xof, 0);
  const delivery_total_xof = sellerOrders.reduce((sum, order) => sum + order.delivery_fee_xof, 0);
  return {
    address_snapshot: structuredClone(address),
    seller_orders: sellerOrders,
    subtotal_xof,
    delivery_total_xof,
    total_xof: subtotal_xof + delivery_total_xof,
  };
}

export function transitionShipment(shipment, nextStatus, { actorId, note, now = new Date() } = {}) {
  if (!shipment?.status || !Object.hasOwn(SHIPMENT_TRANSITIONS, shipment.status)) throw new Error('Statut de colis inconnu.');
  if (!SHIPMENT_TRANSITIONS[shipment.status].includes(nextStatus)) {
    throw new Error(`Transition de livraison interdite : ${shipment.status} → ${nextStatus}.`);
  }
  if (nextStatus === 'assigned' && !shipment.partner_id) throw new Error('Affectez un coursier avant le dispatch.');
  if (nextStatus === 'delivery_failed' && !note?.trim()) throw new Error('Le motif d’échec est obligatoire.');
  const updated = { ...shipment, status: nextStatus, updated_at: now.toISOString() };
  if (nextStatus === 'assigned') updated.assigned_at = now.toISOString();
  if (nextStatus === 'picked_up') updated.picked_up_at = now.toISOString();
  if (nextStatus === 'delivered') updated.delivered_at = now.toISOString();
  if (nextStatus === 'delivery_failed') updated.failed_reason = note.trim();
  return {
    shipment: updated,
    event: { event_type: nextStatus, note: note?.trim() || null, actor_id: actorId ?? null, created_at: now.toISOString() },
  };
}
