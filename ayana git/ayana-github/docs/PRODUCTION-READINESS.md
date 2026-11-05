# Ayana — checklist de passage en production

## 1. Livraison nationale (MVP manuel)
1. L'administrateur crée les zones desservies (région, ville, quartier), tarif et fenêtre de livraison. Une zone sans tarif actif est non livrable.
2. Au checkout, le serveur vérifie stock, abonnement boutique, tarifs par destination et frais. Il crée une commande mère et une sous-commande + expédition par boutique.
3. Le back-office affecte chaque colis à un coursier partenaire et consigne la référence externe, le contact, le tarif et l'historique.
4. Le partenaire signale les étapes par le tableau d'administration ou un lien sécurisé à usage limité : pris en charge, en transit, en livraison, livré/échec/retour.
5. La livraison est clôturée avec code de remise ou preuve de livraison conforme à la procédure d'exploitation. Les données de géolocalisation restent optionnelles et limitées.
6. En cas d'échec, un motif obligatoire et une nouvelle tentative ou un retour sont enregistrés. Un colis livré ne peut pas être remis en transit sans action de correction autorisée et auditée.
7. Afficher un suivi client par code opaque ; ne jamais exposer les adresses ou téléphones des autres vendeurs/acheteurs.

## 2. Paiements
- Mobile Money : choisir d'abord le prestataire contractuel qui couvre le Niger et vérifier disponibilité XOF, signature des webhooks, annulations/remboursements, rapprochement, frais et règlement. Secrets uniquement côté serveur.
- Un retour navigateur ne constitue jamais une preuve de paiement. Vérifier l'événement signé ou interroger l'API du prestataire ; rendre la confirmation idempotente.
- Paiement à la livraison : enregistrer commande, montant dû, montant encaissé, date, collecteur et preuve ; rapprocher le cash par tournée/partenaire. Ne pas marquer une commande payée avant collecte constatée.
- Abonnement boutique : 5 000 XOF / 40 jours, pas de commission. Tant que le prestataire n'est pas raccordé, l'activation d'essai doit être auditée et limitée dans le temps. La durée d'essai est une décision Ayana à configurer.
- Clarifier avant mise en service : qui encaisse les frais de livraison et qui les reverse au transporteur ; traitement des frais si livraison échoue ; politique de remboursement/retour.

## 3. Abonnement et onboarding vendeur
- Vérification manuelle/KYC définie par Ayana avant statut boutique `active`.
- Essai avec dates de début/fin ; à l'expiration sans paiement vérifié, blocage des nouvelles ventes (catalogue non indexé, commandes en cours accessibles au support).
- Le statut et les périodes sont modifiables uniquement par un processus serveur sécurisé et journalisé.
- Les jours d'essai, conditions de renouvellement, reçus et éventuels proratas doivent être affichés sans ambiguïté.

## 4. Transporteurs et grille de zones
Avant lancement national, importer la couverture réelle des partenaires et les tarifs négociés. Ne pas accepter un checkout hors couverture. Prévoir des prix distincts par destination, poids/volume ou classe de produit lorsque le partenaire les facture ainsi. Ajouter les SLA, plafonds de responsabilité, colis perdus/endommagés et procédure de réclamation au contrat.

## 5. Contrôles techniques obligatoires
- Authentification avec vérification téléphone ou mécanisme alternatif fiable ; MFA obligatoire pour les comptes administrateurs.
- RLS testée avec comptes client, vendeur A, vendeur B, support, admin et anonyme.
- Création commande atomique avec idempotency key et verrouillage/réservation de stock.
- Validation server-side de tous montants, états et identifiants ; ne jamais faire confiance au total envoyé par le navigateur.
- Journaux d'audit append-only pour paiements, changement d'état et affectation de livraison.
- Sauvegarde/restauration testée, alertes d'erreurs, limitation de débit, protection anti-spam, politique de rétention et procédure d'incident.
- Tests automatisés de séparation des vendeurs, double callback paiement, double clic commande, annulation, stock concurrent et échec livraison.
- Pages conditions, confidentialité, retours, livraison et contact ; validation locale des obligations légales/fiscales et de protection des données.

## 6. Mise en service
- Utiliser des ressources cloud dédiées `Ayana`, jamais les projets d'autres applications.
- Configurer les secrets via le gestionnaire Supabase/Vercel, jamais dans le dépôt ou le client.
- Déployer d'abord en préproduction ; appliquer migration, tests RLS, test achat Mobile Money en sandbox, test cash-on-delivery et simulation de tournée.
- Le passage au domaine public intervient après validation des prestataires, des tarifs, des contrats, de la politique d'essai et des procédures de support.
