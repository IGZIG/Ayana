import test from 'node:test';
import assert from 'node:assert/strict';
import { assertValidSubscription, nextSubscriptionPeriod, splitCheckout, transitionShipment } from './marketplace.mjs';

const now = new Date('2026-11-05T00:00:00.000Z');
const address = { recipient_name: 'Amina', phone: '+22790000000', region: 'Niamey', city: 'Niamey', address_line: 'Quartier test' };
const subscription = { status: 'active', current_period_end: '2026-12-15T00:00:00.000Z' };
const product = (id, storeId, price = 2500) => ({ id, name: `Produit ${id}`, active: true, price_xof: price, stock_qty: 5, store: { id: storeId, active: true } });

test('abonnement vendeur: 5 000 XOF / 40 jours', () => {
  const period = nextSubscriptionPeriod(now);
  assert.equal(period.amount_xof, 5000);
  assert.equal(period.period_days, 40);
  assert.equal(new Date(period.current_period_end).toISOString(), '2026-12-15T00:00:00.000Z');
});

test('refuse un abonnement expiré', () => {
  assert.throws(() => assertValidSubscription({ status: 'active', current_period_end: '2026-10-01T00:00:00.000Z' }, now), /expiré/);
});

test('un panier multi-vendeurs crée des colis séparés, sans commission', () => {
  const result = splitCheckout({
    items: [
      { product: product('p1', 's1', 3000), quantity: 2, subscription },
      { product: product('p2', 's2', 7000), quantity: 1, subscription },
    ], address, zone: { id: 'z1', active: true, fee_xof: 1000 }, now,
  });
  assert.equal(result.seller_orders.length, 2);
  assert.equal(result.subtotal_xof, 13000);
  assert.equal(result.delivery_total_xof, 2000);
  assert.equal(result.total_xof, 15000);
  assert.equal(result.seller_orders[0].seller_amount_xof, result.seller_orders[0].subtotal_xof);
});

test('refuse une destination sans tarif actif', () => {
  assert.throws(() => splitCheckout({ items: [{ product: product('p1', 's1'), quantity: 1, subscription }], address, zone: { active: false, fee_xof: 0 }, now }), /pas desservie/);
});

test('dispatch exige un coursier et consigne les évènements', () => {
  assert.throws(() => transitionShipment({ status: 'unassigned' }, 'assigned', { now }), /Affectez un coursier/);
  const result = transitionShipment({ status: 'unassigned', partner_id: 'partner-1' }, 'assigned', { actorId: 'admin-1', now });
  assert.equal(result.shipment.status, 'assigned');
  assert.equal(result.event.event_type, 'assigned');
});

test('un échec de livraison requiert un motif', () => {
  assert.throws(() => transitionShipment({ status: 'out_for_delivery' }, 'delivery_failed', { now }), /motif/);
});
