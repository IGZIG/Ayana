# Ayana — Marketplace multi-vendeurs

MVP Ayana pour le Niger : catalogue multi-catégories, vendeurs sur abonnement, checkout multi-vendeur et livraison par partenaires.

## État actuel
- Interface statique mobile-first, raccordée en lecture à Supabase.
- Authentification e-mail/mot de passe, demande vendeur et checkout COD via RPC Supabase.
- Abonnement vendeur : 5 000 FCFA / 40 jours, sans commission sur les ventes.
- Une commande multi-boutiques est découpée en sous-commandes et colis séparés.
- Paiement Mobile Money non activé tant que le prestataire n’est pas choisi.
- La configuration du domaine Auth, les produits et les tarifs de zones restent à établir avant les commandes réelles.

## Supabase
Projet utilisé : `Ayana` (`egqvgzcggmynzzlfzewh`, région `eu-west-1`). Les migrations sont ordonnées selon l’historique appliqué :
1. `20261105005951_ayana_marketplace_core.sql`
2. `20261105013451_ayana_secure_flows.sql`
3. `20261105013814_ayana_rpc_permissions.sql`

L’interface contient l’URL Supabase et une clé **publishable** destinée à l’usage navigateur. Ne jamais y ajouter de clé `service_role` ou de secret fournisseur. Toutes les opérations privilégiées restent protégées côté base par RLS/RPC.

Avant l’inscription publique, configurer `site_url` et l’allowlist Auth avec le domaine de production. Avant le checkout, créer les zones tarifées et publier les produits/vendeurs validés.

## Développement local
Prérequis : Node.js 20+ et Python 3.

```bash
npm test
npm run dev
```

Puis ouvrir `http://localhost:8000`. CORS et Auth redirects doivent également autoriser cette origine pour tester l’inscription.

## Déploiement Vercel
Le projet Vercel `ayana` a été créé séparément. Pour publier ce dépôt, connecter le repo dans Vercel ou utiliser la CLI après authentification :

```bash
npx vercel link --project ayana
npx vercel --prod
```

Après le premier déploiement, reporter l’URL stable Vercel dans Supabase Auth (`site_url` et allowlist). Vérifier les procédures et les prérequis dans `docs/PRODUCTION-READINESS.md`.
